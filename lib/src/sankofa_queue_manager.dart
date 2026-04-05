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
  void Function(List<dynamic>)? onCommands;

  SankofaQueueManager({
    required this.logger,
    required this.apiKey,
    required this.v1BaseUri,
    required this.trackUri,
    this.onCommands,
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

    try {
      // Snapshot the queue and clear immediately to avoid duplicates
      final batch = List<Map<String, dynamic>>.from(_queue);
      _queue.clear();
      await _persist();

      // Transform generic events into unified Batch Operations format required by Backend
      final operations = batch.map((event) {
        String opType = 'track';
        if (event['type'] == 'alias') opType = 'alias';
        if (event['type'] == 'people') opType = 'people';
        return {
          'type': opType,
          'payload': event,
        };
      }).toList();

      final batchUrl = UriHelper.appendPath(v1BaseUri, const ['batch']);
      final body = jsonEncode({'operations': operations});
      logger.log('📤 Flushing ${operations.length} events...');
      
      try {
        final res = await http
            .post(
              batchUrl,
              headers: {
                'Content-Type': 'application/json',
                'x-api-key': apiKey,
              },
              body: body,
            )
            .timeout(const Duration(seconds: 15));

        if (res.statusCode == 200 || res.statusCode == 202) {
          logger.log('✅ Batch sent: ${operations.length} events to $batchUrl');
          
          // 🎮 Process Commands
          try {
            final data = jsonDecode(res.body);
            if (data['commands'] != null && onCommands != null) {
              onCommands!(data['commands'] as List<dynamic>);
            }
          } catch (e) {
            // Unparsable JSON
          }
        } else {
          logger.log('❌ Batch send failed (${res.statusCode})');
          _queue.insertAll(0, batch);
          await _persist();
        }
      } catch (e) {
        logger.log('❌ Network error during batch send: $e');
        _queue.insertAll(0, batch);
        await _persist();
      }

    } catch (e) {
      logger.log('❌ Flush error: $e');
    } finally {
      _isFlushing = false;
    }
  }
}
