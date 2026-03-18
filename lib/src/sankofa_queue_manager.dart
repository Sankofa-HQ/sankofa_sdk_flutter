import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'sankofa_constants.dart';
import 'utils/logger.dart';
import 'utils/uri_helper.dart';

class SankofaQueueManager {
  final SankofaLogger logger;
  final String apiKey;
  final Uri v1BaseUri;
  final Uri trackUri;
  final List<Map<String, dynamic>> _queue = [];
  bool _isFlushing = false;

  SankofaQueueManager({
    required this.logger,
    required this.apiKey,
    required this.v1BaseUri,
    required this.trackUri,
  });

  int get length => _queue.length;

  Future<void> load() async {
    _queue.clear();
    final prefs = await SharedPreferences.getInstance();
    final jsonString = prefs.getString(kQueueKey);
    if (jsonString != null) {
      try {
        final List<dynamic> list = jsonDecode(jsonString);
        _queue.addAll(list.cast<Map<String, dynamic>>());
      } catch (e) {
        logger.log('❌ Failed to load queue: $e');
      }
    }
  }

  Future<void> add(Map<String, dynamic> event) async {
    _queue.add(event);
    await _persist();
    if (_queue.length >= kMaxQueueSize) {
      await flush();
    }
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kQueueKey, jsonEncode(_queue));
  }

  Future<void> flush() async {
    if (_isFlushing || _queue.isEmpty) return;
    _isFlushing = true;

    final batch = List<Map<String, dynamic>>.from(_queue);
    final failedEvents = <Map<String, dynamic>>[];

    for (final event in batch) {
      try {
        Uri url = trackUri;
        if (event['type'] == 'alias') {
          url = UriHelper.appendPath(v1BaseUri, const ['alias']);
        } else if (event['type'] == 'people') {
          url = UriHelper.appendPath(v1BaseUri, const ['people']);
        }

        final res = await http.post(
          url,
          headers: {'Content-Type': 'application/json', 'x-api-key': apiKey},
          body: jsonEncode(event),
        );

        if (res.statusCode != 200) {
          logger.log('❌ Failed to send ${event['type']}: ${res.statusCode}');
          failedEvents.add(event);
        } else {
          logger.log('✅ Sent ${event['type']}');
        }
      } catch (e) {
        logger.log('❌ Network error: $e');
        failedEvents.add(event);
      }
    }

    _queue.clear();
    _queue.addAll(failedEvents);
    await _persist();
    _isFlushing = false;
  }
}
