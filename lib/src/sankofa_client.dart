import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sankofa_constants.dart';
import 'sankofa_deep_links.dart';
import 'presence_heartbeat.dart';
import 'screen_seen.dart';
import 'sankofa_device_info.dart';
import 'sankofa_identity.dart';
import 'sankofa_lifecycle_observer.dart';
import 'sankofa_network_info.dart';
import 'sankofa_people.dart';
import 'sankofa_queue_manager.dart';
import 'sankofa_session_manager.dart';
import 'sankofa_track.dart';
import 'heatmap/heatmap_snapshotter.dart';
import 'replay/sankofa_replay.dart';
import 'replay/sankofa_replay_config.dart';
import 'core/module_registry.dart';
import 'catch/catch_types.dart';
import 'catch/native_bridge.dart';
import 'catch/sankofa_catch.dart';
import 'core/integration_reporter.dart';
import 'deploy/deploy_config.dart';
import 'deploy/sankofa_deploy.dart';
import 'switch/sankofa_switch.dart';
import 'switch/flag_decision.dart';
import 'config/sankofa_config.dart';
import 'config/item_decision.dart';
import 'pulse/sankofa_pulse.dart';
import 'utils/logger.dart';
import 'utils/uri_helper.dart';
import 'sankofa_bootstrap.dart';

/// The main entry point for the Sankofa Analytics SDK.
///
/// Use [Sankofa.instance] to access the singleton client.
class Sankofa {
  /// The singleton instance of the Sankofa client.
  static final Sankofa instance = Sankofa._internal();
  Sankofa._internal();

  /// One-call startup: read sankofa.yaml from the asset bundle, init
  /// the SDK with the parsed apiKey + endpoint, apply any KBC patch
  /// staged on disk, and schedule `notifyKbcPatchReady` after the
  /// first frame paints.
  ///
  /// Replaces ~15 lines of boilerplate in `main()` with one call. See
  /// [SankofaBootstrap.run] for the full contract.
  ///
  /// ```dart
  /// import 'package:dynamic_modules/dynamic_modules.dart';
  /// import 'package:sankofa_flutter/sankofa_flutter.dart';
  ///
  /// void main() async {
  ///   WidgetsFlutterBinding.ensureInitialized();
  ///   final boot = await Sankofa.bootstrap(
  ///     options: SankofaBootstrapOptions(loader: loadModuleFromBytes),
  ///   );
  ///   runApp(MyApp(bootResult: boot));
  /// }
  /// ```
  static Future<SankofaBootstrapResult> bootstrap({
    SankofaBootstrapOptions options = const SankofaBootstrapOptions(),
  }) {
    return SankofaBootstrap.run(options: options);
  }

  // ───────────────────────────────────────────────────────────────────
  // Static error-tracking helpers — Crashlytics + Sentry style
  // ───────────────────────────────────────────────────────────────────
  //
  // These delegate to the active [SankofaCatch] singleton (auto-
  // constructed by `Sankofa.instance.init(enableCatch: true)`).  Calls
  // before init runs degrade to no-ops so host code never has to guard.
  //
  // Why they're static: this is the API surface the host should reach
  // for from anywhere — `Sankofa.captureException(err)` from a deeply
  // nested screen, no instance plumbing.  The full instance API
  // (`SankofaCatch.instance!.foo`) stays available for advanced users
  // who need it.

  /// Record a handled exception with an optional stack trace + options.
  /// Uncaught errors are captured automatically — only call this when
  /// you caught an error yourself but still want it reported (e.g.
  /// inside a `try/catch` that recovered gracefully but should log).
  /// Returns the event id (empty string when Catch isn't initialized).
  static String captureException(
    Object error, [
    Object? stackTrace,
    CatchCaptureOptions? options,
  ]) {
    return SankofaCatch.instance?.captureException(error, stackTrace, options) ?? '';
  }

  /// Record a free-form message as a standalone Catch event.  Use this
  /// for "interesting non-error" reports where you want a billable
  /// event (e.g. "payment retry exhausted").  For pure "log this
  /// breadcrumb" use [log] instead — it's free.
  static String captureMessage(String message, [CatchCaptureOptions? options]) {
    return SankofaCatch.instance?.captureMessage(message, options) ?? '';
  }

  /// Crashlytics-style structured log.  Adds a breadcrumb that rides
  /// on the next captured event.  Free, doesn't bill — use liberally
  /// to narrate user activity ("entered checkout", "tapped pay").
  static void log(String message, {String? category}) {
    SankofaCatch.instance?.log(message, category: category);
  }

  /// Attach a single tag to every subsequent event.  Sticky — call
  /// again with a new value to update.  For per-event scoping use
  /// [withScope] instead.
  static void setTag(String key, String value) {
    SankofaCatch.instance?.setTag(key, value);
    // Mirror onto the native side so an NSException / JVM crash that
    // fires after this call carries the same tag.
    unawaited(SankofaNativeCatchBridge.setTags({key: value}));
  }

  /// Attach multiple tags at once.  Sticky.
  static void setTags(Map<String, String> tags) {
    SankofaCatch.instance?.setTags(tags);
    unawaited(SankofaNativeCatchBridge.setTags(tags));
  }

  /// Attach an arbitrary contextual value to every subsequent event.
  /// Sticky.  Use for non-string context (numbers, lists, maps) that
  /// doesn't fit the tag shape.
  static void setExtra(String key, dynamic value) {
    SankofaCatch.instance?.setExtra(key, value);
  }

  /// Identify the user.  Sticky — pass `null` to clear (e.g. on logout).
  static void setUser(CatchUserContext? user) {
    SankofaCatch.instance?.setUser(user);
    unawaited(SankofaNativeCatchBridge.setUser(
      id: user?.id,
      email: user?.email,
      username: user?.username,
    ));
  }

  /// Push a custom breadcrumb.  Auto-captured ones (HTTP, navigation,
  /// console.error etc.) already flow without this; reach for it when
  /// you want a structured marker like `addBreadcrumb(category: 'auth',
  /// message: 'token refreshed')`.
  static void addBreadcrumb(CatchBreadcrumb crumb) {
    SankofaCatch.instance?.addBreadcrumb(crumb);
  }

  /// Run [fn] with a temporary scope.  Mutations made via the scope
  /// (tags, extras, user, level, fingerprint) overlay onto any
  /// [captureException] / [captureMessage] calls inside [fn].  Outside
  /// [fn] the scope is gone — async captures deferred past the
  /// closure's return will NOT see the scope.
  ///
  /// No-op when Catch isn't initialized; [fn] still runs with a sink
  /// scope so host code that does work alongside captures isn't skipped.
  ///
  /// ```dart
  /// Sankofa.withScope((scope) {
  ///   scope.setTag('flow', 'checkout');
  ///   scope.setExtra('cart_id', cart.id);
  ///   Sankofa.captureException(err);
  /// });
  /// ```
  static T withScope<T>(T Function(SankofaCatchScope scope) fn) {
    final c = SankofaCatch.instance;
    if (c != null) return c.withScope(fn);
    return fn(SankofaCatchScope());
  }

