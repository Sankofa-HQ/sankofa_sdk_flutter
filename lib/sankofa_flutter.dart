library sankofa_flutter;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

const String _kQueueKey = 'sankofa_queue';
const String _kAnonIdKey = 'sankofa_anon_id';
const String _kSessionIdKey = 'sankofa_session_id';
const String _kLastEventTimeKey = 'sankofa_last_event_time';
const int _kSessionTimeoutMinutes = 30;

class Sankofa with WidgetsBindingObserver {
  static final Sankofa _instance = Sankofa._internal();
  static Sankofa get instance => _instance;

  String? _apiKey;
  String? _endpoint;
  String? _userId;
  String? _anonymousId;
  String? _sessionId;

  bool _debug = false;
  final Map<String, String> _defaultProperties = {};

  final List<Map<String, dynamic>> _queue = [];
  Timer? _flushTimer;
  bool _isFlushing = false;

  Sankofa._internal();

  /// Initialize the SDK
  Future<void> init({
    required String apiKey,
    String endpoint = 'http://localhost:8080',
    bool debug = false,
  }) async {
    _apiKey = apiKey;
    _endpoint = "$endpoint/api/v1/track";
    _debug = debug;

    await _loadAnonymousId();
    await _loadQueue();
    await _loadDefaultProperties();

    // Start auto-flush timer
    _flushTimer = Timer.periodic(const Duration(seconds: 30), (_) => _flush());

    // Register the SDK to listen to OS lifecycle changes
    WidgetsBinding.instance.addObserver(this);

    // Track an automatic "App Opened" event to trigger session logic
    await track('\$app_opened');

    if (_debug) print('⚡ Sankofa initialized');
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.resumed) {
      if (_debug) print('🟢 App in Foreground');
      track('\$app_foregrounded');
    } else if (state == AppLifecycleState.paused) {
      if (_debug) print('🔴 App in Background - Forcing Emergency Flush');
      track('\$app_backgrounded').then((_) {
        _flush();
      });
    }
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _flushTimer?.cancel();
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
      if (_debug) print('🔗 Identify: Aliasing $previousId -> $userId');
    }

    _flush();
  }

  /// Reset identity (Logout)
  Future<void> reset() async {
    _userId = null;
    _anonymousId = const Uuid().v4(); // Generate new Anon ID
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('sankofa_user_id');
    await prefs.setString(_kAnonIdKey, _anonymousId!);
    if (_debug) print('🔄 Reset Identity: New AnonID $_anonymousId');
  }

  /// Set User Properties (People Profile)
  Future<void> peopleSet(Map<String, dynamic> properties) async {
    final profileEvent = {
      'type': 'people',
      'distinct_id': _userId ?? _anonymousId,
      'properties': properties.map(
        (key, value) => MapEntry(key, value.toString()),
      ),
      'timestamp': DateTime.now().toIso8601String(),
      'message_id': const Uuid().v4(),
    };
    _queue.add(profileEvent);
    await _persistQueue();
    if (_debug) print('👤 People Set: $properties');
    _flush();
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
      if (_debug) print('🆕 New Session Started: $_sessionId');

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
      if (_debug) print('❌ Sankofa not initialized');
      return;
    }

    // 1. Validate and refresh the session before recording the event
    await _refreshSession();

    final event = {
      'type': 'track',
      'event_name': eventName,
      'distinct_id': _userId ?? _anonymousId,
      'properties': {
        // Inject Session ID into the root properties of every event
        '\$session_id': _sessionId,
        ...(properties?.map((key, value) => MapEntry(key, value.toString())) ??
            {}),
      },
      'default_properties': _defaultProperties,
      'timestamp': DateTime.now().toIso8601String(),
      'lib_version': 'flutter-0.1.0', // Bumped version
      'message_id': const Uuid().v4(),
    };

    _queue.add(event);
    await _persistQueue();

    if (_debug)
      print(
        '📝 Tracked: $eventName (Session: ${_sessionId?.substring(0, 8)}...)',
      );

    if (_queue.length >= 10) _flush();
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
    final prefs = await SharedPreferences.getInstance();
    final jsonString = prefs.getString(_kQueueKey);
    if (jsonString != null) {
      try {
        final List<dynamic> list = jsonDecode(jsonString);
        _queue.addAll(list.cast<Map<String, dynamic>>());
      } catch (e) {
        if (_debug) print('❌ Failed to load queue: $e');
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
      if (_debug) print('⚠️ Could not load screen dimensions');
    }

    // 5. Locale & Timezone Info
    _defaultProperties['\$timezone'] = DateTime.now().timeZoneName;
    try {
      final locale = ui.PlatformDispatcher.instance.locale;
      _defaultProperties['\$locale'] =
          '${locale.languageCode}_${locale.countryCode}';
    } catch (e) {
      if (_debug) print('⚠️ Could not load locale');
    }
  }

  /// Flush events to backend
  Future<void> _flush() async {
    if (_isFlushing || _queue.isEmpty) return;
    _isFlushing = true;

    final batch = List<Map<String, dynamic>>.from(_queue);
    final failedEvents = <Map<String, dynamic>>[];

    // Define base URL logic (remove /v1/track if present to get base)
    // Actually simplicity: we assume _endpoint is the base API URL e.g. http://host:8080/v1
    // But init() defaults to /v1/track. Let's fix that dynamically or just string replace.

    final baseUrl = _endpoint!.replaceAll('/track', '');

    for (final event in batch) {
      try {
        String url = _endpoint!;
        if (event['type'] == 'alias') url = '$baseUrl/alias';
        if (event['type'] == 'people') url = '$baseUrl/people';
        // 'track' uses default _endpoint

        final res = await http.post(
          Uri.parse(url),
          headers: {'Content-Type': 'application/json', 'x-api-key': _apiKey!},
          body: jsonEncode(event),
        );

        if (res.statusCode != 200) {
          if (_debug)
            print('❌ Failed to send ${event['type']}: ${res.statusCode}');
          failedEvents.add(event); // Retry later
        } else {
          if (_debug) print('✅ Sent ${event['type']}');
        }
      } catch (e) {
        if (_debug) print('❌ Network error: $e');
        failedEvents.add(event);
      }
    }

    _queue.clear();
    _queue.addAll(failedEvents);
    await _persistQueue();
    _isFlushing = false;
  }
}
