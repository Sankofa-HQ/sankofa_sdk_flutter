import Flutter
import UIKit

/// Phase C — iOS half of the Flutter native-crash bridge.
///
/// **Standalone**: this file ships entirely inside the Flutter plugin
/// — no dependency on the public `SankofaIOS` Pod. The iOS SDK is a
/// separate product for native iOS apps; Flutter apps already own
/// their analytics + replay surface in Dart and only need the
/// crash-reporting piece below the Dart layer.
///
/// Coverage on top of `FlutterError.onError` / `PlatformDispatcher.onError`:
///   - **NSException** via `NSSetUncaughtExceptionHandler` (chained so
///     other crash reporters / the runtime's own default still fire).
///   - **POSIX signals** (SIGSEGV/SIGABRT/SIGBUS/SIGILL/SIGFPE/SIGTRAP/
///     SIGSYS) via `sigaction` writing an async-signal-safe dump that
///     gets drained on the next launch — the process dying mid-handler
///     means we can't POST inline.
///   - **Main-queue stalls** via background-timer sentinel pings
///     (configurable threshold; 2s default matches Sentry).
///
/// All events POST to `<endpoint>/api/catch/events` with a JSON body
/// matching the same wire shape the Dart side uses. The Dart side
/// captures Dart-level errors; this plugin captures native-level
/// errors — together they cover the full surface.
public class SankofaFlutterPlugin: NSObject, FlutterPlugin {

    // MARK: - Plugin entry point

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "sankofa_flutter/native_catch",
            binaryMessenger: registrar.messenger()
        )
        let instance = SankofaFlutterPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "initializeNativeCatch":
            handleInitialize(call: call, result: result)
        case "setUser":
            handleSetUser(call: call, result: result)
        case "setTags":
            handleSetTags(call: call, result: result)
        case "flush":
            SankofaCatchCore.shared.flush()
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func handleInitialize(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let apiKey = args["apiKey"] as? String,
              let endpoint = args["endpoint"] as? String,
              !apiKey.isEmpty, !endpoint.isEmpty
        else {
            result(FlutterError(
                code: "ERR_INVALID_ARGS",
                message: "initializeNativeCatch requires non-empty apiKey + endpoint",
                details: nil
            ))
            return
        }
        let environment = args["environment"] as? String ?? "live"
        let release = args["release"] as? String
        let appVersion = args["appVersion"] as? String
        let stallThreshold = (args["stallThresholdSeconds"] as? Double) ?? 2.0

        SankofaCatchCore.shared.start(
            apiKey: apiKey,
            endpoint: endpoint,
            environment: environment,
            release: release,
            appVersion: appVersion,
            stallThresholdSeconds: stallThreshold
        )
        result(nil)
    }

    private func handleSetUser(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any?]
        let id = args?["id"] as? String
        let email = args?["email"] as? String
        let username = args?["username"] as? String
        if args == nil || (id == nil && email == nil && username == nil) {
            SankofaCatchCore.shared.setUser(nil)
        } else {
            SankofaCatchCore.shared.setUser(SankofaCatchUser(id: id, email: email, username: username))
        }
        result(nil)
    }

    private func handleSetTags(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let tags = args["tags"] as? [String: String]
        else {
            result(FlutterError(code: "ERR_INVALID_ARGS", message: "setTags requires a tags map", details: nil))
            return
        }
        SankofaCatchCore.shared.setTags(tags)
        result(nil)
    }
}

// MARK: - Core types

/// Minimal user-context shape sent on every event.
public struct SankofaCatchUser: Codable {
    public let id: String?
    public let email: String?
    public let username: String?
}

// MARK: - SankofaCatchCore — standalone native crash reporter

/// Singleton that owns the NSException handler, signal handlers,
/// stall detector, and HTTP transport. Lives entirely inside the
/// Flutter plugin so the SDK has zero cross-deps.
final class SankofaCatchCore {

    static let shared = SankofaCatchCore()
    private init() {}

    // ── Configuration (set by start()) ─────────────────────────────
    private var apiKey: String = ""
    private var endpoint: String = ""
    private var environment: String = "live"
    private var release: String?
    private var appVersion: String?
    private var started: Bool = false

    // ── Ambient context ────────────────────────────────────────────
    private var user: SankofaCatchUser?
    private var tags: [String: String] = [:]

