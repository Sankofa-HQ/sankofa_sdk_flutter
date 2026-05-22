import Foundation

/// Swift-side façade over the Sankofa Rust updater's iOS FFI surface.
///
/// Mirrors the Android `SankofaUpdaterJNI` API one-to-one so the
/// Dart-facing behaviour is identical across platforms. Once the
/// Rust updater is ported to iOS (Phase 6 — Rust updater on iOS), the
/// `native*` methods will bind to the FFI symbols via `@_silgen_name`
/// or a `module.modulemap` exposing the C header from
/// `cli/sankofa-cli/rust/sankofa-updater-ffi/include`.
///
/// **Current state** (Phase 6 not done): every `native*` method is a
/// stub that returns the "no active patch / not initialized" value.
/// This is intentional — it lets:
///
///   - the CLI's `init --deploy --flutter` auto-patch reference
///     `SankofaFlutterAppDelegate` today, without compile errors,
///   - `SankofaFlutterAppDelegate` fall through cleanly to vanilla
///     Flutter behaviour (no override → APK-default snapshot loads),
///   - the API surface customers wire up to remain stable when the
///     Rust port lands — only this file changes, not their code.
///
/// When the Rust port ships, `nativeGetLibappPath()` returns the
/// resolved path to the OTA-installed AOT snapshot (analog of
/// Android's `libapp.so` — on iOS, the App framework's AOT image
/// inside `App.framework/App`).
public enum SankofaUpdaterBridge {

    /// True once any caller has successfully invoked `nativeInit`.
    /// Read by the SankofaDeploy plugin to short-circuit the Dart-side
    /// init when something earlier in app lifecycle has already run
    /// pre-engine. Mirrors Android's `SankofaUpdaterJNI.isInitialized`.
    public static var isInitialized: Bool = false

    /// Sankofa API key (`sk_live_*` / `sk_test_*`). Set by whichever
    /// code path initializes the updater first (the AppDelegate's
    /// `application(_:didFinishLaunchingWithOptions:)` reading
    /// Info.plist, or the Dart side via the SankofaDeploy plugin).
    public static var apiKey: String?

    /// Sankofa API endpoint base URL. Trailing slashes stripped at
    /// write time so URL construction is unambiguous.
    public static var endpoint: String? {
        didSet {
            if let raw = endpoint, raw.hasSuffix("/") {
                endpoint = String(raw.dropLast())
            }
        }
    }

    /// Initialize the iOS Rust updater. Stub until Phase 6 lands —
    /// returns `notInitialized` so callers fall through to vanilla
    /// Flutter behaviour.
    @discardableResult
    public static func nativeInit(
        appId: String,
        baselineLibappPath: String,
        dataDir: String,
        baselineEngineVersion: String
    ) -> SankofaUpdaterReturnCode {
        // Phase 6 will replace this stub with a call into the Rust
        // updater's iOS FFI: `sankofa_updater_init(app_id, …)`.
        // The Android side stores `apiKey` / `endpoint` from the
        // earliest init caller; mirror that here so the configuration
        // is observable even though the actual init is a no-op.
        return .notInitialized
    }

    /// Returns the absolute filesystem path to the active OTA-installed
    /// AOT snapshot, or `nil` if no patch is active OR the updater has
    /// not been initialized.
    ///
    /// `SankofaFlutterAppDelegate` queries this on first engine boot
    /// and, when non-nil, passes the path to Flutter as
    /// `--aot-shared-library-name=<path>` — the same engine flag the
    /// Android `SankofaFlutterActivity` uses.
    public static func nativeGetLibappPath() -> String? {
        // Phase 6: bridge to `sankofa_updater_get_libapp_path()`.
        return nil
    }

    /// Returns the active patch version string (e.g. "v1.2.3-hotfix")
    /// or nil when no patch is active. Surfaced to Dart via the plugin
    /// so apps can read `Sankofa.instance.deploy?.activeVersion`.
    public static func nativeGetActiveVersion() -> String? {
        return nil
    }

    /// Called by the Dart side from `notifyAppReady()` once the app's
    /// first frame has rendered without crashing. Tells the updater
    /// the active patch is safe to "promote" — future cold boots will
    /// continue serving it instead of rolling back to the baseline.
    public static func nativeNotifyAppReady() {
        // Phase 6: bridge to `sankofa_updater_notify_app_ready()`.
    }

    /// Called from the iOS NSException + signal handler in
    /// `SankofaFlutterPlugin.swift` so the Rust updater can roll back
    /// the active patch on the next cold boot. Idempotent.
    public static func nativeReportCrash() {
        // Phase 6: bridge to `sankofa_updater_report_crash()`.
    }

    /// Tear-down hook for hot-reload / process-survives-test paths.
    /// Production app processes never call this — the OS reclaims the
    /// updater state when the process exits.
    public static func nativeShutdown() {
        // Phase 6: bridge to `sankofa_updater_shutdown()`.
    }

    /// SDK version string the Dart plugin surfaces via
    /// `Sankofa.instance.deploy?.engineForkVersion`. Pulled from the
    /// Flutter engine binary's compile-time fork suffix (the
    /// `<commit>+sankofa-1` marker added by the Phase 6 iOS-fork-marker
    /// engine patch) once Phase 6 wires the FFI bridge.
    public static func nativeVersion() -> String {
        // Phase 6: bridge to `sankofa_updater_version()`.
        return "0.0.0-stub"
    }
}

/// Mirrors the Android `SankofaUpdaterReturnCode` and the C-side
/// `SANKOFA_*` constants so the Dart-facing API behaves identically.
public enum SankofaUpdaterReturnCode: Int {
    case ok = 0
    case invalidInput = 1
    case recovered = 2
    case fatal = 3
    case notInitialized = -1
}
