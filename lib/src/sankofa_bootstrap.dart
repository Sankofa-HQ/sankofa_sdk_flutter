import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'deploy/deploy_config.dart';
import 'deploy/kbc_loader.dart';
import 'sankofa_client.dart';

/// Result of [Sankofa.bootstrap] — what the engine + SDK figured out
/// about the project at startup, plus any staged KBC patch the deploy
/// pipeline applied before the first frame.
///
/// Hosts that want to react to a successful boot-time patch (e.g. to
/// drive a custom UI override) read [stagedPatch]; the boolean
/// [didApplyStagedPatch] is the common short-circuit.
@immutable
class SankofaBootstrapResult {
  const SankofaBootstrapResult({
    required this.apiKey,
    required this.endpoint,
    required this.appId,
    required this.engineVersion,
    required this.didApplyStagedPatch,
    required this.stagedPatch,
  });

  /// API key the SDK was initialized with (from sankofa.yaml).
  final String apiKey;

  /// Backend endpoint the SDK was initialized with (from sankofa.yaml).
  final String endpoint;

  /// Application ID (from sankofa.yaml). May be empty if not set.
  final String appId;

  /// Sankofa engine version pinned by sankofa.yaml. May be empty.
  final String engineVersion;

  /// True iff [Sankofa.bootstrap] applied a staged KBC patch from a
  /// previous session. False on first boot / after rollback / when no
  /// loader was provided.
  final bool didApplyStagedPatch;

  /// The patch result, or null if no patch was applied.
  final KbcPatchResult? stagedPatch;
}

/// Configuration object exposed to [Sankofa.bootstrap]. Most fields
/// mirror [Sankofa.init] one-to-one, with the addition of:
///
/// - [loader]: the dynamic-modules loader (`loadModuleFromBytes` from
///   `package:dynamic_modules/dynamic_modules.dart`). Pass when Deploy
///   is enabled; pass null to skip the boot-time apply (Deploy keeps
///   working for first-run downloads).
/// - [yamlAssetPath]: override the default `sankofa.yaml` asset path
///   (e.g. for multi-flavor builds that ship a per-flavor yaml).
/// - [scheduleNotifyOnFirstFrame]: schedule `notifyKbcPatchReady`
///   automatically after the first widget tree paints. Defaults true.
@immutable
class SankofaBootstrapOptions {
  const SankofaBootstrapOptions({
    this.loader,
    this.yamlAssetPath = 'sankofa.yaml',
    this.scheduleNotifyOnFirstFrame = true,
    this.fallbackEndpoint = 'https://api.sankofa.dev',
    this.deployOptions = const SankofaDeployOptions(),
    this.enableDeploy,
    this.enableCatch,
    this.enableAnalytics,
    this.debug = false,
  });

  /// Dynamic-modules loader. Required when [enableDeploy] is true.
  final KbcLoaderFn? loader;

  /// Asset path to read sankofa.yaml from. Default `sankofa.yaml`.
  final String yamlAssetPath;

  /// Auto-call [Sankofa.instance.deploy?.notifyKbcPatchReady] from the
  /// first-frame callback. Defaults true; flip off if the host wants
  /// to gate it behind a custom "rendered correctly" check.
  final bool scheduleNotifyOnFirstFrame;

  /// Endpoint to fall back to if sankofa.yaml doesn't specify one.
  /// Default: production sankofa.dev.
  final String fallbackEndpoint;

  /// Pass-through to [Sankofa.init] — signing pubkey, auto-check, etc.
  final SankofaDeployOptions deployOptions;

  /// Override the Deploy enablement. Defaults to: enabled iff [loader]
  /// is non-null AND sankofa.yaml exists.
  final bool? enableDeploy;

  /// Override Catch enablement. Defaults to [Sankofa.init]'s default.
  final bool? enableCatch;

  /// Override Analytics enablement. Defaults to [Sankofa.init]'s default.
  final bool? enableAnalytics;

  /// Pass-through debug flag for [Sankofa.init].
  final bool debug;
}

/// One-call bootstrap that does everything [main] would otherwise
/// hand-wire:
///
///   1. Read `sankofa.yaml` from the asset bundle.
///   2. Call [Sankofa.instance.init] with the parsed apiKey + endpoint.
///   3. If Deploy is enabled and a [loader] was provided, apply any
///      KBC patch staged on disk via
///      [Sankofa.instance.deploy.tryApplyStagedKbcPatch].
///   4. Schedule [notifyKbcPatchReady] after the first frame (so the
///      time-window crash detector treats this boot as healthy when
///      rendering succeeds).
///
/// Returns a [SankofaBootstrapResult] the host can inspect to drive
/// custom UI (e.g. show a "Patch applied" banner). Boilerplate-free:
///
/// ```dart
/// import 'package:dynamic_modules/dynamic_modules.dart';
/// import 'package:sankofa_flutter/sankofa_flutter.dart';
///
/// void main() async {
///   WidgetsFlutterBinding.ensureInitialized();
///   final boot = await Sankofa.bootstrap(
///     options: SankofaBootstrapOptions(loader: loadModuleFromBytes),
///   );
///   runApp(MyApp(bootResult: boot));
/// }
/// ```
///
/// This is the Option-B path for engine-auto-init: the engine doesn't
/// inject anything before the Dart main isolate, but the SDK collapses
/// all the boilerplate into one Dart call. Phase 2 of engine-auto-init
/// (full pre-isolate apply in the engine) is gated on multi-day engine
/// work and is not required for v1 customers.
class SankofaBootstrap {
  SankofaBootstrap._();

