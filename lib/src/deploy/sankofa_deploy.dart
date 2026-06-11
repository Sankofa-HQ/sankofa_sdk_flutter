import 'dart:async' show Timer;
import 'dart:convert' show jsonEncode;
import 'dart:io' show Directory, File, Platform;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/module_registry.dart';
import 'deploy_config.dart';
import 'deploy_platform_interface.dart';
import 'kbc_loader.dart' show KbcApplyException;
// Prefix-imported so the SankofaDeploy instance methods named
// applyKbcPatchFromBytes / applyKbcPatchFromFile / fetchAndApplyKbcPatch
// don't shadow the top-level helpers they delegate to — without the
// prefix, calling `applyKbcEnvelope(...)` inside an instance method
// resolves to `this.applyKbcEnvelope(...)` and recurses infinitely
// (proven by hello_sankofa's "Unexpected error: Stack Overflow"
// after the η-polish prefer-SDK-path wiring landed).
import 'kbc_envelope.dart' show parseKbcEnvelope, KbcSigAlg;
import 'kbc_fetch.dart' as kbc_fetch;
import 'kbc_loader.dart' as kbc_loader;
import 'kbc_loader.dart' show KbcPatchResult, KbcLoaderFn;
import 'kbc_fetch.dart' show KbcFetchResult;
import 'sankofa_update.dart';
import 'update_status.dart';

/// Read-only view of a KBC patch staged on disk — what
/// [SankofaDeploy.getStagedKbcPatchInfo] returns. Lets dashboards /
/// support / debug screens surface which patch a device is on without
/// re-running the interpreter.
class KbcStagedPatchInfo {
  const KbcStagedPatchInfo({
    required this.path,
    required this.sizeBytes,
    required this.modifiedAt,
    required this.label,
    required this.engineCommit,
    required this.dartVersion,
    required this.targetBinaryVersion,
    required this.signed,
    this.parseError = false,
  });

  /// Absolute on-device path of the staged envelope.
  final String path;

  /// envelope file size in bytes (sha-256 NOT recomputed — that's a
  /// full [applyKbcEnvelope] call's job).
  final int sizeBytes;

  /// When the envelope file was last written (= when the most recent
  /// fetch + persist happened).
  final DateTime modifiedAt;

  /// Producer-set patch label from envelope metadata (e.g.
  /// `tier-b-v2-signed-1`). Null when metadata is missing or the
  /// envelope failed to parse.
  final String? label;

  /// Producer-set Sankofa engine fork commit. Useful for rolling
  /// "which engine revision shipped this patch?" up to dashboards.
  final String? engineCommit;

  /// Dart SDK version the patch was built against (e.g. `3.11.5`).
  /// Must match the engine's Platform.version minor for apply to
  /// succeed; ζ.1 enforces this.
  final String? dartVersion;

  /// Host app binary version the patch is bound to (e.g. `1.0.0`).
  final String? targetBinaryVersion;

  /// True iff the envelope carries an Ed25519 signature in the trailer.
  /// (Whether that signature would VERIFY against the host's known
  /// pubkeys is a separate question — call [applyKbcPatchFromBytes] or
  /// [tryApplyStagedKbcPatch] to actually run the check.)
  final bool signed;

  /// True when the envelope on disk failed to parse — the fields above
  /// are best-effort placeholders. Indicates the patch is unusable;
  /// the host should delete it and fall back to baseline.
  final bool parseError;
}

/// Sankofa Deploy — Flutter Code OTA updates.
///
/// Constructed automatically by `Sankofa.init(enableDeploy: true)` and
/// exposed via [Sankofa.deploy]. Mirrors the React-Native SDK's
/// `SankofaDeploy` class but renamed to be a real instance (not a
/// static-only class) so the namespaced access pattern
/// `Sankofa.deploy.notifyAppReady()` reads as expected.
///
/// **Server overrides client.** The host's `enableDeploy: true` flag in
/// `Sankofa.init` is an *intent* — the SDK constructs the module and
/// registers it with [SankofaModuleRegistry]. The handshake response
/// from `GET /api/v1/handshake` includes a `modules.deploy.enabled`
/// boolean and (when enabled) any pending update payload. If the
/// server says `enabled: false` (subscription suspended, project
/// disabled, kill-switch flipped) the registry skips routing — the
/// module receives no instructions and the host's
/// `Sankofa.deploy.checkForUpdate()` call goes through the platform
/// plugin's own HTTP fetch, which the server also refuses on the
/// server side. Either way the host can't ship updates the server
/// hasn't authorized.
///
/// The OTA mechanism itself lives in:
///   • `libsankofa_updater_ffi.so` (Rust updater bundled in the AAB
///     via the plugin's jniLibs) — does the SHA-verified libapp.so
///     download + atomic install + boot-counter rollback;
///   • `SankofaFlutterActivity` (Kotlin) — overrides
///     `getFlutterShellArgs()` to add `--aot-shared-library-name=...`
///     pointing at the patched libapp.so when one is staged.
///
/// This Dart class is just the host-facing API around those pieces.
class SankofaDeploy implements SankofaModule {
  SankofaDeploy._({required this.options});

  // ── SankofaModule (Traffic Cop hook) ──────────────────────────────

  @override
  SankofaModuleName get name => SankofaModuleName.deploy;

  /// Called by [SankofaModuleRegistry.routeHandshake] when the server
  /// returns a non-empty `modules.deploy` payload AND that payload's
  /// `enabled` field is true. The registry skips this entirely when
  /// the server says `enabled: false` — there's no kill-switch path
  /// here because there's no opt-out: the server simply refuses to
  /// issue patches for disabled customers.
  ///
  /// The current implementation no-ops; the platform plugin's own
  /// fetch is the authoritative path for the install. A future
  /// optimization can use the unified handshake's pre-fetched payload
  /// (download_url + sha256 + label) to skip the second round-trip.
  @override
  Future<void> applyHandshake(Map<String, dynamic> config) async {
    // v2.2 — always read signing_keys, even when the module is disabled
    // for THIS device's current request (e.g. has_update=false). The
    // pubkeys are project-scoped, not request-scoped, and a future
    // apply call in this session needs them ready.
    final rawKeys = config['signing_keys'];
    if (rawKeys is List) {
      final out = <String>[];
      for (final entry in rawKeys) {
        if (entry is Map) {
          final pk = entry['pubkey_b64'];
          if (pk is String && pk.isNotEmpty) {
            out.add(pk);
          }
        }
      }
      _serverSigningKeysB64 = List.unmodifiable(out);
      if (kDebugMode && out.isNotEmpty) {
        debugPrint('[Sankofa.deploy] handshake cached ${out.length} server signing key(s)');
      }
    }
    if (config['enabled'] == false) return;
    // Future: if config['has_update'] == true, feed the
    // download_url + sha256 + label + size into the platform plugin
    // so the Rust updater can install without an extra fetch.
    // For now we let the platform plugin's checkForUpdate() handle it.
    if (kDebugMode) {
      final hasUpdate = config['has_update'] == true;
      final label = config['label'] as String?;
      if (hasUpdate) {
        debugPrint('[Sankofa.deploy] handshake reports pending update: $label');
      }
    }
  }

  /// Singleton — assigned during [Sankofa.init] when `enableDeploy: true`.
  /// `Sankofa.deploy` returns this; legacy code that needs static
  /// access can read `SankofaDeploy.instance`.
  static SankofaDeploy? _instance;
  static SankofaDeploy? get instance => _instance;

  // ── Chain-safety auto-confirm timer (RN parity) ───────────────────
  //
  // Mirrors the React-Native SDK's `HEALTH_CONFIRM_MS = 10_000` safety
  // net (see `sankofa_sdk_react_native/src/deploy/SankofaDeploy.ts`).
  // After a patch successfully applies on cold boot, we start a 10s
  // timer that auto-acks the patch if the host never calls
  // [notifyKbcPatchReady] explicitly. This removes the "customer
  // forgot to wire notifyKbcPatchReady" footgun — a clean app that
  // renders fine for 10s is treated as proof the patch is healthy.
  //
  // [notifyKbcPatchReady] cancels this timer and confirms manually,
  // so apps that DO wire it still get exact "first-frame ready"
  // semantics.
  Timer? _autoConfirmTimer;
  static const Duration kKbcAutoConfirmDelay = Duration(seconds: 10);

