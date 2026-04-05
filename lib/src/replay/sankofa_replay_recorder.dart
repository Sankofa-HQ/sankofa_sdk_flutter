import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'dart:ui' as ui;

import 'sankofa_replay_client.dart';
import 'sankofa_replay_uploader.dart';
import '../sankofa_client.dart';

class SankofaReplayRecorder {
  final void Function(String) logger;
  final SankofaReplayUploader uploader;

  bool _isRecording = false;
  bool _isCapturingFrame = false;
  SankofaReplayMode _mode = SankofaReplayMode.wireframe;
  int _fps = 1;

  Timer? _captureTimer;
  Timer? _highFidelityTimer;
  Timer? _scrollDebounceTimer;

  double _screenWidth = 0;
  double _screenHeight = 0;
  double _pixelRatio = 1.0;

  final GlobalKey rootBoundaryKey = GlobalKey();
  final List<Uint8List> _frameBuffer = [];
  final List<Map<String, dynamic>> _eventBuffer = [];
  DateTime? _chunkStartTime;
  bool _isBlueprintRunning = false;

  SankofaReplayRecorder({required this.logger, required this.uploader});

  bool get isRecording => _isRecording;
  bool get isCapturingFrame => _isCapturingFrame;
  SankofaReplayMode get mode => _mode;

  Future<void> configure({
    required SankofaReplayMode mode,
    required int fps,
    required String sessionId,
  }) async {
    final configChanged = _mode != mode || _fps != fps;

    if (_isRecording && configChanged) {
      await flush(force: true);
      _stopTimers();
      _isRecording = false;
    }

    _mode = mode;
    _fps = fps;

    if (!_isRecording) {
      _startRecording();
    }
  }

  void _startRecording() {
    _isRecording = true;
    _chunkStartTime = DateTime.now();

    if (_mode == SankofaReplayMode.screenshot) {
      final duration = Duration(milliseconds: (1000 / _fps).round());
      _captureTimer = Timer.periodic(duration, (_) => _captureFrame());
    } else {
      _captureTimer = Timer.periodic(
        const Duration(seconds: 10),
        (_) => flush(),
      );
      Future.delayed(const Duration(seconds: 1), _captureUIBlueprint);
    }
  }

  void _stopTimers() {
    _captureTimer?.cancel();
    _highFidelityTimer?.cancel();
    _scrollDebounceTimer?.cancel();
  }

  void stopRecording() {
    _stopTimers();
    _isRecording = false;
    flush(force: true);
  }

  Future<void> flush({bool force = false}) async {
    if (_mode == SankofaReplayMode.screenshot && _frameBuffer.isEmpty) return;
    if (_mode == SankofaReplayMode.wireframe && _eventBuffer.isEmpty) return;

    final frames = List.of(_frameBuffer);
    final events = List.of(_eventBuffer);
    final startTime = _chunkStartTime;

    _frameBuffer.clear();
    _eventBuffer.clear();
    _chunkStartTime = DateTime.now();

    await uploader.uploadChunk(
      mode: _mode,
      frames: frames,
      events: events,
      startTime: startTime,
      deviceContext: {
        'screen_width': _screenWidth,
        'screen_height': _screenHeight,
        'pixel_ratio': _pixelRatio,
      },
    );
  }

  // --- Capture Logic ---

  double _currentScrollY = 0;

