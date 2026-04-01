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

      // Separate events by type for batched endpoints
      final trackEvents = <Map<String, dynamic>>[];
      final aliasEvents = <Map<String, dynamic>>[];
      final peopleEvents = <Map<String, dynamic>>[];

      for (final event in batch) {
        switch (event['type']) {
          case 'alias':
            aliasEvents.add(event);
            break;
          case 'people':
            peopleEvents.add(event);
            break;
          default:
            trackEvents.add(event);
        }
      }

      final failedEvents = <Map<String, dynamic>>[];

      // Batch send track events in a single request
      if (trackEvents.isNotEmpty) {
        final failed = await _sendBatch(trackEvents, trackUri);
        failedEvents.addAll(failed);
      }

      // Batch send alias events
      if (aliasEvents.isNotEmpty) {
        final aliasUrl = UriHelper.appendPath(v1BaseUri, const ['alias']);
        final failed = await _sendBatch(aliasEvents, aliasUrl);
        failedEvents.addAll(failed);
      }

      // Batch send people events
      if (peopleEvents.isNotEmpty) {
        final peopleUrl = UriHelper.appendPath(v1BaseUri, const ['people']);
        final failed = await _sendBatch(peopleEvents, peopleUrl);
        failedEvents.addAll(failed);
      }

      // Re-queue any failed events for retry
      if (failedEvents.isNotEmpty) {
        _queue.insertAll(0, failedEvents);
        await _persist();
        logger.log('⚠️ ${failedEvents.length} events re-queued for retry');
      }
    } catch (e) {
      logger.log('❌ Flush error: $e');
    } finally {
      _isFlushing = false;
    }
  }

  /// Sends a batch of events to the given [url] in a single HTTP request.
  /// Returns any events that failed to send (for retry).
  Future<List<Map<String, dynamic>>> _sendBatch(
    List<Map<String, dynamic>> events,
    Uri url,
  ) async {
    try {
      final res = await http
          .post(
            url,
            headers: {
              'Content-Type': 'application/json',
              'x-api-key': apiKey,
            },
            body: jsonEncode({'batch': events}),
          )
          .timeout(const Duration(seconds: 15));

      if (res.statusCode == 200 || res.statusCode == 202) {
        logger.log('✅ Batch sent: ${events.length} events to $url');
        
        // 🎮 Process Commands
        try {
          final data = jsonDecode(res.body);
          if (data['commands'] != null && onCommands != null) {
            onCommands!(data['commands'] as List<dynamic>);
          }
        } catch (e) {
          // Response body might not be JSON or might be empty
        }

        return [];
      }

      // If the server doesn't support batch, fall back to individual sends
      if (res.statusCode == 400 || res.statusCode == 404) {
        logger.log('⚠️ Batch endpoint not supported, falling back to individual sends');
        return _sendIndividually(events, url);
      }

      logger.log('❌ Batch send failed (${res.statusCode}): ${events.length} events');
      return events; // Re-queue all on server error
    } catch (e) {
      logger.log('❌ Network error during batch send: $e');
      return events; // Re-queue all on network error
    }
  }

  /// Fallback: sends events one-by-one if batch endpoint isn't available.
  Future<List<Map<String, dynamic>>> _sendIndividually(
    List<Map<String, dynamic>> events,
    Uri url,
  ) async {
    final failed = <Map<String, dynamic>>[];

    for (final event in events) {
      try {
        final res = await http
            .post(
              url,
              headers: {
                'Content-Type': 'application/json',
                'x-api-key': apiKey,
              },
              body: jsonEncode(event),
            )
            .timeout(const Duration(seconds: 10));

        if (res.statusCode == 200 || res.statusCode == 202) {
          logger.log('✅ Sent ${event['type']}');
          
          // 🎮 Process Commands
          try {
            final data = jsonDecode(res.body);
            if (data['commands'] != null && onCommands != null) {
              onCommands!(data['commands'] as List<dynamic>);
            }
          } catch (e) {
            // ...
          }
        } else {
          logger.log('❌ Failed to send ${event['type']}: ${res.statusCode}');
          failed.add(event);
        }
      } catch (e) {
        logger.log('❌ Network error: $e');
        failed.add(event);
      }
    }

    return failed;
  }
}
