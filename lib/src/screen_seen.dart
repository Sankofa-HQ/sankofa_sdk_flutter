import 'dart:convert';
import 'package:http/http.dart' as http;

/// Canonical screen-seen emitter — fire-and-forget POST to
/// `/api/v1/screens/seen`. Mirrors the web / RN / iOS / Android
/// implementations: every `Sankofa.instance.screen('Identify')` call
/// (and every `SankofaNavigatorObserver` route change) hits this so
/// the lexicon + dwell + presence get populated regardless of which
/// Sankofa products the host has enabled.
///
/// Best-effort by design — failures are silent. The server endpoint
/// is idempotent + TTL-based for presence, so a missed call self-heals
/// on the next call.
Future<void> emitScreenSeen({
  required String endpoint,
  required String apiKey,
  required String screen,
  required String distinctId,
  String? sessionId,
  Map<String, dynamic>? properties,
}) async {
  if (screen.isEmpty || distinctId.isEmpty) return;
  if (endpoint.isEmpty || apiKey.isEmpty) return;

  final base = endpoint.endsWith('/')
      ? endpoint.substring(0, endpoint.length - 1)
      : endpoint;
  final uri = Uri.parse('$base/api/v1/screens/seen');

  final body = <String, dynamic>{
    'screen': screen,
    'distinct_id': distinctId,
    'ts_ms': DateTime.now().millisecondsSinceEpoch,
  };
  if (sessionId != null && sessionId.isNotEmpty) {
    body['session_id'] = sessionId;
  }
  if (properties != null && properties.isNotEmpty) {
    body['properties'] = properties;
  }

  try {
    await http.post(
      uri,
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': apiKey,
      },
      body: jsonEncode(body),
    );
  } catch (_) {
    // Decorative — never throw.
  }
}
