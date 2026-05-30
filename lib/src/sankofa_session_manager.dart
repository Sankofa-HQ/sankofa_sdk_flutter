import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'sankofa_constants.dart';
import 'utils/logger.dart';

class SankofaSessionManager {
  static const kLastBackgroundTimeKey = 'dev.sankofa.last_background_time';
  
  final SankofaLogger logger;
  final Future<void> Function() onNewSession;
  String? _sessionId;

  SankofaSessionManager({required this.logger, required this.onNewSession});

  String? get sessionId => _sessionId;

  static const int _timeoutMs = kSessionTimeoutMinutes * 60 * 1000;

  Future<void> refresh() async {
    final prefs = await SharedPreferences.getInstance();
    _sessionId = prefs.getString(kSessionIdKey);

    if (_sessionId == null) {
      await startNewSession();
      return;
    }

    // Cold-start timeout: if the app was last backgrounded longer than the
    // session timeout ago, the persisted session is stale. Rotate instead of
    // reusing it — otherwise a session can span days across kill/relaunch and
    // corrupt every session-scoped metric. (Previously the timeout was only
    // enforced on a warm resume, never on a cold launch.)
    final lastBackground = prefs.getInt(kLastBackgroundTimeKey) ?? 0;
    if (lastBackground != 0 &&
        DateTime.now().millisecondsSinceEpoch - lastBackground > _timeoutMs) {
      logger.log('⌛ Cold start after long background — rotating stale session');
      await startNewSession();
      await prefs.remove(kLastBackgroundTimeKey);
      return;
    }

    await onNewSession();
  }

  /// Called when the app is resumed.
  /// If the app has been in the background longer than the session timeout,
  /// we rotate the session and return true.
  Future<bool> checkRotationOnResume() async {
    final prefs = await SharedPreferences.getInstance();
    final lastBackground = prefs.getInt(kLastBackgroundTimeKey) ?? 0;

    if (lastBackground == 0) return false;

    final elapsed = DateTime.now().millisecondsSinceEpoch - lastBackground;
    if (elapsed > _timeoutMs) {
      logger.log('⌛ Session timed out after ${elapsed ~/ 60000} minutes. Rotating.');
      await startNewSession();
      await prefs.remove(kLastBackgroundTimeKey);
      return true;
    }

    return false;
  }

  /// Called when the app moves to the background.
  Future<void> setLastBackgroundTime() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      kLastBackgroundTimeKey,
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<void> startNewSession() async {
    final prefs = await SharedPreferences.getInstance();
    _sessionId = 's_${const Uuid().v4()}';
    await prefs.setString(kSessionIdKey, _sessionId!);
    logger.log('🆕 New Session Started: $_sessionId');
    await onNewSession();
  }
}