  /// Force a flush of any pending Catch events.  No-op when Catch
  /// isn't initialized.  Pair with [Sankofa.flush] (the analytics
  /// flush) when you want to evacuate everything before backgrounding.
  /// Flushes both the Dart-side queue AND the native iOS/Android
  /// queue so both layers are evacuated.
  static Future<void> flushCatch() async {
    final c = SankofaCatch.instance;
    if (c != null) await c.flush();
    await SankofaNativeCatchBridge.flush();
  }

  late SankofaLogger _logger;
  late SankofaIdentity _identity;
  late SankofaQueueManager _queueManager;
  late SankofaSessionManager _sessionManager;
  late SankofaDeepLinks _deepLinks;
  late SankofaLifecycleObserver _lifecycleObserver;
  PresenceHeartbeat? _presence;
  /// Dedicated heatmap-background snapshotter. Independent of the
  /// replay frame loop — fires one stability-gated raster per
  /// `(screen, viewport-bucket)` per session so the dashboard's
  /// heatmap renders over a fully-laid-out frame instead of a
  /// mid-load capture.
  SankofaHeatmapSnapshotter? _heatmapSnapshotter;

  final Map<String, String> _defaultProperties = {};

  // Empty string is the "untagged" sentinel — set to that before the
  // host tags a screen (via `Sankofa.instance.screen(...)` or the
  // `SankofaNavigatorObserver`).  The replay recorder skips frame
  // captures and interaction emits while untagged, so cold-start
  // gestures never flow into the dashboard's "Unknown" screen bucket.
  // Mirrors the iOS / Android cold-start guard.
  String _currentScreen = '';
  String get currentScreen => _currentScreen;

  /// True once the host has tagged a screen (manually via
  /// [SankofaClient.screen] or automatically via the navigator
  /// observer).  Used by the replay pipeline to skip frames + events
  /// captured during the cold-start window before the first screen
  /// has been resolved.
  bool get hasTaggedScreen => _currentScreen.isNotEmpty;

  SankofaReplayConfig? _replayConfig;
  bool _isInitialized = false;
  // Master switch for the analytics pipeline (event tracking, auto
  // lifecycle/deep-link capture, presence heartbeat). Defaults true;
  // flipped by `init(enableAnalytics:)`. When false, `track()` no-ops
  // and the autonomous capture loops never start — but the core
  // (identity, session, the unified handshake other modules depend on)
  // still runs, so Catch/Switch/Config/Pulse/Deploy are unaffected.
  bool _analyticsEnabled = true;

  // ── Local targeting state (read by Pulse) ─────────────────────────
  //
  // Pulse evaluates targeting rules on-device, so it needs the data
  // the rules reference. The core owns these caches because `track()`
  // and `peopleSet()` live here — Pulse reads them via the getters
  // below when building its eligibility context.
  //
  // User traits last set via peopleSet/setPerson, persisted so
  // `user_property` rules still resolve on a cold start before the host
  // re-sets them this session.
  static const String _userTraitsKey = 'sankofa:user_traits';
  final Map<String, Object?> _userTraits = {};
  // Recent custom-event timestamps (epoch ms) keyed by event name, for
  // `event` targeting rules. On-device only and bounded — see
  // [_eventRetention] / [_maxEventTimestamps]. Counts since app start /
  // the retention window, NOT the server's full history.
  final Map<String, List<int>> _recentEventTimestamps = {};
  static const Duration _eventRetention = Duration(days: 30);
  static const int _maxEventTimestamps = 50;

  // Listeners notified whenever the tagged screen changes (via screen()
  // or SankofaNavigatorObserver). Pulse subscribes so screen-targeted
  // auto-show surveys re-evaluate on navigation, not just app-load /
  // resume / fetch.
  final List<void Function(String screen)> _screenChangeListeners = [];
  // Re-entrancy guard: prevents two overlapping init() calls (rebuild, hot
  // restart, failed-then-retry) from both proceeding and double-registering
  // observers / leaking a second flush timer + presence heartbeat.
  bool _initializing = false;
  Timer? _flushTimer;

  // ── Remote-config refresh ──────────────────────────────────────────
  // Config rides the unified handshake, so a "config fetch" is a
  // handshake re-fetch (cheap via If-None-Match). _configRefreshTimer
  // polls on _configFetchInterval; _lastHandshakeFetchAtMs backs the
  // minimum-fetch-interval throttle; _handshakeRefreshInFlight makes
  // concurrent refreshes single-flight.
  Timer? _configRefreshTimer;
  Uri? _serverBaseUri;
  Duration _configFetchInterval = const Duration(minutes: 30);
  int _lastHandshakeFetchAtMs = 0;
  Future<bool>? _handshakeRefreshInFlight;

  // Flutter product flavor this build is (prod/staging/…). Reported in
  // the handshake so Deploy scopes OTA updates per flavor (empty = the
  // app is unflavored → matches every release). Resolved from the
  // init(flavor:) arg, else the `--dart-define=SANKOFA_FLAVOR=...` the
  // CLI injects on flavored builds.
  String _flavor = '';

  // Cached copies of the init-time credentials so modules constructed
  // after init() (Catch, Switch, Config) can resolve their own
  // endpoints without being passed the config twice.
  String? _apiKey;
  String? _endpoint;

  /// Returns true if the SDK has been initialized.
  bool get isInitialized => _isInitialized;

  /// The API key passed to init(). Null when init() hasn't completed.
  /// Exposed so sibling modules (Catch, Switch, Config) can authenticate
  /// their own API calls without the host app plumbing credentials twice.
  String? get apiKey => _apiKey;

  /// The server endpoint passed to init(). Null when init() hasn't completed.
  String? get endpoint => _endpoint;

  /// Cached integration self-audit result from the most recent Deploy
  /// initialization. Null when Deploy isn't enabled or hasn't finished
  /// initializing yet. Future work: forward this to the server in the
  /// reverse handshake so the dashboard can surface "SDK integration
  /// incomplete" warnings to the developer.
  ModuleIntegrationStatus? _lastDeployIntegrationStatus;
  ModuleIntegrationStatus? get lastDeployIntegrationStatus => _lastDeployIntegrationStatus;

  // ─────────────────────────────────────────────────────────────────
  //  Module accessors — `Sankofa.instance.deploy`, `.flags`, `.config`,
  //  `.errors`, `.pulse`.
  //
  // Each returns the singleton constructed during `init()` when the
  // corresponding `enableX` flag was true (or that the host built
  // manually via the legacy constructor). Returns null otherwise — the
  // host gets a quiet no-op-friendly accessor rather than a thrown
  // exception, mirroring the RN SDK.
  // ─────────────────────────────────────────────────────────────────

  /// Sankofa Deploy — OTA updates. Construct via
  /// `Sankofa.instance.init(enableDeploy: true)`.
  SankofaDeploy? get deploy => SankofaDeploy.instance;

  /// Sankofa Catch — errors + crashes. Construct via
  /// `Sankofa.instance.init(enableCatch: true)` (default true).
  SankofaCatch? get errors => SankofaCatch.instance;

  /// Sankofa Switch — feature flags. Auto-constructed by
  /// `Sankofa.instance.init(enableFlags: true)` (default true); null if
  /// flags were disabled and no `SankofaSwitch()` was made by hand.
  SankofaSwitch? get flags => SankofaSwitch.instance;

