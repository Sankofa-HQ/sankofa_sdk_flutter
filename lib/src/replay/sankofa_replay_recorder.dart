import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'dart:ui' as ui;

import 'sankofa_replay_client.dart';
import 'sankofa_replay_uploader.dart';
import 'sankofa_replay_mask.dart';
import '../sankofa_client.dart';

class SankofaReplayRecorder {
  final void Function(String) logger;
  final SankofaReplayUploader uploader;

  bool _isRecording = false;
  bool _isCapturingFrame = false;
  SankofaReplayMode _mode = SankofaReplayMode.wireframe;
  int _fps = 1;

  /// Privacy policy. [maskAllInputs] (server default true) masks every text
  /// input; obscured fields are ALWAYS masked regardless. [maskAllText] also
  /// masks rendered Text (screenshot) and redacts it in the wireframe
  /// blueprint. [maskAllImages] masks Image widgets.
  bool _maskAllInputs = true;
  bool _maskAllText = false;
  bool _maskAllImages = false;

  /// Downscale factor for screenshot capture (and the divisor used to map
  /// logical mask rects onto the captured image's pixels).
  static const double _capturePixelRatio = 0.7;

  /// Hard caps so a stalled/offline uploader can't grow the buffers without
  /// bound (OOM). Oldest are dropped past the cap.
  static const int _maxBufferedFrames = 30;
  static const int _maxBufferedEvents = 1000;

  Timer? _captureTimer;
  Timer? _highFidelityTimer;
  Timer? _scrollDebounceTimer;

  double _screenWidth = 0;
  double _screenHeight = 0;
  double _pixelRatio = 1.0;

