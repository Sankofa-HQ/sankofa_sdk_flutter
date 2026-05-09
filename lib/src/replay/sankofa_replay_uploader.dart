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
  bool _isUploading = false;

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
      _loadChunkIndex();
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

  Future<void> uploadChunk({
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
  }) async {
    if (_isUploading || _sessionId.isEmpty) return;
    _isUploading = true;

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
      } else {
        logger('❌ Replay upload failed: ${resp.statusCode}');
      }
    } catch (e) {
      logger('❌ Replay upload error: $e');
    } finally {
      _isUploading = false;
    }
  }
}