  /// Sankofa Config — remote config. Auto-constructed by
  /// `Sankofa.instance.init(enableConfig: true)` (default true); null if
  /// config was disabled and none was constructed by hand.
  SankofaConfig? get config => SankofaConfig.instance;

  /// Sankofa Pulse — in-app surveys. Always returns the singleton; check
  /// [SankofaPulse.isRegistered] to know whether `init(enablePulse: true)`
  /// (default true) has wired it to the core yet.
  SankofaPulse get pulse => SankofaPulse.instance;

  /// Current identity — distinct_id + anonymous_id state. Modules that
  /// need to attach user identity to their own events (e.g. Catch) read
  /// from this rather than duplicating the identity machinery.
  SankofaIdentity? get identity => _isInitialized ? _identity : null;

  /// Current session manager — modules needing session_id (Catch for
  /// replay linking) read from here.
  SankofaSessionManager? get sessionManager => _isInitialized ? _sessionManager : null;

  /// Snapshot of the user traits last set via [peopleSet] / [setPerson]
  /// (persisted across launches). Pulse reads this to resolve
  /// `user_property` targeting rules without the host re-passing them.
  Map<String, Object?> get userTraitsSnapshot => Map.unmodifiable(_userTraits);

  /// Per-event-name counts of custom events tracked on THIS device
  /// within [window] (default 30 days, the retention cap). Pulse reads
  /// this for `event` targeting rules. Note: on-device only — it does
  /// not see events from other devices or before the SDK started.
  Map<String, int> recentEventCounts({Duration window = _eventRetention}) {
    final cutoff = DateTime.now().millisecondsSinceEpoch - window.inMilliseconds;
    final out = <String, int>{};
    _recentEventTimestamps.forEach((name, stamps) {
      final n = stamps.where((ms) => ms >= cutoff).length;
      if (n > 0) out[name] = n;
    });
    return out;
  }

  /// Subscribe to tagged-screen changes. Used by Pulse to re-evaluate
  /// screen-targeted auto-show surveys on navigation. Returns a function
  /// that removes the listener.
  void Function() addScreenChangeListener(void Function(String screen) cb) {
    _screenChangeListeners.add(cb);
    return () => _screenChangeListeners.remove(cb);
  }

