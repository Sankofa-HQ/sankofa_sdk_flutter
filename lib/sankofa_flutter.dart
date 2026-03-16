import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:app_links/app_links.dart';
import 'package:carrier_info/carrier_info.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'src/replay/sankofa_replay.dart';
export 'src/replay/sankofa_replay.dart';

const String _kQueueKey = 'sankofa_queue';
const String _kAnonIdKey = 'sankofa_anon_id';
const String _kSessionIdKey = 'sankofa_session_id';
const String _kLastEventTimeKey = 'sankofa_last_event_time';
const int _kSessionTimeoutMinutes = 30;

class Sankofa with WidgetsBindingObserver {
  static final Sankofa _instance = Sankofa._internal();
  static Sankofa get instance => _instance;

  String? _apiKey;
  Uri? _serverBaseUri;
  Uri? _v1BaseUri;
  Uri? _trackUri;
  String? _userId;
  String? _anonymousId;
  String? _sessionId;

  bool _isInitialized = false;
  bool _debug = false;
  bool _trackLifecycleEvents = true;
  final Map<String, String> _defaultProperties = {};

  late AppLinks _appLinks;
  StreamSubscription<Uri>? _linkSubscription;

  final List<Map<String, dynamic>> _queue = [];
  Timer? _flushTimer;
  bool _isFlushing = false;

  SankofaReplayMode _replayMode = SankofaReplayMode.wireframe;
  int _replayFps = 1;
  bool _enableSessionReplay = true;

  // High-fidelity dynamic triggers
  List<String> _highFidelityTriggers = [
    'purchase_error',
    'checkout_started',
    'app_crash',
  ];
  Duration _highFidelityDuration = const Duration(seconds: 30);

  Sankofa._internal();

  /// Initialize the SDK
  Future<void> init({
    required String apiKey,
    String endpoint = 'http://localhost:8080',
    bool debug = false,
    bool trackLifecycleEvents = true,
    bool enableSessionReplay = true,
    SankofaReplayMode replayMode = SankofaReplayMode.wireframe,
    int replayFps = 1,
  }) async {
    _resetRuntimeStateForInit();

    _apiKey = apiKey;
    _serverBaseUri = resolveServerBaseUri(endpoint);
    _v1BaseUri = resolveV1BaseUri(endpoint);
    _trackUri = resolveTrackUri(endpoint);
    _debug = debug;
    _trackLifecycleEvents = trackLifecycleEvents;
    _enableSessionReplay = enableSessionReplay;
    _replayMode = replayMode;
    _replayFps = replayFps;

    await _loadAnonymousId();
    await _loadQueue();
    await _loadDefaultProperties();
    await _updateNetworkProperties(); // Initial network check
    await _refreshSession();
    _initDeepLinkListener(); // Start listening for UTMs
    await _configureReplay();

    // Start auto-flush timer
    _flushTimer = Timer.periodic(const Duration(seconds: 30), (_) => _flush());

    // Register the SDK to listen to OS lifecycle changes
    WidgetsBinding.instance.addObserver(this);

    // Track an automatic "App Opened" event to trigger session logic
    if (_trackLifecycleEvents) {
      await track('\$app_opened');
    }

    _isInitialized = true;
    _log('⚡ Sankofa initialized');
  }

  void _resetRuntimeStateForInit() {
    if (_isInitialized) {
      WidgetsBinding.instance.removeObserver(this);
    }

    SankofaReplay.instance.stopRecording();
    _flushTimer?.cancel();
    _flushTimer = null;
    _linkSubscription?.cancel();
    _linkSubscription = null;

    _queue.clear();
    _defaultProperties.clear();
  }

  Future<void> _configureReplay() async {
    if (!_enableSessionReplay) return;
    if (_apiKey != null && _serverBaseUri != null && _sessionId != null) {
      await SankofaReplay.instance.configure(
        apiKey: _apiKey!,
        endpoint: _serverBaseUri!.toString(),
        sessionId: _sessionId!,
        distinctId: _userId ?? _anonymousId ?? 'anonymous',
        mode: _replayMode,
        fps: _replayFps,
        debug: _debug,
      );

      // Fetch dynamic configuration overrides from the Go backend natively
      await _fetchReplayConfig(_serverBaseUri!);
    }
  }

