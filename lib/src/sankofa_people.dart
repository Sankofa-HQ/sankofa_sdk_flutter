import 'package:uuid/uuid.dart';
import 'utils/serialization_helper.dart';

class SankofaPeople {
  static Map<String, dynamic> createProfileEvent({
    required String distinctId,
    required String sessionId,
    required Map<String, dynamic> properties,
  }) {
    return {
      'type': 'people',
      'distinct_id': distinctId,
      'properties': {
        r'$session_id': sessionId,
        ...SerializationHelper.serializeTransportProperties(properties),
      },
      'timestamp': DateTime.now().toIso8601String(),
      'message_id': const Uuid().v4(),
    };
  }

  static Map<String, dynamic> getPersonProperties({
    String? name,
    String? email,
    String? avatar,
    Map<String, dynamic>? properties,
  }) {
    final Map<String, dynamic> traits = {...(properties ?? {})};
    if (name != null) traits[r'$name'] = name;
    if (email != null) traits[r'$email'] = email;
    if (avatar != null) traits[r'$avatar'] = avatar;
    return traits;
  }
}