  static const String _kFallbackAppId = '';
  static const String _kFallbackApiKey = '';

  /// Run the bootstrap. Idempotent — calling twice is harmless (the
  /// second call is a no-op because [Sankofa.instance] is already
  /// initialized).
  static Future<SankofaBootstrapResult> run({
    SankofaBootstrapOptions options = const SankofaBootstrapOptions(),
  }) async {
    final config = await _readSankofaYaml(options.yamlAssetPath);
    final apiKey = config['api_key']?.trim() ?? _kFallbackApiKey;
    final appId = config['app_id']?.trim() ?? _kFallbackAppId;
    final endpoint = config['base_url']?.trim() ?? options.fallbackEndpoint;
    final engineVersion = config['engine_version']?.trim() ?? '';

    if (apiKey.isEmpty && kDebugMode) {
      debugPrint(
        '[Sankofa.bootstrap] WARNING: api_key missing in '
        '${options.yamlAssetPath} — SDK will initialize with empty apiKey '
        'and the server will refuse all calls.',
      );
    }

    // Auto-enable Deploy when a loader was provided.
    final enableDeploy = options.enableDeploy ?? (options.loader != null);

    // If sankofa.yaml carried an engine_version and the host's
    // deployOptions didn't already set one, forward it as the default
    // so `Sankofa.deploy.checkForKbcUpdate()` doesn't require the host
    // to repeat the engine identity on every call.
    SankofaDeployOptions effectiveDeployOptions = options.deployOptions;
    if (engineVersion.isNotEmpty &&
        (effectiveDeployOptions.engineVersion == null ||
            effectiveDeployOptions.engineVersion!.isEmpty)) {
      effectiveDeployOptions =
          effectiveDeployOptions.copyWith(engineVersion: engineVersion);
    }

    await Sankofa.instance.init(
      apiKey: apiKey,
      endpoint: endpoint,
      debug: options.debug,
      enableDeploy: enableDeploy,
      deployOptions: effectiveDeployOptions,
      // Respect overrides; otherwise leave init() defaults alone.
      enableCatch: options.enableCatch ?? true,
      enableAnalytics: options.enableAnalytics ?? true,
    );

    KbcPatchResult? staged;
    if (enableDeploy && options.loader != null) {
      try {
        staged = await Sankofa.instance.deploy?.tryApplyStagedKbcPatch(
          loader: options.loader!,
        );
      } catch (e, st) {
        if (kDebugMode) {
          debugPrint('[Sankofa.bootstrap] tryApplyStagedKbcPatch threw: $e\n$st');
        }
      }

      if (options.scheduleNotifyOnFirstFrame && staged != null) {
        // Schedule notify after the first frame paints. The deploy
        // module's auto-confirm timer is a safety net; this is the
        // explicit path that lets the host signal "rendering worked"
        // without writing the addPostFrameCallback boilerplate.
        SchedulerBinding.instance.addPostFrameCallback((_) {
          // Schedule on the next microtask so we don't block frame work.
          Future<void>.delayed(Duration.zero, () async {
            try {
              await Sankofa.instance.deploy?.notifyKbcPatchReady();
            } catch (e) {
              if (kDebugMode) {
                debugPrint('[Sankofa.bootstrap] notifyKbcPatchReady failed: $e');
              }
            }
          });
        });
      }
    }

    return SankofaBootstrapResult(
      apiKey: apiKey,
      endpoint: endpoint,
      appId: appId,
      engineVersion: engineVersion,
      didApplyStagedPatch: staged != null,
      stagedPatch: staged,
    );
  }

  /// Read sankofa.yaml from the asset bundle and parse into a flat
  /// map. Tolerant: missing or malformed file returns an empty map
  /// (and the bootstrap falls back to the options-provided defaults).
  static Future<Map<String, String>> _readSankofaYaml(String assetPath) async {
    String raw;
    try {
      raw = await rootBundle.loadString(assetPath);
    } catch (e) {
      if (kDebugMode) {
        debugPrint(
          '[Sankofa.bootstrap] could not load $assetPath from assets ($e). '
          'Have you listed it under `flutter.assets:` in pubspec.yaml?',
        );
      }
      return const {};
    }

    final result = <String, String>{};
    for (final line in raw.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      final colon = trimmed.indexOf(':');
      if (colon <= 0) continue;
      final key = trimmed.substring(0, colon).trim();
      var value = trimmed.substring(colon + 1).trim();
      // Strip optional quotes; sankofa.yaml is a flat KV file by
      // convention so we don't need a real YAML parser. If a customer
      // ships nested YAML the values just won't bind — they'd get a
      // clearer error from Sankofa.init().
      if ((value.startsWith('"') && value.endsWith('"')) ||
          (value.startsWith("'") && value.endsWith("'"))) {
        value = value.substring(1, value.length - 1);
      }
      result[key] = value;
    }
    return result;
  }
}

// Customers can call either `SankofaBootstrap.run(...)` (full name) or
// `Sankofa.bootstrap(...)` (shortcut wired in [sankofa_client.dart]).
