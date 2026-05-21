/// Result of a Sankofa Deploy update check or install lifecycle event.
///
/// Mirrors the same enum in the Android plugin's `SankofaUpdaterJNI`
/// return-codes layer (`SankofaUpdaterReturnCode`). When the platform
/// channel receives a status string, it is mapped to one of these
/// values via [SankofaDeployPlatform._parseStatus].
enum UpdateStatus {
  /// No newer patch available for the current engine + binary version.
  upToDate,

  /// A patch is available and (depending on policy) staged for install
  /// on the next launch.
  updateAvailable,

  /// A patch download is in progress; subsequent checks will land on
  /// [installed] (success) or [failed] (download error).
  downloading,

  /// A patch was downloaded, SHA-verified, and persisted. Active on
  /// next app launch.
  installed,

  /// The update flow encountered an unrecoverable error. The host can
  /// inspect the platform log for details.
  failed,

  /// A previously installed patch was rolled back (auto-recovery from
  /// a crash loop). The app is running the prior-good version.
  rolledBack,
}
