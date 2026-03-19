import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;

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
    SankofaReplayMode replayMode = SankofaReplayMode.wireframe,
    int replayFps = 1,
  }) async {
    if (_isInitialized) await dispose();

    _logger = SankofaLogger(debug: debug);
    _identity = SankofaIdentity(logger: _logger);
    
    final v1BaseUri = UriHelper.resolveV1BaseUri(endpoint);
    final trackUri = UriHelper.resolveTrackUri(endpoint);
    final serverBaseUri = UriHelper.resolveServerBaseUri(endpoint);

    _queueManager = SankofaQueueManager(
      logger: _logger,
      apiKey: apiKey,
      v1BaseUri: v1BaseUri,
      trackUri: trackUri,
    );

    _sessionManager = SankofaSessionManager(
      logger: _logger,
      onNewSession: () async {
        if (!enableSessionReplay) return;

        // Remote Configuration Sync
        _replayConfig = await _fetchReplayConfig(apiKey, serverBaseUri);
        final config = _replayConfig ?? SankofaReplayConfig.defaults();

        if (!config.enabled) return;

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
    _deepLinks.init();
    _lifecycleObserver.init();

    _flushTimer = Timer.periodic(
      const Duration(seconds: kFlushIntervalSeconds),
      (_) => _queueManager.flush(),
    );

    if (trackLifecycleEvents) {
      await track('\$app_opened');
    }

    _isInitialized = true;
    _logger.log('⚡ Sankofa initialized');
  }

  /// Tracks a custom event with optional [properties].
  Future<void> track(String eventName, [Map<String, dynamic>? properties]) async {
    if (!_isInitialized) {
      _logger.log('❌ Sankofa not initialized');
      return;
    }

    await _sessionManager.refresh();
    
    final networkProps = await SankofaNetworkInfo.getProperties(_logger);
    _defaultProperties.addAll(networkProps);

    final event = SankofaTrack.createEvent(
      eventName: eventName,
      distinctId: _identity.distinctId,
      sessionId: _sessionManager.sessionId!,
      defaultProperties: _defaultProperties,
      properties: properties,
    );

    await _queueManager.add(event);
    _logger.log('📝 Tracked: $eventName');

    // Check for High Fidelity Triggers
    if (_replayConfig != null && _replayConfig!.highFidelityTriggers.contains(eventName)) {
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
    await _identity.identify(userId, (event) => _queueManager.add(event));
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

  Future<SankofaReplayConfig?> _fetchReplayConfig(String apiKey, Uri baseUri) async {
    try {
      final response = await http.get(
        baseUri.replace(path: '/api/v1/replay/config'),
        headers: {'x-api-key': apiKey},
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return SankofaReplayConfig.fromJson(data);
      }
    } catch (e) {
      _logger.log('⚠️ Failed to fetch replay config: $e');
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
}
