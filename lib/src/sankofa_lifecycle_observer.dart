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

  // Serialize lifecycle handlers so a rapid background→foreground bounce
  // (lock screen, app-switcher peek) can't interleave _handleBackground
  // (writes last_background_time) with _handleResume (reads it) and produce
  // spurious or missed session rotations.
  Future<void> _chain = Future.value();
  void _enqueue(Future<void> Function() op) {
    _chain = _chain.then((_) => op()).catchError((_) {});
  }

  void _handleAppLifecycleStateChanged(AppLifecycleState state) {
    logger.log('📱 AppLifecycleState: $state');

    switch (state) {
      case AppLifecycleState.resumed:
        _enqueue(_handleResume);
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        // The canonical "really backgrounded" states. NOT `inactive`, which
        // on iOS fires transiently for control center / a call banner / the
        // app-switcher peek — treating it as background inflated
        // $app_backgrounded and stamped bogus background times that drove
        // false 30-min rotations.
        _enqueue(_handleBackground);
        break;
      case AppLifecycleState.inactive:
        break; // transient — ignore
      case AppLifecycleState.detached:
        _enqueue(() async {
          if (trackLifecycleEvents) await track('\$app_terminated');
          await flush();
        });
        break;
    }
  }

  Future<void> _handleResume() async {
    final rotated = await sessionManager.checkRotationOnResume();
    if (rotated) {
      await track('\$session_start');
    }

    if (trackLifecycleEvents) {
      logger.log('🟢 App in Foreground');
      await track('\$app_foregrounded');
    }
  }

  Future<void> _handleBackground() async {
    await sessionManager.setLastBackgroundTime();

    if (trackLifecycleEvents) {
      logger.log('🔴 App in Background - Forcing Emergency Flush');
      await track('\$app_backgrounded');
    }
    await flush();
  }
}
