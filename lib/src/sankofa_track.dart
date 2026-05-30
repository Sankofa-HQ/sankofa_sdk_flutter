import 'package:uuid/uuid.dart';
import 'sankofa_constants.dart';
import 'utils/serialization_helper.dart';

class SankofaTrack {
  static Map<String, dynamic> createEvent({
    required String eventName,
    required String distinctId,
    required String sessionId,
    required Map<String, String> defaultProperties,
    Map<String, dynamic>? properties,
  }) {
    final serializedProperties = properties == null
        ? const <String, dynamic>{}
        : SerializationHelper.serializeTransportProperties(properties);

    return {
      'type': 'track',
      'event_name': eventName,
      'distinct_id': distinctId,
      'properties': {
        r'$event_name': eventName,
        r'$session_id': sessionId,
        ...serializedProperties,
      },
      'default_properties': defaultProperties,
      // Keep millisecond precision so events fired in the same second keep a
      // stable order instead of colliding on an identical timestamp.
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'lib_version': kLibVersion,
      'id': const Uuid().v4(),
    };
  }
}
