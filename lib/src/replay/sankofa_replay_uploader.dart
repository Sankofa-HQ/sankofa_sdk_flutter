import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'sankofa_replay_client.dart';
import '../sankofa_client.dart';

class SankofaReplayUploader {
  final void Function(String) logger;
  String _apiKey = '';
  String _endpoint = '';
  String _sessionId = '';
  String _distinctId = 'anonymous';
  int _chunkIndex = 0;

  /// Serializes uploads so two chunks never POST concurrently AND no chunk is
  /// dropped. Previously a boolean `_isUploading` guard early-returned (and
  /// silently discarded) any chunk that arrived while one was in flight.
  Future<void> _uploadChain = Future.value();

  /// Completes once the persisted chunk index for the current session has been
  /// loaded. Awaited before the first upload so a process-restart mid-session
  /// can't reuse index 0 and clobber an already-uploaded chunk.
  Future<void>? _chunkIndexLoad;

  String get sessionId => _sessionId;
  int get chunkIndex => _chunkIndex;
  String get _os => Platform.operatingSystem.toLowerCase();

  SankofaReplayUploader({required this.logger});

  Map<String, String> _deviceProperties = {};

  void updateConfig({
    required String apiKey,
    required String endpoint,
    required String sessionId,
    required String distinctId,
    Map<String, String> deviceProperties = const {},
  }) {
    if (_sessionId != sessionId) {
      _sessionId = sessionId;
      _chunkIndexLoad = _loadChunkIndex();
    }
    _apiKey = apiKey;
    _endpoint = endpoint;
    _distinctId = distinctId;
    _deviceProperties = deviceProperties;
  }

  void updateDistinctId(String id) => _distinctId = id;

  Future<void> _loadChunkIndex() async {
    final prefs = await SharedPreferences.getInstance();
    _chunkIndex = prefs.getInt('sankofa_replay_chunk_$_sessionId') ?? 0;
  }

  /// Upload a chunk. Returns true on confirmed delivery (2xx) so the caller can
  /// retain-and-retry the data on failure rather than losing it. Uploads run
  /// strictly one-at-a-time via [_uploadChain].
  Future<bool> uploadChunk({
    required SankofaReplayMode mode,
    required List<Uint8List> frames,
    // Per-frame capture timestamps in lockstep with [frames].  Empty
    // when the recorder didn't supply them — the upload path falls
    // back to the upload-time millisecond in that case so older
    // recorders still produce parseable chunks.
    List<int> frameTimestamps = const [],
    required List<Map<String, dynamic>> events,
    required DateTime? startTime,
    required Map<String, dynamic> deviceContext,
  }) {
    if (_sessionId.isEmpty) return Future.value(false);
    final result = _uploadChain.then((_) => _doUpload(
          mode: mode,
          frames: frames,
          frameTimestamps: frameTimestamps,
          events: events,
          startTime: startTime,
          deviceContext: deviceContext,
        ));
    // Keep the chain alive regardless of this upload's outcome.
    _uploadChain = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<bool> _doUpload({
    required SankofaReplayMode mode,
    required List<Uint8List> frames,
    List<int> frameTimestamps = const [],
    required List<Map<String, dynamic>> events,
    required DateTime? startTime,
    required Map<String, dynamic> deviceContext,
  }) async {
    // Ensure the persisted chunk index has loaded before the first POST.
    if (_chunkIndexLoad != null) {
      try {
        await _chunkIndexLoad;
      } catch (_) {}
      _chunkIndexLoad = null;
    }
    try {
      final appVersion = _deviceProperties['\$app_version'] ?? 'unknown';
      final deviceContextWithOs = {
        ...deviceContext,
        '\$os': _os,
        '\$app_version': appVersion,
      };

      final payload = {
        'session_id': _sessionId,
        'distinct_id': _distinctId,
        'chunk_index': _chunkIndex,
        'mode': mode.name,
        // Keep underscores for backend Body Peeking (Legacy & Reliability)
        '_session_id': _sessionId,
        '_distinct_id': _distinctId,
        '_chunk_index': _chunkIndex,
        '_replay_mode': mode.name,
        '\$app_version': appVersion,
        'meta': {
          'current_screen': Sankofa.instance.currentScreen,
        },
        'device_context': deviceContextWithOs,
        'events': events,
      };

      if (mode == SankofaReplayMode.screenshot) {
        logger('🚀 Replay: Uploading screenshot chunk ($_chunkIndex) with ${frames.length} frames');
        // Pair each frame with the timestamp captured when the bitmap
        // was actually rendered, NOT the upload time.  Without this,
        // every frame in a 5-frame chunk would get the same millisecond
        // (one upload-time `DateTime.now()` per .map() iteration) and
        // the dashboard's session-replay player would render them as a
        // single still frame instead of an animated sequence.  Falls
        // back to the upload-time millisecond if the recorder didn't
        // supply per-frame stamps.
        final fallbackNow = DateTime.now().toUtc().millisecondsSinceEpoch;
        payload['frames'] = List<Map<String, dynamic>>.generate(
          frames.length,
          (i) => {
            'timestamp': i < frameTimestamps.length
                ? frameTimestamps[i]
                : fallbackNow,
            'image_base64': base64Encode(frames[i]),
            'screen': Sankofa.instance.currentScreen,
          },
        );
      } else {
        payload['chunk_start_timestamp'] = startTime?.toUtc().millisecondsSinceEpoch ?? DateTime.now().toUtc().millisecondsSinceEpoch;
      }

      final compressedBody = GZipCodec().encode(utf8.encode(jsonEncode(payload)));
      final uri = Uri.parse('$_endpoint/api/ee/replay/chunk');
      
      final resp = await http.post(
        uri,
        headers: {
          'x-api-key': _apiKey,
          'Content-Type': 'application/json',
          'Content-Encoding': 'gzip',
          'X-Session-Id': _sessionId,
          'X-Distinct-Id': _distinctId,
          'X-Chunk-Index': _chunkIndex.toString(),
          'X-Replay-Mode': mode.name,
        },
        body: compressedBody,
      );

      if (resp.statusCode == 200) {
        logger('🚀 Replay: Uploaded ${mode.name} chunk $_chunkIndex');
        _chunkIndex++;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt('sankofa_replay_chunk_$_sessionId', _chunkIndex);
        return true;
      }
      // 4xx (except 408/429) won't succeed on retry → report as "handled"
      // (true) so the recorder drops it; 408/429/5xx are transient → false.
      final code = resp.statusCode;
      final transient = code == 408 || code == 429 || code >= 500;
      logger('❌ Replay upload failed: $code${transient ? ' (will retry)' : ' (dropping)'}');
      return !transient;
    } catch (e) {
      logger('❌ Replay upload error: $e (will retry)');
      return false; // network error — transient, retain for retry
    }
  }
}
