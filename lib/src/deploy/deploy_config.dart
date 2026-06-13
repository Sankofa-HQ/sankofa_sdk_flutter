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

  /// Sankofa-engine identity this app was built against
  /// (e.g. `3.44.0+sankofa-1`). Used as the default `engineVersion`
  /// passed to `/api/deploy/check` whenever the host calls
  /// `Sankofa.deploy.checkForKbcUpdate()` / `downloadKbcUpdate` /
  /// `fetchAndApplyKbcPatch` without an explicit override.
  ///
  /// When null, those calls require the host to pass `engineVersion:`
  /// explicitly. The recommended pattern is to set it once here at
  /// init time and forget about it for every subsequent call.
  ///
  /// [SankofaBootstrap.run] auto-fills this from `sankofa.yaml`'s
  /// `engine_version` field if the field isn't already set.
  final String? engineVersion;

  /// Default platform string sent to `/api/deploy/check` when the host
  /// doesn't override it. When null, the SDK derives it from
  /// `Platform.isIOS` / `Platform.isAndroid` at call time. Override
  /// only when running on an exotic host the SDK can't detect (e.g.
  /// integration tests with a faked Platform).
  final String? platformOverride;

  const SankofaDeployOptions({
    this.appReadyTimeout = const Duration(seconds: 10),
    this.autoCheckOnStartup = true,
    this.signingPubkeyB64,
    this.engineVersion,
    this.platformOverride,
  });

  /// Returns a copy with [engineVersion] overridden — used by
  /// [SankofaBootstrap.run] to bind the engine version read from
  /// `sankofa.yaml` without making the host re-construct the options
  /// object themselves.
  SankofaDeployOptions copyWith({
    Duration? appReadyTimeout,
    bool? autoCheckOnStartup,
    String? signingPubkeyB64,
    String? engineVersion,
    String? platformOverride,
  }) {
    return SankofaDeployOptions(
      appReadyTimeout: appReadyTimeout ?? this.appReadyTimeout,
      autoCheckOnStartup: autoCheckOnStartup ?? this.autoCheckOnStartup,
      signingPubkeyB64: signingPubkeyB64 ?? this.signingPubkeyB64,
      engineVersion: engineVersion ?? this.engineVersion,
      platformOverride: platformOverride ?? this.platformOverride,
    );
  }

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
        // The Android plugin's handshake + nativeInit otherwise fall back
        // to a compile-time baseline constant — which mis-gates the
        // server's engine_version release filter the moment the app runs
        // a newer engine than the constant.
        if (engineVersion != null) 'engineVersion': engineVersion,
      };
}
