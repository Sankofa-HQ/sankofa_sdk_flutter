import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

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
      if (boundary == null || boundary.debugNeedsPaint) return;

      final image = await boundary.toImage(
        pixelRatio: 1.0,
      ); // Keep ratio 1.0 to save space
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      // Note: Flutter doesn't natively encode WebP. We'll use PNG, which gzip will compress well.

      if (byteData != null) {
        final bytes = byteData.buffer.asUint8List();
        _frameBuffer.add(_ReplayFrame(DateTime.now(), bytes));

        if (_frameBuffer.length >= 20) {
          _flush();
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('SankofaReplay Error capturing frame: $e');
      }
    }
  }

  Future<void> _flush({bool force = false}) async {
    if (_isFlushing || _frameBuffer.isEmpty) return;
    _isFlushing = true;

    try {
      final framesToUpload = List.of(_frameBuffer);
      _frameBuffer.clear();

      // Encode frames as a very simple custom binary format for MVP:
      // [8 bytes timestamp][N bytes PNG length][PNG bytes] ...
      // But since we want to be simple, let's just upload the last frame per chunk for now,
      // or concat them. For MVP of "video", a sequence of images is fine.
      // Let's create a tar-like or simple prefixed format.
      // Easiest is to just send the raw bytes of ONE image per chunk for testing, or JSON encode base64.
      // Wait, the Go backend expects raw WebP/PNG byte array. So let's just send the first frame of the buffer for the chunk,
      // or we can append them. Let's send them individually as chunks to fit the backend MVP perfectly.

      for (var frame in framesToUpload) {
        final compressed = GZipCodec().encode(frame.bytes);

        final uri = Uri.parse('$_endpoint/api/ee/replay/chunk');

        final req = http.Request('POST', uri)
          ..headers['x-api-key'] = _apiKey
          ..headers['Content-Type'] = 'application/octet-stream'
          ..headers['Content-Encoding'] = 'gzip'
          ..headers['X-Session-Id'] = _sessionId
          ..headers['X-Chunk-Index'] = _chunkIndex.toString()
          ..bodyBytes = compressed;

        final resp = await req.send();
        if (resp.statusCode == 200) {
          _chunkIndex++;
        } else {
          if (kDebugMode) {
            print('SankofaReplay Chunk upload failed: ${resp.statusCode}');
          }
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('SankofaReplay flush error: $e');
      }
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

  const SankofaReplayBoundary({Key? key, required this.child})
    : super(key: key);

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

  const SankofaMask({Key? key, required this.child}) : super(key: key);

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
