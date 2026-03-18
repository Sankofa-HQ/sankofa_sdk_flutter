import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'sankofa_replay_client.dart';

/// A widget that defines the visual boundary for session replay recording.
///
/// This should typically wrap your [MaterialApp] or the root of your application
/// to enable session capture and gesture tracking.
class SankofaReplayBoundary extends StatelessWidget {
  /// The widget below this boundary in the tree.
  final Widget child;

  /// Creates a replay boundary.
  const SankofaReplayBoundary({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    try {
      final view = ui.PlatformDispatcher.instance.views.first;
      SankofaReplay.instance.updateDeviceContext(
        view.physicalSize.width / view.devicePixelRatio,
        view.physicalSize.height / view.devicePixelRatio,
        view.devicePixelRatio,
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('⚠️ SankofaReplay: Could not load screen dimensions');
      }
    }

    return RepaintBoundary(
      key: SankofaReplay.instance.rootBoundaryKey,
      child: NotificationListener<ScrollNotification>(
        onNotification: (ScrollNotification scrollInfo) {
          if (scrollInfo.depth == 0) {
            SankofaReplay.instance.recordScrollEvent(
              scrollInfo.metrics.pixels,
            );
          }
          return false;
        },
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (e) =>
              SankofaReplay.instance.recordPointerEvent('pointer_down', e),
          onPointerMove: (e) =>
              SankofaReplay.instance.recordPointerEvent('pointer_move', e),
          onPointerUp: (e) =>
              SankofaReplay.instance.recordPointerEvent('pointer_up', e),
          child: child,
        ),
      ),
    );
  }
}

/// A [NavigatorObserver] that automatically tracks screen changes for Sankofa Analytics.
///
/// Add this to your [MaterialApp.navigatorObservers] to enable automatic
/// page view tracking and route-based session replay events.
class SankofaNavigatorObserver extends RouteObserver<PageRoute<dynamic>> {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    if (route.settings.name != null) {
      SankofaReplay.instance.recordRouteEvent(route.settings.name!);
    }
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    if (newRoute?.settings.name != null) {
      SankofaReplay.instance.recordRouteEvent(newRoute!.settings.name!);
    }
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    if (previousRoute?.settings.name != null) {
      SankofaReplay.instance.recordRouteEvent(previousRoute!.settings.name!);
    }
  }
}
