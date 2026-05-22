import Foundation
import SankofaUpdaterFFI

/// Swift-side façade over the Sankofa Rust updater's iOS FFI surface.
///
/// Mirrors the Android `SankofaUpdaterJNI` API one-to-one so the
/// Dart-facing behaviour is identical across platforms. The
/// underlying static library is shipped by the
/// `SankofaUpdaterFFI.xcframework` vendored in the sankofa_flutter
/// pod, built by `flutter-deploy/sankofa-flutter-deploy/updater/build-ios.sh`.
///
/// All `native*` calls below cross into the Rust core via the C ABI
/// declared in `sankofa_updater.h`. The Rust side is thread-safe (every
/// entry wraps a Mutex around the Manager singleton), so it's safe to
/// call from any queue — though in practice all initialization happens
/// once on the main queue during `application(_:didFinishLaunchingWithOptions:)`.
public enum SankofaUpdaterBridge {

    /// True once `nativeInit` has been called with a non-error return
    /// code. Toggled by the AppDelegate's pre-engine hook and read by
    /// the Dart-side SankofaDeploy plugin to short-circuit redundant
    /// re-initialisation when the host already wired things up.
    public static var isInitialized: Bool = false

    /// Sankofa API key (`sk_live_*` / `sk_test_*`). Resolved by
    /// `SankofaFlutterAppDelegate.configureSankofaFromInfoPlist()`
    /// from the `com.sankofa.apiKey` key the CLI's `init` command
    /// writes to Info.plist.
    public static var apiKey: String?

    /// Sankofa API endpoint base URL. Trailing slashes stripped at
    /// write time so downstream URL construction stays unambiguous.
    public static var endpoint: String? {
        didSet {
            if let raw = endpoint, raw.hasSuffix("/") {
                endpoint = String(raw.dropLast())
            }
        }
    }

    /// Initialize the Rust updater. Wraps `sankofa_updater_init`. All
    /// four arguments must be non-empty strings; passing empties to
    /// Rust would surface as `SANKOFA_INVALID_INPUT`.
    @discardableResult
    public static func nativeInit(
        appId: String,
        baselineLibappPath: String,
        dataDir: String,
        baselineEngineVersion: String
    ) -> SankofaUpdaterReturnCode {
        let rc = appId.withCString { appIdC in
            baselineLibappPath.withCString { baselineC in
                dataDir.withCString { dataDirC in
                    baselineEngineVersion.withCString { engineVerC in
                        sankofa_updater_init(appIdC, baselineC, dataDirC, engineVerC)
                    }
                }
            }
        }
        let code = SankofaUpdaterReturnCode(rawValue: Int(rc)) ?? .fatal
        // SANKOFA_OK and SANKOFA_RECOVERED both indicate a working
        // updater — the rolled-back boot is still a successful init.
        if code == .ok || code == .recovered {
            isInitialized = true
        }
        return code
    }

    /// Returns the absolute filesystem path the Flutter engine should
    /// load the AOT snapshot from, or `nil` if init hasn't run or
    /// returned an error. The C string is owned by the Rust updater
    /// — we copy into a Swift `String` so the caller doesn't have to
    /// reason about pointer lifetime.
    public static func nativeGetLibappPath() -> String? {
        guard let ptr = sankofa_updater_get_libapp_path() else { return nil }
        return String(cString: ptr)
    }

    /// Returns the active patch version (`"baseline"` or e.g.
    /// `"v1.2.3-hotfix"`). nil before init or after a fatal error.
    public static func nativeGetActiveVersion() -> String? {
        guard let ptr = sankofa_updater_get_active_version() else { return nil }
        return String(cString: ptr)
    }

    /// Notify the Rust updater that the app reached its first frame
    /// without crashing. Called from the Dart plugin once `runApp(...)`
    /// resolves cleanly.
    public static func nativeNotifyAppReady() {
        sankofa_updater_notify_app_ready()
    }

    /// Record a crash. Called from the iOS NSException handler in
    /// `SankofaFlutterPlugin.swift` so the next boot's init can decide
    /// whether to roll back the active patch.
    public static func nativeReportCrash() {
        sankofa_updater_report_crash()
    }

    /// Drop the updater singleton. Mobile apps rarely need this; we
    /// keep it for hot-reload + test scenarios where the same process
    /// re-inits the updater repeatedly.
    public static func nativeShutdown() {
        sankofa_updater_shutdown()
        isInitialized = false
    }

    /// FFI library version string (matches Cargo.toml's package
    /// version). Useful as a runtime smoke-test that the static lib
    /// linked cleanly + as the value surfaced to Dart via
    /// `Sankofa.instance.deploy?.engineForkVersion`.
    public static func nativeVersion() -> String {
        guard let ptr = sankofa_updater_version() else { return "unknown" }
        return String(cString: ptr)
    }

    /// Mark the current patch dead. Returns the same int the C ABI
    /// returns: 0 = no patch was active (no-op), 1 = marked dead,
    /// negative = persistence error. Surfaced to the Dart plugin as
    /// `disableCurrentPatch()`.
    @discardableResult
    public static func nativeDisableCurrentPatch() -> Int {
        return Int(sankofa_updater_disable_current_patch())
    }
}

/// Mirrors the C-side `SankofaUpdaterReturnCode` enum exposed in
/// `sankofa_updater.h`. Kept as a Swift-native enum so callers can
/// pattern-match without dragging raw `Int32` everywhere.
public enum SankofaUpdaterReturnCode: Int {
    case ok = 0
    case invalidInput = 1
    case recovered = 2
    case fatal = 3
    /// `nativeInit` returned a code we don't recognise. Treat as fatal.
    case notInitialized = -1
}
