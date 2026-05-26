import 'dart:io' show File;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

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
import 'kbc_fetch.dart' as kbc_fetch;
import 'kbc_loader.dart' as kbc_loader;
import 'kbc_loader.dart' show KbcPatchResult, KbcLoaderFn;
import 'kbc_fetch.dart' show KbcFetchResult;
import 'update_status.dart';

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
  }) async {
    if (_instance != null) return _instance!;
    final deploy = SankofaDeploy._(options: options);
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
      // the next checkForUpdate() call will surface the state.
      // Skip on iOS Path C (where _ready stays false) because
      // checkForUpdate hits the libapp.so binary-diff endpoint, not
      // the KBC pipeline — wrong path for iOS Path C apps.
      unawaited(deploy.checkForUpdate());
    }
    return deploy;
  }

  /// Check the server for a new patch. The result reflects what the
  /// updater did — `installed` means a patch was staged for the next
  /// boot; `upToDate` means nothing changed; `rolledBack` means we
  /// detected a prior boot-loop and reverted.
  Future<UpdateStatus> checkForUpdate() {
    _assertReady();
    return SankofaDeployPlatform.instance.checkForUpdate();
  }

  /// Signals that the app has reached a stable state. Must be called
  /// AFTER `runApp()` returns and the first frame has rendered —
  /// typically right after the first user-visible widget is on screen.
  ///
  /// Resets the boot-counter rollback timer. Skipping this call after
  /// a patch is staged will trigger a rollback on the next launch.
  Future<void> notifyAppReady() {
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
    required String endpoint,
    required String apiKey,
    required String appVersion,
    required String engineVersion,
    required String distinctId,
    required KbcLoaderFn loader,
    String platform = 'ios',
    String? currentLabel,
    bool persistToDisk = true,
    Duration timeout = const Duration(seconds: 30),
  }) {
    // Path C is pure Dart — see applyKbcPatchFromBytes above.
    // Prefix-call to avoid infinite recursion on the instance method.
    return kbc_fetch.fetchAndApplyKbcPatch(
      endpoint: endpoint,
      apiKey: apiKey,
      appVersion: appVersion,
      engineVersion: engineVersion,
      distinctId: distinctId,
      loader: loader,
      platform: platform,
      currentLabel: currentLabel,
      persistToDisk: persistToDisk,
      timeout: timeout,
      signingPubkeysB64: _effectiveSigningPubkeys,
    );
  }

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
    final docsDir = await getApplicationDocumentsDirectory();
    final patchPath =
        '${docsDir.path}/sankofa-deploy/patches/active/patch.skdp';
    if (!File(patchPath).existsSync()) return null;
    try {
      return await kbc_loader.applyKbcEnvelopeFromFile(
        patchPath,
        loader: loader,
        signingPubkeysB64: _effectiveSigningPubkeys,
      );
    } on KbcApplyException catch (err) {
      if (kDebugMode) {
        debugPrint(
          '[Sankofa.deploy] staged patch at $patchPath failed to apply: ${err.message}',
        );
      }
      return null;
    } catch (err) {
      if (kDebugMode) {
        debugPrint(
          '[Sankofa.deploy] unexpected error applying staged patch at $patchPath: $err',
        );
      }
      return null;
    }
  }

  /// Tear down the platform plugin. Called by `Sankofa.dispose()`;
  /// hosts almost never need this directly.
  Future<void> shutdown() async {
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
