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

  /// v2 envelope MVP — Ed25519 public key (base64 of the raw 32-byte
  /// point) that authorizes patches for this app. When set, the SDK
  /// rejects any KBC patch whose envelope is unsigned, signed with a
  /// different algorithm, or whose signature does not verify.
  ///
  /// Generate via `sankofa keys generate` on the dev machine — the CLI
  /// prints the matching public key in the exact format this field
  /// expects. The private key never leaves the dev machine.
  ///
  /// Leave null to accept any envelope (legacy / dev mode). v2.2 will
  /// move this off the host app and onto the server's /handshake
  /// response, but for MVP we keep the trust root in the host bundle
  /// so the SDK has no extra round-trip on cold start.
  final String? signingPubkeyB64;

  const SankofaDeployOptions({
    this.appReadyTimeout = const Duration(seconds: 10),
    this.autoCheckOnStartup = true,
    this.signingPubkeyB64,
  });

  /// Serialized form sent over the platform channel to the Kotlin/Swift
  /// side. Keys mirror the receiving `SankofaDeployPlugin.kt` parameter
  /// names exactly. signingPubkeyB64 is NOT forwarded — the Dart side is
  /// the only consumer (envelope verification happens before bytes hit
  /// the platform plugin).
  Map<String, dynamic> toMap({required String apiKey, required String endpoint}) => {
        'apiKey': apiKey,
        'endpoint': endpoint,
        'appReadyTimeoutMs': appReadyTimeout.inMilliseconds,
        'autoCheckOnStartup': autoCheckOnStartup,
      };
}
