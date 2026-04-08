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

  // ── Move-event rate limiting (parity with iOS / Android / Web SDKs) ──────
  // Flutter's [Listener] receives every PointerMove the engine produces —
  // 60Hz on most devices, 120Hz on ProMotion iPads.  Without throttling, a
  // single 5-second drag used to produce 300+ rows in replay_interactions,
  // inflating "Gestures on Screen" by 100x and triggering false rage clusters.
  //
  // Throttle = max 1 move sample per 50ms (~20 Hz, same as the other SDKs).
  // Coalesce = drop moves whose (x,y) is within MOVE_COALESCE_PX of the
  //            last recorded sample.  Eliminates jitter while a finger is
  //            held still.
  static const Duration _moveThrottleInterval = Duration(milliseconds: 50);
  static const double _moveCoalescePx = 4.0;
  int _lastMoveSampleAtMs = 0;
  double _lastMoveX = -9999;
  double _lastMoveY = -9999;

  // ── Double-tap recognition ────────────────────────────────────────────────
  // When two pointer_down events fire within DOUBLE_TAP_INTERVAL_MS and
  // DOUBLE_TAP_RADIUS_PX of each other, we emit an additional rrweb event
  // with type=4 (dblclick) so the dashboard renders a "2×" marker overlay
  // distinct from regular taps.  Mirrors the iOS / Android / Web detectors.
  static const int _doubleTapIntervalMs = 350;
  static const double _doubleTapRadiusPx = 25.0;
  int _lastTapAtMs = 0;
  double _lastTapX = -9999;
  double _lastTapY = -9999;

  Future<void> _captureFrame() async {
    if (rootBoundaryKey.currentContext == null) return;
    _isCapturingFrame = true;

    try {
      final boundary =
          rootBoundaryKey.currentContext!.findRenderObject()
              as RenderRepaintBoundary?;
      if (boundary == null) return;

      // 🚀 THE FIX: If it's dirty, wait for a few frames before snapping!
      // This ensures we capture the 'final' rendered state for heatmaps.
      if (boundary.debugNeedsPaint) {
        await Future.delayed(const Duration(milliseconds: 100));
      }

      final image = await boundary.toImage(pixelRatio: 0.7);
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

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final x = event.position.dx;
    final yScreen = event.position.dy;
    // 🚀 Absolute Y = Screen position + Current Scroll Offset.
    // Used as the canonical Y for ALL event types so move samples line up
    // with the down/up rows the heatmap renders against.
    final absoluteY = yScreen + _currentScrollY;

    // ── (1) Down resets the move + double-tap trackers ────────────────────
    if (type == 'pointer_down') {
      _lastMoveSampleAtMs = 0;
      _lastMoveX = -9999;
      _lastMoveY = -9999;
    }

    // ── (2) Throttle + coalesce pointer_move ──────────────────────────────
    // 60-120 Hz raw move events are reduced to ~20 Hz max, and any move
    // within MOVE_COALESCE_PX of the previous sample is dropped entirely.
    // Defends against flooding the dashboard heatmap with jitter samples.
    if (type == 'pointer_move') {
      if (nowMs - _lastMoveSampleAtMs < _moveThrottleInterval.inMilliseconds) {
        return;
      }
      final dx = x - _lastMoveX;
      final dy = yScreen - _lastMoveY;
      if (dx * dx + dy * dy < _moveCoalescePx * _moveCoalescePx) {
        return;
      }
      _lastMoveSampleAtMs = nowMs;
      _lastMoveX = x;
      _lastMoveY = yScreen;
    }

    int rrwebType;
    switch (type) {
      case 'pointer_down':
        rrwebType = 1;
        break;
      case 'pointer_up':
        rrwebType = 0;
        break;
      case 'pointer_move':
        rrwebType = 6;
        break;
      case 'pointer_pan_zoom':
        rrwebType = 7;
        break;
      default:
        rrwebType = 1;
    }

    _eventBuffer.add({
      'type': 3, // rrweb IncrementalSnapshot
      'timestamp': nowMs,
      'data': {
        'source': 2, // MouseInteraction
        'type': rrwebType,
        'id': 1,
        'x': x,
        'y': absoluteY,
      },
      'screen': Sankofa.instance.currentScreen, // 🔥 Stateful screen tagging
      'time_offset_ms': DateTime.now()
          .difference(_chunkStartTime!)
          .inMilliseconds,
    });

    // ── (3) Double-tap recognition (parity with iOS / Android / Web) ──────
    // Runs ONLY on pointer_down events.  When the current down lands within
    // _doubleTapIntervalMs and _doubleTapRadiusPx of the previous one, we
    // emit an additional rrweb event with type=4 (dblclick).  The dashboard
    // reads this as a "2×" marker overlay distinct from regular taps.
    // The original pointer_down stays in the buffer so the click heatmap
    // intensity is unaffected.
    if (type == 'pointer_down') {
      final dt = nowMs - _lastTapAtMs;
      final dxc = x - _lastTapX;
      final dyc = yScreen - _lastTapY;
      final isDouble = _lastTapAtMs > 0 &&
          dt < _doubleTapIntervalMs &&
          dxc * dxc + dyc * dyc < _doubleTapRadiusPx * _doubleTapRadiusPx;

      if (isDouble) {
        _eventBuffer.add({
          'type': 3,
          'timestamp': nowMs,
          'data': {
            'source': 2,
            'type': 4, // rrweb dblclick
            'id': 1,
            'x': x,
            'y': absoluteY,
          },
          'screen': Sankofa.instance.currentScreen,
          'time_offset_ms': DateTime.now()
              .difference(_chunkStartTime!)
              .inMilliseconds,
        });
        // Reset so a third tap doesn't fire another double-tap.
        _lastTapAtMs = 0;
        _lastTapX = -9999;
        _lastTapY = -9999;
      } else {
        _lastTapAtMs = nowMs;
        _lastTapX = x;
        _lastTapY = yScreen;
      }
    }
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
      'type': 3, // rrweb IncrementalSnapshot
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'data': {
        'source': 3, // Scroll
        'y': scrollY,
      },
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