  final SankofaDeployOptions options;
  bool _ready = false;

  /// v2.2 — pubkeys distributed by the server via /api/v1/handshake's
  /// `modules.deploy.signing_keys` payload. Populated in [applyHandshake];
  /// merged with [SankofaDeployOptions.signingPubkeyB64] (compile-time
  /// trust root, if any) at envelope-verify time. Lets a project rotate
  /// signing keys server-side without a host-app rebuild.
  ///
  /// Empty until the first handshake succeeds. If the host app embedded
  /// a pubkey AND the server hasn't enrolled keys yet, envelopes still
  /// verify against the embedded key only — graceful adoption path.
  List<String> _serverSigningKeysB64 = const <String>[];

  /// Cached at init so apply / rollback / boot-apply paths can fire
  /// `/api/deploy/report` events without needing to walk back through
  /// `Sankofa.instance` (which would create a circular module dep). Set
  /// once in [initInternal]; never rotated — endpoint changes require
  /// re-initializing the SDK.
  String? _ingestEndpoint;
  String? _ingestApiKey;

  /// App version captured at init. Drives the `app_version` query
  /// parameter on `/api/deploy/check` so the host doesn't have to
  /// re-supply it on every call. `Sankofa.init(appVersion: ...)`
  /// flows in here; `Sankofa.bootstrap` reads it from `pubspec.yaml`
  /// via `package_info_plus` and forwards.
  String? _defaultAppVersion;

  /// Callback that returns the device's current distinct ID. Sourced
  /// from `Sankofa.instance.identity?.distinctId` so the same ID the
  /// analytics module uses also drives rollout hashing for patches.
  /// A callback (rather than a captured string) keeps the resolved
  /// value fresh across `identify()` / `reset()` calls.
  String Function()? _distinctIdResolver;

  /// Resolve a runtime platform string. Defaults to `'ios'` /
  /// `'android'` via Platform.is*; can be overridden via
  /// [SankofaDeployOptions.platformOverride] for tests.
  String get _effectivePlatform {
    final override = options.platformOverride;
    if (override != null && override.isNotEmpty) return override;
    if (Platform.isIOS) return 'ios';
    if (Platform.isAndroid) return 'android';
    return 'ios';
  }

  String _resolveDistinctId(String? explicit) {
    if (explicit != null && explicit.isNotEmpty) return explicit;
    try {
      final fromResolver = _distinctIdResolver?.call();
      if (fromResolver != null && fromResolver.isNotEmpty) {
        return fromResolver;
      }
    } catch (_) {
      /* fall through */
    }
    return 'anonymous';
  }

  String _resolveAppVersion(String? explicit) {
    if (explicit != null && explicit.isNotEmpty) return explicit;
    if (_defaultAppVersion != null && _defaultAppVersion!.isNotEmpty) {
      return _defaultAppVersion!;
    }
    throw StateError(
      'Sankofa.deploy: no appVersion in scope. Pass appVersion to '
      'Sankofa.init() OR supply it directly to the check / download / '
      'fetch call.',
    );
  }

  String _resolveEngineVersion(String? explicit) {
    if (explicit != null && explicit.isNotEmpty) return explicit;
    final fromOptions = options.engineVersion;
    if (fromOptions != null && fromOptions.isNotEmpty) return fromOptions;
    throw StateError(
      'Sankofa.deploy: no engineVersion in scope. Set engineVersion on '
      'SankofaDeployOptions at init time (or via Sankofa.bootstrap, '
      'which reads it from sankofa.yaml) OR pass it directly to the '
      'check / download / fetch call.',
    );
  }

  String _resolveEndpoint(String? explicit) {
    if (explicit != null && explicit.isNotEmpty) return explicit;
    if (_ingestEndpoint != null && _ingestEndpoint!.isNotEmpty) {
      return _ingestEndpoint!;
    }
    throw StateError('Sankofa.deploy: endpoint missing (called before init?).');
  }

  String _resolveApiKey(String? explicit) {
    if (explicit != null && explicit.isNotEmpty) return explicit;
    if (_ingestApiKey != null && _ingestApiKey!.isNotEmpty) {
      return _ingestApiKey!;
    }
    throw StateError('Sankofa.deploy: apiKey missing (called before init?).');
  }

  /// Snapshot of the active server-distributed signing keys. Exposed
  /// mostly for debugging — production code never has to read this
  /// because the apply pipeline pulls it via [_effectiveSigningPubkeys].
  List<String> get serverSigningKeysB64 => List.unmodifiable(_serverSigningKeysB64);

  /// Merge of the host-embedded pubkey + server-distributed pubkeys.
  /// Order: embedded first (matches first → fastest path for the common
  /// "single key" case); server keys after. Caller passes this to
  /// `verifyKbcEnvelopeSignature` which iterates with any-match semantics.
  List<String> get _effectiveSigningPubkeys {
    final embedded = options.signingPubkeyB64;
    if (embedded == null || embedded.isEmpty) {
      return _serverSigningKeysB64;
    }
    if (_serverSigningKeysB64.isEmpty) {
      return <String>[embedded];
    }
    return <String>[embedded, ..._serverSigningKeysB64];
  }

  /// Internal hook used by `Sankofa.init` — DO NOT call directly. The
  /// per-product `enableDeploy` flag triggers this. Idempotent.
  ///
  /// **Native platform plugin init is best-effort.** When the platform
  /// plugin's initialize() throws (e.g. on iOS Path C where the native
  /// half of the libapp.so binary-diff updater doesn't exist),
  /// `_instance` is still set + `_ready` is left false. Pure-Dart
  /// methods (the KBC patch apply pipeline — `applyKbcPatchFromBytes`,
  /// `applyKbcPatchFromFile`, `fetchAndApplyKbcPatch`) don't gate on
  /// `_ready` and remain usable. Methods that DO require the platform
  /// plugin (Android baseline OTA — `checkForUpdate`, `notifyAppReady`,
  /// `reportCrash`, `disableCurrentPatch`, `getActiveVersion`,
  /// `getCurrentLibappPath`) throw via `_assertReady()` with a clear
  /// message explaining the platform is unavailable.
  ///
  /// Before η polish (2026-05-24): platform-init failure inside the
  /// `unawaited()` wrapper that calls this function would silently
  /// leave `_instance == null` and `Sankofa.deploy` returned null —
  /// hello_sankofa hit this on iOS, fell back to the standalone
  /// `applyKbcEnvelopeFromFile` helper.
  static Future<SankofaDeploy> initInternal({
    required String apiKey,
    required String endpoint,
    required SankofaDeployOptions options,
    String? appVersion,
    String Function()? distinctIdResolver,
  }) async {
    if (_instance != null) return _instance!;
    final deploy = SankofaDeploy._(options: options);
    deploy._ingestEndpoint = endpoint;
    deploy._ingestApiKey = apiKey;
    deploy._defaultAppVersion = appVersion;
    deploy._distinctIdResolver = distinctIdResolver;
    // Register with the Traffic Cop BEFORE the platform init kicks off
    // so the first unified handshake (fired from Sankofa.init right
    // after this call returns) has a route for `modules.deploy`. The
    // server is the source of truth for whether this module operates;
    // host-side `enableDeploy: true` is just intent.
    SankofaModuleRegistry.instance.register(deploy);

    // Publish the instance EAGERLY so a slow / failing platform plugin
    // init never strands `Sankofa.deploy` at null. The Path C methods
    // are pure Dart and don't need the native plugin; the Android
    // methods gate on `_ready` and throw a clear message when it's
    // false. Either way `Sankofa.deploy` is the canonical entry point.
    _instance = deploy;

    try {
      await SankofaDeployPlatform.instance.initialize(
        apiKey: apiKey,
        endpoint: endpoint,
        options: options,
      );
      deploy._ready = true;
    } catch (err, st) {
      if (kDebugMode) {
        debugPrint(
          '[Sankofa.deploy] platform plugin init failed — '
          'Path C (KBC) pipeline still works; Android baseline methods '
          'will throw _assertReady until the plugin succeeds: $err\n$st',
        );
      }
      // Intentionally leave _ready=false. Path C methods don't gate on it.
    }

    if (options.autoCheckOnStartup && deploy._ready) {
      // Fire-and-forget. Errors flow into the platform's logger and
      // the next checkForUpdate() call will surface the state. Skip
      // on iOS where _ready stays false because the legacy libapp.so
      // path is Android-only.
      // ignore: deprecated_member_use_from_same_package
      unawaited(deploy.legacyAndroidCheckForUpdate());
    }
    return deploy;
  }

