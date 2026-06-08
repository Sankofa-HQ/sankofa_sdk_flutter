import 'package:dynamic_modules/dynamic_modules.dart' show loadModuleFromBytes;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../sankofa_bootstrap.dart';
import '../sankofa_client.dart';
import 'sankofa_update.dart';

/// **The one class you call.** Mirrors Shorebird's `ShorebirdUpdater`
/// in every respect: zero constructor arguments, lazy auto-config from
/// `sankofa.yaml`, no exposed engine versions or signing keys, no
/// `init()` to remember.
///
/// ## Setup (one-time, ~30 seconds)
///
/// 1. Add the SDK to `pubspec.yaml`:
///
///    ```yaml
///    dependencies:
///      sankofa_flutter: ^0.2.1
///    flutter:
///      assets:
///        - sankofa.yaml
///    ```
///
/// 2. Create `sankofa.yaml` in your project root:
///
///    ```yaml
///    app_id: proj_xxxxxxxxxxxxx
///    api_key: sk_live_xxxxxxxxxxxxxxxx
///    ```
///
///    (Run `sankofa init` to have the CLI write these for you.)
///
/// 3. In `main()`, apply any patch that was staged on the last run
///    BEFORE `runApp`:
///
///    ```dart
///    void main() async {
///      WidgetsFlutterBinding.ensureInitialized();
///      await SankofaUpdater.preFlight();
///      runApp(const MyApp());
///    }
///    ```
///
/// ## Customer-facing API
///
/// ```dart
/// final updater = SankofaUpdater();
///
/// // What patch is the device currently running?
/// final current = await updater.readCurrentPatch();
/// print(current?.label ?? 'baseline');
///
/// // Is a new patch available?
/// final result = await updater.checkForUpdate();
/// if (result.hasUpdate) {
///   if (result.update!.isMandatory) {
///     // skip user prompt
///     await updater.downloadUpdate(result.update!);
///   } else {
///     final yes = await showUpdateDialog(context, result.update!);
///     if (yes) {
///       await updater.downloadUpdate(
///         result.update!,
///         onProgress: (received, total) =>
///             setState(() => _progress = total > 0 ? received / total : 0),
///       );
///     }
///   }
/// }
/// ```
///
/// That's the complete public surface. Engine versions, KBC bytecode,
/// signing keys — none of it appears in customer code. The SDK reads
/// `sankofa.yaml` on first use, talks to the server, and applies
/// updates. The `how` lives in the package source — see the
/// `flutter-deploy/` repo for architecture docs.
class SankofaUpdater {
  /// Construct an updater. Zero args by design.
  ///
  /// The first method call lazily reads `sankofa.yaml` from the asset
  /// bundle and (when needed) brings up the underlying `Sankofa.deploy`
  /// module. Calling `SankofaUpdater()` multiple times is harmless —
  /// the underlying state is process-wide.
  SankofaUpdater();

  static bool _preFlightDone = false;

  /// Call once from `main()` before `runApp()`. Reads `sankofa.yaml`,
  /// applies any patch the previous run staged, and schedules the
  /// "app rendered successfully" health confirmation after the first
  /// frame paints.
  ///
  /// **Zero args.** The SDK pulls the VM bytecode loader (`loadModule
  /// FromBytes`) from `package:dynamic_modules`, which is a transitive
  /// dep of `sankofa_flutter` — customer code never imports it.
  ///
  /// Safe to call multiple times — subsequent calls are no-ops after
  /// the first.
  ///
  /// ```dart
  /// import 'package:sankofa_flutter/sankofa_flutter.dart';
  ///
  /// void main() async {
  ///   WidgetsFlutterBinding.ensureInitialized();
  ///   await SankofaUpdater.preFlight();
  ///   runApp(const MyApp());
  /// }
  /// ```
  static Future<void> preFlight() async {
    if (_preFlightDone) return;
    _preFlightDone = true;

    await SankofaBootstrap.run(
      options: const SankofaBootstrapOptions(loader: loadModuleFromBytes),
    );
  }

  /// Returns metadata for the patch currently installed on the
  /// device, or `null` when the app is running its baseline code.
  /// Same shape as Shorebird's `Patch`.
  Future<SankofaCurrentPatch?> readCurrentPatch() async {
    await _ensureReady();
    final deploy = Sankofa.instance.deploy;
    if (deploy == null) return null;
    return deploy.readCurrentPatch();
  }

  /// Asks the server whether a new patch is available for the device.
  /// Does NOT download — only returns metadata. Drives the
  /// `update.isMandatory` flag the host uses to skip / show a prompt.
  Future<SankofaUpdateCheckResult> checkForUpdate() async {
    await _ensureReady();
    final deploy = Sankofa.instance.deploy;
    if (deploy == null) {
      return const SankofaUpdateCheckResult(
        status: SankofaUpdateStatus.unavailable,
        reason: 'sankofa.yaml missing or deploy disabled — see SankofaUpdater docs',
      );
    }
    return deploy.checkForUpdate();
  }

  /// Downloads + verifies a patch returned by [checkForUpdate] and
  /// stages it for the NEXT cold boot. `onProgress` fires on every
  /// network chunk with the running `(received, total)` bytes so you
  /// can drive a progress bar without buffering the patch in memory.
  ///
  /// Apply on the next launch is automatic — `preFlight()` picks up
  /// the staged patch.
  Future<void> downloadUpdate(
    SankofaUpdate update, {
    void Function(int received, int total)? onProgress,
    Duration timeout = const Duration(minutes: 5),
  }) async {
    await _ensureReady();
    final deploy = Sankofa.instance.deploy;
    if (deploy == null) {
      throw StateError(
        'SankofaUpdater: sankofa.yaml not configured. See package readme.',
      );
    }
    await deploy.downloadUpdate(
      update,
      onProgress: onProgress,
      timeout: timeout,
    );
  }

  /// True when `sankofa.yaml` is present and the SDK is ready to
  /// receive updates. False when the deploy module couldn't be
  /// initialised (missing asset, malformed yaml, or `enableDeploy`
  /// disabled via an explicit `Sankofa.init` call). Mirrors
  /// Shorebird's `ShorebirdUpdater.isAvailable`.
  Future<bool> get isAvailable async {
    await _ensureReady();
    return Sankofa.instance.deploy != null;
  }

  /// Lazy init guard. Reads `sankofa.yaml` and brings up the deploy
  /// module if it isn't already running. Idempotent + cheap on warm
  /// calls (returns immediately once `Sankofa.instance.deploy` is
  /// non-null).
  Future<void> _ensureReady() async {
    if (Sankofa.instance.deploy != null) return;
    try {
      await SankofaBootstrap.run(
        options: const SankofaBootstrapOptions(loader: loadModuleFromBytes),
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[SankofaUpdater] auto-init failed: $e');
      }
    }
  }
}

/// Tiny helper to surface sankofa.yaml read failures more clearly
/// when SankofaUpdater is the customer's only touchpoint. Used by
/// the cookbook + a future doctor command. Not exported.
@visibleForTesting
Future<bool> sankofaYamlAssetIsPresent({String path = 'sankofa.yaml'}) async {
  try {
    await rootBundle.loadString(path);
    return true;
  } catch (_) {
    return false;
  }
}
