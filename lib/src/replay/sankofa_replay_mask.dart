import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'sankofa_replay_client.dart';

class SankofaMask extends SingleChildRenderObjectWidget {
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
