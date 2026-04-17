import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'sankofa_constants.dart';
import 'sankofa_deep_links.dart';
import 'sankofa_device_info.dart';
import 'sankofa_identity.dart';
import 'sankofa_lifecycle_observer.dart';
import 'sankofa_network_info.dart';
import 'sankofa_people.dart';
import 'sankofa_queue_manager.dart';
import 'sankofa_session_manager.dart';
import 'sankofa_track.dart';
import 'replay/sankofa_replay.dart';
import 'replay/sankofa_replay_config.dart';
import 'core/module_registry.dart';
import 'utils/logger.dart';
import 'utils/uri_helper.dart';

/// The main entry point for the Sankofa Analytics SDK.
///
/// Use [Sankofa.instance] to access the singleton client.
class Sankofa {
  /// The singleton instance of the Sankofa client.
  static final Sankofa instance = Sankofa._internal();
  Sankofa._internal();

  late SankofaLogger _logger;
  late SankofaIdentity _identity;
  late SankofaQueueManager _queueManager;
  late SankofaSessionManager _sessionManager;
  late SankofaDeepLinks _deepLinks;
  late SankofaLifecycleObserver _lifecycleObserver;

  final Map<String, String> _defaultProperties = {};
  String _currentScreen = 'Unknown';
  String get currentScreen => _currentScreen;

  SankofaReplayConfig? _replayConfig;
  bool _isInitialized = false;
  Timer? _flushTimer;

  /// Returns true if the SDK has been initialized.
  bool get isInitialized => _isInitialized;

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
  }) async {
    if (_isInitialized) await dispose();

    _logger = SankofaLogger(debug: debug);
    _identity = SankofaIdentity(logger: _logger);

    // Traffic Cop: flip core-ready so modules registered AFTER this
    // point don't emit the "registered before init()" warning.
    SankofaModuleRegistry.instance.markCoreInitialized();

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
  Future<Map<String, dynamic>?> _fetchHandshake(
    String apiKey,
    Uri baseUri,
  ) async {
    try {
      final installed = SankofaModuleRegistry.instance.getInstalledModules().join(',');
      final uri = baseUri.replace(
        path: '/api/v1/handshake',
        queryParameters: {
          'installed': installed,
          'sdk': 'flutter',
        },
      );
      final response = await http.get(
        uri,
        headers: {'x-api-key': apiKey},
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        _logger.log('🤝 Handshake OK (project: ${data['project_id']}, installed: $installed)');
        final modules = data['modules'] as Map<String, dynamic>?;

        // Traffic Cop — route each enabled module flag to its registered
        // handler. Flags for missing modules warn (debug) or no-op (release).
        await SankofaModuleRegistry.instance.routeHandshake(modules);

        return modules;
      }
      _logger.log('🤝 Handshake returned ${response.statusCode} — falling back to legacy');
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