  Future<void> _fetchReplayConfig(Uri serverBaseUri) async {
    try {
      final uri = _appendPath(serverBaseUri, const [
        'api',
        'ee',
        'replay',
        'config',
      ]);
      final resp = await http.get(uri, headers: {'x-api-key': _apiKey!});
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        if (data['high_fidelity_triggers'] != null) {
          _highFidelityTriggers = List<String>.from(
            data['high_fidelity_triggers'],
          );
        }
        if (data['high_fidelity_duration_seconds'] != null) {
          _highFidelityDuration = Duration(
            seconds: data['high_fidelity_duration_seconds'],
          );
        }
        _log('⚙️ Sankofa: Loaded remote Replay Config: $_highFidelityTriggers');
      }
    } catch (e) {
      _log(
        '⚠️ Sankofa: Failed to load remote Replay Config, using local defaults.',
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (_enableSessionReplay) {
      SankofaReplay.instance.onAppLifecycleStateChanged(state);
    }

    if (state == AppLifecycleState.resumed) {
      _log('🟢 App in Foreground');
      if (_trackLifecycleEvents) {
        unawaited(track('\$app_foregrounded'));
      }
    } else if (state == AppLifecycleState.paused) {
      _log('🔴 App in Background - Forcing Emergency Flush');
      if (_trackLifecycleEvents) {
        unawaited(
          track('\$app_backgrounded').then((_) {
            _flush();
          }),
        );
      } else {
        // Still force flush even if we aren't tracking the lifecycle event!
        unawaited(_flush());
      }
    }
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _flushTimer?.cancel();
    _linkSubscription?.cancel();
    if (_enableSessionReplay) {
      SankofaReplay.instance.stopRecording();
    }
    _isInitialized = false;
  }

  /// 🌐 Listen for Deep Links to capture UTM Marketing data
  void _initDeepLinkListener() {
    try {
      _appLinks = AppLinks();

      _linkSubscription = _appLinks.uriLinkStream.listen((uri) {
        _log('🔗 Deep Link Caught: $uri');

        final queryParams = uri.queryParameters;
        bool hasUtms = false;

        // Extract standard marketing UTMs and attach them to the session
        final utmKeys = [
          'utm_source',
          'utm_medium',
          'utm_campaign',
          'utm_term',
          'utm_content',
        ];

        for (final key in utmKeys) {
          if (queryParams.containsKey(key)) {
            // Note: Mixpanel doesn't use the '\$' prefix for UTMs
            _defaultProperties[key] = queryParams[key]!;
            hasUtms = true;
          }
        }

        // If we caught UTMs, immediately track a marketing event
        if (hasUtms) {
          unawaited(track('\$campaign_details', queryParams));
        }
      });
    } catch (e) {
      _log('⚠️ Sankofa: Deep links are unavailable on this platform.');
    }
  }

  /// 📡 Dynamic Network & Carrier Info
  Future<void> _updateNetworkProperties() async {
    try {
      // Check Wi-Fi vs Cellular
      final connectivityResult = await Connectivity().checkConnectivity();
      _defaultProperties['\$wifi'] =
          (connectivityResult == ConnectivityResult.wifi).toString();

      // Check Telecom Carrier (MTN, Vodafone, etc.)
      if (Platform.isAndroid) {
        final carrierData = await CarrierInfo.getAndroidInfo();
        if (carrierData != null && carrierData.telephonyInfo.isNotEmpty) {
          final name = carrierData.telephonyInfo.first.carrierName;
          _defaultProperties['\$carrier'] = name.isNotEmpty ? name : 'Unknown';
        }
      } else if (Platform.isIOS) {
        final carrierData = await CarrierInfo.getIosInfo();
        if (carrierData.carrierData.isNotEmpty) {
          final name = carrierData.carrierData.first.carrierName;
          _defaultProperties['\$carrier'] = name.isNotEmpty ? name : 'Unknown';
        }
      }
    } catch (e) {
      _log('⚠️ Could not load network info (Simulators often fail this)');
    }
  }

  /// Identify a user (Link anonymous ID to User ID)
  Future<void> identify(String userId) async {
    if (_userId == userId) return; // Already identified

    final previousId = _userId ?? _anonymousId;
    _userId = userId;

    // Persist new User ID
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('sankofa_user_id', userId);

    // Send Alias Event: Link previousId -> userId
    // If we were anonymous properly, previousId is the AnonUUID.
    // If we are re-identifying, this might link oldUserID -> newUserID (depending on logic)
    // For Mixpanel parity: Alias is usually (Anonymous -> UserID).

    if (previousId != null && previousId != userId) {
      final aliasEvent = {
        'type': 'alias',
        'alias_id': previousId,
        'distinct_id': userId,
        'timestamp': DateTime.now().toIso8601String(),
        'message_id': const Uuid().v4(),
      };
      _queue.add(aliasEvent);
      await _persistQueue();
      _log('🔗 Identify: Aliasing $previousId -> $userId');
    }

    await _flush();
    if (_enableSessionReplay) {
      SankofaReplay.instance.setDistinctId(userId);
    }
  }

  /// Reset identity (Logout)
  Future<void> reset() async {
    await _flush();

    _userId = null;
    _anonymousId = const Uuid().v4(); // Generate new Anon ID
    _sessionId = const Uuid().v4();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('sankofa_user_id');
    await prefs.setString(_kAnonIdKey, _anonymousId!);
    await prefs.setString(_kSessionIdKey, _sessionId!);
    await prefs.setInt(
      _kLastEventTimeKey,
      DateTime.now().millisecondsSinceEpoch,
    );
    _log('🔄 Reset Identity: New AnonID $_anonymousId');
    if (_enableSessionReplay) {
      await _configureReplay();
    }
  }

  /// Set User Properties (People Profile)
  Future<void> peopleSet(Map<String, dynamic> properties) async {
    final profileEvent = {
      'type': 'people',
      'distinct_id': _userId ?? _anonymousId,
      'properties': serializeTransportProperties(properties),
      'timestamp': DateTime.now().toIso8601String(),
      'message_id': const Uuid().v4(),
    };
    _queue.add(profileEvent);
    await _persistQueue();
    _log('👤 People Set: $properties');
    await _flush();
  }

  /// Helper method to set common user properties (name, email, avatar)
  Future<void> setPerson({
    String? name,
    String? email,
    String? avatar,
    Map<String, dynamic>? properties,
  }) async {
    final Map<String, dynamic> traits = {...(properties ?? {})};
    if (name != null) traits[r'$name'] = name;
    if (email != null) traits[r'$email'] = email;
    if (avatar != null) traits[r'$avatar'] = avatar;
    await peopleSet(traits);
  }

  /// 🧠 Core Session Management Logic
  Future<void> _refreshSession() async {
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now().millisecondsSinceEpoch;

    _sessionId = prefs.getString(_kSessionIdKey);
    final lastEventTime = prefs.getInt(_kLastEventTimeKey) ?? 0;

    // If no session exists, or 30 minutes have passed since the LAST event
    if (_sessionId == null ||
        (now - lastEventTime) > (_kSessionTimeoutMinutes * 60 * 1000)) {
      _sessionId = const Uuid().v4();
      await prefs.setString(_kSessionIdKey, _sessionId!);
      _log('🆕 New Session Started: $_sessionId');
      await _configureReplay();

      // Optional: Auto-fire a Session Start event
      // _queue.add({... 'event_name': '\$session_started' ...});
    }

    // Always bump the last event time to keep the session alive
    await prefs.setInt(_kLastEventTimeKey, now);
  }

  /// Track an event
  Future<void> track(
    String eventName, [
    Map<String, dynamic>? properties,
  ]) async {
    if (_apiKey == null) {
      _log('❌ Sankofa not initialized');
      return;
    }

    // 1. Validate and refresh the session before recording the event
    await _refreshSession();

    // Refresh network state right before tracking (users turn wifi on/off)
    await _updateNetworkProperties();

    final serializedProperties = properties == null
        ? const <String, String>{}
        : serializeTransportProperties(properties);

    final event = {
      'type': 'track',
      'event_name': eventName,
      'distinct_id': _userId ?? _anonymousId,
      'properties': {
        // Inject Session ID into the root properties of every event
        '\$session_id': _sessionId,
        ...serializedProperties,
      },
      'default_properties': Map<String, String>.from(_defaultProperties),
      'timestamp': DateTime.now().toIso8601String(),
      'lib_version': 'flutter-0.0.1',
      'message_id': const Uuid().v4(), // Perfect for ClickHouse deduplication
    };

    _queue.add(event);
    await _persistQueue();

    _log('📝 Tracked: $eventName (Session: ${_sessionId?.substring(0, 8)}...)');

    // 🌟 SHAPESHIFTER TIER: Dynamite Video Triggers!
    // Intercept Analytics events and turn on video recording automatically
    if (_enableSessionReplay && _highFidelityTriggers.contains(eventName)) {
      SankofaReplay.instance.triggerHighFidelityMode(_highFidelityDuration);
    }

    if (_queue.length >= 10) {
      await _flush();
    }
  }

  /// Load or generate anonymous ID
  Future<void> _loadAnonymousId() async {
    final prefs = await SharedPreferences.getInstance();
    _anonymousId = prefs.getString(_kAnonIdKey);
    if (_anonymousId == null) {
      _anonymousId = const Uuid().v4();
      await prefs.setString(_kAnonIdKey, _anonymousId!);
    }
    _userId = prefs.getString('sankofa_user_id');
  }

  /// Load pending events from disk
  Future<void> _loadQueue() async {
    _queue.clear();
    final prefs = await SharedPreferences.getInstance();
    final jsonString = prefs.getString(_kQueueKey);
    if (jsonString != null) {
      try {
        final List<dynamic> list = jsonDecode(jsonString);
        _queue.addAll(list.cast<Map<String, dynamic>>());
      } catch (e) {
        _log('❌ Failed to load queue: $e');
      }
    }
  }

  /// Save pending events to disk
  Future<void> _persistQueue() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kQueueKey, jsonEncode(_queue));
  }

  /// 🌐 Gather rich tier-1 device info
  Future<void> _loadDefaultProperties() async {
    _defaultProperties.clear();
    final plugin = DeviceInfoPlugin();
    final packageInfo = await PackageInfo.fromPlatform();

    // 1. App Info
    _defaultProperties['\$app_version'] = packageInfo.version;
    _defaultProperties['\$build_number'] = packageInfo.buildNumber;

    // 2. OS Info
    _defaultProperties['\$os'] = Platform.operatingSystem;
    _defaultProperties['\$os_version'] = Platform.operatingSystemVersion;

    // 3. Hardware Info
    if (Platform.isAndroid) {
      final android = await plugin.androidInfo;
      _defaultProperties['\$device_model'] = android.model;
      _defaultProperties['\$device_manufacturer'] = android.manufacturer;
      _defaultProperties['\$is_simulator'] = (!android.isPhysicalDevice)
          .toString();
    } else if (Platform.isIOS) {
      final ios = await plugin.iosInfo;
      _defaultProperties['\$device_model'] = ios.model;
      _defaultProperties['\$device_manufacturer'] = 'Apple';
      _defaultProperties['\$is_simulator'] = (!ios.isPhysicalDevice).toString();
    }

    // 4. Display Info (Safe access via PlatformDispatcher)
    try {
      final view = ui.PlatformDispatcher.instance.views.first;
      _defaultProperties['\$screen_width'] = view.physicalSize.width.toString();
      _defaultProperties['\$screen_height'] = view.physicalSize.height
          .toString();
    } catch (e) {
      _log('⚠️ Could not load screen dimensions');
    }

    // 5. Locale & Timezone Info
    _defaultProperties['\$timezone'] = DateTime.now().timeZoneName;
    try {
      final locale = ui.PlatformDispatcher.instance.locale;
      _defaultProperties['\$locale'] = locale.toLanguageTag();
    } catch (e) {
      _log('⚠️ Could not load locale');
    }
  }

  /// Flush events to backend
  Future<void> _flush() async {
    if (_isFlushing || _queue.isEmpty) return;
    _isFlushing = true;

    final batch = List<Map<String, dynamic>>.from(_queue);
    final failedEvents = <Map<String, dynamic>>[];

    for (final event in batch) {
      try {
        Uri url = _trackUri!;
        if (event['type'] == 'alias') {
          url = _appendPath(_v1BaseUri!, const ['alias']);
        }
        if (event['type'] == 'people') {
          url = _appendPath(_v1BaseUri!, const ['people']);
        }
        // 'track' uses default _endpoint

        final res = await http.post(
          url,
          headers: {'Content-Type': 'application/json', 'x-api-key': _apiKey!},
          body: jsonEncode(event),
        );

        if (res.statusCode != 200) {
          _log('❌ Failed to send ${event['type']}: ${res.statusCode}');
          failedEvents.add(event); // Retry later
        } else {
          _log('✅ Sent ${event['type']}');
        }
      } catch (e) {
        _log('❌ Network error: $e');
        failedEvents.add(event);
      }
    }

    _queue.clear();
    _queue.addAll(failedEvents);
    await _persistQueue();
    _isFlushing = false;
  }

  void _log(String value) {
    if (_debug) debugPrint(value);
  }

  @visibleForTesting
  static Uri resolveServerBaseUri(String endpoint) {
    final v1BaseUri = resolveV1BaseUri(endpoint);
    final trimmedSegments = v1BaseUri.pathSegments
        .where((segment) => segment.isNotEmpty)
        .toList();

    if (_endsWithSegments(trimmedSegments, const ['api', 'v1'])) {
      return _replacePathSegments(
        v1BaseUri,
        trimmedSegments.sublist(0, trimmedSegments.length - 2),
      );
    }

    return v1BaseUri;
  }

  @visibleForTesting
  static Uri resolveV1BaseUri(String endpoint) {
    final uri = Uri.parse(endpoint.trim());
    final segments = uri.pathSegments
        .where((segment) => segment.isNotEmpty)
        .toList();

    if (_endsWithSegments(segments, const ['api', 'v1', 'track'])) {
      return _replacePathSegments(
        uri,
        segments.sublist(0, segments.length - 1),
      );
    }

    if (_endsWithSegments(segments, const ['api', 'v1'])) {
      return _replacePathSegments(uri, segments);
    }

    if (_endsWithSegments(segments, const ['v1', 'track'])) {
      return _replacePathSegments(uri, [
        ...segments.sublist(0, segments.length - 2),
        'api',
        'v1',
      ]);
    }

    if (_endsWithSegments(segments, const ['v1'])) {
      return _replacePathSegments(uri, [
        ...segments.sublist(0, segments.length - 1),
        'api',
        'v1',
      ]);
    }

    return _replacePathSegments(uri, [...segments, 'api', 'v1']);
  }

  @visibleForTesting
  static Uri resolveTrackUri(String endpoint) {
    final v1BaseUri = resolveV1BaseUri(endpoint);
    return _appendPath(v1BaseUri, const ['track']);
  }

  @visibleForTesting
  static Map<String, String> serializeTransportProperties(
    Map<String, dynamic> properties,
  ) {
    return properties.map(
      (key, value) => MapEntry(key, _serializeTransportValue(value)),
    );
  }

  static Uri _appendPath(Uri uri, List<String> segments) {
    final pathSegments = uri.pathSegments
        .where((segment) => segment.isNotEmpty)
        .toList();
    return _replacePathSegments(uri, [...pathSegments, ...segments]);
  }

  static Uri _replacePathSegments(Uri uri, List<String> segments) {
    return uri.replace(pathSegments: segments);
  }

  static bool _endsWithSegments(List<String> actual, List<String> suffix) {
    if (actual.length < suffix.length) return false;
    for (var index = 0; index < suffix.length; index++) {
      if (actual[actual.length - suffix.length + index] != suffix[index]) {
        return false;
      }
    }
    return true;
  }

  static String _serializeTransportValue(dynamic value) {
    if (value == null) return 'null';
    if (value is String) return value;
    if (value is num || value is bool) return value.toString();
    if (value is DateTime) return value.toIso8601String();
    if (value is Iterable || value is Map) {
      return jsonEncode(_toEncodableJson(value));
    }
    return value.toString();
  }

  static dynamic _toEncodableJson(dynamic value) {
    if (value == null || value is String || value is num || value is bool) {
      return value;
    }
    if (value is DateTime) return value.toIso8601String();
    if (value is Iterable) {
      return value.map(_toEncodableJson).toList();
    }
    if (value is Map) {
      return value.map(
        (key, nestedValue) =>
            MapEntry(key.toString(), _toEncodableJson(nestedValue)),
      );
    }
    return value.toString();
  }
}