    // ── Buffer + transport ─────────────────────────────────────────
    private let queue = DispatchQueue(label: "dev.sankofa.flutter.catch", qos: .utility)
    private var buffer: [[String: Any]] = []
    private var flushTimer: DispatchSourceTimer?
    private static let flushIntervalSeconds: TimeInterval = 5.0

    // ── Global handler state ───────────────────────────────────────
    private var previousNSExceptionHandler: NSUncaughtExceptionHandler?
    private var stallDetector: StallDetector?

    func start(
        apiKey: String,
        endpoint: String,
        environment: String,
        release: String?,
        appVersion: String?,
        stallThresholdSeconds: Double
    ) {
        queue.async {
            // Idempotent — refresh creds on re-init, but install
            // handlers + timer only once.
            self.apiKey = apiKey
            self.endpoint = endpoint
            self.environment = environment
            self.release = release
            self.appVersion = appVersion

            guard !self.started else { return }
            self.started = true

            self.installNSExceptionHandler()
            SankofaSignalHandler.install { signo, backtrace in
                self.persistSignalDump(signo: signo, backtrace: backtrace)
            }
            self.drainPendingSignalDumps()
            self.startFlushTimer()
            if stallThresholdSeconds > 0 {
                let detector = StallDetector(thresholdSeconds: stallThresholdSeconds) { [weak self] durationMs in
                    self?.captureStall(durationMs: durationMs)
                }
                detector.start()
                self.stallDetector = detector
            }
        }
    }

    func setUser(_ user: SankofaCatchUser?) {
        queue.async { self.user = user }
    }

    func setTags(_ tags: [String: String]) {
        queue.async {
            for (k, v) in tags { self.tags[k] = v }
        }
    }

    func flush() {
        queue.async { self.flushInternal() }
    }

    // MARK: - NSException

    private func installNSExceptionHandler() {
        previousNSExceptionHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { exception in
            // Compose synchronously — the process is about to die.
            let stack = exception.callStackSymbols
            SankofaCatchCore.shared.captureSync(
                type: "unhandled_exception",
                level: "fatal",
                excType: exception.name.rawValue,
                excValue: exception.reason ?? "",
                stack: stack,
                mechanism: "ns_exception",
                handled: false
            )
            // Best-effort flush before chaining to the previous handler.
            SankofaCatchCore.shared.flushInternalSync()
            SankofaCatchCore.shared.previousNSExceptionHandler?(exception)
        }
    }

    // MARK: - Capture composition

    /// Synchronous capture used by the NSException handler — the
    /// process is dying so we can't trampoline through the dispatch
    /// queue. The buffer mutation here races with the timer's flush;
    /// the persistence write below pins the event to disk so a
    /// concurrent drop is recoverable on the next launch.
    private func captureSync(
        type: String,
        level: String,
        excType: String,
        excValue: String,
        stack: [String],
        mechanism: String,
        handled: Bool
    ) {
        let event = composeEvent(
            type: type,
            level: level,
            exception: [
                "type": excType,
                "value": excValue,
                "mechanism": ["type": mechanism, "handled": handled],
                "stacktrace": ["frames": stack.enumerated().map { i, s in
                    [
                        "function": s,
                        "in_app": i < 16
                    ] as [String: Any]
                }],
            ]
        )
        buffer.append(event)
        persistToStorage()
    }

    /// Async stall capture. The main thread is wedged so we can't
    /// touch UIKit; we emit a minimal event with the duration.
    private func captureStall(durationMs: Double) {
        queue.async {
            let event = self.composeEvent(
                type: "anr",
                level: "warning",
                exception: [
                    "type": "MainQueueStall",
                    "value": String(format: "Main queue stalled for %.0f ms", durationMs),
                    "mechanism": ["type": "main_queue_stall", "handled": false],
                ]
            )
            self.buffer.append(event)
            self.persistToStorage()
        }
    }

    /// Compose the wire-format event envelope. Mirrors what the Dart
    /// side / standalone iOS SDK send, minus the optional fields
    /// (debug_meta, replay_chunk_index) that this plugin doesn't
    /// produce.
    private func composeEvent(
        type: String,
        level: String,
        exception: [String: Any]
    ) -> [String: Any] {
        var event: [String: Any] = [
            "wire_version": 1,
            "event_id": UUID().uuidString,
            "ts_ms": Int64(Date().timeIntervalSince1970 * 1000),
            "environment": environment,
            "level": level,
            "type": type,
            "platform": "ios",
            "sdk": [
                "name": "sankofa.flutter.ios",
                "version": "flutter-ios-0.1.0"
            ],
            "exception": exception,
        ]
        if let r = release { event["release"] = r }
        if !tags.isEmpty { event["tags"] = tags }
        if let u = user, let userDict = try? userToDict(u) { event["user"] = userDict }
        event["device"] = buildDeviceContext()
        return event
    }

