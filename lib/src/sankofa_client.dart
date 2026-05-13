import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';
import 'dart:ui' as ui;
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
import 'utils/logger.dart';
import 'utils/uri_helper.dart';

/// The main entry point for the Sankofa Analytics SDK.
///
/// Use [Sankofa.instance] to access the singleton client.
class Sankofa {
  /// The singleton instance of the Sankofa client.
  static final Sankofa instance = Sankofa._internal();
  Sankofa._internal();

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
  Timer? _flushTimer;

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

  /// Current identity — distinct_id + anonymous_id state. Modules that
  /// need to attach user identity to their own events (e.g. Catch) read
  /// from this rather than duplicating the identity machinery.
  SankofaIdentity? get identity => _isInitialized ? _identity : null;

  /// Current session manager — modules needing session_id (Catch for
  /// replay linking) read from here.
  SankofaSessionManager? get sessionManager => _isInitialized ? _sessionManager : null;

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
    /// Synchronous hook called AFTER an event has been composed but
    /// BEFORE it's enqueued.  Return the (possibly modified) event to
    /// ship it; return `null` to drop it entirely.  Use for PII
    /// scrubbing, noise filtering, or late tag enrichment.
    BeforeSendFn? beforeSend,
  }) async {
    if (_isInitialized) await dispose();

    _apiKey = apiKey;
    _endpoint = endpoint;
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

    final v1BaseUri = UriHelper.resolveV1BaseUri(endpoint);
    final trackUri = UriHelper.resolveTrackUri(endpoint);
    final serverBaseUri = UriHelper.resolveServerBaseUri(endpoint);

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

    final deviceProps = await SankofaDeviceInfo.getProperties(_logger);
    _defaultProperties.addAll(deviceProps);

    final networkProps = await SankofaNetworkInfo.getProperties(_logger);
    _defaultProperties.addAll(networkProps);

    await _sessionManager.refresh();
    
    // First Time Open Logic
    final prefs = await SharedPreferences.getInstance();
    const firstOpenKey = 'dev.sankofa.first_open_detected';
    if (!(prefs.getBool(firstOpenKey) ?? false)) {
      await prefs.setBool(firstOpenKey, true);
      await track('\$app_open_first_time');
    }

    _deepLinks.init();
    _lifecycleObserver.init();

    _flushTimer = Timer.periodic(
      const Duration(seconds: kFlushIntervalSeconds),
      (_) => _queueManager.flush(),
    );

    // Live-presence heartbeat — independent of analytics flush so it
    // ticks at its own cadence (15s) while the app is foregrounded.
    // Cheap one-tiny-POST-per-tick; paused on
    // AppLifecycleState.paused / hidden.
    _presence = PresenceHeartbeat(
      endpoint: endpoint,
      apiKey: apiKey,
      payloadProvider: () => (
        screen: hasTaggedScreen ? _currentScreen : null,
        distinctId: _identity.distinctId,
        sessionId: _sessionManager.sessionId,
      ),
    )..start();

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

    _isInitialized = true;
    _logger.log('⚡ Sankofa initialized');
  }
  
  /// Explicitly tag the screen the user is currently viewing.
  /// Crucial for building accurate Heatmaps in the Dashboard.
  Future<void> screen(String screenName, [Map<String, dynamic>? properties]) async {
    if (!_isInitialized) return;

    _currentScreen = screenName;
    _defaultProperties['\$screen_name'] = screenName;

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

  /// Tracks a custom event with optional [properties].
  Future<void> track(
    String eventName, [
    Map<String, dynamic>? properties,
  ]) async {
    if (!_isInitialized && (eventName != '\$app_open_first_time' && eventName != '\$session_start')) {
      _logger.log('❌ Sankofa not initialized');
      return;
    }

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
    await _sessionManager.startNewSession();
  }

  /// Sets profile attributes for the current user.
  Future<void> peopleSet(Map<String, dynamic> properties) async {
    if (!_isInitialized) return;
    final event = SankofaPeople.createProfileEvent(
      distinctId: _identity.distinctId,
      sessionId: _sessionManager.sessionId!,
      properties: properties,
    );
    await _queueManager.add(event);
    await _queueManager.flush();
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
    _deepLinks.dispose();
    _lifecycleObserver.dispose();
    _presence?.stop();
    _presence = null;
    _heatmapSnapshotter?.dispose();
    _heatmapSnapshotter = null;
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