  /// Legacy Android-only libapp.so binary-diff check. Calls into the
  /// native plugin and stages a binary-diff patch on next boot. Most
  /// hosts should use the cross-platform [checkForUpdate] (no args,
  /// works on iOS + Android) instead — kept exposed only because the
  /// auto-startup hook still calls it on Android. Will become fully
  /// internal once the libapp.so path is sunset in favour of β.3 KBC.
  @Deprecated('Use checkForUpdate() — cross-platform, no args needed.')
  Future<UpdateStatus> legacyAndroidCheckForUpdate() {
    _assertReady();
    return SankofaDeployPlatform.instance.checkForUpdate();
  }

  /// Legacy Android-only "app ready" hook for the libapp.so path. Most
  /// hosts should use [notifyAppReady] (cross-platform) instead.
  @Deprecated('Use notifyAppReady() — cross-platform, manages both libapp.so + KBC paths.')
  Future<void> legacyAndroidNotifyAppReady() {
    _assertReady();
    return SankofaDeployPlatform.instance.notifyAppReady();
  }

  /// Tell the updater that a fatal error was caught — equivalent to a
  /// hard crash from the rollback perspective. Optional; the native
  /// crash bridge fires this automatically for uncaught exceptions.
  Future<void> reportCrash() {
    _assertReady();
    return SankofaDeployPlatform.instance.reportCrash();
  }

  /// Returns the active patch label (e.g. `"v1.2.0-patch.3"`) or the
  /// baseline label if no patch is active.
  Future<String?> getActiveVersion() {
    _assertReady();
    return SankofaDeployPlatform.instance.getActiveVersion();
  }

  /// Absolute filesystem path of the currently active `libapp.so`.
  /// Mostly useful for debugging — production code shouldn't need
  /// this.
  Future<String?> getCurrentLibappPath() {
    _assertReady();
    return SankofaDeployPlatform.instance.getCurrentLibappPath();
  }

  /// Disable the currently active patch, forcing the next launch to
  /// boot from the baseline libapp.so. Useful for support workflows
  /// ("turn off the bad patch for this user, we'll re-roll").
  Future<void> disableCurrentPatch() {
    _assertReady();
    return SankofaDeployPlatform.instance.disableCurrentPatch();
  }

  /// β.3 + ε + β.4 + η: apply a Sankofa Deploy: Flutter Code KBC patch.
  ///
  /// Pass a [SANKOFA_KBC_ENVELOPE] (`.skdp`) buffer plus a [loader]
  /// callback that calls the Dart VM's `loadDynamicModule`. The
  /// canonical wiring (from a host app's pubspec with
  /// `dynamic_modules` as a path-dep on `pkg/dynamic_modules` from our
  /// Dart SDK fork) is:
  ///
  /// ```dart
  /// import 'package:dynamic_modules/dynamic_modules.dart';
  ///
  /// final result = await Sankofa.deploy!.applyKbcPatchFromBytes(
  ///   envelopeBytes,
  ///   loader: loadModuleFromBytes,
  /// );
  /// ```
  ///
  /// The SDK:
  ///   * parses the envelope (`magic SKDP`, version 1, length-prefixed
  ///     header + JSON metadata + KBC payload + signature trailer)
  ///   * verifies the payload SHA-256 against the carried digest —
  ///     **fail-closed on mismatch**, the loader is never called
  ///   * sanity-checks the inner KBC magic (`DBC3` = 33 43 42 44)
  ///   * hands the verified KBC bytes to [loader]
  ///   * returns the dyn-module entry-point's return value plus the
  ///     envelope metadata in a [KbcPatchResult]
  ///
  /// Throws [KbcApplyException] on any pre-load failure. Throws via
  /// the loader on engine-side issues (e.g. running a stock Flutter
  /// engine that wasn't built with `dart_dynamic_modules=true` → "Loading
  /// of dynamic modules is not supported"). The exception message
  /// names the most likely cause to keep debugging short.
  ///
  /// This is the iOS Path C ship surface (β.3 proved on iPhone
  /// 2026-05-24). Android baseline OTA still uses the Phase 5
  /// libapp.so binary-diff route — see [checkForUpdate].
  Future<KbcPatchResult> applyKbcPatchFromBytes(
    Uint8List envelopeBytes, {
    required KbcLoaderFn loader,
  }) {
    // Path C is pure Dart — no platform plugin needed. Do NOT call
    // _assertReady(): on iOS the platform plugin's libapp.so updater
    // doesn't exist, so _ready stays false even though Path C works.
    return kbc_loader.applyKbcEnvelope(
      envelopeBytes,
      loader: loader,
      signingPubkeysB64: _effectiveSigningPubkeys,
    );
  }

  /// Convenience wrapper around [applyKbcPatchFromBytes]. Reads the
  /// envelope file off disk, then dispatches as above.
  ///
  /// The canonical on-device path is
  /// `<App Documents>/sankofa-deploy/patches/active/patch.skdp` — the
  /// SDK doesn't enforce this so apps can stage patches wherever fits.
  Future<KbcPatchResult> applyKbcPatchFromFile(
    String path, {
    required KbcLoaderFn loader,
  }) {
    // Path C is pure Dart — see applyKbcPatchFromBytes above.
    return kbc_loader.applyKbcEnvelopeFromFile(
      path,
      loader: loader,
      signingPubkeysB64: _effectiveSigningPubkeys,
    );
  }