  /// Initializes the Sankofa SDK with your [apiKey].
  ///
  /// Optional parameters:
  /// - [endpoint]: The base URL of your Sankofa engine (defaults to api.sankofa.dev).
  /// - [debug]: Enable verbose logging.
  /// - [trackLifecycleEvents]: Automatically track app opened/foregrounded/backgrounded.
  /// - [enableSessionReplay]: Enable recording of user sessions.
  /// - [replayMode]: Choose between [SankofaReplayMode.wireframe] (default) or [SankofaReplayMode.screenshot].
  /// - [replayFps]: The frame rate for session recording (defaults to 1 fps).
  Future<void> init({
    required String apiKey,
    String endpoint = 'https://api.sankofa.dev',
    bool debug = false,
    bool trackLifecycleEvents = true,
    bool enableSessionReplay = true,
    SankofaReplayMode replayMode = SankofaReplayMode.screenshot,
    int replayFps = 1,
    // ── Analytics (event tracking) ─────────────────────────────────
    //
    // Master switch for the analytics product — event `track()`s, the
    // auto lifecycle/deep-link capture, first-open, and the presence
    // heartbeat. Defaults ON (analytics is the SDK's baseline product).
    // Pass `enableAnalytics: false` to ship a build that runs ONLY the
    // other products (Catch/Switch/Config/Pulse/Deploy) with zero
    // analytics events leaving the device — the core handshake those
    // modules ride on still runs.
    bool enableAnalytics = true,
    // ── Catch (error tracking) ────────────────────────────────────
    //
    // Defaults match the "Crashlytics on by default" expectation —
    // hosts that want it OFF (a billing-tier downgrade, a custom
    // pipeline) pass `enableCatch: false`.  When ON, we auto-construct
    // a [SankofaCatch] singleton with handlers wired so EVERY uncaught
    // Dart error, async error, and isolate error gets reported with no
    // further setup.  Sentry-style flag/config snapshots are auto-
    // discovered from any registered [SankofaSwitch] / [SankofaConfig]
    // — no `readFlagSnapshot` boilerplate.
    bool enableCatch = true,
    String catchEnvironment = 'live',
    String? release,
    String? appVersion,
    /// Flutter product flavor this build was compiled as (e.g. 'prod',
    /// 'staging'). Reported in the handshake so Sankofa Deploy scopes OTA
    /// updates per flavor — a prod build only receives prod (or
    /// unflavored) releases. Leave null for single-flavor apps. If null,
    /// falls back to `--dart-define=SANKOFA_FLAVOR=<flavor>` (which
    /// `sankofa release/patch --flavor` injects automatically), so you
    /// usually don't pass it by hand.
    String? flavor,
    /// Synchronous hook called AFTER an event has been composed but
    /// BEFORE it's enqueued.  Return the (possibly modified) event to
    /// ship it; return `null` to drop it entirely.  Use for PII
    /// scrubbing, noise filtering, or late tag enrichment.
    BeforeSendFn? beforeSend,
    // ── Deploy (OTA updates) ──────────────────────────────────────
    //
    // When [enableDeploy] is true the SDK auto-constructs the
    // [SankofaDeploy] singleton, hands it the shared apiKey/endpoint,
    // and (per [SankofaDeployOptions.autoCheckOnStartup]) fires off
    // an initial update check. Access via `Sankofa.instance.deploy`.
    //
    // Defaults to false because Deploy is a separately-purchased
    // product family — flipping this on without a Sankofa Deploy
    // subscription just gives a no-op (the server refuses to issue
    // patches). Hosts opt in via init.
    bool enableDeploy = false,
    SankofaDeployOptions deployOptions = const SankofaDeployOptions(),
    // ── Switch (feature flags) ─────────────────────────────────────
    //
    // Auto-construct the [SankofaSwitch] singleton so flags resolve
    // the moment the handshake lands — no host-side `SankofaSwitch()`
    // boilerplate. Idempotent: a host that constructed one BEFORE
    // init() (legacy path) keeps it. Defaults ON like Catch; the
    // server handshake's `modules.switch.enabled` is authoritative, so
    // an unsubscribed tier resolves to a no-op. Pass [flagDefaults] for
    // values returned before the first handshake (and offline).
    bool enableFlags = true,
    Map<String, FlagDecision>? flagDefaults,
    // ── Config (remote config) ─────────────────────────────────────
    //
    // Same shape as Switch — auto-constructs [SankofaConfig] so typed
    // remote variables resolve from launch. Server-gated; [configDefaults]
    // back synchronous reads before the handshake.
    bool enableConfig = true,
    Map<String, ItemDecision>? configDefaults,
    /// How often the SDK refreshes remote config in the background by
    /// re-running the unified handshake (cheap — If-None-Match yields a
    /// 304 when nothing changed). This is ALSO the default
    /// minimum-fetch-interval throttle applied to manual
    /// `Sankofa.instance.config.refresh()` calls, mirroring Firebase
    /// Remote Config. Defaults to 30 minutes. Pass [Duration.zero] to
    /// disable background refresh (manual-only). Individual call sites
    /// can override the throttle per-call via
    /// `config.refresh(minimumFetchInterval: ...)`.
    Duration configFetchInterval = const Duration(minutes: 30),
    // ── Pulse (in-app surveys) ─────────────────────────────────────
    //
    // Auto-registers [SankofaPulse] against the core we stand up below
    // so the handshake's `modules.pulse` payload routes through and
    // surveys flow with no `SankofaPulse.instance.register()`
    // boilerplate. Auto-show needs no host wiring — Pulse discovers the
    // root navigator from the element tree itself. (Nested-navigator
    // apps that must pin a specific navigator can still call
    // `SankofaPulse.instance.setNavigatorKey(...)`.)
    bool enablePulse = true,
  }) async {
    // Re-entrancy guard — ignore overlapping init() calls.
    if (_initializing) return;
    _initializing = true;
    if (_isInitialized) await dispose();

    _apiKey = apiKey;
    _endpoint = endpoint;
    _configFetchInterval = configFetchInterval;
    // Explicit init(flavor:) wins; otherwise read the compile-time
    // --dart-define the CLI injects on flavored builds. Empty = unflavored.
    _flavor = (flavor != null && flavor.trim().isNotEmpty)
        ? flavor.trim()
        : const String.fromEnvironment('SANKOFA_FLAVOR');
    _analyticsEnabled = enableAnalytics;
    _logger = SankofaLogger(debug: debug);
    _identity = SankofaIdentity(logger: _logger);

    // Traffic Cop: flip core-ready so modules registered AFTER this
    // point don't emit the "registered before init()" warning.
    SankofaModuleRegistry.instance.markCoreInitialized();

    // ── Catch (error + crash tracking) ────────────────────────────
    //
    // Auto-construct the SankofaCatch singleton so the host doesn't
    // have to.  Idempotent — if the host already constructed one
    // BEFORE init() (the legacy boilerplate path), the `_instance ??=`
    // guard inside SankofaCatch keeps that instance and we skip.
    // FlutterError.onError + PlatformDispatcher.onError + isolate
    // listeners install immediately so errors that happen during the
    // remainder of init() are still captured.
    if (enableCatch && SankofaCatch.instance == null) {
      SankofaCatch(
        environment: catchEnvironment,
        release: release,
        appVersion: appVersion,
        beforeSend: beforeSend,
      );

      // Phase C — bridge into the native crash reporter on iOS +
      // Android. The Dart-side Catch above handles Dart errors
      // (FlutterError.onError, PlatformDispatcher.onError, isolate
      // listeners); the native bridge picks up what Dart can't see:
      // NSException + POSIX signals on iOS, JVM-uncaught + ANR on
      // Android. The bridge is best-effort — failures don't block
      // init, and on web/desktop it silently no-ops.
      unawaited(SankofaNativeCatchBridge.initialize(
        apiKey: apiKey,
        endpoint: endpoint,
        environment: catchEnvironment,
        release: release,
        appVersion: appVersion,
      ));
    }

    // ── Switch (feature flags) ──────────────────────────────────────
    //
    // Construct once if the host opted in and hasn't already made one.
    // The constructor self-registers with the Traffic Cop and hydrates
    // its disk cache off-frame, so flag reads work before the first
    // handshake. `SankofaSwitch.instance` is the legacy-path dedupe.
    if (enableFlags && SankofaSwitch.instance == null) {
      SankofaSwitch(defaults: flagDefaults);
    }

    // ── Config (remote config) ──────────────────────────────────────
    //
    // Same shape as Switch — `SankofaConfig.instance` dedupes a host
    // that constructed one before init() (legacy path).
    if (enableConfig && SankofaConfig.instance == null) {
      SankofaConfig(defaults: configDefaults);
    }

    // ── Pulse (in-app surveys) ──────────────────────────────────────
    //
    // Register against the core we just stood up. `register()` reads
    // the apiKey/endpoint set above, self-registers with the Traffic
    // Cop, and kicks an off-frame survey refresh — we don't await it so
    // a slow network never blocks app boot. Idempotent via
    // `isRegistered`. Auto-show resolves its own navigator from the
    // element tree, so no key wiring is needed here.
    if (enablePulse && !SankofaPulse.instance.isRegistered) {
      unawaited(SankofaPulse.instance.register());
    }

    // ── Deploy (OTA updates) ────────────────────────────────────────
    //
    // Auto-construct the [SankofaDeploy] singleton if the host opted
    // in. The platform plugin (Kotlin on Android, Swift on iOS — Phase
    // 6) is initialized lazily inside `SankofaDeploy.initInternal`.
    // We do NOT block init on the platform-channel call so a flaky
    // native side doesn't deadlock the rest of the SDK; failures land
    // in the platform logger and surface on the first
    // `Sankofa.deploy.checkForUpdate()` call.
    Future<void>? deployReady;
    if (enableDeploy && SankofaDeploy.instance == null) {
      // Resolve appVersion in priority order:
      //   1. explicit `appVersion:` argument to `Sankofa.init`
      //   2. `_defaultProperties['$app_version']` (track-time backfill)
      //   3. fallback to PackageInfo's pubspec version
      String? resolvedAppVersion = appVersion;
      if (resolvedAppVersion == null || resolvedAppVersion.isEmpty) {
        resolvedAppVersion = _defaultProperties[r'$app_version'];
      }
      if (resolvedAppVersion == null || resolvedAppVersion.isEmpty) {
        try {
          final info = await PackageInfo.fromPlatform();
          if (info.version.isNotEmpty) {
            resolvedAppVersion = info.version;
          }
        } catch (_) {
          // PackageInfo may fail on web / test envs — leave null, deploy
          // calls will require an explicit appVersion arg in that case.
        }
      }

      deployReady = SankofaDeploy.initInternal(
        apiKey: apiKey,
        endpoint: endpoint,
        options: deployOptions,
        appVersion: resolvedAppVersion,
        // Flavor scopes OTA patches per flavor on /api/deploy/check —
        // same value the handshake reports.
        flavor: _flavor.isNotEmpty ? _flavor : null,
        // Pass a getter so identify()/reset() flips reflect in
        // subsequent deploy calls without a re-init.
        distinctIdResolver: () => _identity.distinctId,
        // Bridge Deploy lifecycle → analytics: keeps $ota_label current
        // and drops a marker event when a patch applies/rolls back, so
        // graphs can be sliced by patch + correlated with a deploy.
        onLifecycleEvent: (eventType, {label, releaseId}) =>
            _handleDeployLifecycleEvent(eventType,
                label: label, releaseId: releaseId),
      ).then((deploy) async {
        // Post-init integration self-audit. Warns in debug mode when
        // the host's manifest, MainActivity, permissions, or meta-data
        // are missing pieces that would make OTA silently fail at
        // runtime. Cached for the SDK Health reverse handshake below
        // (and exposed via [lastDeployIntegrationStatus]). The report
        // itself is NOT fired here — see the Deploy-independent block
        // after this one.
        // Seed OTA attribution from the patch the device actually booted
        // on, so analytics events are tagged with the real active patch
        // (not just "baseline") from app start.
        try {
          final cur = await deploy.readCurrentPatch();
          _updateOtaSuperProps(cur?.label, cur?.releaseId);
        } catch (_) {/* best-effort — baseline default already set */}

        final status = await deploy.checkIntegration();
        _lastDeployIntegrationStatus = status;
        if (!status.isFull && kDebugMode) {
          // ignore: avoid_print
          print('');
          // ignore: avoid_print
          print('────────────────────────────────────────────────');
          // ignore: avoid_print
          print('[Sankofa Deploy] integration: ${status.level.name.toUpperCase()}');
          for (final m in status.missing) {
            // ignore: avoid_print
            print('  ✖ $m');
          }
          for (final w in status.warnings) {
            // ignore: avoid_print
            print('  ! $w');
          }
          // ignore: avoid_print
          print('────────────────────────────────────────────────');
          // ignore: avoid_print
          print('');
        }
      }).catchError((Object err, StackTrace st) {
        // Audit failures are non-fatal — leave a debug breadcrumb only.
        if (kDebugMode) {
          // ignore: avoid_print
          print('[Sankofa Deploy] integration audit threw: $err');
        }
      });
    }

    // ── SDK Health (reverse handshake) — INDEPENDENT of every product ─
    //
    // Fires for EVERY init regardless of which products are enabled, so
    // an analytics-only or Catch-only app still shows up on the
    // dashboard's SDK Health page. (This used to live INSIDE the Deploy
    // block, so apps without `enableDeploy` reported nothing — even
    // while their events and errors flowed through their own pipelines.)
    // It POSTs to /api/v1/handshake/integrations and depends on nothing
    // but the apiKey/endpoint set above. Fire-and-forget; never blocks
    // boot. When Deploy is enabled we wait for its async audit first so
    // its status lands in the same batch; otherwise we report straight
    // away off the synchronously-registered modules.
    unawaited(() async {
      if (deployReady != null) {
        try {
          await deployReady;
        } catch (_) {/* already logged above; report the rest anyway */}
      }
      await _reportSdkHealth(
        apiKey: apiKey,
        endpoint: endpoint,
        appVersion: appVersion,
      );
    }());

    final v1BaseUri = UriHelper.resolveV1BaseUri(endpoint);
    final trackUri = UriHelper.resolveTrackUri(endpoint);
    final serverBaseUri = UriHelper.resolveServerBaseUri(endpoint);
    _serverBaseUri = serverBaseUri; // reused by refreshConfig()

    _queueManager = SankofaQueueManager(
      logger: _logger,
      apiKey: apiKey,
      v1BaseUri: v1BaseUri,
      trackUri: trackUri,
      onCommands: (commands) => _handleServerCommands(commands),
    );

    _sessionManager = SankofaSessionManager(
      logger: _logger,
      onNewSession: () async {
        // ── Unified Handshake ──
        // One call to /api/v1/handshake returns the config for ALL
        // Sankofa products. We extract the replay module config here.
        // Falls back to the legacy /api/replay/config endpoint if the
        // handshake is unavailable (older server versions).
        final handshakeModules = await _fetchHandshake(apiKey, serverBaseUri);

        if (!enableSessionReplay) return;

        // Extract replay config from handshake or fetch legacy
        if (handshakeModules != null && handshakeModules.containsKey('replay')) {
          final replayData = handshakeModules['replay'] as Map<String, dynamic>?;
          _replayConfig = replayData != null
              ? SankofaReplayConfig.fromJson(replayData)
              : SankofaReplayConfig.defaults();
        } else {
          _replayConfig = await _fetchLegacyReplayConfig(apiKey, serverBaseUri) ??
              SankofaReplayConfig.defaults();
        }
        final config = _replayConfig!;

        if (!config.enabled) {
          _logger.log('⏸ Replay disabled by server config');
          return;
        }

        // Client-side Sampling
        final shouldRecord = Random().nextDouble() < config.sampleRate;
        if (!shouldRecord) {
          _logger.log('Session sampled out (Rate: ${config.sampleRate})');
          return;
        }

        await SankofaReplay.instance.configure(
          apiKey: apiKey,
          endpoint: serverBaseUri.toString(),
          sessionId: _sessionManager.sessionId!,
          distinctId: _identity.distinctId,
          mode: replayMode,
          fps: replayFps,
          debug: debug,
          deviceProperties: _defaultProperties,
          maskAllInputs: config.maskAllInputs,
        );
      },
    );

    _deepLinks = SankofaDeepLinks(
      logger: _logger,
      defaultProperties: _defaultProperties,
      onUtmCaught: (name, props) => track(name, props),
    );

    _lifecycleObserver = SankofaLifecycleObserver(
      logger: _logger,
      sessionManager: _sessionManager,
      track: (name) => track(name),
      flush: () => _queueManager.flush(),
      trackLifecycleEvents: trackLifecycleEvents,
      enableSessionReplay: enableSessionReplay,
    );

    await _identity.load();
    await _queueManager.load();
    await _loadUserTraits();

    final deviceProps = await SankofaDeviceInfo.getProperties(_logger);
    _defaultProperties.addAll(deviceProps);

    final networkProps = await SankofaNetworkInfo.getProperties(_logger);
    _defaultProperties.addAll(networkProps);

    // Seed OTA attribution so EVERY analytics event carries it from the
    // first event — even before Deploy's async boot resolves the active
    // patch (and for analytics-only apps with no Deploy at all). The
    // Deploy init block + lifecycle bridge refine this to the real patch
    // label when one is active. See [_updateOtaSuperProps].
    _defaultProperties[r'$ota_label'] = 'baseline';

    await _sessionManager.refresh();

    // Mark ready SYNCHRONOUSLY now — every core dependency (_identity,
    // _queueManager, _sessionManager, _defaultProperties) is assigned and
    // loaded. Doing this BEFORE registering the lifecycle/deep-link observers,
    // the flush timer, and the presence heartbeat closes the half-built-state
    // window where an observer callback could fire into a not-yet-ready SDK
    // and silently drop the first lifecycle/screen events.
    _isInitialized = true;

    // First Time Open Logic. Enqueue the event BEFORE flipping the persisted
    // flag so a process death between the two re-fires it next launch rather
    // than silently losing first-open.
    final prefs = await SharedPreferences.getInstance();
    const firstOpenKey = 'dev.sankofa.first_open_detected';
    if (!(prefs.getBool(firstOpenKey) ?? false)) {
      await track('\$app_open_first_time');
      await prefs.setBool(firstOpenKey, true);
    }

    _deepLinks.init();
    _lifecycleObserver.init();

    _flushTimer = Timer.periodic(
      const Duration(seconds: kFlushIntervalSeconds),
      (_) => _queueManager.flush(),
    );

    // Remote-config refresh — give the Config module a hook for manual
    // `config.refresh(...)`, then start the background poll that re-runs
    // the handshake on _configFetchInterval (throttled + If-None-Match,
    // so a 304 is cheap). Disabled when the interval is zero; floored at
    // 10s so a misconfigured tiny interval can't hammer the server.
    SankofaConfig.instance?.bindRefresher(
      (interval, force) =>
          refreshConfig(minimumFetchInterval: interval, force: force),
    );
    if (SankofaConfig.instance != null && _configFetchInterval > Duration.zero) {
      final poll = _configFetchInterval < const Duration(seconds: 10)
          ? const Duration(seconds: 10)
          : _configFetchInterval;
      _configRefreshTimer = Timer.periodic(poll, (_) => refreshConfig());
    }

    // Live-presence heartbeat — independent of analytics flush so it
    // ticks at its own cadence (15s) while the app is foregrounded.
    // Cheap one-tiny-POST-per-tick; paused on
    // AppLifecycleState.paused / hidden. Part of the analytics product,
    // so it stays dark when `enableAnalytics: false`.
    if (_analyticsEnabled) {
      _presence = PresenceHeartbeat(
        endpoint: endpoint,
        apiKey: apiKey,
        payloadProvider: () => (
          screen: hasTaggedScreen ? _currentScreen : null,
          distinctId: _identity.distinctId,
          sessionId: _sessionManager.sessionId,
        ),
      )..start();
    }

    // Heatmap snapshotter — reuses the replay recorder's root
    // RepaintBoundary key so the host only needs one wrap point. Off
    // the UI thread by virtue of `RenderRepaintBoundary.toImage()`
    // running on the raster/GPU thread.
    final String heatmapAppVersion =
        _defaultProperties['\$app_version'] ?? 'unknown';
    _heatmapSnapshotter = SankofaHeatmapSnapshotter(
      boundaryKey: SankofaReplay.instance.rootBoundaryKey,
      endpoint: endpoint,
      apiKey: apiKey,
      appVersion: heatmapAppVersion,
      debug: debug ? (msg) => _logger.log(msg) : null,
    );

    await track('\$session_start');

    _initializing = false;
    _logger.log('⚡ Sankofa initialized');
  }
  
