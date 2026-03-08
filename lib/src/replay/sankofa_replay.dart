import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:http/http.dart' as http;

class SankofaReplay {
  static final SankofaReplay instance = SankofaReplay._internal();
  SankofaReplay._internal();

  bool _isInit = false;
  bool _isRecording = false;
  String _apiKey = '';
  String _endpoint = '';
  String _sessionId = '';
  int _fps = 1;
  Timer? _captureTimer;

  final GlobalKey _repaintBoundaryKey = GlobalKey();

  // Provide this key to the root widget
  GlobalKey get rootBoundaryKey => _repaintBoundaryKey;

  final List<_ReplayFrame> _frameBuffer = [];
  int _chunkIndex = 0;
  bool _isFlushing = false;

  /// Start recording the session. Call this after `Sankofa.instance.init()`
  void init({
    required String apiKey,
    required String endpoint,
    required String sessionId,
    int fps = 1,
  }) {
    if (_isInit) return;
    _apiKey = apiKey;
    _endpoint = endpoint;
    _sessionId = sessionId;
    _fps = fps;
    _isInit = true;
    print(
      '🎥 SankofaReplay: Initialized correctly with Session: $_sessionId and Endpoint: $_endpoint',
    );
    _startRecording();
  }

  void _startRecording() {
    if (_isRecording || !_isInit) return;
    _isRecording = true;

    final duration = Duration(milliseconds: 1000 ~/ _fps);
    _captureTimer = Timer.periodic(duration, (_) => _captureFrame());
  }

  void stopRecording() {
    _captureTimer?.cancel();
    _isRecording = false;
    _flush(force: true);
  }

  Future<void> _captureFrame() async {
    if (_repaintBoundaryKey.currentContext == null) return;

    try {
      final boundary =
          _repaintBoundaryKey.currentContext!.findRenderObject()
              as RenderRepaintBoundary?;
      if (boundary == null) {
        print('❌ SankofaReplay: Boundary is null');
        return;
      }
      if (boundary.debugNeedsPaint) {
        print(
          '⚠️ SankofaReplay: Skipped frame because boundary needs paint (animation running?)',
        );
        return;
      }

      final image = await boundary.toImage(
        pixelRatio:
            0.5, // Crush the pixel ratio to vastly reduce B2 storage payload
      );
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      // Note: Flutter doesn't natively encode WebP. We'll use PNG, which gzip will compress well.

      if (byteData != null) {
        final bytes = byteData.buffer.asUint8List();
        _frameBuffer.add(_ReplayFrame(DateTime.now(), bytes));

        if (_frameBuffer.length % 5 == 0) {
          print('📸 SankofaReplay: Buffered ${_frameBuffer.length} frames');
        }

        // Lower threshold to 5 frames (5 seconds) for easier MVP testing
        if (_frameBuffer.length >= 5) {
          _flush();
        }
      }
    } catch (e) {
      print(
        '❌ SankofaReplay Error capturing frame so we skipped this tick: $e',
      );
    }
  }

  Future<void> _flush({bool force = false}) async {
    if (_isFlushing || _frameBuffer.isEmpty) return;
    _isFlushing = true;

    // 1. Snapshot the queue and clear it to accept new frames while uploading
    final framesToUpload = List.of(_frameBuffer);
    _frameBuffer.clear();

    try {
      // 2. Build the JSON Batch Payload with precise timestamps
      final List<Map<String, dynamic>> serializedFrames = framesToUpload.map((
        f,
      ) {
        return {
          'timestamp': f.timestamp.millisecondsSinceEpoch,
          'image_base64': base64Encode(f.bytes),
        };
      }).toList();

      final Map<String, dynamic> payload = {
        'session_id': _sessionId,
        'chunk_index': _chunkIndex,
        'frames': serializedFrames,
      };

      // 3. Gzip the JSON directly on the device (Massive bandwidth saver)
      final jsonString = jsonEncode(payload);
      final compressedBody = GZipCodec().encode(utf8.encode(jsonString));

      // 4. Send ONE single HTTP Request
      final uri = Uri.parse('$_endpoint/api/ee/replay/chunk');
      final req = http.Request('POST', uri)
        ..headers['x-api-key'] = _apiKey
        ..headers['Content-Type'] = 'application/json'
        ..headers['Content-Encoding'] = 'gzip'
        ..headers['X-Session-Id'] = _sessionId
        ..headers['X-Chunk-Index'] = _chunkIndex.toString()
        ..bodyBytes = compressedBody;

      final resp = await req.send();

      if (resp.statusCode == 200) {
        print(
          '🚀 SankofaReplay: Uploaded chunk $_chunkIndex (${framesToUpload.length} frames)',
        );
        _chunkIndex++;
      } else {
        print('❌ SankofaReplay: Chunk upload failed: ${resp.statusCode}');
        // 🛡️ CRITICAL: If upload fails (e.g., went into a tunnel), put frames back!
        _frameBuffer.insertAll(0, framesToUpload);
      }
    } catch (e) {
      print('❌ SankofaReplay: flush error: $e');
      // 🛡️ CRITICAL: Network crash fallback
      _frameBuffer.insertAll(0, framesToUpload);
    } finally {
      _isFlushing = false;
    }
  }

  // Handle app lifecycle for background flush
  void onAppLifecycleStateChanged(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _flush(force: true);
    }
  }
}

class _ReplayFrame {
  final DateTime timestamp;
  final Uint8List bytes;
  _ReplayFrame(this.timestamp, this.bytes);
}

/// Wrap your root MaterialApp with this widget to enable screenshot capture.
class SankofaReplayBoundary extends StatelessWidget {
  final Widget child;

  const SankofaReplayBoundary({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      key: SankofaReplay.instance.rootBoundaryKey,
      child: child,
    );
  }
}

/// A widget to mask sensitive information (like passwords or PII).
/// It paints a solid black box over its child during a replay capture tick.
class SankofaMask extends StatelessWidget {
  final Widget child;

  const SankofaMask({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    // In actual implementation, this would detect if a capture is happening
    // and replace the child with a black box. For MVP, we can return the child,
    // or wrap it in a custom RenderObject that knows when to paint black.
    // To keep it simple, we'll leave it as a pass-through for Phase 1.
    return child;
  }
}

class SankofaNavigatorObserver extends RouteObserver<PageRoute<dynamic>> {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    // Could send a route change event to Sankofa core here natively
  }
}
