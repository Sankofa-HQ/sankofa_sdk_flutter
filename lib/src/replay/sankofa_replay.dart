import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

enum SankofaReplayMode { wireframe, screenshot }

class SankofaReplay {
  static final SankofaReplay instance = SankofaReplay._internal();
  SankofaReplay._internal();

  bool _isInit = false;
  bool _isRecording = false;
  bool _isCapturingFrame =
      false; // Add state to know *exactly* when we are painting for capture
  String _apiKey = '';
  String _endpoint = '';
  String _sessionId = '';
  String _distinctId = 'anonymous';
  SankofaReplayMode _mode = SankofaReplayMode.wireframe;
  int _fps = 1;
  Timer? _captureTimer;

  // Device dimensions for wireframe mode
  double _screenWidth = 0;
  double _screenHeight = 0;
  double _pixelRatio = 1.0;

  final GlobalKey _repaintBoundaryKey = GlobalKey();

  // Provide this key to the root widget
  GlobalKey get rootBoundaryKey => _repaintBoundaryKey;

  // Expose this for the Mask render object
  bool get isCapturingFrame => _isCapturingFrame;
  SankofaReplayMode get mode => _mode;

  final List<_ReplayFrame> _frameBuffer = [];
  final List<Map<String, dynamic>> _eventBuffer = [];
  DateTime? _chunkStartTime;

  int _chunkIndex = 0;
  bool _isFlushing = false;

  void init({
    required String apiKey,
    required String endpoint,
    required String sessionId,
    String distinctId = 'anonymous',
    SankofaReplayMode mode = SankofaReplayMode.wireframe,
    int fps = 1,
  }) {
    if (_isInit) return;
    _apiKey = apiKey;
    _endpoint = endpoint;
    _sessionId = sessionId;
    _distinctId = distinctId;
    _mode = mode;
    _fps = fps;
    _isInit = true;

    // Load persisted chunk index to prevent Backblaze duplicates on hot restarts
    SharedPreferences.getInstance().then((prefs) {
      final key = 'sankofa_replay_chunk_$_sessionId';
      _chunkIndex = prefs.getInt(key) ?? 0;

      print(
        '🎥 SankofaReplay: Initialized correctly with Session: $_sessionId and Endpoint: $_endpoint (Starting at Chunk $_chunkIndex)',
      );
      _startRecording();
    });
  }

  void setDistinctId(String distinctId) {
    _distinctId = distinctId;
  }

  void _startRecording() {
    if (_isRecording || !_isInit) return;
    _isRecording = true;
    _chunkStartTime = DateTime.now();

    if (_mode == SankofaReplayMode.screenshot) {
      final duration = Duration(milliseconds: (1000 / _fps).round());
      _captureTimer = Timer.periodic(duration, (_) => _captureFrame());
    } else {
      // Wireframe Mode uses a 10s async flush loop instead of FPS capture
      _captureTimer = Timer.periodic(
        const Duration(seconds: 10),
        (_) => _flush(),
      );
    }
  }

  // --- Wireframe Engine Methods ---

  void _updateDeviceContext(double width, double height, double pixelRatio) {
    _screenWidth = width;
    _screenHeight = height;
    _pixelRatio = pixelRatio;
  }

  void _recordPointerEvent(String type, PointerEvent event) {
    if (_mode != SankofaReplayMode.wireframe || !_isRecording) return;
    _chunkStartTime ??= DateTime.now();

    _eventBuffer.add({
      'type': type,
      'x': event.position.dx,
      'y': event.position.dy,
      'time_offset_ms': DateTime.now()
          .difference(_chunkStartTime!)
          .inMilliseconds,
    });
  }

  void _recordRouteEvent(String routeName) {
    if (_mode != SankofaReplayMode.wireframe || !_isRecording) return;
    _chunkStartTime ??= DateTime.now();

    _eventBuffer.add({
      'type': 'route_change',
      'route': routeName,
      'time_offset_ms': DateTime.now()
          .difference(_chunkStartTime!)
          .inMilliseconds,
    });
  }

  // --- Screenshot Engine Methods ---

  void stopRecording() {
    _captureTimer?.cancel();
    _isRecording = false;
    _flush(force: true);
  }