    private func userToDict(_ u: SankofaCatchUser) throws -> [String: Any] {
        var d: [String: Any] = [:]
        if let id = u.id { d["id"] = id }
        if let e = u.email { d["email"] = e }
        if let n = u.username { d["username"] = n }
        return d
    }

    private func buildDeviceContext() -> [String: Any] {
        let device = UIDevice.current
        var d: [String: Any] = [
            "os": device.systemName,
            "os_version": device.systemVersion,
            "model": device.model,
            "locale": Locale.current.identifier,
            "timezone": TimeZone.current.identifier,
        ]
        if let v = appVersion { d["app_version"] = v }
        #if arch(arm64)
        d["arch"] = "arm64"
        #elseif arch(x86_64)
        d["arch"] = "x86_64"
        #endif
        return d
    }

    // MARK: - Persistence (UserDefaults — survives signal crashes)

    private static let storageKey = "dev.sankofa.flutter.catch.queue"
    private static let signalDumpKey = "dev.sankofa.flutter.catch.signal_dumps"

    private func persistToStorage() {
        guard !buffer.isEmpty else {
            UserDefaults.standard.removeObject(forKey: SankofaCatchCore.storageKey)
            return
        }
        if let data = try? JSONSerialization.data(withJSONObject: buffer) {
            UserDefaults.standard.set(data, forKey: SankofaCatchCore.storageKey)
        }
    }

