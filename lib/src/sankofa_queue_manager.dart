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
  void Function(List<dynamic>)? onCommands;

  /// Single-flight guard. A flush in progress is stored here so concurrent
  /// callers (the periodic timer, identify(), the size threshold) await the
  /// SAME completion instead of silently no-op'ing — which previously broke
  /// the identify()/reset() ordering guarantee.
  Future<void>? _inFlight;

  /// One reusable client so flushes don't open a fresh socket each time.
  final http.Client _client = http.Client();

  SankofaQueueManager({
    required this.logger,
    required this.apiKey,
    required this.v1BaseUri,
    required this.trackUri,
    this.onCommands,
  });

  int get length => _queue.length;

  void dispose() => _client.close();

  Future<void> load() async {
    _queue.clear();
    final prefs = await SharedPreferences.getInstance();
    final jsonString = prefs.getString(kQueueKey);
    if (jsonString != null) {
      try {
        final List<dynamic> list = jsonDecode(jsonString);
        for (final e in list) {
          if (e is Map) _queue.add(Map<String, dynamic>.from(e));
        }
        _dropExpired();
        _enforceCap();
      } catch (e) {
        logger.log('❌ Failed to load queue: $e');
      }
    }
  }

  Future<void> add(Map<String, dynamic> event) async {
    // Stamp an enqueue time (internal, stripped before transport) for TTL.
    event[kEnqueuedAtField] = DateTime.now().millisecondsSinceEpoch;
    _queue.add(event);
    _enforceCap();
    await _persist();
    if (_queue.length >= kMaxQueueSize) {
      await flush();
    }
  }

  /// Drop the oldest events once the queue exceeds the hard cap, so a long
  /// offline window can't grow it without bound (and turn every enqueue into
  /// an O(n) SharedPreferences rewrite / OOM).
  void _enforceCap() {
    if (_queue.length > kMaxStoredEvents) {
      final overflow = _queue.length - kMaxStoredEvents;
      _queue.removeRange(0, overflow);
      logger.log('⚠️ Queue cap hit — dropped $overflow oldest event(s)');
    }
  }

  /// Drop events older than [kEventTtl] — stale events have no analytics value
  /// and pollute time-series data on reconnect.
  void _dropExpired() {
    final cutoff =
        DateTime.now().millisecondsSinceEpoch - kEventTtl.inMilliseconds;
    final before = _queue.length;
    _queue.removeWhere((e) {
      final ts = e[kEnqueuedAtField];
      return ts is int && ts < cutoff;
    });
    final dropped = before - _queue.length;
    if (dropped > 0) logger.log('⚠️ Dropped $dropped expired event(s)');
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kQueueKey, jsonEncode(_queue));
  }

  /// Flush is single-flight: concurrent callers await the in-flight future
  /// rather than no-op'ing.
  Future<void> flush() {
    if (_queue.isEmpty) return Future.value();
    if (_inFlight != null) return _inFlight!;
    final f = _doFlush().whenComplete(() => _inFlight = null);
    _inFlight = f;
    return f;
  }

  Future<void> _doFlush() async {
    try {
      _dropExpired();
      if (_queue.isEmpty) {
        await _persist();
        return;
      }
      // Snapshot the queue and clear immediately. New events added during the
      // in-flight POST land in the now-empty _queue; on a retain we re-insert
      // the batch ahead of them, preserving order.
      final batch = List<Map<String, dynamic>>.from(_queue);
      _queue.clear();
      await _persist();

      // Transform into the unified batch-operations shape. The internal
      // enqueue-time field is stripped from each payload before transport.
      final operations = batch.map((event) {
        final type = event['type'];
        final opType = (type == 'alias' || type == 'people') ? type : 'track';
        final payload = Map<String, dynamic>.from(event)
          ..remove(kEnqueuedAtField);
        return {'type': opType, 'payload': payload};
      }).toList();

      final batchUrl = UriHelper.appendPath(v1BaseUri, const ['batch']);
      final body = jsonEncode({'operations': operations});
      logger.log('📤 Flushing ${operations.length} events...');

      try {
        final res = await _client
            .post(
              batchUrl,
              headers: {
                'Content-Type': 'application/json',
                'x-api-key': apiKey,
              },
              body: body,
            )
            .timeout(const Duration(seconds: 15));

        final code = res.statusCode;
        if (code == 200 || code == 202) {
          // Delivered (202 = server accepted/"discarded_all" — stop retrying).
          // The batch is already removed from the queue; nothing to do.
          logger.log('✅ Batch sent: ${operations.length} events');
          try {
            final data = jsonDecode(res.body);
            if (data is Map &&
                data['commands'] is List &&
                onCommands != null) {
              onCommands!(data['commands'] as List<dynamic>);
            }
          } catch (_) {
            // Unparsable command channel — ignore.
          }
        } else if (code == 408 || code == 429 || code >= 500) {
          // Transient (timeout / rate-limit / server error): retain + retry.
          logger.log('⚠️ Batch transient failure ($code) — retaining for retry');
          _requeue(batch);
          await _persist();
        } else {
          // Client error (4xx: malformed payload, bad/expired key, auth):
          // retrying the identical body will never succeed. DROP so a single
          // poison-pill event can't wedge the queue forever (and dup good
          // events on every retry). This is the core all-or-nothing fix.
          logger.log('❌ Batch rejected ($code) — dropping ${operations.length} event(s); will not retry');
        }
      } catch (e) {
        // Network error / timeout — transient, retain.
        logger.log('❌ Network error during batch send: $e — retaining for retry');
        _requeue(batch);
        await _persist();
      }
    } catch (e) {
      logger.log('❌ Flush error: $e');
    }
  }

  /// Re-insert a failed batch at the head, then re-apply the cap (so a
  /// persistent transient failure can't grow the queue unbounded either).
  void _requeue(List<Map<String, dynamic>> batch) {
    _queue.insertAll(0, batch);
    _enforceCap();
  }
}