  /// Explicitly tag the screen the user is currently viewing.
  /// Crucial for building accurate Heatmaps in the Dashboard.
  Future<void> screen(String screenName, [Map<String, dynamic>? properties]) async {
    if (!_isInitialized) return;

    final changed = screenName != _currentScreen;
    _currentScreen = screenName;
    _defaultProperties['\$screen_name'] = screenName;

    // Notify subscribers (Pulse) so screen-targeted auto-show surveys
    // re-evaluate on navigation. Only on an actual change — a re-tag of
    // the same screen shouldn't re-pump. Listener errors are isolated.
    if (changed) {
      for (final cb in List.of(_screenChangeListeners)) {
        try {
          cb(screenName);
        } catch (_) {/* a faulty listener never breaks screen tracking */}
      }
    }

    // Fire a standard screen_view event
    final screenProps = properties ?? {};
    screenProps['\$screen_name'] = screenName;

    await track('\$screen_view', screenProps);
    // Canonical screen signal — fires regardless of which Sankofa
    // products the host has enabled, so the lexicon + dwell + presence
    // are always populated.
    unawaited(emitScreenSeen(
      endpoint: _endpoint ?? '',
      apiKey: _apiKey ?? '',
      screen: screenName,
      distinctId: _identity.distinctId,
      sessionId: _sessionManager.sessionId,
      properties: properties,
    ));
    // Stability-gated heatmap snapshot. Deduped inside the
    // snapshotter — repeated screen() calls on the same view are
    // no-ops, and a quick re-tag during the settle window supersedes
    // the previous schedule.
    _heatmapSnapshotter?.scheduleCapture(screenName);
    _logger.log('📍 Screen changed to: $screenName');
  }

