import 'dart:convert';

class SerializationHelper {
  static Map<String, String> serializeTransportProperties(
    Map<String, dynamic> properties,
  ) {
    return properties.map(
      (key, value) => MapEntry(key, _serializeTransportValue(value)),
    );
  }

  static String _serializeTransportValue(dynamic value) {
    if (value == null) return 'null';
    if (value is String) return value;
    if (value is num || value is bool) return value.toString();
    if (value is DateTime) return value.toIso8601String();
    if (value is Iterable || value is Map) {
      return jsonEncode(_toEncodableJson(value));
    }
    return value.toString();
  }

  static dynamic _toEncodableJson(dynamic value) {
    if (value == null || value is String || value is num || value is bool) {
      return value;
    }
    if (value is DateTime) return value.toIso8601String();
    if (value is Iterable) {
      return value.map(_toEncodableJson).toList();
    }
    if (value is Map) {
      return value.map(
        (key, nestedValue) =>
            MapEntry(key.toString(), _toEncodableJson(nestedValue)),
      );
    }
    return value.toString();
  }
}