  final GlobalKey rootBoundaryKey = GlobalKey();
  final List<Uint8List> _frameBuffer = [];
  // Per-frame capture timestamps in lockstep with `_frameBuffer`.
  // Previously every frame in a chunk was tagged with the upload-time
  // millisecond, which collapsed all frames in a 5-frame chunk to the
  // same point on the replay player's timeline (visible as a stutter or
  // a single still frame).  Capture-time stamps fix that.
  final List<int> _frameTimestamps = [];
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
    bool maskAllInputs = true,
    bool maskAllText = false,
    bool maskAllImages = false,
  }) async {
    final configChanged = _mode != mode || _fps != fps;

    _maskAllInputs = maskAllInputs;
    _maskAllText = maskAllText;
    _maskAllImages = maskAllImages;

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
    final frameTimestamps = List.of(_frameTimestamps);
    final events = List.of(_eventBuffer);
    final startTime = _chunkStartTime;

    _frameBuffer.clear();
    _frameTimestamps.clear();
    _eventBuffer.clear();
    _chunkStartTime = DateTime.now();

    final delivered = await uploader.uploadChunk(
      mode: _mode,
      frames: frames,
      frameTimestamps: frameTimestamps,
      events: events,
      startTime: startTime,
      deviceContext: {
        'screen_width': _screenWidth,
        'screen_height': _screenHeight,
        'pixel_ratio': _pixelRatio,
      },
    );

    // On a transient failure, put the chunk back at the FRONT of the buffers
    // (oldest-first) rather than dropping it, then re-enforce the caps so a
    // persistent outage still can't grow memory without bound.
    if (!delivered) {
      _frameBuffer.insertAll(0, frames);
      _frameTimestamps.insertAll(0, frameTimestamps);
      _eventBuffer.insertAll(0, events);
      _enforceBufferCaps();
    }
  }

  /// Drop oldest buffered frames/events past the hard caps (OOM guard).
  void _enforceBufferCaps() {
    while (_frameBuffer.length > _maxBufferedFrames) {
      _frameBuffer.removeAt(0);
      if (_frameTimestamps.isNotEmpty) _frameTimestamps.removeAt(0);
    }
    while (_eventBuffer.length > _maxBufferedEvents) {
      _eventBuffer.removeAt(0);
    }
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

  // ── Multi-touch pinch detection (mobile) ─────────────────────────────────
  // Flutter's [Listener] surfaces every pointer as a separate stream of
  // Down → Move → Up events keyed by `event.pointer`.  When two pointers
  // are active simultaneously we emit a single midpoint event with
  // rrweb type 7 (Pinch / Zoom) per throttle window — replacing the
  // regular pointer_move path so a pinch never double-records as both
  // a swipe and a pinch.  Mirrors the iOS / Android pinch detectors.
  //
  // `onPointerPanZoomUpdate` covers the desktop / iPad-trackpad pinch
  // case where the engine surfaces pan-zoom directly.  This map covers
  // the mobile two-finger case where it does not.
  final Map<int, Offset> _activePointers = {};
  int _lastPinchAtMs = 0;

  Future<void> _captureFrame() async {
    if (rootBoundaryKey.currentContext == null) return;

    // 🚦 Cold-start screen guard.  The host tags screens explicitly via
    // `Sankofa.instance.screen(...)` or the `SankofaNavigatorObserver`.
    // Until that happens, captured frames would all be attributed to an
    // untagged bucket the dashboard's per-screen heatmap can't match.
    // Mirrors the iOS / Android `hasTaggedScreen()` guard.
    if (!Sankofa.instance.hasTaggedScreen) return;

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

      // Collect sensitive regions to mask BEFORE rasterizing (logical coords,
      // relative to the capture boundary).
      final maskRects = _collectMaskRects(boundary);

      // Capture timestamp BEFORE the (potentially slow) toImage / encode
      // pipeline so the recorded time reflects when the bitmap was
      // actually rendered.  Both lists stay in lockstep so the uploader
      // can pair each frame with its capture moment.
      final captureTimestampMs = DateTime.now().toUtc().millisecondsSinceEpoch;
      final image = await boundary.toImage(pixelRatio: _capturePixelRatio);

      // Overpaint sensitive regions with solid black on a composited copy.
      // Doing this in the bitmap (rather than relying on the SankofaMask
      // widget painting black during capture) guarantees masking even across
      // route transitions / un-repainted frames — closing the mask-transition
      // race — and covers auto-detected inputs the host never wrapped.
      final masked = await _applyMasks(image, maskRects);
      final byteData =
          await masked.toByteData(format: ui.ImageByteFormat.png);
      masked.dispose();

      if (byteData != null) {
        _frameBuffer.add(byteData.buffer.asUint8List());
        _frameTimestamps.add(captureTimestampMs);
        _enforceBufferCaps();
        if (_frameBuffer.length >= 5) flush();
      }
    } catch (e) {
      logger('❌ Capture error: $e');
    } finally {
      _isCapturingFrame = false;
    }
  }

  /// Walk the render tree under [boundary] and return the rects (logical
  /// coordinates, relative to the boundary) of every surface that must be
  /// masked per the active privacy policy: all obscured text fields always;
  /// all text inputs when [_maskAllInputs]; explicit [SankofaMask] regions
  /// always; Text when [_maskAllText]; Image when [_maskAllImages].
  List<Rect> _collectMaskRects(RenderObject boundary) {
    final rects = <Rect>[];
    final ctx = rootBoundaryKey.currentContext;
    if (ctx == null) return rects;

    void visit(Element element) {
      if (rects.length > 400) return; // safety bound
      final widget = element.widget;
      final ro = element.renderObject;

      bool shouldMask = false;
      if (widget is EditableText) {
        // Always mask obscured (password) fields; mask all inputs when asked.
        shouldMask = _maskAllInputs || widget.obscureText;
      } else if (widget is SankofaMask) {
        shouldMask = true;
      } else if (widget is Image && _maskAllImages) {
        shouldMask = true;
      } else if (widget is Text && _maskAllText) {
        shouldMask = true;
      }

      if (shouldMask && ro is RenderBox && ro.hasSize && ro.attached) {
        try {
          final origin = ro.localToGlobal(Offset.zero, ancestor: boundary);
          rects.add(origin & ro.size);
        } catch (_) {/* detached mid-walk — skip */}
      }
      element.visitChildren(visit);
    }

    ctx.visitChildElements(visit);
    return rects;
  }

  /// Composite [image] with solid-black rectangles over each masked region.
  /// [maskRects] are in logical coordinates; they're scaled by
  /// [_capturePixelRatio] to match the rasterized image. Returns the original
  /// image untouched when there's nothing to mask.
  Future<ui.Image> _applyMasks(ui.Image image, List<Rect> maskRects) async {
    if (maskRects.isEmpty) return image;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImage(image, Offset.zero, Paint());
    final blackout = Paint()..color = const Color(0xFF000000);
    for (final r in maskRects) {
      canvas.drawRect(
        Rect.fromLTWH(
          r.left * _capturePixelRatio,
          r.top * _capturePixelRatio,
          r.width * _capturePixelRatio,
          r.height * _capturePixelRatio,
        ),
        blackout,
      );
    }
    final picture = recorder.endRecording();
    final out = await picture.toImage(image.width, image.height);
    picture.dispose();
    image.dispose(); // source no longer needed; caller disposes `out`
    return out;
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
                final raw = widget.data ?? widget.textSpan?.toPlainText();
                // Redact rendered text content when masking is on — the
                // wireframe is sold as privacy-focused but otherwise ships
                // visible text (balances, names, messages) verbatim. We keep
                // the length (as bullets) so layout/heatmap stay meaningful.
                if (_maskAllText && raw != null) {
                  value = '•' * raw.length;
                } else {
                  value = raw;
                }
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

    // 🚦 Cold-start screen guard — see `_captureFrame` above for the
    // rationale.  Without this, the very first taps of a session
    // would attribute to an empty/Unknown screen the dashboard can't
    // match against any real navigation.
    if (!Sankofa.instance.hasTaggedScreen) return;

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final x = event.position.dx;
    final yScreen = event.position.dy;

    // 🚫 Drop interactions whose coordinates are NaN/Infinity.  Flutter's
    // PointerEvent positions are normally finite but custom pointer
    // sources (third-party gesture frameworks, hot-reload edge cases)
    // can occasionally produce non-finite values that would otherwise
    // plot a phantom dot at the heatmap's origin.  Mirrors iOS I5.
    if (!x.isFinite || !yScreen.isFinite) return;

    // 🚀 Absolute Y = Screen position + Current Scroll Offset.
    // Used as the canonical Y for ALL event types so move samples line up
    // with the down/up rows the heatmap renders against.
    final absoluteY = yScreen + _currentScrollY;

    // ── (0) Maintain the active-pointer map for mobile pinch detection ────
    // Flutter surfaces each finger as a separate Down → Move → Up stream
    // keyed by `event.pointer`.  When two are active simultaneously the
    // move handler below emits a midpoint type-7 event instead of two
    // independent moves.
    if (type == 'pointer_down') {
      _activePointers[event.pointer] = event.position;
    } else if (type == 'pointer_up') {
      _activePointers.remove(event.pointer);
    } else if (type == 'pointer_move') {
      _activePointers[event.pointer] = event.position;
    }

    // ── (1) Down resets the move + double-tap trackers ────────────────────
    if (type == 'pointer_down') {
      _lastMoveSampleAtMs = 0;
      _lastMoveX = -9999;
      _lastMoveY = -9999;
    }

    // ── (2a) Two-finger pinch — REPLACES the regular move path ────────────
    // When two or more pointers are active the move event represents one
    // finger of a pinch gesture, not a swipe.  Emit a single midpoint
    // event per throttle window with rrweb type 7 (Pinch / Zoom) and
    // skip the regular pointer_move emit so the gesture never
    // double-records.  `onPointerPanZoomUpdate` further down keeps
    // covering the desktop / trackpad case.
    if (type == 'pointer_move' && _activePointers.length >= 2) {
      if (nowMs - _lastPinchAtMs < _moveThrottleInterval.inMilliseconds) {
        return;
      }
      _lastPinchAtMs = nowMs;
      final pts = _activePointers.values.take(2).toList();
      final midX = (pts[0].dx + pts[1].dx) / 2.0;
      final midY = (pts[0].dy + pts[1].dy) / 2.0;
      _eventBuffer.add({
        'type': 3,
        'timestamp': nowMs,
        'data': {
          'source': 2, // MouseInteraction
          'type': 7,   // rrweb Pinch / Zoom
          'id': 1,
          'x': midX,
          'y': midY + _currentScrollY,
        },
        'screen': Sankofa.instance.currentScreen,
        'time_offset_ms': DateTime.now()
            .difference(_chunkStartTime!)
            .inMilliseconds,
      });
      return;
    }

    // ── (2b) Throttle + coalesce single-pointer pointer_move ──────────────
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
