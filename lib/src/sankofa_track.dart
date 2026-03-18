import 'package:uuid/uuid.dart';
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
        ? const <String, String>{}
        : SerializationHelper.serializeTransportProperties(properties);

    return {
      'type': 'track',
      'event_name': eventName,
      'distinct_id': distinctId,
      'properties': {
        '\$session_id': sessionId,
        ...serializedProperties,
      },
      'default_properties': defaultProperties,
      'timestamp': DateTime.now().toIso8601String(),
      'lib_version': 'flutter-0.1.0',
      'message_id': const Uuid().v4(),
    };
  }
}
