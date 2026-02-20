library sankofa_flutter;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

const String _kQueueKey = 'sankofa_queue';
const String _kAnonIdKey = 'sankofa_anon_id';

class Sankofa {
  static final Sankofa _instance = Sankofa._internal();
  static Sankofa get instance => _instance;

  String? _apiKey;
  String? _endpoint;
  String? _userId;
  String? _anonymousId;
  bool _debug = false;
  Map<String, String> _defaultProperties = {};

  final List<Map<String, dynamic>> _queue = [];
  Timer? _flushTimer;
  bool _isFlushing = false;

  Sankofa._internal();

  /// Initialize the SDK
  Future<void> init({
    required String apiKey,
    String endpoint = 'http://localhost:8080/api/v1/track',
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

    if (_debug) print('⚡ Sankofa initialized');
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

  /// Track an event
  Future<void> track(
    String eventName, [
    Map<String, dynamic>? properties,
  ]) async {
    if (_apiKey == null) {
      if (_debug) print('❌ Sankofa not initialized');
      return;
    }

    final event = {
      'type': 'track', // Internal discriminator
      'event_name': eventName,
      'distinct_id': _userId ?? _anonymousId, // Changed to distinct_id
      'properties':
          properties?.map((key, value) => MapEntry(key, value.toString())) ??
          {},
      'default_properties': _defaultProperties,
      'timestamp': DateTime.now().toIso8601String(),
      'lib_version': 'flutter-0.0.2',
      'message_id': const Uuid().v4(),
    };

    _queue.add(event);
    await _persistQueue();

    if (_debug) print('📝 Tracked: $eventName (Queue: ${_queue.length})');

    // If queue is large, flush immediately
    if (_queue.length >= 10) {
      _flush();
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

  /// Gather device info
  Future<void> _loadDefaultProperties() async {
    final plugin = DeviceInfoPlugin();
    final packageInfo = await PackageInfo.fromPlatform();

    _defaultProperties['app_version'] = packageInfo.version;
    _defaultProperties['build_number'] = packageInfo.buildNumber;
    _defaultProperties['os'] = Platform.operatingSystem;
    _defaultProperties['os_version'] = Platform.operatingSystemVersion;

    if (Platform.isAndroid) {
      final android = await plugin.androidInfo;
      _defaultProperties['device_model'] = android.model;
      _defaultProperties['device_manufacturer'] = android.manufacturer;
    } else if (Platform.isIOS) {
      final ios = await plugin.iosInfo;
      _defaultProperties['device_model'] = ios.model;
      _defaultProperties['device_manufacturer'] = 'Apple';
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