  /// η v1: in-app fetch + apply for iOS Path C.
  ///
  /// Replaces the manual `xcrun devicectl device copy to` workflow
  /// with a single in-app call. Hits the Sankofa server's
  /// `/api/deploy/check` endpoint, downloads the latest matching
  /// envelope, verifies sha-256, persists to
  /// `<Documents>/sankofa-deploy/patches/active/patch.skdp`, and
  /// applies via [loader].
  ///
  /// The canonical wiring from a host app:
  ///
  /// ```dart
  /// import 'package:dynamic_modules/dynamic_modules.dart';
  ///
  /// final result = await Sankofa.deploy!.fetchAndApplyKbcPatch(
  ///   endpoint: 'http://172.20.10.8:8080',  // Mac's LAN IP in dev
  ///   apiKey: '<test or live SDK key>',
  ///   appVersion: '1.0.0',
  ///   engineVersion: '3.41.9+sankofa-1',
  ///   distinctId: await getOrCreateDistinctId(),
  ///   loader: loadModuleFromBytes,
  /// );
  /// if (result.hasUpdate) {
  ///   print('patched: ${result.applied?.returnValue}');
  /// }
  /// ```
  ///
  /// Throws [KbcFetchException] on any HTTP / sha-mismatch / apply
  /// failure. The exception message names the most likely cause.
  Future<KbcFetchResult> fetchAndApplyKbcPatch({
    required KbcLoaderFn loader,
    String? endpoint,
    String? apiKey,
    String? appVersion,
    String? engineVersion,
    String? distinctId,
    String? platform,
    String? currentLabel,
    bool persistToDisk = true,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    // Path C is pure Dart — see applyKbcPatchFromBytes above.
    // Prefix-call to avoid infinite recursion on the instance method.
    final banned = await getBannedKbcLabels();
    final resolvedAppVersion = _resolveAppVersion(appVersion);
    final resolvedPlatform = platform ?? _effectivePlatform;
    KbcFetchResult result;
    try {
      result = await kbc_fetch.fetchAndApplyKbcPatch(
        endpoint: _resolveEndpoint(endpoint),
        apiKey: _resolveApiKey(apiKey),
        appVersion: resolvedAppVersion,
        engineVersion: _resolveEngineVersion(engineVersion),
        distinctId: _resolveDistinctId(distinctId),
        loader: loader,
        platform: resolvedPlatform,
        currentLabel: currentLabel,
        persistToDisk: persistToDisk,
        timeout: timeout,
        signingPubkeysB64: _effectiveSigningPubkeys,
        bannedLabels: banned.isEmpty ? null : banned,
      );
    } catch (err, st) {
      // Telemetry fire-and-forget. Don't await — preserve the original
      // throw timing for the host's UI feedback.
      final stack = err is KbcApplyException
          ? _formatKbcStackTrace(err.causeStackTrace ?? st)
          : _formatKbcStackTrace(st);
      _reportKbcEvent(
        eventType: 'kbc_apply_failed',
        bundleLabel: currentLabel,
        appVersion: resolvedAppVersion,
        platform: resolvedPlatform,
        errorMessage: err.toString(),
        extra: {
          'phase': 'fetch_apply',
          'cause_class': err.runtimeType.toString(),
          if (err is KbcApplyException && err.cause != null)
            'inner_cause': err.cause.toString(),
          if (err is KbcApplyException && err.cause != null)
            'inner_cause_class': err.cause.runtimeType.toString(),
          if (stack != null) 'stack_trace': stack,
        },
      );
      rethrow;
    }
    if (result.hasUpdate && result.applied != null) {
      _reportKbcEvent(
        eventType: 'kbc_apply_success',
        releaseId: result.releaseId,
        bundleLabel: result.label,
        appVersion: resolvedAppVersion,
        platform: resolvedPlatform,
      );
    } else if (result.reason == 'label_banned_locally') {
      // Surface the skip so dashboards know "this device knows label X
      // is bad and is refusing to re-fetch it". Server-side telemetry
      // can then prompt the customer to disable the release globally.
      _reportKbcEvent(
        eventType: 'kbc_apply_skipped_label_banned',
        releaseId: result.releaseId,
        bundleLabel: result.label,
        appVersion: resolvedAppVersion,
        platform: resolvedPlatform,
      );
    }
    return result;
  }

  // ── Shorebird-style developer-facing API ────────────────────────────
  //
  // These methods split [fetchAndApplyKbcPatch]'s "check + download +
  // apply" into the three pieces customers actually want to drive
  // independently:
  //
  //   1. [checkForUpdate]   → is there a patch?
  //   2. [downloadKbcUpdate]   → bring the bytes down (optional UX
  //                              gating, progress reporting)
  //   3. [tryApplyStagedKbcPatch] (existing) → apply on next boot
  //
  // Plus [readCurrentPatch] which exposes the active patch's
  // metadata so the host can render "You are on v1.2.0-patch.3".
  //
  // The all-in-one [fetchAndApplyKbcPatch] still exists for hosts that
  // want one call; the split API is for hosts that need an "Update?"
  // dialog, a progress bar, or both.

  /// Probe the server for a new patch WITHOUT downloading. The result
  /// carries the patch label, size, sha256, signed download URL, and
  /// [SankofaUpdate.isMandatory] flag — enough to drive a confirmation
  /// dialog. Hosts then call [downloadKbcUpdate] when ready.
  ///
  /// ```dart
  /// final result = await Sankofa.instance.deploy?.checkForUpdate(
  ///   endpoint:      'https://api.sankofa.dev',
  ///   apiKey:        'sk_live_…',
  ///   appVersion:    '1.2.0',
  ///   engineVersion: '3.44.0+sankofa-1',
  ///   distinctId:    await getOrCreateDistinctId(),
  /// );
  /// if (result?.hasUpdate == true) {
  ///   if (result!.update!.isMandatory) {
  ///     await Sankofa.instance.deploy?.downloadUpdate(result.update!);
  ///   } else {
  ///     final yes = await showUpdateDialog(context, result.update!);
  ///     if (yes) await Sankofa.instance.deploy?.downloadUpdate(result.update!);
  ///   }
  /// }
  /// ```
  ///
  /// Locally-banned labels (previously auto-rolled-back on this
  /// device) are filtered automatically — the result's `status` is
  /// [SankofaUpdateStatus.bannedLocally] in that case.
  Future<SankofaUpdateCheckResult> checkForUpdate({
    String? endpoint,
    String? apiKey,
    String? appVersion,
    String? engineVersion,
    String? distinctId,
    String? platform,
    String? currentLabel,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final banned = await getBannedKbcLabels();
    return kbc_fetch.checkForKbcUpdate(
      endpoint: _resolveEndpoint(endpoint),
      apiKey: _resolveApiKey(apiKey),
      appVersion: _resolveAppVersion(appVersion),
      engineVersion: _resolveEngineVersion(engineVersion),
      distinctId: _resolveDistinctId(distinctId),
      platform: platform ?? _effectivePlatform,
      currentLabel: currentLabel,
      timeout: timeout,
      bannedLabels: banned.isEmpty ? null : banned,
    );
  }

  /// Download the envelope discovered by [checkForUpdate] and stage
  /// it on disk for [tryApplyStagedKbcPatch] to pick up on the next
  /// launch. Streams the response so [onProgress] fires on every
  /// chunk with the running `(received, total)` bytes — drives a
  /// progress bar without buffering the whole envelope in memory.
  ///
  /// The streamed bytes are verified against [SankofaUpdate.sha256]
  /// before the file is moved into place; a corrupt download deletes
  /// the partial file and throws [KbcFetchException].
  ///
  /// Returns the absolute on-disk path of the staged envelope. Hosts
  /// rarely need this — kept for debugging and tests.
  ///
  /// Telemetry: emits `kbc_patch_downloaded` on success and
  /// `kbc_apply_failed{phase=download}` on transport / SHA failures.
  Future<String> downloadUpdate(
    SankofaUpdate update, {
    void Function(int received, int total)? onProgress,
    Duration timeout = const Duration(minutes: 5),
  }) async {
    _assertReady();
    try {
      final path = await kbc_fetch.downloadKbcUpdateToFile(
        update,
        onProgress: onProgress,
        timeout: timeout,
      );
      _reportKbcEvent(
        eventType: 'kbc_patch_downloaded',
        bundleLabel: update.label,
        releaseId: update.releaseId,
        extra: {'size_bytes': update.sizeBytes, 'staged_path': path},
      );
      return path;
    } catch (err, st) {
      final stack = _formatKbcStackTrace(st);
      _reportKbcEvent(
        eventType: 'kbc_apply_failed',
        bundleLabel: update.label,
        releaseId: update.releaseId,
        errorMessage: err.toString(),
        extra: {
          'phase': 'download',
          'cause_class': err.runtimeType.toString(),
          if (stack != null) 'stack_trace': stack,
        },
      );
      rethrow;
    }
  }

  /// Returns metadata for the patch currently believed to be live on
  /// this device. The SDK reads the `last_good/patch.skdp` envelope
  /// — the patch that survived a `notifyKbcPatchReady` confirmation
  /// — and surfaces its label.
  ///
  /// Returns null when no patch has ever been promoted (the app is
  /// running its baseline AOT code).
  ///
  /// ```dart
  /// final current = await Sankofa.instance.deploy?.readCurrentPatch();
  /// setState(() => _patchLabel = current?.label ?? 'baseline');
  /// ```
  Future<SankofaCurrentPatch?> readCurrentPatch() async {
    final path = await _kbcSlotPath(_kbcSlotLastGood);
    final file = File(path);
    if (!file.existsSync()) return null;
    try {
      final bytes = await file.readAsBytes();
      final env = parseKbcEnvelope(bytes);
      final label = env.metadata['label']?.toString();
      if (label == null || label.isEmpty) return null;
      final releaseId = env.metadata['release_id']?.toString();
      final stamped = env.metadata['issued_at_unix_ms'];
      DateTime? appliedAt;
      if (stamped is num) {
        appliedAt = DateTime.fromMillisecondsSinceEpoch(stamped.toInt());
      }
      return SankofaCurrentPatch(
        label: label,
        releaseId: releaseId,
        appliedAt: appliedAt,
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[Sankofa.deploy] readCurrentPatch: $e');
      }
      return null;
    }
  }

  // ── Rollback safety (RN-style time-window) ──────────────────────────
  //
  // Auto-rollback uses the **same time-window heuristic** the React
  // Native SDK ships in production: at boot, if the previous boot did
  // NOT confirm healthy AND was within [kKbcCrashWindow] ago, treat
  // that previous boot as a crash. Two such consecutive crashes trip
  // the rollback (file moves to disabled/, last_good restores to
  // active). Healthy long sessions never count — a user who relaunches
  // the app three times across the day is not a crash storm.
  //
  // Migration: the previous boot-count model used `_kbcBootCounterKey`
  // alone (every boot incremented, regardless of duration). That key
  // is read once on first run after upgrade, then deleted — the new
  // model is its own state machine.
  //
  // RN parity: CRASH_THRESHOLD=2, CRASH_WINDOW_MS=30_000,
  // HEALTH_CONFIRM_MS=10_000 (already in [kKbcAutoConfirmDelay]).

  /// Legacy boot-count key (pre-time-window). Read at most once to
  /// detect upgrade, then cleared. Do not use for new chain-safety.
  static const String _kbcBootCounterKey = 'sankofa.deploy.kbc.boot_counter';
  static const String _kbcLastBootTimeMsKey = 'sankofa.deploy.kbc.last_boot_ms';
  static const String _kbcBootConfirmedKey = 'sankofa.deploy.kbc.boot_confirmed';
  static const String _kbcCrashCountKey = 'sankofa.deploy.kbc.crash_count';
  static const String _kbcLastDisabledKey = 'sankofa.deploy.kbc.last_disabled_label';

  /// Threshold of consecutive quick-boot crashes that triggers rollback.
  /// Mirrors RN's `CRASH_THRESHOLD`.
  static const int kKbcCrashThreshold = 2;

  /// A boot is considered a "crash" only if the previous boot didn't
  /// confirm healthy and was within this window of the current boot.
  /// Mirrors RN's `CRASH_WINDOW_MS`.
  static const Duration kKbcCrashWindow = Duration(seconds: 30);

  /// Comma-separated set of patch labels that have triggered auto-
  /// rollback at any point in this app's life. The SDK refuses to
  /// re-apply any patch whose label is in this set — prevents the
  /// "crash 3x → rollback → server still serves the same bad patch →
  /// re-download → crash again" loop. Customers can clear via
  /// [clearBannedKbcLabels] when a fixed re-issue ships with the same
  /// label (rare; usually a hotfix uses a new label like "v1-hotfix").
  static const String _kbcBannedLabelsKey = 'sankofa.deploy.kbc.banned_labels';

  /// On-disk slot names beneath `<Documents>/sankofa-deploy/patches/`.
  ///   - `active/`     — what tryApplyStagedKbcPatch reads on every boot
  ///   - `last_good/`  — most recent patch promoted by notifyKbcPatch
  ///                     Ready. Auto-rollback restores from here.
  ///   - `disabled/`   — bad patches that crashed past the rollback
  ///                     threshold. Kept for forensics; never re-applied.
  static const String _kbcSlotActive = 'active';
  static const String _kbcSlotLastGood = 'last_good';
  static const String _kbcSlotDisabled = 'disabled';
  static const String _kbcPatchFileName = 'patch.skdp';

  /// Absolute path to a slot's patch file. Used by all the boot-time
  /// and rollback paths so the layout stays consistent.
  Future<String> _kbcSlotPath(String slot) async {
    final docsDir = await getApplicationDocumentsDirectory();
    return '${docsDir.path}/sankofa-deploy/patches/$slot/$_kbcPatchFileName';
  }

  Future<Directory> _kbcSlotDir(String slot) async {
    final docsDir = await getApplicationDocumentsDirectory();
    return Directory('${docsDir.path}/sankofa-deploy/patches/$slot');
  }

  /// Legacy boot-count threshold (pre-time-window). Kept as a public
  /// const for API stability — the new model uses [kKbcCrashThreshold]
  /// + [kKbcCrashWindow].
  @Deprecated('Use kKbcCrashThreshold + kKbcCrashWindow (time-window model).')
  static const int kbcRollbackThreshold = 3;

  /// Look for a KBC patch that a previous session staged on disk and
  /// apply it now, before [runApp]. Returns the apply result, or null
  /// if no patch was staged (or the staged patch is invalid).
  ///
  /// This is the **boot-time apply** that closes the OTA loop end-to-end:
  /// [fetchAndApplyKbcPatch] persists the envelope at
  /// `<App Documents>/sankofa-deploy/patches/active/patch.skdp`, but
  /// the patch's effect (e.g. JSON UI overrides decoded by the host)
  /// lives only in memory for that session. On the next cold boot the
  /// host must re-apply from disk — otherwise the user sees the
  /// baseline UI again and "OTA" feels broken. Call this from `main()`
  /// after `Sankofa.init(...)` and BEFORE `runApp(...)`:
  ///
  /// ```dart
  /// void main() async {
  ///   WidgetsFlutterBinding.ensureInitialized();
  ///   await Sankofa.instance.init(enableDeploy: true);
  ///   final stagedResult = await Sankofa.instance.deploy?.tryApplyStagedKbcPatch(
  ///     loader: loadModuleFromBytes,
  ///   );
  ///   runApp(MyApp(initialPatch: stagedResult));
  /// }
  /// ```
  ///
  /// Signature verification + ζ.1 engine check + sha-256 integrity all
  /// run on the staged file just like a fresh fetch — bytes from disk
  /// are treated with the same fail-closed posture as bytes from B2.
  /// A signature mismatch (e.g. customer rotated keys via
  /// `sankofa keys generate` AFTER staging this patch) returns null,
  /// not an exception, so the app boots clean to baseline.
  ///
  /// Throws `StateError` if [Sankofa.deploy] wasn't enabled — calling
  /// this on a deploy-disabled app is almost certainly a bug. Other
  /// failures (no file, parse error, sig mismatch, loader error) all
  /// return null so the cold-start path stays defensive.
  Future<KbcPatchResult?> tryApplyStagedKbcPatch({
    required KbcLoaderFn loader,
  }) async {
    final patchPath = await _kbcSlotPath(_kbcSlotActive);
    if (!File(patchPath).existsSync()) return null;

    // Rollback gate (time-window model — RN parity). Counts a boot as
    // a "crash" only if the previous boot didn't confirm healthy AND
    // was within kKbcCrashWindow. Two such consecutive crashes trip
    // the rollback.
    final prefs = await SharedPreferences.getInstance();
    final nowMs = DateTime.now().millisecondsSinceEpoch;

    // Migrate from the legacy boot-count model: if the old counter
    // exists, ignore it (no decision based on it) and just delete.
    if (prefs.containsKey(_kbcBootCounterKey)) {
      await prefs.remove(_kbcBootCounterKey);
    }

    final lastBootMs = prefs.getInt(_kbcLastBootTimeMsKey);
    final lastBootConfirmed = prefs.getBool(_kbcBootConfirmedKey) ?? false;
    int crashCount = prefs.getInt(_kbcCrashCountKey) ?? 0;

    final previousBootCrashed = !lastBootConfirmed &&
        lastBootMs != null &&
        (nowMs - lastBootMs) < kKbcCrashWindow.inMilliseconds;

    if (previousBootCrashed) {
      crashCount += 1;
      await prefs.setInt(_kbcCrashCountKey, crashCount);
    } else if (lastBootConfirmed) {
      // Clean reset on any healthy prior boot.
      crashCount = 0;
      await prefs.setInt(_kbcCrashCountKey, 0);
    }

    if (crashCount >= kKbcCrashThreshold) {
      // Best-effort: parse the bad envelope's label before moving it
      // aside, so we can record it in the banned set + tell the
      // dashboard which release failed. Parse-only — no apply.
      String? rolledBackLabel;
      try {
        final bytes = await File(patchPath).readAsBytes();
        final parsed = parseKbcEnvelope(bytes);
        final lbl = parsed.metadata['label'];
        if (lbl is String && lbl.isNotEmpty) {
          rolledBackLabel = lbl;
          await prefs.setString(_kbcLastDisabledKey, lbl);
          // Ban the label so /api/deploy/check serving the same patch
          // again doesn't crash-loop: fetchAndApplyKbcPatch consults
          // _kbcBannedLabelsKey before applying.
          await _addBannedLabel(prefs, lbl);
        }
      } catch (_) {
        // Parse failed too — wedged envelope; can't ban the label but
        // the file still gets moved aside.
      }
      try {
        final disabledDir = await _kbcSlotDir(_kbcSlotDisabled);
        if (!disabledDir.existsSync()) {
          disabledDir.createSync(recursive: true);
        }
        final disabledPath =
            '${disabledDir.path}/patch.skdp.disabled-${DateTime.now().millisecondsSinceEpoch}';
        await File(patchPath).rename(disabledPath);
        if (kDebugMode) {
          debugPrint(
            '[Sankofa.deploy] AUTO-ROLLBACK: staged patch "$rolledBackLabel" '
            'crashed $crashCount consecutive boots inside ${kKbcCrashWindow.inSeconds}s '
            '— moved to $disabledPath.',
          );
        }
      } catch (_) {
        // Rename failed — disk full or permission. Still bail out of
        // applying; don't keep crash-looping.
      }
      // Reset chain-safety state — we just rolled back.
      await prefs.remove(_kbcCrashCountKey);
      await prefs.setBool(_kbcBootConfirmedKey, false);
      await prefs.setInt(_kbcLastBootTimeMsKey, nowMs);

      // Restore last_good → active if we have one. Customer doesn't
      // drop all the way back to baseline — falls back to the most
      // recent patch that actually survived a boot.
      final restoredFromLastGood = await _restoreLastGoodToActive();
      if (restoredFromLastGood) {
        if (kDebugMode) {
          debugPrint(
            '[Sankofa.deploy] AUTO-ROLLBACK: restored last_good patch to active. '
            'Next boot will apply the previous known-good patch.',
          );
        }
        unawaited(_reportKbcEvent(
          eventType: 'kbc_patch_restored_from_last_good',
          bundleLabel: rolledBackLabel,
          extra: {'reason': 'rollback_threshold_exceeded'},
        ));
      }

      unawaited(_reportKbcEvent(
        eventType: 'kbc_boot_apply_skipped_rollback',
        bundleLabel: rolledBackLabel,
        extra: {'restored_last_good': restoredFromLastGood},
      ));
      return null;
    }

    // Record this boot. boot_confirmed flips to true only when the host
    // calls notifyKbcPatchReady() or the 10s auto-confirm timer fires.
    await prefs.setInt(_kbcLastBootTimeMsKey, nowMs);
    await prefs.setBool(_kbcBootConfirmedKey, false);

    try {
      final result = await kbc_loader.applyKbcEnvelopeFromFile(
        patchPath,
        loader: loader,
        signingPubkeysB64: _effectiveSigningPubkeys,
      );
      unawaited(_reportKbcEvent(
        eventType: 'kbc_boot_apply_success',
        bundleLabel: result.metadata['label']?.toString(),
      ));
      // Arm the 10s auto-confirm safety net (RN parity). If the host
      // never calls notifyKbcPatchReady, we'll auto-ack so a clean
      // 10-second-old app session is treated as proof the patch is
      // healthy. notifyKbcPatchReady cancels this and confirms exactly.
      _armAutoConfirmTimer();
      return result;
    } on KbcApplyException catch (err) {
      if (kDebugMode) {
        debugPrint(
          '[Sankofa.deploy] staged patch at $patchPath failed to apply: ${err.message}'
          '${err.cause != null ? '\n[Sankofa.deploy] cause: ${err.cause}' : ''}'
          '${err.causeStackTrace != null ? '\n[Sankofa.deploy] cause stack:\n${err.causeStackTrace}' : ''}',
        );
      }
      final stack = _formatKbcStackTrace(err.causeStackTrace);
      unawaited(_reportKbcEvent(
        eventType: 'kbc_boot_apply_failed',
        errorMessage: err.message,
        extra: {
          'phase': 'boot_apply',
          'cause_class': 'KbcApplyException',
          if (err.cause != null) 'inner_cause': err.cause.toString(),
          if (err.cause != null)
            'inner_cause_class': err.cause.runtimeType.toString(),
          if (stack != null) 'stack_trace': stack,
        },
      ));
      return null;
    } catch (err, st) {
      if (kDebugMode) {
        debugPrint(
          '[Sankofa.deploy] unexpected error applying staged patch at $patchPath: $err',
        );
      }
      final stack = _formatKbcStackTrace(st);
      unawaited(_reportKbcEvent(
        eventType: 'kbc_boot_apply_failed',
        errorMessage: err.toString(),
        extra: {
          'phase': 'boot_apply',
          'cause_class': err.runtimeType.toString(),
          if (stack != null) 'stack_trace': stack,
        },
      ));
      return null;
    }
  }

  /// Reset the rollback boot-counter — call this from the host's
  /// first-frame callback (or any "the app survived initial render"
  /// signal). Without this call, a bad patch will crash-loop the app
  /// until [kKbcCrashThreshold] quick-crash boots (each within
  /// [kKbcCrashWindow] of the previous), then auto-disable itself.
  ///
  /// Typical wiring:
  ///
  /// ```dart
  /// WidgetsBinding.instance.addPostFrameCallback((_) {
  ///   Sankofa.instance.deploy?.notifyKbcPatchReady();
  /// });
  /// ```
  ///
  /// Idempotent — calling twice in one boot is harmless. Returns the
  /// boot count that was reset, mostly useful for telemetry / tests.
  ///
  /// Side effect: PROMOTES the currently-active patch to the last_good
  /// slot. This is the moment we declare "this patch worked" — every
  /// subsequent auto-rollback can restore from this slot instead of
  /// dropping the user all the way back to baseline.
  Future<int> notifyKbcPatchReady() async {
    // Cancel the auto-confirm safety-net timer if it's armed — the
    // host has explicitly told us the patch is healthy, so we don't
    // need the 10s fallback to do it for us.
    _autoConfirmTimer?.cancel();
    _autoConfirmTimer = null;
    final prefs = await SharedPreferences.getInstance();
    final priorCrashCount = prefs.getInt(_kbcCrashCountKey) ?? 0;
    await _confirmHealthInternal(prefs: prefs);
    return priorCrashCount;
  }

  /// Internal "this patch is healthy" routine — shared by
  /// [notifyKbcPatchReady] (explicit, host-driven) and the auto-confirm
  /// safety-net timer (implicit, fired 10s after a successful apply).
  /// Idempotent: marks the boot as confirmed, resets the crash counter,
  /// and best-effort promotes the active patch to last_good.
  Future<void> _confirmHealthInternal({SharedPreferences? prefs}) async {
    final p = prefs ?? await SharedPreferences.getInstance();
    await p.setBool(_kbcBootConfirmedKey, true);
    await p.setInt(_kbcCrashCountKey, 0);
    // Clean legacy key if a migration didn't catch it earlier.
    if (p.containsKey(_kbcBootCounterKey)) {
      await p.remove(_kbcBootCounterKey);
    }
    try {
      await _promoteActiveToLastGood();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[Sankofa.deploy] last_good promotion failed (best-effort): $e');
      }
    }
  }

  /// Arm the 10s auto-confirm safety net. Called from
  /// [tryApplyStagedKbcPatch] on the success path so a host that forgets
  /// to call [notifyKbcPatchReady] still gets chain-safety semantics:
  /// if the app survives 10s after a successful apply, the patch is
  /// trusted (counter reset + active→last_good promoted) automatically.
  ///
  /// Mirrors RN's [HEALTH_CONFIRM_MS] timer. Idempotent — calling twice
  /// cancels the previous arm.
  void _armAutoConfirmTimer({Duration delay = kKbcAutoConfirmDelay}) {
    _autoConfirmTimer?.cancel();
    _autoConfirmTimer = Timer(delay, () async {
      _autoConfirmTimer = null;
      try {
        await _confirmHealthInternal();
        if (kDebugMode) {
          debugPrint(
            '[Sankofa.deploy] auto-confirm fired (host did not call '
            'notifyKbcPatchReady within ${delay.inSeconds}s) — patch trusted.',
          );
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('[Sankofa.deploy] auto-confirm failed: $e');
        }
      }
    });
  }

  /// Copy active/patch.skdp → last_good/patch.skdp. Called by
  /// [notifyKbcPatchReady] to mark the current patch as trusted.
  /// Returns true on success, false when no active patch existed or
  /// the copy threw. Idempotent — overwrites existing last_good.
  Future<bool> _promoteActiveToLastGood() async {
    final activePath = await _kbcSlotPath(_kbcSlotActive);
    if (!File(activePath).existsSync()) return false;
    final lastGoodDir = await _kbcSlotDir(_kbcSlotLastGood);
    if (!lastGoodDir.existsSync()) {
      lastGoodDir.createSync(recursive: true);
    }
    final lastGoodPath = await _kbcSlotPath(_kbcSlotLastGood);
    await File(activePath).copy(lastGoodPath);
    // Best-effort telemetry — record which label just got trusted so
    // dashboards can see the promotion cadence per release.
    String? label;
    try {
      final bytes = await File(activePath).readAsBytes();
      final parsed = parseKbcEnvelope(bytes);
      final lbl = parsed.metadata['label'];
      if (lbl is String) label = lbl;
    } catch (_) {}
    unawaited(_reportKbcEvent(
      eventType: 'kbc_patch_promoted_to_last_good',
      bundleLabel: label,
    ));
    return true;
  }

  /// Move last_good/patch.skdp → active/patch.skdp. Called by the
  /// auto-rollback path so the user doesn't drop all the way back to
  /// baseline UI when a single patch crashes. Returns true if a
  /// last_good existed and was restored.
  Future<bool> _restoreLastGoodToActive() async {
    final lastGoodPath = await _kbcSlotPath(_kbcSlotLastGood);
    if (!File(lastGoodPath).existsSync()) return false;
    // If the last_good label is itself banned (shouldn't happen — only
    // promoted patches make it here — but defensive), skip restore.
    try {
      final bytes = await File(lastGoodPath).readAsBytes();
      final parsed = parseKbcEnvelope(bytes);
      final lbl = parsed.metadata['label'];
      if (lbl is String) {
        final prefs = await SharedPreferences.getInstance();
        final banned = await _getBannedLabels(prefs);
        if (banned.contains(lbl)) {
          if (kDebugMode) {
            debugPrint(
              '[Sankofa.deploy] last_good patch "$lbl" is in the banned set; '
              'refusing to restore. Falling back to baseline.',
            );
          }
          return false;
        }
      }
    } catch (_) {
      // Parse failed — last_good is corrupt; treat as no restore.
      return false;
    }
    final activeDir = await _kbcSlotDir(_kbcSlotActive);
    if (!activeDir.existsSync()) {
      activeDir.createSync(recursive: true);
    }
    final activePath = await _kbcSlotPath(_kbcSlotActive);
    await File(lastGoodPath).copy(activePath);
    return true;
  }

  /// Read the banned-label set out of SharedPreferences. Stored as a
  /// comma-separated string for forward-compat with SharedPreferences
  /// implementations that don't support setStringList everywhere.
  Future<Set<String>> _getBannedLabels(SharedPreferences prefs) async {
    final raw = prefs.getString(_kbcBannedLabelsKey);
    if (raw == null || raw.isEmpty) return <String>{};
    return raw.split(',').where((s) => s.isNotEmpty).toSet();
  }

  Future<void> _addBannedLabel(SharedPreferences prefs, String label) async {
    final cur = await _getBannedLabels(prefs);
    cur.add(label);
    // Cap at 50 entries (FIFO drop oldest) so a misbehaving customer
    // app can't grow this prefs blob unboundedly. 50 is generous —
    // most production apps will see < 5 bad labels in their lifetime.
    final list = cur.toList();
    if (list.length > 50) {
      list.removeRange(0, list.length - 50);
    }
    await prefs.setString(_kbcBannedLabelsKey, list.join(','));
  }

  /// Returns the current set of banned patch labels — patches that
  /// auto-rolled-back and won't be re-applied. Dashboards / support
  /// flows can show these; [clearBannedKbcLabels] resets the set.
  Future<Set<String>> getBannedKbcLabels() async {
    final prefs = await SharedPreferences.getInstance();
    return _getBannedLabels(prefs);
  }

  /// Clear the banned-label set so previously rolled-back patches can
  /// be re-applied. Useful when a customer ships a fix re-using the
  /// same label as a broken one (rare). Returns the labels that were
  /// cleared, for logging / telemetry.
  Future<Set<String>> clearBannedKbcLabels() async {
    final prefs = await SharedPreferences.getInstance();
    final cur = await _getBannedLabels(prefs);
    await prefs.remove(_kbcBannedLabelsKey);
    return cur;
  }

  /// Best-effort fire-and-forget POST to `/api/deploy/report` so the
  /// server can roll up "what fraction of devices on app_version X
  /// have patch label Y applied?". Silent on every failure mode —
  /// telemetry that crashes the app is a net loss. Bounded 3s timeout
  /// so cold-boot path isn't blocked by a slow/unreachable server.
  ///
  /// Event types we emit:
  ///   - `kbc_boot_apply_success`       — staged patch re-applied at cold boot
  ///   - `kbc_boot_apply_failed`        — boot-apply parse/sig/loader error
  ///   - `kbc_boot_apply_skipped_rollback` — auto-disable fired before this boot
  ///   - `kbc_apply_success`            — fresh fetch + apply landed
  ///   - `kbc_apply_failed`             — fetch ok, apply rejected (sig fail, etc.)
  ///
  /// `errorMessage` / `extra`, when set, are JSON-packed into the
  /// request body's `metadata` field (deploy_events has a text column
  /// for it). This is the ζ.2 MVP — instead of shipping full bytecode
  /// symbolication today, customers get "release X failed on Y devices
  /// with error: <message>" rolled up in the dashboard, which is 80%
  /// of the debugging value.
  ///
  /// Mirrors the existing apply_success/rollback semantics that the
  /// Android baseline path emits — same `deploy_events` ClickHouse
  /// table, same dashboard rollups.
  Future<void> _reportKbcEvent({
    required String eventType,
    String? releaseId,
    String? bundleLabel,
    String? appVersion,
    String? platform,
    String? errorMessage,
    Map<String, Object?>? extra,
  }) async {
    final endpoint = _ingestEndpoint;
    final apiKey = _ingestApiKey;
    if (endpoint == null || apiKey == null) return;
    try {
      final url = Uri.parse(
        '${endpoint.replaceAll(RegExp(r'/+$'), '')}/api/deploy/report',
      );
      // Pack diagnostic context into the existing metadata field so
      // the server schema doesn't grow per new SDK feature. Truncate
      // error messages aggressively — full stack traces don't help
      // server-side rollups and waste cold-boot bandwidth.
      final metaMap = <String, Object?>{
        if (errorMessage != null && errorMessage.isNotEmpty)
          'error': _truncate(errorMessage, 512),
        if (extra != null) ...extra,
      };
      final body = {
        'events': [
          {
            'event_type': eventType,
            if (releaseId != null) 'release_id': releaseId,
            if (bundleLabel != null) 'bundle_label': bundleLabel,
            if (appVersion != null) 'app_version': appVersion,
            if (platform != null) 'platform': platform,
            if (metaMap.isNotEmpty) 'metadata': jsonEncode(metaMap),
          },
        ],
      };
      await http
          .post(
            url,
            headers: {
              'x-api-key': apiKey,
              'Content-Type': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 3));
    } catch (_) {
      // Telemetry MUST be silent — never crash the host's cold-start
      // path or steal the network for a failing batch retry.
    }
  }

  static String _truncate(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max)}…<+${s.length - max}>';

