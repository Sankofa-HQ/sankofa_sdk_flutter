import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'sankofa_constants.dart';
import 'utils/logger.dart';

class SankofaIdentity {
  final SankofaLogger logger;
  String? _userId;
  String? _anonymousId;

  SankofaIdentity({required this.logger});

  String? get userId => _userId;
  String? get anonymousId => _anonymousId;
  String get distinctId => _userId ?? _anonymousId ?? 'anonymous';

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _anonymousId = prefs.getString(kAnonIdKey);
    if (_anonymousId == null) {
      _anonymousId = const Uuid().v4();
      await prefs.setString(kAnonIdKey, _anonymousId!);
    }
    _userId = prefs.getString(kUserIdKey);
  }

  Future<void> identify(String userId, String sessionId, Future<void> Function(Map<String, dynamic> aliasEvent) onAlias) async {
    if (_userId == userId) return;

    final previousId = distinctId;
    _userId = userId;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kUserIdKey, userId);

    if (previousId != userId) {
      final aliasEvent = {
        'type': 'alias',
        'alias_id': previousId,
        'distinct_id': userId,
        'properties': {
          r'$session_id': sessionId,
        },
        'timestamp': '${DateTime.now().toUtc().toIso8601String().split('.')[0]}Z',
        'id': const Uuid().v4(),
      };
      await onAlias(aliasEvent);
      logger.log('🔗 Identify: Aliasing $previousId -> $userId');
    }
  }

  Future<void> reset() async {
    _userId = null;
    _anonymousId = const Uuid().v4();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(kUserIdKey);
    await prefs.setString(kAnonIdKey, _anonymousId!);
    logger.log('🔄 Identity Reset: New AnonID $_anonymousId');
  }
}
