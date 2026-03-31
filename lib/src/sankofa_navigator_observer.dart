import 'package:flutter/widgets.dart';
import 'sankofa_client.dart';

/// A [NavigatorObserver] that automatically tracks screen changes in Flutter.
/// 
/// Add this to your [MaterialApp] to enable automatic Heatmap screen tagging:
/// ```dart
/// MaterialApp(
///   navigatorObservers: [SankofaNavigatorObserver()],
///   ...
/// )
/// ```
class SankofaNavigatorObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    _trackScreen(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    if (newRoute != null) _trackScreen(newRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    if (previousRoute != null) _trackScreen(previousRoute);
  }

  void _trackScreen(Route<dynamic> route) {
    final name = route.settings.name;
    if (name != null && name.isNotEmpty) {
      // 🚀 Manual Hook > Automatic Router Fallback
      // We call .screen() but the SDK will manage the 'isManual' state internally
      // (Currently the Flutter SDK .screen() always updates _currentScreen)
      Sankofa.instance.screen(name);
    }
  }
}