  /// ζ.2 — format a StackTrace for telemetry. Strips framework noise,
  /// keeps the leading user-source + interpreter frames, caps at 12
  /// frames (≈ 1.5 KB worst case). Preserves source-position info that
  /// dart2bytecode bakes into KBC when `source-positions` is set in
  /// the bytecode-options (default for `sankofa patch`).
  ///
  /// Output shape (one line per frame, oldest last):
  ///   "#0 patchFn (file:///.../sankofa_patch.dart:14:5)"
  ///   "#1 main (file:///.../sankofa_patch.dart:8:3)"
  ///   "#2 _Interpreter.invoke (sankofa-fork interpreter)"
  ///
  /// Returns null for null / empty input so the caller can skip adding
  /// the field entirely (smaller telemetry payload).
  static String? _formatKbcStackTrace(StackTrace? st) {
    if (st == null) return null;
    final raw = st.toString();
    if (raw.isEmpty) return null;
    // Split + trim. Dart's StackTrace.toString() uses '\n' line breaks.
    final lines = raw.split('\n').map((l) => l.trimRight()).where((l) => l.isNotEmpty).toList();
    if (lines.isEmpty) return null;
    // Keep frames that look like Dart stack-trace lines (#N or 'at ').
    // Skip generic "<asynchronous suspension>" markers — they bloat
    // without adding signal.
    final kept = <String>[];
    for (final line in lines) {
      if (line.contains('<asynchronous suspension>')) continue;
      // Drop pure framework/runtime noise that doesn't help debugging
      // (the engine + telemetry serializer don't add value here).
      if (line.contains('package:flutter/src/runner') ||
          line.contains('package:stack_trace/')) {
        continue;
      }
      kept.add(line);
      if (kept.length >= 12) break;
    }
    if (kept.isEmpty) return null;
    return _truncate(kept.join('\n'), 2048);
  }

