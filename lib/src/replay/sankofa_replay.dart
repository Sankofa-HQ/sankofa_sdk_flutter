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
  Timer? _highFidelityTimer;

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

      // Capture the initial UI blueprint for the first screen
      Future.delayed(const Duration(milliseconds: 1000), () {
        _captureUIBlueprint();
      });
    }
  }

  // --- Dynamic Mode Switching ---

  /// Temporarily switches the recording engine to high-fidelity (screenshot mode)
  /// for a set duration to capture critical visual states.
  void triggerHighFidelityMode(Duration duration) {
    if (!_isInit || !_isRecording) return;

    // If already in screenshot mode, just extend the timer if applicable
    if (_mode == SankofaReplayMode.screenshot) {
      _highFidelityTimer?.cancel();
      _highFidelityTimer = Timer(duration, _revertToWireframe);
      return;
    }

    print(
      '🔥 SankofaReplay: High-Fidelity Trigger activated for ${duration.inSeconds} seconds!',
    );

    // 1. Flush any pending wireframes immediately
    _flush(force: true).then((_) {
      // 2. Switch mode
      _mode = SankofaReplayMode.screenshot;
      _chunkStartTime = DateTime.now();

      // 3. Restart timers for screenshot capture
      _captureTimer?.cancel();
      final fpsDuration = Duration(milliseconds: (1000 / _fps).round());
      _captureTimer = Timer.periodic(fpsDuration, (_) => _captureFrame());

      // 4. Set the timer to revert back to wireframe
      _highFidelityTimer?.cancel();
      _highFidelityTimer = Timer(duration, _revertToWireframe);
    });
  }

  void _revertToWireframe() {
    if (_mode != SankofaReplayMode.screenshot || !_isRecording) return;

    print(
      '🧊 SankofaReplay: High-Fidelity duration ended. Reverting to wireframe.',
    );

    _flush(force: true).then((_) {
      _mode = SankofaReplayMode.wireframe;
      _chunkStartTime = DateTime.now();

      _captureTimer?.cancel();
      _captureTimer = Timer.periodic(
        const Duration(seconds: 10),
        (_) => _flush(),
      );
    });
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

    // 🌟 NEW: Take a snapshot of the UI 500ms after a route change (allowing animations to finish)
    Future.delayed(const Duration(milliseconds: 500), () {
      _captureUIBlueprint();
    });
  }

  double _lastScrollY = 0;
  Timer? _scrollDebounceTimer;

  void _recordScrollEvent(double scrollY) {
    if (_mode != SankofaReplayMode.wireframe || !_isRecording) return;
    _chunkStartTime ??= DateTime.now();

    // Debounce noise for tiny rapid scroll ticks
    if ((scrollY - _lastScrollY).abs() < 5) return;
    _lastScrollY = scrollY;

    _eventBuffer.add({
      'type': 'scroll',
      'y': scrollY,
      'time_offset_ms': DateTime.now()
          .difference(_chunkStartTime!)
          .inMilliseconds,
    });

    // Capture the UI blueprint 500ms after the user *stops* scrolling
    _scrollDebounceTimer?.cancel();
    _scrollDebounceTimer = Timer(const Duration(milliseconds: 500), () {
      _captureUIBlueprint();
    });
  }

  /// Walks the Flutter Element tree to map the UI layout
  void _captureUIBlueprint() {
    if (_mode != SankofaReplayMode.wireframe || !_isRecording) return;
    if (_repaintBoundaryKey.currentContext == null) return;

    try {
      final rootRenderObject = _repaintBoundaryKey.currentContext!
          .findRenderObject();
      if (rootRenderObject == null) return;

      final List<Map<String, dynamic>> nodes = [];

      // Recursive function to walk the tree
      void walkTree(Element element) {
        final widget = element.widget;
        final renderObject = element.renderObject;

        // We only care about leaf-node widgets to keep the UI clean
        final isMeaningful =
            widget is Text ||
            widget is Image ||
            widget is Icon ||
            widget is ElevatedButton ||
            widget is TextButton ||
            widget is OutlinedButton ||
            widget is FilledButton ||
            widget is IconButton;

        if (isMeaningful && renderObject is RenderBox && renderObject.hasSize) {
          try {
            // Get exact coordinates relative to our root boundary
            final offset = renderObject.localToGlobal(
              Offset.zero,
              ancestor: rootRenderObject,
            );
            final size = renderObject.size;

            // Ignore invisible or full-screen wrappers to keep JSON tiny
            if (size.width > 0 &&
                size.height > 0 &&
                size.width < _screenWidth &&
                size.height < _screenHeight) {
              
              String nodeType = 'box';
              String? nodeValue;

              if (widget is Text) {
                nodeType = 'text';
                nodeValue = widget.data ?? widget.textSpan?.toPlainText();
              } else if (widget is Image || widget is Icon) {
                nodeType = 'media';
              } else if (widget is ElevatedButton || widget is TextButton || widget is OutlinedButton || widget is FilledButton || widget is IconButton) {
                nodeType = 'button';
              }

              nodes.add({
                't': nodeType,
                if (nodeValue != null) 'v': nodeValue,
                'x': offset.dx.round(),
                'y': offset.dy.round(),
                'w': size.width.round(),
                'h': size.height.round(),
              });
            }
          } catch (e) {
            // Ignore geometry errors for unmounted widgets
          }
        }

        // Recursively visit children
        element.visitChildren(walkTree);
      }

      // Start the walk from the root boundary
      _repaintBoundaryKey.currentContext!.visitChildElements(walkTree);

      // Save the snapshot to the event buffer
      _chunkStartTime ??= DateTime.now();
      _eventBuffer.add({
        'type': 'ui_snapshot',
        'time_offset_ms': DateTime.now()
            .difference(_chunkStartTime!)
            .inMilliseconds,
        'nodes': nodes,
      });

      if (kDebugMode) {
        print(
          '📐 SankofaReplay: Captured UI Blueprint with ${nodes.length} nodes',
        );
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ SankofaReplay Blueprint Error: $e');
      }
    }
  }

  // --- Screenshot Engine Methods ---

  void stopRecording() {
    _captureTimer?.cancel();
    _highFidelityTimer?.cancel();
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
    final oldChunkStartTime = _chunkStartTime;

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
        payload['chunk_start_timestamp'] =
            oldChunkStartTime?.millisecondsSinceEpoch ??
            DateTime.now().millisecondsSinceEpoch;
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
        view.physicalSize.width / view.devicePixelRatio,
        view.physicalSize.height / view.devicePixelRatio,
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
      child: NotificationListener<ScrollNotification>(
        onNotification: (ScrollNotification scrollInfo) {
          if (scrollInfo.depth == 0) {
            SankofaReplay.instance._recordScrollEvent(scrollInfo.metrics.pixels);
          }
          return false;
        },
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
