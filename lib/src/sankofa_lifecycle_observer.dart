import 'package:flutter/widgets.dart';
import 'replay/sankofa_replay.dart';
import 'utils/logger.dart';

class SankofaLifecycleObserver with WidgetsBindingObserver {
  final SankofaLogger logger;
  final Future<void> Function(String eventName) track;
  final Future<void> Function() flush;
  final bool trackLifecycleEvents;
  final bool enableSessionReplay;

  SankofaLifecycleObserver({
    required this.logger,
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

    if (state == AppLifecycleState.resumed) {
      logger.log('🟢 App in Foreground');
      if (trackLifecycleEvents) {
        track('\$app_foregrounded');
      }
    } else if (state == AppLifecycleState.paused) {
      logger.log('🔴 App in Background - Forcing Emergency Flush');
      if (trackLifecycleEvents) {
        track('\$app_backgrounded').then((_) => flush());
      } else {
        flush();
      }
    }
  }
}
