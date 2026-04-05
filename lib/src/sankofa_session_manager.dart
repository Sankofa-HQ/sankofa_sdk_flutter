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

  Future<void> refresh() async {
    final prefs = await SharedPreferences.getInstance();
    _sessionId = prefs.getString(kSessionIdKey);

    if (_sessionId == null) {
      await startNewSession();
    } else {
      await onNewSession();
    }
  }

  /// Called when the app is resumed.
  /// If the app has been in the background for more than 30 minutes, 
  /// we rotate the session and return true.
  Future<bool> checkRotationOnResume() async {
    final prefs = await SharedPreferences.getInstance();
    final lastBackground = prefs.getInt(kLastBackgroundTimeKey) ?? 0;
    
    if (lastBackground == 0) return false;

    final now = DateTime.now().millisecondsSinceEpoch;
    final elapsed = now - lastBackground;
    const thirtyMinutes = 30 * 60 * 1000;

    if (elapsed > thirtyMinutes) {
      logger.log('⌛ Session timed out after ${elapsed / 60000} minutes. Rotating.');
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