  /// SDK Health reverse handshake — audits every installed module and
  /// POSTs the batch to `/api/v1/handshake/integrations` so the
  /// dashboard's SDK Health page reflects this app. Independent of
  /// which products are enabled: it walks the Module Registry, so
  /// whatever was constructed (Catch / Switch / Config / Pulse /
  /// Deploy) gets reported. Fire-and-forget — every error is swallowed
  /// (the next launch re-runs the audit).
  Future<void> _reportSdkHealth({
    required String apiKey,
    required String endpoint,
    String? appVersion,
  }) async {
    try {
      final batch = <ModuleIntegrationStatus>[];
      // Analytics is the SDK's core — it never registers as a
      // SankofaModule (it has no Traffic Cop handshake of its own), so
      // the registry walk below can't see it. Synthesize its status
      // explicitly when enabled: if init() got this far the event
      // pipeline is up, so it's `full`. Without this, SDK Health shows
      // every product EXCEPT analytics even though events are flowing.
      if (_analyticsEnabled) {
        batch.add(ModuleIntegrationStatus.full(SankofaModuleName.analytics));
      }
      // Deploy audits asynchronously over a platform channel; prefer its
      // cached result so we don't fire a second channel call here. Every
      // other module's checkIntegration() is cheap and synchronous-ish.
      final cachedDeploy = _lastDeployIntegrationStatus;
      for (final mod in SankofaModuleRegistry.instance.installed()) {
        if (mod.name == SankofaModuleName.deploy && cachedDeploy != null) {
          continue; // added below from cache
        }
        try {
          final dynamic dynMod = mod;
          final result = dynMod.checkIntegration();
          if (result is Future<ModuleIntegrationStatus>) {
            batch.add(await result);
          } else if (result is ModuleIntegrationStatus) {
            batch.add(result);
          }
        } catch (_) {
          // Per-module audit errors stay quiet; the next launch re-runs.
        }
      }
      if (cachedDeploy != null) batch.add(cachedDeploy);
      if (batch.isEmpty) return; // nothing installed — nothing to report
      await reportIntegrationStatuses(
        apiKey: apiKey,
        serverBaseUri: UriHelper.resolveServerBaseUri(endpoint),
        statuses: batch,
        appVersion: appVersion,
        debug: kDebugMode,
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[Sankofa] SDK Health report failed: $e');
      }
    }
  }

  /// Tracks a custom event with optional [properties].
  /// Sets the OTA-attribution super-properties so every subsequent
  /// analytics event carries the active patch identity. `null`/empty label
  /// means the device is on its store build → `$ota_label: 'baseline'`.
  /// Cheap: a couple of map writes, no disk I/O.
  void _updateOtaSuperProps(String? label, String? releaseId) {
    final resolved = (label != null && label.isNotEmpty) ? label : 'baseline';
    _defaultProperties[r'$ota_label'] = resolved;
    if (releaseId != null && releaseId.isNotEmpty) {
      _defaultProperties[r'$ota_release_id'] = releaseId;
    } else {
      _defaultProperties.remove(r'$ota_release_id');
    }
    // Tag Dart-side crashes with the active patch too, so Catch can answer
    // "which patch was this user on when it crashed". (OTA patches are Dart
    // bytecode, so the Dart Catch path is where patch-induced crashes
    // surface.) Best-effort — Catch may be disabled.
    try {
      SankofaCatch.instance?.setTag('ota_label', resolved);
      if (releaseId != null && releaseId.isNotEmpty) {
        SankofaCatch.instance?.setTag('ota_release_id', releaseId);
      }
    } catch (_) {/* Catch off / not ready */}
  }

