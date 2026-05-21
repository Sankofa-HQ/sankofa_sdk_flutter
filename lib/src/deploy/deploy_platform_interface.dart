import 'package:flutter/services.dart';

import 'deploy_config.dart';
import 'update_status.dart';

/// Method-channel bridge to the native Sankofa Deploy plugin (Kotlin
/// on Android, Swift on iOS — iOS lands in Phase 6). Channel name is
/// `com.sankofa.deploy/main` because the plugin's Kotlin package is
/// `com.sankofa.deploy` and the channel registration in
/// `SankofaDeployPlugin.kt` uses the same identifier.
///
/// Kept as a singleton because the underlying Rust updater is itself
/// a process-singleton — there's exactly one state.json on disk, one
/// boot-rollback timer, etc. Multiple `SankofaDeployPlatform` instances
/// would race on the same shared state.
class SankofaDeployPlatform {
  SankofaDeployPlatform._();

  static final SankofaDeployPlatform instance = SankofaDeployPlatform._();

  static const MethodChannel _channel = MethodChannel('com.sankofa.deploy/main');

  Future<void> initialize({
    required String apiKey,
    required String endpoint,
    required SankofaDeployOptions options,
  }) async {
    await _channel.invokeMethod<void>(
      'initialize',
      options.toMap(apiKey: apiKey, endpoint: endpoint),
    );
  }

  Future<UpdateStatus> checkForUpdate() async {
    final result = await _channel.invokeMethod<String>('checkForUpdate');
    return _parseStatus(result);
  }

  Future<void> notifyAppReady() async {
    await _channel.invokeMethod<void>('notifyAppReady');
  }

  Future<void> reportCrash() async {
    await _channel.invokeMethod<void>('reportCrash');
  }

  Future<String?> getActiveVersion() async {
    return _channel.invokeMethod<String>('getActiveVersion');
  }

  Future<String?> getCurrentLibappPath() async {
    return _channel.invokeMethod<String>('getCurrentLibappPath');
  }

  Future<void> disableCurrentPatch() async {
    await _channel.invokeMethod<void>('disableCurrentPatch');
  }

  Future<void> shutdown() async {
    await _channel.invokeMethod<void>('shutdown');
  }

  /// Native integration audit. Asks the platform plugin (Kotlin /
  /// Swift) to inspect the host's runtime wiring and report what's
  /// missing. Used by [SankofaDeploy.checkIntegration]. Returns a raw
  /// map matching the Kotlin response shape:
  ///
  /// ```
  /// {
  ///   applicationClass: String,        // FQN of the host's Application
  ///   activityClass: String?,          // FQN of the current Activity (null pre-attach)
  ///   sankofaDeployApplication: bool,  // does the Application chain include SankofaDeployApplication?
  ///   sankofaFlutterActivity: bool,    // does the Activity chain include SankofaFlutterActivity?
  ///   internetPermission: bool,        // is android.permission.INTERNET in the manifest + granted?
  ///   updaterInitialized: bool,        // did the JNI bridge load + init OK?
  ///   apiKeyMetaData: bool,            // is the com.sankofa.apiKey meta-data set?
  ///   endpointMetaData: bool,          // is the com.sankofa.endpoint meta-data set?
  /// }
  /// ```
  Future<Map<String, Object?>> checkIntegration() async {
    final raw = await _channel.invokeMethod<Map<Object?, Object?>>('checkIntegration');
    if (raw == null) return const {};
    return raw.map((k, v) => MapEntry(k as String, v));
  }

  UpdateStatus _parseStatus(String? raw) {
    return switch (raw) {
      'up_to_date' => UpdateStatus.upToDate,
      'update_available' => UpdateStatus.updateAvailable,
      'downloading' => UpdateStatus.downloading,
      'installed' => UpdateStatus.installed,
      'rolled_back' => UpdateStatus.rolledBack,
      _ => UpdateStatus.failed,
    };
  }
}
