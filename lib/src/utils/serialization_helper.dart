class SerializationHelper {
  /// Convert host-supplied properties into a JSON-safe map that PRESERVES
  /// native types. Numbers stay numbers, bools stay bools, nested maps/lists
  /// are kept as real JSON — so the backend can do numeric aggregation and
  /// boolean faceting. Previously every scalar was stringified
  /// (`42` → `"42"`, `true` → `"true"`), which silently broke all downstream
  /// numeric/boolean analytics. Only genuinely non-encodable values fall back
  /// to `toString()`.
  static Map<String, dynamic> serializeTransportProperties(
    Map<String, dynamic> properties,
  ) {
    return properties.map(
      (key, value) => MapEntry(key, _toEncodableJson(value)),
    );
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