  /// Bridges Deploy lifecycle events into analytics. On a successful apply
  /// it refreshes [_updateOtaSuperProps] and emits a `$ota_applied` marker
  /// (so a deploy shows up on the timeline / can be correlated with a
  /// change in the numbers); on a rollback it resets to baseline and emits
  /// `$ota_rolled_back`. Other lifecycle events (download, skipped) are
  /// ignored for analytics. Invoked from [SankofaDeploy] via the
  /// `onLifecycleEvent` callback registered at init.
  void _handleDeployLifecycleEvent(
    String eventType, {
    String? label,
    String? releaseId,
  }) {
    switch (eventType) {
      case 'kbc_apply_success':
      case 'kbc_boot_apply_success':
        _updateOtaSuperProps(label, releaseId);
        unawaited(track(r'$ota_applied', {
          r'$ota_label': label ?? 'baseline',
          if (releaseId != null && releaseId.isNotEmpty)
            r'$ota_release_id': releaseId,
        }));
        break;
      case 'kbc_boot_apply_skipped_rollback':
      case 'kbc_patch_restored_from_last_good':
        // Restored to the previous good patch (or baseline). The restored
        // label isn't known here; reset to baseline — the next cold boot
        // re-reads the real active patch at init.
        _updateOtaSuperProps(null, null);
        unawaited(track(r'$ota_rolled_back', {
          if (label != null && label.isNotEmpty) r'$ota_from_label': label,
        }));
        break;
      default:
        break;
    }
  }

  Future<void> track(
    String eventName, [
    Map<String, dynamic>? properties,
  ]) async {
    if (!_isInitialized && (eventName != '\$app_open_first_time' && eventName != '\$session_start')) {
      _logger.log('❌ Sankofa not initialized');
      return;
    }

    // Analytics product disabled — drop every event (manual + auto
    // lifecycle/deep-link/first-open) so nothing reaches the queue.
    // The other products run their own pipelines and are unaffected.
    if (!_analyticsEnabled) return;

    // Refresh only if not initialized yet (for first internal events) or normally
    if (_isInitialized) await _sessionManager.refresh();

    final networkProps = await SankofaNetworkInfo.getProperties(_logger);
    _defaultProperties.addAll(networkProps);

    // Manual > Auto Injection
    final eventProps = properties ?? {};
    if (!eventProps.containsKey('\$screen_name')) {
      eventProps['\$screen_name'] = _currentScreen;
    }

    final event = SankofaTrack.createEvent(
      eventName: eventName,
      distinctId: _identity.distinctId,
      sessionId: _sessionManager.sessionId!,
      defaultProperties: _defaultProperties,
      properties: eventProps,
    );

    await _queueManager.add(event);
    _logger.log('📝 Tracked: $eventName');

    // Record for Pulse `event` targeting rules. Bounded ring per name:
    // prune past the retention window and cap the list length so a
    // chatty event can't grow unbounded.
    final stamps = _recentEventTimestamps.putIfAbsent(eventName, () => <int>[]);
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    stamps.add(nowMs);
    final cutoff = nowMs - _eventRetention.inMilliseconds;
    stamps.removeWhere((ms) => ms < cutoff);
    if (stamps.length > _maxEventTimestamps) {
      stamps.removeRange(0, stamps.length - _maxEventTimestamps);
    }

    // Check for High Fidelity Triggers
    if (_replayConfig != null &&
        _replayConfig!.highFidelityTriggers.contains(eventName)) {
      _logger.log('🚀 High Fidelity Trigger fired: $eventName');
      SankofaReplay.instance.triggerHighFidelityMode(
        Duration(seconds: _replayConfig!.highFidelityDurationSeconds),
      );
    }
  }

  /// Identifies the current user with a unique [userId].
  ///
  /// This merges the anonymous session data with the identified user profile.
  Future<void> identify(String userId) async {
    if (!_isInitialized) return;
    await _identity.identify(
      userId,
      _sessionManager.sessionId!,
      (event) => _queueManager.add(event),
    );
    await _queueManager.flush();
    SankofaReplay.instance.setDistinctId(userId);
  }

  /// Resets the current user identity and starts a fresh anonymous session.
  Future<void> reset() async {
    if (!_isInitialized) return;
    await _queueManager.flush();
    await _identity.reset();
    // Re-point replay at the new anonymous id — otherwise post-logout frames
    // keep being attributed to the previous (identified) user.
    SankofaReplay.instance.setDistinctId(_identity.distinctId);
    await _sessionManager.startNewSession();
  }

  /// Sets profile attributes for the current user.
  Future<void> peopleSet(Map<String, dynamic> properties) async {
    if (!_isInitialized) return;
    // Cache locally (and persist) so Pulse `user_property` rules can
    // resolve against these traits — including on the next cold start.
    _userTraits.addAll(properties);
    unawaited(_persistUserTraits());
    final event = SankofaPeople.createProfileEvent(
      distinctId: _identity.distinctId,
      sessionId: _sessionManager.sessionId!,
      properties: properties,
      defaultProperties: _defaultProperties,
    );
    await _queueManager.add(event);
    await _queueManager.flush();
  }