  /// Returns the label of the most recently auto-disabled patch (and
  /// clears the marker so next call returns null). Dashboards can show
  /// "we rolled back release X for you" the next time the app phones
  /// home. Empty string when no rollback has happened.
  Future<String?> consumeLastAutoDisabledPatchLabel() async {
    final prefs = await SharedPreferences.getInstance();
    final label = prefs.getString(_kbcLastDisabledKey);
    if (label != null) {
      await prefs.remove(_kbcLastDisabledKey);
    }
    return label;
  }

  /// Describes the patch currently staged at the canonical persistence
  /// path — what [tryApplyStagedKbcPatch] would re-apply on the next
  /// cold boot. Returns null when no patch is staged. Does NOT touch
  /// the loader; safe to call from a dashboard / debug screen at any
  /// time. Reads metadata only — the KBC payload is not parsed.
  ///
  /// Useful for "active version" displays, support flows ("paste the
  /// label of the patch you're running"), and the eventual server-side
  /// "what patches do my devices report?" rollup.
  Future<KbcStagedPatchInfo?> getStagedKbcPatchInfo() async {
    final docsDir = await getApplicationDocumentsDirectory();
    final patchPath =
        '${docsDir.path}/sankofa-deploy/patches/active/patch.skdp';
    final f = File(patchPath);
    if (!f.existsSync()) return null;
    try {
      final bytes = await f.readAsBytes();
      final parsed = parseKbcEnvelope(bytes);
      final stat = await f.stat();
      return KbcStagedPatchInfo(
        path: patchPath,
        sizeBytes: bytes.length,
        modifiedAt: stat.modified,
        label: parsed.metadata['label']?.toString(),
        engineCommit: parsed.metadata['engineCommit']?.toString(),
        dartVersion: parsed.metadata['dartVersion']?.toString(),
        targetBinaryVersion:
            parsed.metadata['targetBinaryVersion']?.toString(),
        signed: parsed.sigAlg == KbcSigAlg.ed25519,
      );
    } catch (_) {
      return KbcStagedPatchInfo(
        path: patchPath,
        sizeBytes: f.lengthSync(),
        modifiedAt: f.statSync().modified,
        label: null,
        engineCommit: null,
        dartVersion: null,
        targetBinaryVersion: null,
        signed: false,
        parseError: true,
      );
    }
  }

