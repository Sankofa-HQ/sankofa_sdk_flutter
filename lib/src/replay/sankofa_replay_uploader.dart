import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'sankofa_replay_client.dart';

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

  SankofaReplayUploader({required this.logger});

  void updateConfig({
    required String apiKey,
    required String endpoint,
    required String sessionId,
    required String distinctId,
  }) {
    if (_sessionId != sessionId) {
      _sessionId = sessionId;
      _loadChunkIndex();
    }
    _apiKey = apiKey;
    _endpoint = endpoint;
    _distinctId = distinctId;
  }

  void updateDistinctId(String id) => _distinctId = id;

  Future<void> _loadChunkIndex() async {
    final prefs = await SharedPreferences.getInstance();
    _chunkIndex = prefs.getInt('sankofa_replay_chunk_$_sessionId') ?? 0;
  }

  Future<void> uploadChunk({
    required SankofaReplayMode mode,
    required List<Uint8List> frames,
    required List<Map<String, dynamic>> events,
    required DateTime? startTime,
    required Map<String, dynamic> deviceContext,
  }) async {
    if (_isUploading || _sessionId.isEmpty) return;
    _isUploading = true;

    try {
      final payload = {
        'session_id': _sessionId,
        'chunk_index': _chunkIndex,
        'mode': mode.name,
        if (mode == SankofaReplayMode.screenshot)
          'frames': frames.map((f) => {
            'timestamp': DateTime.now().millisecondsSinceEpoch, // Simplification for refactor
            'image_base64': base64Encode(f),
          }).toList()
        else ...{
          'chunk_start_timestamp': startTime?.millisecondsSinceEpoch ?? DateTime.now().millisecondsSinceEpoch,
          'device_context': deviceContext,
          'events': events,
        }
      };

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
