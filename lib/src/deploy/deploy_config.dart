/// Per-module options for Sankofa Deploy (OTA updates).
///
/// Passed to [Sankofa.init] as `deployOptions:` when `enableDeploy: true`.
/// The apiKey + endpoint are inherited from the parent [Sankofa.init]
/// call so the host never has to repeat them.
class SankofaDeployOptions {
  /// Maximum time we'll wait for the host's `Sankofa.deploy.notifyAppReady()`
  /// call before assuming the new patch boot-looped and triggering a
  /// rollback. Mirrors the same timer in the Rust updater's
  /// `notify_app_ready_timeout` field.
  ///
  /// Defaults to 10 seconds — long enough for any reasonable app to
  /// finish the cold-start path, short enough that crash-looping users
  /// recover quickly.
  final Duration appReadyTimeout;

  /// When true, the SDK fires off an update check during init —
  /// equivalent to calling `Sankofa.deploy.checkForUpdate()` manually
  /// at startup. Defaults to true because the common case is "ship
  /// patches on launch."
  final bool autoCheckOnStartup;

  const SankofaDeployOptions({
    this.appReadyTimeout = const Duration(seconds: 10),
    this.autoCheckOnStartup = true,
  });

  /// Serialized form sent over the platform channel to the Kotlin/Swift
  /// side. Keys mirror the receiving `SankofaDeployPlugin.kt` parameter
  /// names exactly.
  Map<String, dynamic> toMap({required String apiKey, required String endpoint}) => {
        'apiKey': apiKey,
        'endpoint': endpoint,
        'appReadyTimeoutMs': appReadyTimeout.inMilliseconds,
        'autoCheckOnStartup': autoCheckOnStartup,
      };
}
