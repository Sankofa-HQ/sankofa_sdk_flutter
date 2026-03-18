import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'sankofa_replay_client.dart';

/// A widget that masks its child from being captured in session replays.
///
/// Use this to protect sensitive information like passwords or personal data.
/// The child will be replaced by a solid black box in the recording.
class SankofaMask extends SingleChildRenderObjectWidget {
  /// Creates a mask for session replay.
  const SankofaMask({super.key, required Widget child}) : super(child: child);

  @override
  RenderObject createRenderObject(BuildContext context) {
    return SankofaMaskRenderObject();
  }
}

class SankofaMaskRenderObject extends RenderProxyBox {
  @override
  void paint(PaintingContext context, Offset offset) {
    if (SankofaReplay.instance.isCapturingFrame) {
      final paint = Paint()..color = const Color(0xFF000000);
      context.canvas.drawRect(offset & size, paint);
    } else {
      child?.paint(context, offset);
    }
  }
}