  Future<void> _captureFrame() async {
    if (rootBoundaryKey.currentContext == null) return;
    _isCapturingFrame = true;

    try {
      final boundary =
          rootBoundaryKey.currentContext!.findRenderObject()
              as RenderRepaintBoundary?;
      if (boundary == null) return;

      // 🚀 THE FIX: If it's dirty, wait for the next frame before snapping!
      // This prevents capturing a partial/wireframe frame during animations.
      if (boundary.debugNeedsPaint) {
        await Future.delayed(const Duration(milliseconds: 20));
      }

      final image = await boundary.toImage(pixelRatio: 0.5);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);

      if (byteData != null) {
        _frameBuffer.add(byteData.buffer.asUint8List());
        if (_frameBuffer.length >= 5) flush();
      }
    } catch (e) {
      logger('❌ Capture error: $e');
    } finally {
      _isCapturingFrame = false;
    }
  }
  
  void _captureUIBlueprint() {
    if (_isBlueprintRunning) return;
    _isBlueprintRunning = true;

    try {
      final rootRenderObject = rootBoundaryKey.currentContext!
          .findRenderObject();
      if (rootRenderObject == null) {
        _isBlueprintRunning = false;
        return;
      }

      final List<Map<String, dynamic>> nodes = [];

      void walkTree(Element element) {
        if (nodes.length > 250) return; // 🛑 HARD LIMIT: Don't choke on giant lists

        final widget = element.widget;
        final renderObject = element.renderObject;

        // Skip internal/invisible elements
        final isLeaf =
            widget is Text ||
            widget is Image ||
            widget is Icon ||
            widget is ButtonStyleButton ||
            widget is IconButton;

        if (isLeaf && renderObject is RenderBox && renderObject.hasSize) {
          try {
            final offset = renderObject.localToGlobal(
              Offset.zero,
              ancestor: rootRenderObject,
            );
            final size = renderObject.size;

            // 🔦 VISIBILITY GUARD: Skip off-screen elements
            if (offset.dx < _screenWidth &&
                offset.dy < _screenHeight &&
                offset.dx + size.width > 0 &&
                offset.dy + size.height > 0) {
              
              String type = 'box';
              String? value;
              if (widget is Text) {
                type = 'text';
                value = widget.data ?? widget.textSpan?.toPlainText();
              } else if (widget is Image || widget is Icon) {
                type = 'media';
              } else if (widget is ButtonStyleButton || widget is IconButton) {
                type = 'button';
              }

              nodes.add({
                't': type,
                if (value != null) 'v': value,
                'x': offset.dx, // 🎯 DOUBLE PRECISION
                'y': offset.dy,
                'w': size.width,
                'h': size.height,
              });
            }
          } catch (_) {}
        }
        element.visitChildren(walkTree);
      }

      rootBoundaryKey.currentContext!.visitChildElements(walkTree);
      _eventBuffer.add({
        'type': 'ui_snapshot',
        'screen': Sankofa.instance.currentScreen,
        'time_offset_ms': DateTime.now()
            .difference(_chunkStartTime!)
            .inMilliseconds,
        'nodes': nodes,
      });
    } catch (e) {
      logger('❌ Blueprint error: $e');
    } finally {
      _isBlueprintRunning = false;
    }
  }

  // --- Event Recording ---

  void updateDeviceContext(double w, double h, double pr) {
    _screenWidth = w;
    _screenHeight = h;
    _pixelRatio = pr;
  }

  void recordPointerEvent(String type, PointerEvent event) {
    if (!_isRecording) return;

    // 🚀 Absolute Y = Screen position + Current Scroll Offset
    final absoluteY = event.position.dy + _currentScrollY;

    int rrwebType = 1;
    if (type == 'pointer_up') {
      rrwebType = 0;
    } else if (type == 'pointer_move') {
      rrwebType = 6;
    } else if (type == 'pointer_pan_zoom') {
      rrwebType = 7;
    }

    _eventBuffer.add({
      'type': 3, // rrweb IncrementalSnapshot
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'data': {
        'source': 2, // MouseInteraction
        'type': rrwebType,
        'id': 1,
        'x': event.position.dx,
        'y': absoluteY, // Heatmap will use this!
      },
      'screen': Sankofa.instance.currentScreen, // 🔥 Stateful screen tagging
      'time_offset_ms': DateTime.now()
          .difference(_chunkStartTime!)
          .inMilliseconds,
    });
  }

  void recordRouteEvent(String routeName) {
    if (!_isRecording) return;
    _eventBuffer.add({
      'type': 'route_change',
      'route': routeName,
      'screen': routeName,
      'time_offset_ms': DateTime.now()
          .difference(_chunkStartTime!)
          .inMilliseconds,
    });
    Future.delayed(const Duration(milliseconds: 500), _captureUIBlueprint);
  }

  void recordScrollEvent(double scrollY) {
    _currentScrollY = scrollY; // 🚀 Keep track of exactly where we are

    if (_mode != SankofaReplayMode.wireframe || !_isRecording) return;
    _eventBuffer.add({
      'type': 'scroll',
      'y': scrollY,
      'screen': Sankofa.instance.currentScreen,
      'time_offset_ms': DateTime.now()
          .difference(_chunkStartTime!)
          .inMilliseconds,
    });
    _scrollDebounceTimer?.cancel();
    _scrollDebounceTimer = Timer(
      const Duration(milliseconds: 500),
      _captureUIBlueprint,
    );
  }

  void triggerHighFidelityMode(Duration duration) {
    if (_mode == SankofaReplayMode.screenshot) {
      _highFidelityTimer?.cancel();
      _highFidelityTimer = Timer(duration, _revertToWireframe);
      return;
    }

    flush(force: true).then((_) {
      _mode = SankofaReplayMode.screenshot;
      _chunkStartTime = DateTime.now();
      _captureTimer?.cancel();
      
      // 📸 Capture AND Flush immediately on trigger!
      _captureFrame().then((_) => flush(force: true));

      final fpsDuration = Duration(milliseconds: (1000 / _fps).round());
      _captureTimer = Timer.periodic(fpsDuration, (_) => _captureFrame());
      _highFidelityTimer = Timer(duration, _revertToWireframe);
    });
  }

  void _revertToWireframe() {
    flush(force: true).then((_) {
      _mode = SankofaReplayMode.wireframe;
      _chunkStartTime = DateTime.now();
      _captureTimer?.cancel();
      _captureTimer = Timer.periodic(
        const Duration(seconds: 10),
        (_) => flush(),
      );
    });
  }
}
