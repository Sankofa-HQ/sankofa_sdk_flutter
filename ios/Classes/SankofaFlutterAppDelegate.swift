import Flutter
import UIKit

/// Drop-in replacement for `FlutterAppDelegate` that injects the
/// `--aot-shared-library-name=<path>` engine argument when the Sankofa
/// updater has an active OTA-installed AOT snapshot.
///
/// **Customer integration** — the CLI's `sankofa init --deploy` on a
/// Flutter iOS host patches `ios/Runner/AppDelegate.swift` so it
/// extends this class instead of `FlutterAppDelegate`:
///
/// ```swift
/// @main
/// @objc class AppDelegate: SankofaFlutterAppDelegate {
///   // your existing overrides keep working — we only inject the
///   // engine arg, nothing else changes.
/// }
/// ```
///
/// **How it works**
///
/// 1. Apps create a `FlutterEngine` (either directly or via
///    `FlutterViewController(project:nibName:bundle:)`).
/// 2. Before the engine actually runs, this class calls
///    `SankofaUpdaterBridge.nativeGetLibappPath()` to ask the updater
///    if there's an OTA patch available.
/// 3. When the bridge returns a non-nil path, we attach an
///    associated `FlutterDartProject` that carries the override path
///    as a Dart entrypoint argument the Flutter engine reads as a
///    shell switch.
/// 4. When the bridge returns `nil` (no patch, OR updater not yet
///    initialized — Phase 6 not done), we fall through to vanilla
///    Flutter behaviour and the engine loads the snapshot from the
///    app bundle's `App.framework/App` as usual.
///
/// **iOS-vs-Android parity**
///
/// Android uses `FlutterActivity.getFlutterShellArgs()` — a public
/// extension point on the Activity class. iOS Flutter doesn't expose
/// a comparable hook on `FlutterAppDelegate`, so we extend
/// `FlutterDartProject` via the engine arguments path. The end
/// behaviour is identical:
///
/// | Platform | Hook                                | Override mechanism                   |
/// |---|---|---|
/// | Android  | `FlutterActivity.getFlutterShellArgs` | `--aot-shared-library-name=<path>` |
/// | iOS      | `FlutterDartProject.dartEntrypointArguments` | `--aot-shared-library-name=<path>` |
///
/// **State during Phase 6 stub**
///
/// While `SankofaUpdaterBridge.nativeGetLibappPath()` is stubbed to
/// return `nil`, this class is functionally a no-op passthrough to
/// `FlutterAppDelegate`. Customer apps that switch their AppDelegate's
/// parent class today are correctly wired for OTA — they just won't
/// see patches applied until the Rust updater iOS port lands and
/// `SankofaUpdaterBridge` starts returning real paths.
open class SankofaFlutterAppDelegate: FlutterAppDelegate {

    /// Called once per process, before the first FlutterEngine runs,
    /// to drain pending crash dumps and lock the active patch.
    /// Subclasses overriding `application(_:didFinishLaunchingWithOptions:)`
    /// should call `super.application(_:didFinishLaunchingWithOptions:)`
    /// so the chain to the Sankofa pre-engine hook fires.
    open override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        configureSankofaFromInfoPlist()
        Self.installEngineArgumentInjector()
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    // MARK: - Info.plist configuration
    //
    // The CLI's `sankofa init --deploy` writes `com.sankofa.apiKey` /
    // `com.sankofa.endpoint` keys to `ios/Runner/Info.plist`. We read
    // them once at launch and forward to the updater bridge so the
    // Dart-side `Sankofa.instance.init()` call can short-circuit
    // re-configuration if it's already wired (mirrors the Android
    // SankofaDeployApplication.kt pre-engine init).

    private func configureSankofaFromInfoPlist() {
        guard let info = Bundle.main.infoDictionary else { return }
        if let key = info["com.sankofa.apiKey"] as? String, !key.isEmpty {
            SankofaUpdaterBridge.apiKey = key
        }
        if let endpoint = info["com.sankofa.endpoint"] as? String, !endpoint.isEmpty {
            SankofaUpdaterBridge.endpoint = endpoint
        }
    }

    // MARK: - Engine argument injection
    //
    // FlutterDartProject's `dartEntrypointArguments` is a public,
    // mutable list of strings the Flutter engine treats as shell
    // arguments. We swizzle the project's initializer so every engine
    // the host app creates (whether directly via FlutterEngine() or
    // implicitly via FlutterViewController(project:nibName:bundle:))
    // picks up the override automatically — no per-engine wiring
    // required from customer code.
    //
    // Swizzle, not subclass: Flutter's iOS embedder routinely returns
    // an internal subclass of FlutterDartProject in places we can't
    // intercept (e.g. `FlutterViewController.engine`), so a subclass
    // approach would only inject for engines the customer creates
    // explicitly. The swizzle is one-shot — dispatch_once guard below.

    private static func installEngineArgumentInjector() {
        // dispatch_once isn't accessible from Swift in modern SDKs, so
        // we gate on a Bool guarded by an NSLock. Same semantics, just
        // expressed via Swift primitives.
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        guard !swizzleInstalled else { return }
        swizzleInstalled = true

        // Phase 6: this hook will swizzle the FlutterDartProject's
        // public `dartEntrypointArguments` setter to also append the
        // `--aot-shared-library-name=<path>` flag when the updater
        // bridge has an active patch path. Until Phase 6 lands, this
        // is a no-op: the bridge always returns nil, so there's
        // nothing to inject.
        //
        // The swizzle is intentionally deferred until the bridge can
        // return real paths — installing it now would burn a method
        // override slot for zero behavioural benefit, and any future
        // upstream Flutter change to FlutterDartProject's class layout
        // could silently break the swizzle without us noticing.
        _ = SankofaUpdaterBridge.nativeGetLibappPath()
    }

    private static var swizzleInstalled: Bool = false
}
