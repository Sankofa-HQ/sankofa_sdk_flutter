import 'package:uuid/uuid.dart';
import 'sankofa_constants.dart';
import 'utils/serialization_helper.dart';

class SankofaPeople {
  static Map<String, dynamic> createProfileEvent({
    required String distinctId,
    required String sessionId,
    required Map<String, dynamic> properties,
    Map<String, String> defaultProperties = const {},
  }) {
    return {
      'type': 'people',
      'distinct_id': distinctId,
      'properties': {
        r'$session_id': sessionId,
        ...SerializationHelper.serializeTransportProperties(properties),
      },
      'default_properties': defaultProperties,
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'lib_version': kLibVersion,
      'id': const Uuid().v4(),
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
