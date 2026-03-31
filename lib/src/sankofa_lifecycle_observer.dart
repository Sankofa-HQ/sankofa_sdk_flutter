import 'dart:ui';
import 'package:flutter/widgets.dart';
import 'replay/sankofa_replay.dart';
import 'utils/logger.dart';
import 'sankofa_session_manager.dart';

class SankofaLifecycleObserver with WidgetsBindingObserver {
  final SankofaLogger logger;
  final SankofaSessionManager sessionManager;
  final Future<void> Function(String eventName) track;
  final Future<void> Function() flush;
  final bool trackLifecycleEvents;
  final bool enableSessionReplay;

  SankofaLifecycleObserver({
    required this.logger,
    required this.sessionManager,
    required this.track,
    required this.flush,
    required this.trackLifecycleEvents,
    required this.enableSessionReplay,
  });

  void init() {
    WidgetsBinding.instance.addObserver(this);
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (enableSessionReplay) {
      SankofaReplay.instance.onAppLifecycleStateChanged(state);
    }
    _handleAppLifecycleStateChanged(state);
  }

  void _handleAppLifecycleStateChanged(AppLifecycleState state) {
    logger.log('📱 AppLifecycleState: $state');

    switch (state) {
      case AppLifecycleState.resumed:
        _handleResume();
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        _handleBackground();
        break;
      case AppLifecycleState.paused:
        break;
      case AppLifecycleState.detached:
        if (trackLifecycleEvents) track('\$app_terminated');
        flush();
        break;
    }
  }

  void _handleResume() async {
    final rotated = await sessionManager.checkRotationOnResume();
    if (rotated) {
      await track('\$session_start');
    }

    if (trackLifecycleEvents) {
      logger.log('🟢 App in Foreground');
      await track('\$app_foregrounded');
    }
  }

  void _handleBackground() async {
    await sessionManager.setLastBackgroundTime();

    if (trackLifecycleEvents) {
      logger.log('🔴 App in Background - Forcing Emergency Flush');
      await track('\$app_backgrounded');
    }
    await flush();
  }
}
