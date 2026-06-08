import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// A widget that masks its child from being captured in session replays.
///
/// Use this to protect sensitive information like passwords, balances, or
/// personal data. The child renders unchanged in the live UI; the
/// recorder finds [SankofaMask] subtrees during its pre-capture walk and
/// overpaints the corresponding bitmap regions with solid black on a
/// composited copy ([SankofaReplayRecorder._applyMasks]).
///
/// Why this widget does NOT paint black in the live tree:
///
/// An earlier version branched `paint()` on
/// `SankofaReplay.instance.isCapturingFrame` and drew solid black during
/// capture. That produced two real customer bugs:
///
///   1. **Blinking masks.** The `isCapturingFrame` flag flips true for
///      the duration of an async `toImage()` round-trip (often 50–200ms).
///      Flutter's render pipeline doesn't know the paint result depends
///      on that flag, so it doesn't reliably repaint when the flag
///      changes — but unrelated repaints (scroll, animations, route
///      transitions) DO observe the flag and paint black, creating a
///      flicker on every screenshot.
///   2. **Wasted work.** The recorder masks the rasterized bitmap
///      off-screen anyway. Painting black in the live tree as well is
///      a second pass over the same pixels, on the hot UI thread, with
///      no privacy benefit (the bitmap is what leaves the device).
///
/// So this widget is now a transparent passthrough. The recorder
/// remains responsible for masking; the widget just marks the region.
class SankofaMask extends SingleChildRenderObjectWidget {
  /// Creates a mask for session replay.
  const SankofaMask({super.key, required Widget child}) : super(child: child);

  @override
  RenderObject createRenderObject(BuildContext context) {
    return SankofaMaskRenderObject();
  }
}

/// Marker render object. Lets the recorder's `_collectMaskRects` walk
/// recognize this subtree (`element.widget is SankofaMask`) without any
/// paint-time branching.
class SankofaMaskRenderObject extends RenderProxyBox {
  // Intentionally empty — `RenderProxyBox`'s default `paint` passes the
  // child through unchanged. Masking happens off-screen on the captured
  // bitmap; nothing for the live tree to do.
}

/// Marks its subtree as off-limits for session replay capture.
///
/// Wrap your video player, map view, camera preview, or other widget
/// whose underlying render object holds a platform-managed external
/// texture / platform view with this widget. The replay recorder's
/// pre-capture walk recognises the marker and either skips the frame
/// entirely (when an external texture is detected outside any
/// suppress region) or — in a future refinement — bails only on the
/// suppressed subtree while still capturing the rest of the screen.
///
/// Why this is necessary on Android: `RepaintBoundary.toImage()` on
/// Impeller-backed engines can invalidate the external texture handle
/// a media decoder is writing into. The first sign is "Invalid
/// external texture" log spam from Flutter's Android renderer, and the
/// second is the surrounding scrollable repainting in a way the host
/// app may react to (e.g. resetting scroll offset to top).
///
/// Use:
///
/// ```dart
/// SankofaReplaySuppress(
///   child: BetterPlayer(controller: _controller),
/// )
/// ```
class SankofaReplaySuppress extends StatelessWidget {
  /// The widget below this marker in the tree.
  final Widget child;

  /// Creates a replay-capture suppression region.
  const SankofaReplaySuppress({super.key, required this.child});

  @override
  Widget build(BuildContext context) => child;
}