  /// Persist [_userTraits] for cold-start targeting. Best-effort.
  Future<void> _persistUserTraits() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_userTraitsKey, jsonEncode(_userTraits));
    } catch (_) {/* best-effort — targeting still works in-session */}
  }

  /// Hydrate [_userTraits] from disk. Called once during init.
  Future<void> _loadUserTraits() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_userTraitsKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        _userTraits.addAll(decoded);
      }
    } catch (_) {/* best-effort */}
  }

  /// A convenience method to set common user traits like [name], [email], and [avatar].
  Future<void> setPerson({
    String? name,
    String? email,
    String? avatar,
    Map<String, dynamic>? properties,
  }) async {
    final traits = SankofaPeople.getPersonProperties(
      name: name,
      email: email,
      avatar: avatar,
      properties: properties,
    );
    await peopleSet(traits);
  }

  /// Forces an immediate upload of all queued events.
  Future<void> flush() async {
    if (!_isInitialized) return;
    await _queueManager.flush();
  }

  /// Unified handshake — fetches ALL module configs in one call.
  /// Returns the `modules` map, or null on failure.
  ///
  /// Reverse Handshake: appends `installed=analytics,deploy,...` so the
  /// server knows what this app binary can actually run. The dashboard
  /// uses this to gate UI toggles for modules the SDK doesn't have.
  /// Legacy SDKs (no `installed` param) default to "allow everything"
  /// server-side so we stay backward compatible.
  /// Cached modules map from the last successful handshake. Used when
  /// the server returns 304 so the Traffic Cop still gets its routing
  /// pass — late-registered modules (constructed between handshakes)
  /// still pick up the payload they missed.
  Map<String, dynamic>? _cachedHandshakeModules;

  /// Composite ETag from the last successful handshake. Sent as
  /// If-None-Match on the next refresh. Server computes this by
  /// hashing every module's per-module etag (see
  /// server/engine/ee/deploy/handshake.go#computeCompositeEtag).
  String _handshakeEtag = '';

  Future<Map<String, dynamic>?> _fetchHandshake(
    String apiKey,
    Uri baseUri,
  ) async {
    try {
      final installed =
          SankofaModuleRegistry.instance.getInstalledModules().join(',');

      // Device context — the server's evaluator needs distinct_id to
      // bucket rollouts deterministically, resolve cohort membership,
      // and honor user allow-lists. platform + os_version + app_version
      // feed the version-range targeting engine. Missing fields
      // gracefully no-op server-side; we send what we have.
      final query = <String, String>{
        'installed': installed,
        'sdk': 'flutter',
      };
      final did = _identity.distinctId;
      if (did.isNotEmpty) {
        query['distinct_id'] = did;
      }
      // Identity stitching — forward the pre-identify anon id when
      // identify() has fired (post-identify distinctId diverges from
      // anonymousId). The server uses it to fold pre/post login
      // evaluations and exposures into a single experiment subject.
      final anonId = _identity.anonymousId;
      if (anonId != null && anonId.isNotEmpty && anonId != did) {
        query['anon_id'] = anonId;
      }
      // Platform is sync + always available. Use the "ios" / "android"
      // normalised form the server expects.
      if (Platform.isIOS) {
        query['platform'] = 'ios';
      } else if (Platform.isAndroid) {
        query['platform'] = 'android';
      } else {
        query['platform'] = Platform.operatingSystem;
      }
      // App version from package_info — the marketing version the
      // server's semver range compares against. PackageInfo caches
      // internally so calling it every handshake is cheap.
      try {
        final info = await PackageInfo.fromPlatform();
        if (info.version.isNotEmpty) {
          query['app_version'] = info.version;
        }
      } catch (_) {
        // Non-fatal — targeting on version just won't apply.
      }
      // Locale from the PlatformDispatcher — always sync.
      try {
        final locale = ui.PlatformDispatcher.instance.locale;
        final tag = locale.toLanguageTag();
        if (tag.isNotEmpty) query['locale'] = tag;
      } catch (_) {
        // Non-fatal.
      }
      // Flutter flavor — lets Deploy scope OTA updates per flavor.
      // Omitted when unflavored (server treats absent/empty as wildcard).
      if (_flavor.isNotEmpty) {
        query['flavor'] = _flavor;
      }

      final uri = baseUri.replace(
        path: '/api/v1/handshake',
        queryParameters: query,
      );
      final headers = <String, String>{'x-api-key': apiKey};
      if (_handshakeEtag.isNotEmpty) {
        headers['If-None-Match'] = _handshakeEtag;
      }
      final response = await http
          .get(uri, headers: headers)
          .timeout(const Duration(seconds: 10));

      // 304 — cache still current. Re-fire Traffic Cop so modules
      // registered between the last handshake and now pick up the
      // payload they missed (common during hot reload in dev).
      if (response.statusCode == 304 && _cachedHandshakeModules != null) {
        _logger.log('🤝 Handshake 304 — cached modules still current');
        _lastHandshakeFetchAtMs = DateTime.now().millisecondsSinceEpoch;
        await SankofaModuleRegistry.instance
            .routeHandshake(_cachedHandshakeModules);
        return _cachedHandshakeModules;
      }

      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        _logger.log(
            '🤝 Handshake OK (project: ${data['project_id']}, installed: $installed)');
        final modules = data['modules'] as Map<String, dynamic>?;
        _cachedHandshakeModules = modules;
        _lastHandshakeFetchAtMs = DateTime.now().millisecondsSinceEpoch;
        final etag =
            response.headers['etag'] ?? response.headers['ETag'] ?? '';
        _handshakeEtag = etag;

        // Traffic Cop — route each enabled module flag to its registered
        // handler. Flags for missing modules warn (debug) or no-op (release).
        await SankofaModuleRegistry.instance.routeHandshake(modules);

        return modules;
      }
      _logger.log(
          '🤝 Handshake returned ${response.statusCode} — falling back to legacy');
    } catch (e) {
      _logger.log('⚠️ Handshake failed: $e — falling back to legacy');
    }
    return null;
  }

  /// Refreshes remote config (and the rest of the unified handshake)
  /// from the server, honoring a minimum-fetch-interval throttle —
  /// Sankofa's analogue of Firebase Remote Config's `fetch()`.
  ///
  /// Returns `true` when a network fetch actually ran (config may have
  /// changed — listeners registered via `config.onChange` fire on any
  /// diff), or `false` when the last fetch was still within the throttle
  /// window and the cached values were kept.
  ///
  /// [minimumFetchInterval] overrides — for THIS call only — the
  /// `configFetchInterval` set at `init()`. Pass a shorter value on a
  /// screen that needs fresher config than the global default, or
  /// [Duration.zero] (or [force]) to always fetch. This is what lets
  /// different call sites use different intervals.
  ///
  /// Reads stay synchronous and offline-safe throughout — the cache only
  /// flips to new values once the fetch lands.
  Future<bool> refreshConfig({
    Duration? minimumFetchInterval,
    bool force = false,
  }) async {
    if (!_isInitialized || _apiKey == null || _serverBaseUri == null) {
      return false;
    }
    if (!force && _lastHandshakeFetchAtMs > 0) {
      final interval = minimumFetchInterval ?? _configFetchInterval;
      final age = DateTime.now().millisecondsSinceEpoch - _lastHandshakeFetchAtMs;
      if (age < interval.inMilliseconds) {
        return false; // within throttle window — cached values stand
      }
    }
    // Single-flight: concurrent callers (timer + manual) await one fetch.
    final inFlight = _handshakeRefreshInFlight;
    if (inFlight != null) return inFlight;
    final f = _doRefreshHandshake();
    _handshakeRefreshInFlight =
        f.whenComplete(() => _handshakeRefreshInFlight = null);
    return _handshakeRefreshInFlight!;
  }

  Future<bool> _doRefreshHandshake() async {
    try {
      await _fetchHandshake(_apiKey!, _serverBaseUri!);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Legacy fallback for servers without the /api/v1/handshake endpoint.
  Future<SankofaReplayConfig?> _fetchLegacyReplayConfig(
    String apiKey,
    Uri baseUri,
  ) async {
    try {
      final response = await http.get(
        baseUri.replace(path: '/api/replay/config'),
        headers: {'x-api-key': apiKey},
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return SankofaReplayConfig.fromJson(data);
      }
    } catch (e) {
      _logger.log('⚠️ Legacy replay config fetch failed: $e');
    }
    return null;
  }

  /// Disposes of the SDK resources and stops all timers and recording.
  Future<void> dispose() async {
    _isInitialized = false;
    _flushTimer?.cancel();
    _configRefreshTimer?.cancel();
    _configRefreshTimer = null;
    _deepLinks.dispose();
    _lifecycleObserver.dispose();
    _presence?.stop();
    _presence = null;
    _heatmapSnapshotter?.dispose();
    _heatmapSnapshotter = null;
    _queueManager.dispose();
    SankofaReplay.instance.stopRecording();
  }

  void _handleServerCommands(List<dynamic> commands) {
    for (final cmd in commands) {
      if (cmd is! Map<String, dynamic>) continue;
      final type = cmd['type'] as String?;
      final params = cmd['params'] as Map<String, dynamic>?;

      if (type == 'CAPTURE_PRISTINE' && params != null) {
        final screen = params['screen'] as String?;
        if (screen != null) {
          _logger.log('🔥 📸 Server requested pristine capture for screen: $screen');
          SankofaReplay.instance.triggerHighFidelityMode(const Duration(seconds: 1));
        }
      }
    }
  }
}
