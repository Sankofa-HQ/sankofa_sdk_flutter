import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'sankofa_constants.dart';
import 'utils/logger.dart';

class SankofaSessionManager {
  final SankofaLogger logger;
  final Future<void> Function() onNewSession;
  String? _sessionId;

  SankofaSessionManager({required this.logger, required this.onNewSession});

  String? get sessionId => _sessionId;

  Future<void> refresh() async {
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now().millisecondsSinceEpoch;

    _sessionId = prefs.getString(kSessionIdKey);
    final lastEventTime = prefs.getInt(kLastEventTimeKey) ?? 0;

    if (_sessionId == null ||
        (now - lastEventTime) > (kSessionTimeoutMinutes * 60 * 1000)) {
      _sessionId = const Uuid().v4();
      await prefs.setString(kSessionIdKey, _sessionId!);
      logger.log('🆕 New Session Started: $_sessionId');
      await onNewSession();
    }

    await prefs.setInt(kLastEventTimeKey, now);
  }

  Future<void> startNewSession() async {
    final prefs = await SharedPreferences.getInstance();
    _sessionId = const Uuid().v4();
    await prefs.setString(kSessionIdKey, _sessionId!);
    await prefs.setInt(
      kLastEventTimeKey,
      DateTime.now().millisecondsSinceEpoch,
    );
    logger.log('🔄 Session Reset: $_sessionId');
    await onNewSession();
  }
}
