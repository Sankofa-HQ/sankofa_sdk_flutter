import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

/// Dedicated heatmap-background capture for the Flutter SDK.
///
/// ## Why this exists
/// The replay recorder captures a frame on a fixed cadence using the
/// shared `rootBoundaryKey`. Those frames are great for playback but
/// the FIRST frame after a screen transition often catches the
/// widget tree mid-build: images fetched via `Image.network` haven't
/// finished, animations are mid-curve, async `FutureBuilder`s show
/// loading states. The backend was permanently keeping those partial
/// frames as the heatmap background, leaving heat dots floating over
/// a half-rendered UI.
///
/// This snapshotter fires ONCE per `(screen, app_version, viewport
/// bucket)` per process lifetime, AFTER a settle delay measured from
/// the last `Sankofa.instance.screen(...)` call, and uploads directly
/// to `/api/heatmaps/snapshot` (capture_source = 'dedicated' on the
/// server, which out-ranks any replay-derived row).
///
/// ## Performance contract
/// - Scheduling: a single `Timer` per screen tag, cancellable. No tick
///   loops, no polling.
/// - `RepaintBoundary.toImage()` runs the rasterization on Flutter's
///   raster (GPU) thread, not the UI thread, so the host frame budget
///   is unaffected.
/// - PNG encoding (`image.toByteData(format: png)`) is also async and
///   runs off the UI isolate.
/// - One capture per screen-bucket per session — repeated `screen()`
///   calls on the same view are dropped at the dedupe check, NOT at
///   the encode/upload stages.
/// - Cancellable: navigating to a new screen during the settle delay
///   discards the pending capture.
class SankofaHeatmapSnapshotter {
  SankofaHeatmapSnapshotter({
    required this.boundaryKey,
    required this.endpoint,
    required this.apiKey,
    required this.appVersion,
    void Function(String message)? debug,
  }) : _debug = debug;

  /// Reuses `SankofaReplay.instance.rootBoundaryKey` so the host only
  /// has to wrap their app with one `RepaintBoundary` for both replay
  /// and heatmap.
  final GlobalKey boundaryKey;
  final String endpoint;
  final String apiKey;
  final String appVersion;
  final void Function(String)? _debug;

  /// 1.5s settle delay — keeps the SDK consistent across iOS / Android /
  /// Web / Flutter. Long enough for most `Image.network` loads, short
  /// enough that the user is unlikely to have navigated away.
  static const Duration _stabilityDelay = Duration(milliseconds: 1500);

  final Set<String> _captured = <String>{};
  Timer? _pendingTimer;
  String? _pendingScreen;

  /// Called from `SankofaClient.screen(...)` and the navigator
  /// observer. Returns immediately. No raster / encode / upload work
  /// happens on this code path — it just enqueues a delayed task.
  void scheduleCapture(String screen) {
    if (screen.isEmpty) return;
    // Supersede any pending capture for an older screen tag — a fast
    // navigation flurry shouldn't produce a backlog of upload jobs.
    _pendingTimer?.cancel();
    _pendingScreen = screen;
    _pendingTimer = Timer(_stabilityDelay, () => _runCaptureIfNeeded(screen));
  }

  Future<void> _runCaptureIfNeeded(String screen) async {
    // If a newer tag arrived after we were scheduled, the timer would
    // have been replaced — but we also defend in depth here.
    if (_pendingScreen != screen) return;

    final BuildContext? ctx = boundaryKey.currentContext;
    if (ctx == null) return;
    final RenderObject? renderObject = ctx.findRenderObject();
    if (renderObject is! RenderRepaintBoundary) return;
    final RenderRepaintBoundary boundary = renderObject;

    // Wait an extra frame if the boundary still needs paint — same
    // self-defense the replay recorder uses for the same race.
    if (boundary.debugNeedsPaint) {
      await Future<void>.delayed(const Duration(milliseconds: 80));
      if (boundary.debugNeedsPaint) {
        // Still painting — bail; the next screen() call or session
        // retries naturally.
        return;
      }
    }

    final size = boundary.size;
    final int widthPx = (size.width * 1.0).round();
    final int heightPx = (size.height * 1.0).round();
    if (widthPx <= 0 || heightPx <= 0) return;

    final String fingerprint =
        '$screen|$appVersion|${widthPx ~/ 60}x${heightPx ~/ 60}';
    if (_captured.contains(fingerprint)) return;
    _captured.add(fingerprint);

    try {
      // pixelRatio 1.0 keeps the snapshot at logical pixels so the
      // dashboard's heatmap renderer (which works in logical/CSS-px
      // coordinates) lines up exactly with interaction coordinates.
      // Higher ratios produce sharper backdrops but inflate the
      // base64 payload disproportionately.
      final ui.Image image = await boundary.toImage(pixelRatio: 1.0);
      try {
        final ByteData? byteData =
            await image.toByteData(format: ui.ImageByteFormat.png);
        if (byteData == null) return;
        final Uint8List bytes = byteData.buffer.asUint8List();
        await _upload(screen, widthPx, heightPx, bytes);
      } finally {
        image.dispose();
      }
    } catch (e) {
      _debug?.call('Heatmap snapshot failed for $screen: $e');
    }
  }

  Future<void> _upload(
    String screen,
    int widthPx,
    int heightPx,
    Uint8List bytes,
  ) async {
    if (endpoint.isEmpty || apiKey.isEmpty) return;
    final String base =
        endpoint.endsWith('/') ? endpoint.substring(0, endpoint.length - 1) : endpoint;
    final Uri uri = Uri.parse('$base/api/heatmaps/snapshot');

    final body = <String, dynamic>{
      'screen_name': screen,
      'app_version': appVersion,
      'os': _platformName(),
      'device_width': widthPx,
      'device_height': heightPx,
      'scroll_offset_y': 0,
      'image_base64': base64Encode(bytes),
    };

    try {
      final response = await http.post(
        uri,
        headers: <String, String>{
          'Content-Type': 'application/json',
          'x-api-key': apiKey,
        },
        body: jsonEncode(body),
      );
      if (response.statusCode >= 400) {
        _debug?.call(
          'Heatmap snapshot rejected (${response.statusCode}) for $screen',
        );
      } else {
        _debug?.call('📸 Heatmap snapshot accepted for $screen');
      }
    } catch (e) {
      _debug?.call('Heatmap snapshot upload threw for $screen: $e');
    }
  }

  String _platformName() {
    // Flutter runs on iOS, Android, web, desktop. We only emit the
    // mobile / web buckets the dashboard's `os` filter knows about.
    // Avoids importing `dart:io` so this file also compiles on web.
    try {
      if (identical(0, 0.0)) {
        // dart2js / web — JS division of int returns double.
        return 'web';
      }
    } catch (_) {}
    // Fall back to 'flutter' which the backend treats as a generic
    // mobile bucket. Hosts that want explicit iOS/Android attribution
    // can pass it via app_version or future config.
    return 'flutter';
  }

  /// Cancels any pending delayed capture. Call from
  /// `SankofaClient.shutdown()` to avoid a stray timer firing after
  /// the engine has begun tearing down.
  void dispose() {
    _pendingTimer?.cancel();
    _pendingTimer = null;
    _pendingScreen = null;
  }
}