  Future<void> _captureFrame() async {
    if (_repaintBoundaryKey.currentContext == null) return;

    _isCapturingFrame = true; // Signal to our custom painted masks
    await Future.microtask(
      () {},
    ); // Let the event loop run so masks can mark needsPaint if we were doing State management, but RenderObjects paint synchronously on the UI thread when `toImage` is called. Actually, `toImage` forces a repaint layer if needed. For safety, we just set the flag.

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
    } finally {
      _isCapturingFrame = false; // Always turn off the signal
    }
  }

  Future<void> _flush({bool force = false}) async {
    if (_isFlushing) return;

    // Check if we have any data to send
    if (_mode == SankofaReplayMode.screenshot && _frameBuffer.isEmpty) return;
    if (_mode == SankofaReplayMode.wireframe && _eventBuffer.isEmpty) return;

    _isFlushing = true;

    // 1. Snapshot the queue and clear it to accept new data while uploading
    final framesToUpload = List.of(_frameBuffer);
    final eventsToUpload = List.of(_eventBuffer);

    _frameBuffer.clear();
    _eventBuffer.clear();

    // Reset chunk timer for relative event tracking
    _chunkStartTime = DateTime.now();

    try {
      // 2. Build the JSON Batch Payload
      final Map<String, dynamic> payload = {
        'session_id': _sessionId,
        'chunk_index': _chunkIndex,
        'mode': _mode.name,
      };

      if (_mode == SankofaReplayMode.screenshot) {
        payload['frames'] = framesToUpload.map((f) {
          return {
            'timestamp': f.timestamp.millisecondsSinceEpoch,
            'image_base64': base64Encode(f.bytes),
          };
        }).toList();
      } else {
        payload['device_context'] = {
          'screen_width': _screenWidth,
          'screen_height': _screenHeight,
          'pixel_ratio': _pixelRatio,
        };
        payload['events'] = eventsToUpload;
      }

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
        ..headers['X-Distinct-Id'] = _distinctId
        ..headers['X-Chunk-Index'] = _chunkIndex.toString()
        ..headers['X-Replay-Mode'] = _mode.name
        ..bodyBytes = compressedBody;

      final resp = await req.send();

      if (resp.statusCode == 200) {
        final itemCount = _mode == SankofaReplayMode.screenshot
            ? framesToUpload.length
            : eventsToUpload.length;
        print(
          '🚀 SankofaReplay: Uploaded ${_mode.name} chunk $_chunkIndex ($itemCount items)',
        );
        _chunkIndex++;
        // Persist the incremented index in case the app is killed
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt('sankofa_replay_chunk_$_sessionId', _chunkIndex);
      } else {
        print('❌ SankofaReplay: Chunk upload failed: ${resp.statusCode}');
        // 🛡️ CRITICAL: If upload fails (e.g., went into a tunnel), put data back!
        if (_mode == SankofaReplayMode.screenshot) {
          _frameBuffer.insertAll(0, framesToUpload);
        } else {
          _eventBuffer.insertAll(0, eventsToUpload);
        }
      }
    } catch (e) {
      print('❌ SankofaReplay: flush error: $e');
      // 🛡️ CRITICAL: Network crash fallback
      if (_mode == SankofaReplayMode.screenshot) {
        _frameBuffer.insertAll(0, framesToUpload);
      } else {
        _eventBuffer.insertAll(0, eventsToUpload);
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

class SankofaReplayBoundary extends StatelessWidget {
  final Widget child;

  const SankofaReplayBoundary({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    // Safely capture Device Dimensions once without relying on a MaterialApp ancestor
    try {
      final view = ui.PlatformDispatcher.instance.views.first;
      SankofaReplay.instance._updateDeviceContext(
        view.physicalSize.width,
        view.physicalSize.height,
        view.devicePixelRatio,
      );
    } catch (e) {
      if (kDebugMode)
        print('⚠️ SankofaReplay: Could not load screen dimensions');
    }

    // Always include BOTH the RepaintBoundary (for Screenshot Mode)
    // AND the Listener (for Wireframe Mode).
    // The active `_mode` property will determine which engine actually collects data.
    return RepaintBoundary(
      key: SankofaReplay.instance.rootBoundaryKey,
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (e) =>
            SankofaReplay.instance._recordPointerEvent('pointer_down', e),
        onPointerMove: (e) =>
            SankofaReplay.instance._recordPointerEvent('pointer_move', e),
        onPointerUp: (e) =>
            SankofaReplay.instance._recordPointerEvent('pointer_up', e),
        child: child,
      ),
    );
  }
}

/// A widget to mask sensitive information (like passwords or PII).
/// It paints a solid black box over its child during a replay capture tick.
class SankofaMask extends SingleChildRenderObjectWidget {
  const SankofaMask({super.key, required Widget child}) : super(child: child);

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderSankofaMask();
  }

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderSankofaMask renderObject,
  ) {}
}

class _RenderSankofaMask extends RenderProxyBox {
  @override
  void paint(PaintingContext context, Offset offset) {
    if (SankofaReplay.instance.isCapturingFrame) {
      // Paint a solid black rectangle over the child's bounds
      final paint = Paint()..color = const Color(0xFF000000); // Solid Black
      context.canvas.drawRect(offset & size, paint);
    } else {
      // Paint the child normally
      if (child != null) {
        context.paintChild(child!, offset);
      }
    }
  }
}

class SankofaNavigatorObserver extends RouteObserver<PageRoute<dynamic>> {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    if (route.settings.name != null) {
      SankofaReplay.instance._recordRouteEvent(route.settings.name!);
    }
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    if (newRoute?.settings.name != null) {
      SankofaReplay.instance._recordRouteEvent(newRoute!.settings.name!);
    }
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    if (previousRoute?.settings.name != null) {
      SankofaReplay.instance._recordRouteEvent(previousRoute!.settings.name!);
    }
  }
}