  /// Tear down the platform plugin. Called by `Sankofa.dispose()`;
  /// hosts almost never need this directly.
  Future<void> shutdown() async {
    _autoConfirmTimer?.cancel();
    _autoConfirmTimer = null;
    if (!_ready) return;
    await SankofaDeployPlatform.instance.shutdown();
    _ready = false;
    _instance = null;
  }

  /// Self-audit the host's Deploy integration. Returns a structured
  /// status describing whether the manifest, MainActivity, permissions
  /// and updater FFI are all wired up.
  ///
  /// Called automatically by [Sankofa.init] after the platform plugin
  /// initializes; the result is logged in debug mode and held for
  /// later use by the reverse-handshake (which will eventually report
  /// integration status to the server so the dashboard can show
  /// "incomplete SDK integration" warnings — Phase 2).
  Future<ModuleIntegrationStatus> checkIntegration() async {
    if (!_ready) {
      return ModuleIntegrationStatus(
        module: name,
        level: ModuleIntegrationLevel.broken,
        missing: const [
          'Platform plugin not initialized — `Sankofa.init(enableDeploy: true)` did not complete',
        ],
      );
    }
    Map<String, Object?> raw;
    try {
      raw = await SankofaDeployPlatform.instance.checkIntegration();
    } catch (err) {
      return ModuleIntegrationStatus(
        module: name,
        level: ModuleIntegrationLevel.broken,
        missing: ['Platform integration check failed: $err'],
      );
    }
    final missing = <String>[];
    final warnings = <String>[];

    if (raw['sankofaDeployApplication'] != true) {
      missing.add(
        'AndroidManifest <application android:name="com.sankofa.deploy.SankofaDeployApplication"> '
        'is not set — the Updater never initializes pre-Dart, so patches stage but never load. '
        'Re-run `sankofa init --deploy` or set the application name manually.',
      );
    }
    if (raw['sankofaFlutterActivity'] != true) {
      missing.add(
        'MainActivity does not extend `com.sankofa.deploy.SankofaFlutterActivity` — '
        'the Flutter engine launches without `--aot-shared-library-name=...`, so patches install but the engine '
        "still loads the baseline libapp.so. Change `class MainActivity : FlutterActivity()` to "
        '`class MainActivity : SankofaFlutterActivity()`.',
      );
    }
    if (raw['internetPermission'] != true) {
      missing.add(
        'AndroidManifest is missing `<uses-permission android:name="android.permission.INTERNET" />` — '
        'the updater cannot reach the Sankofa endpoint. Add the permission and re-run.',
      );
    }
    if (raw['apiKeyMetaData'] != true) {
      warnings.add(
        'AndroidManifest is missing `<meta-data android:name="com.sankofa.apiKey" ...>` — '
        'the Updater will fall back to whatever apiKey Dart passes via `Sankofa.init`, '
        "but pre-Dart updates won't run.",
      );
    }
    if (raw['updaterInitialized'] != true) {
      warnings.add(
        'JNI bridge reports the Updater is not yet initialized. If you just called `Sankofa.init`, '
        "this is normal — the audit ran before init completed. Re-check after the first frame.",
      );
    }

    final level = missing.isEmpty
        ? ModuleIntegrationLevel.full
        : (missing.length >= 2
            ? ModuleIntegrationLevel.broken
            : ModuleIntegrationLevel.partial);

    return ModuleIntegrationStatus(
      module: name,
      level: level,
      missing: missing,
      warnings: warnings,
    );
  }

  void _assertReady() {
    if (!_ready) {
      throw StateError(
        'Sankofa.deploy: native platform plugin is not ready. Either:\n'
        '  • `Sankofa.init(apiKey: ..., enableDeploy: true)` was never '
        'called / has not yet completed, or\n'
        '  • the platform plugin\'s initialize() threw — common on iOS '
        'Path C apps where the native libapp.so updater half does NOT '
        'exist. Path C apps should use applyKbcPatchFromBytes / '
        'applyKbcPatchFromFile / fetchAndApplyKbcPatch instead, which '
        'do NOT require the platform plugin.',
      );
    }
  }
}

/// Minimal local replacement for `dart:async`'s `unawaited` so the
/// import stays self-contained when this file is exported on its own.
void unawaited(Future<dynamic> future) {
  future.catchError((Object _) {});
}
