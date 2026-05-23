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
        Self.initializeUpdater()
        Self.installEngineArgumentInjector()
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    // MARK: - Updater pre-engine init
    //
    // Drives `SankofaUpdaterBridge.nativeInit` with the host app's
    // baseline AOT snapshot path (inside the bundle's App.framework),
    // a writable data dir under Caches, and a placeholder engine
    // version that the Phase 5 iOS engine hook will later replace with
    // the live `flutter::GetFlutterEngineVersion()` value.
    //
    // Idempotent — dispatch_once-style gate so multiple AppDelegate
    // instances (e.g. unit tests creating disposable hosts) don't
    // race the updater init.

    private static var updaterInitialized: Bool = false

    private static func initializeUpdater() {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        guard !updaterInitialized else { return }

        guard
            let bundleId = Bundle.main.bundleIdentifier,
            let appFramework = Bundle.main.privateFrameworksURL?.appendingPathComponent("App.framework"),
            let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else {
            // Missing standard iOS bundle layout — never expected on a
            // real device, but bail cleanly rather than crash the host.
            return
        }

        let baselinePath = appFramework.appendingPathComponent("App").path
        let dataDir = cachesDir.appendingPathComponent("sankofa-deploy").path
        try? FileManager.default.createDirectory(
            atPath: dataDir,
            withIntermediateDirectories: true
        )

        // The Phase 5 iOS engine-fork patch will FFI-export the running
        // engine's GetFlutterEngineVersion() so we can pass the live
        // value here. Until then, we use a stable placeholder that
        // matches the Sankofa fork marker baked into the engine.
        let engineVersion = "3.41.9+sankofa-1"

        let code = SankofaUpdaterBridge.nativeInit(
            appId: bundleId,
            baselineLibappPath: baselinePath,
            dataDir: dataDir,
            baselineEngineVersion: engineVersion
        )
        updaterInitialized = (code == .ok || code == .recovered)

        // Phase 5 iOS AOT override.
        //
        // If the updater has an active OTA patch, register its path
        // with the Sankofa engine fork's FlutterDartProject hook BEFORE
        // any FlutterEngine is constructed. The engine consumes this
        // value the first time FLTDefaultSettingsForBundle runs and
        // prepends it to `application_library_paths`, so the engine
        // loads the patched App framework binary instead of the
        // bundle-default.
        //
        // The class method only exists on Sankofa-built Flutter
        // frameworks (Phase 5 patch). Hosts that haven't completed the
        // Flutter.framework swap yet are still on vanilla Flutter, so
        // we guard with responds(to:) — a missing selector means OTA
        // is silently disabled, never a crash. Matches the Android
        // pattern where SankofaFlutterActivity's getFlutterShellArgs()
        // override only takes effect when the customer's APK actually
        // ships our libflutter.so.
        if updaterInitialized {
            let override = SankofaUpdaterBridge.nativeGetLibappPath()
            let setterSel = NSSelectorFromString("sankofaSetAOTSharedLibraryOverridePath:")
            if FlutterDartProject.responds(to: setterSel) {
                _ = (FlutterDartProject.self as AnyObject).perform(setterSel, with: override)
            }
        }
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