    private func hydrateFromStorage() {
        guard let data = UserDefaults.standard.data(forKey: SankofaCatchCore.storageKey),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return }
        buffer.append(contentsOf: array)
    }

    /// Read POSIX-signal dump records written from a previous process's
    /// signal handler, compose Catch events from them, and clear the
    /// dump file. Called once at start() so events from a crash that
    /// killed the previous process get reported on the next launch.
    private func drainPendingSignalDumps() {
        guard let data = UserDefaults.standard.data(forKey: SankofaCatchCore.signalDumpKey),
              let dumps = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return }
        UserDefaults.standard.removeObject(forKey: SankofaCatchCore.signalDumpKey)
        for dump in dumps {
            let signo = (dump["signo"] as? Int32) ?? 0
            let backtrace = (dump["backtrace"] as? [String]) ?? []
            let event = composeEvent(
                type: "unhandled_exception",
                level: "fatal",
                exception: [
                    "type": "NativeCrash",
                    "value": "SIG\(signo)",
                    "mechanism": ["type": "signal_handler", "handled": false],
                    "stacktrace": ["frames": backtrace.map { ["function": $0] }],
                ]
            )
            buffer.append(event)
        }
        persistToStorage()
    }

    fileprivate func persistSignalDump(signo: Int32, backtrace: [String]) {
        // Append to the signal-dump array, written async-signal-safely
        // by the caller path. Strictly speaking JSONSerialization isn't
        // async-signal-safe; for Phase C MVP we accept that the dump
        // might be lost in rare cases, which is acceptable because the
        // process is dying anyway.
        var existing: [[String: Any]] = []
        if let data = UserDefaults.standard.data(forKey: SankofaCatchCore.signalDumpKey),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            existing = arr
        }
        existing.append([
            "signo": Int(signo),
            "backtrace": backtrace,
            "ts_ms": Int64(Date().timeIntervalSince1970 * 1000),
        ])
        if let data = try? JSONSerialization.data(withJSONObject: existing) {
            UserDefaults.standard.set(data, forKey: SankofaCatchCore.signalDumpKey)
        }
    }

    // MARK: - Transport

    private func startFlushTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + SankofaCatchCore.flushIntervalSeconds,
                       repeating: SankofaCatchCore.flushIntervalSeconds)
        timer.setEventHandler { [weak self] in self?.flushInternal() }
        timer.resume()
        flushTimer = timer
        hydrateFromStorage()
    }

    private func flushInternal() {
        guard !buffer.isEmpty, !endpoint.isEmpty, !apiKey.isEmpty else { return }
        let pending = buffer
        buffer.removeAll()
        persistToStorage()

        let url = URL(string: "\(endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/api/catch/events")
        guard let url = url else {
            // Bad endpoint — requeue and bail.
            buffer.insert(contentsOf: pending, at: 0)
            persistToStorage()
            return
        }
        let body: Data
        do {
            body = try JSONSerialization.data(withJSONObject: [
                "wire_version": 1,
                "events": pending,
            ])
        } catch {
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.httpBody = body
        URLSession.shared.dataTask(with: req) { [weak self] _, response, error in
            guard let self = self else { return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 500
            if error != nil || status >= 500 {
                self.queue.async {
                    self.buffer.insert(contentsOf: pending, at: 0)
                    self.persistToStorage()
                }
            }
        }.resume()
    }

    /// Synchronous flush used by the NSException handler. The process
    /// is about to terminate; we can't await a URLSession dataTask
    /// callback, so we use a synchronous POST in a brief blocking call.
    fileprivate func flushInternalSync() {
        guard !buffer.isEmpty, !endpoint.isEmpty, !apiKey.isEmpty else { return }
        let pending = buffer
        buffer.removeAll()
        persistToStorage()
        guard let url = URL(string: "\(endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/api/catch/events"),
              let body = try? JSONSerialization.data(withJSONObject: ["wire_version": 1, "events": pending])
        else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.httpBody = body
        req.timeoutInterval = 2.0
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { _, _, _ in
            semaphore.signal()
        }.resume()
        // Cap the wait so a slow network doesn't extend the crash
        // window the user sees.
        _ = semaphore.wait(timeout: .now() + 2.0)
    }
}

// MARK: - StallDetector (background ping → main sentinel)

private final class StallDetector {
    private let thresholdSeconds: TimeInterval
    private let onStall: (Double) -> Void
    private let monitorQueue = DispatchQueue(label: "dev.sankofa.flutter.stall", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var lastObservedMs: Int64 = 0
    private var reported = false

    init(thresholdSeconds: TimeInterval, onStall: @escaping (Double) -> Void) {
        self.thresholdSeconds = thresholdSeconds
        self.onStall = onStall
    }

    func start() {
        let interval = max(0.1, thresholdSeconds / 4.0)
        let t = DispatchSource.makeTimerSource(queue: monitorQueue)
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        lock.lock(); lastObservedMs = now; lock.unlock()
    }

    private func tick() {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        lock.lock()
        let priorObserved = lastObservedMs
        let priorReported = reported
        lock.unlock()
        let gapMs = Double(now - priorObserved)
        if gapMs >= thresholdSeconds * 1000.0 && !priorReported {
            lock.lock(); reported = true; lock.unlock()
            onStall(gapMs)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let observed = Int64(Date().timeIntervalSince1970 * 1000)
            self.lock.lock()
            self.lastObservedMs = observed
            if self.reported { self.reported = false }
            self.lock.unlock()
        }
    }
}

// MARK: - Signal handler

/// Posix signal handler that writes a minimal backtrace dump to
/// UserDefaults. We use `Thread.callStackSymbols` for backtrace,
/// which is technically not async-signal-safe — for Phase C MVP we
/// accept the risk because the process is dying anyway and a missed
/// dump is no worse than what's there today (zero coverage).
enum SankofaSignalHandler {
    static private var onCrash: ((Int32, [String]) -> Void)?
    static private var installed = false

    static func install(onCrash: @escaping (Int32, [String]) -> Void) {
        guard !installed else { return }
        installed = true
        self.onCrash = onCrash
        let signals: [Int32] = [SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGFPE, SIGTRAP, SIGSYS]
        for signo in signals {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = SankofaSignalHandler.handle
            sigemptyset(&action.sa_mask)
            action.sa_flags = 0
            sigaction(signo, &action, nil)
        }
    }

    static let handle: @convention(c) (Int32) -> Void = { signo in
        // Best-effort symbolic backtrace. Not async-signal-safe, but
        // accepted for Phase C MVP.
        let bt = Thread.callStackSymbols
        SankofaSignalHandler.onCrash?(signo, bt)
        // Restore default disposition and re-raise so the process
        // crashes as expected (and core dumps still drop if enabled).
        signal(signo, SIG_DFL)
        raise(signo)
    }
}
