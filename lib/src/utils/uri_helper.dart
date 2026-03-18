class UriHelper {
  static Uri resolveServerBaseUri(String endpoint) {
    final v1BaseUri = resolveV1BaseUri(endpoint);
    final trimmedSegments = v1BaseUri.pathSegments
        .where((segment) => segment.isNotEmpty)
        .toList();

    if (_endsWithSegments(trimmedSegments, const ['api', 'v1'])) {
      return _replacePathSegments(
        v1BaseUri,
        trimmedSegments.sublist(0, trimmedSegments.length - 2),
      );
    }

    return v1BaseUri;
  }

  static Uri resolveV1BaseUri(String endpoint) {
    final uri = Uri.parse(endpoint.trim());
    final segments = uri.pathSegments
        .where((segment) => segment.isNotEmpty)
        .toList();

    if (_endsWithSegments(segments, const ['api', 'v1', 'track'])) {
      return _replacePathSegments(
        uri,
        segments.sublist(0, segments.length - 1),
      );
    }

    if (_endsWithSegments(segments, const ['api', 'v1'])) {
      return _replacePathSegments(uri, segments);
    }

    if (_endsWithSegments(segments, const ['v1', 'track'])) {
      return _replacePathSegments(uri, [
        ...segments.sublist(0, segments.length - 2),
        'api',
        'v1',
      ]);
    }

    if (_endsWithSegments(segments, const ['v1'])) {
      return _replacePathSegments(uri, [
        ...segments.sublist(0, segments.length - 1),
        'api',
        'v1',
      ]);
    }

    return _replacePathSegments(uri, [...segments, 'api', 'v1']);
  }

  static Uri resolveTrackUri(String endpoint) {
    final v1BaseUri = resolveV1BaseUri(endpoint);
    return appendPath(v1BaseUri, const ['track']);
  }

  static Uri appendPath(Uri uri, List<String> segments) {
    final pathSegments = uri.pathSegments
        .where((segment) => segment.isNotEmpty)
        .toList();
    return _replacePathSegments(uri, [...pathSegments, ...segments]);
  }

  static Uri _replacePathSegments(Uri uri, List<String> segments) {
    return uri.replace(pathSegments: segments);
  }

  static bool _endsWithSegments(List<String> actual, List<String> suffix) {
    if (actual.length < suffix.length) return false;
    for (var index = 0; index < suffix.length; index++) {
      if (actual[actual.length - suffix.length + index] != suffix[index]) {
        return false;
      }
    }
    return true;
  }
}
