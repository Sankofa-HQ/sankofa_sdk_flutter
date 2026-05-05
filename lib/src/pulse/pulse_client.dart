import 'dart:convert';

import 'package:http/http.dart' as http;

import 'pulse_models.dart';

/// Pulse REST client. Six endpoints:
///
///   - GET    /api/pulse/handshake          → lightweight survey list
///   - GET    /api/pulse/surveys/:survey_id → full bundle
///   - POST   /api/pulse/responses          → final submit
///   - POST   /api/pulse/partial            → save in-progress state
///   - GET    /api/pulse/partial            → load in-progress state
///   - DELETE /api/pulse/partial            → clear in-progress state
///
/// Authenticated via `x-api-key`. The Flutter renderer + queue
/// serialise calls themselves, so the client is intentionally
/// stateless — each call opens a fresh request.
class PulseClient {
  final String endpoint;
  final String apiKey;
  final http.Client _http;
  final Duration timeout;

  PulseClient({
    required this.endpoint,
    required this.apiKey,
    http.Client? client,
    this.timeout = const Duration(seconds: 15),
  }) : _http = client ?? http.Client();

  String get _base => endpoint.endsWith('/')
      ? endpoint.substring(0, endpoint.length - 1)
      : endpoint;

  Future<PulseHandshakeResponse> handshake() async {
    final uri = Uri.parse('$_base/api/pulse/handshake?installed=pulse');
    final res = await _http
        .get(uri, headers: _headers())
        .timeout(timeout);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw PulseHttpException(res.statusCode, res.body);
    }
    final body = res.body;
    if (body.isEmpty) return const PulseHandshakeResponse();
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) return const PulseHandshakeResponse();
    return PulseHandshakeResponse.fromJson(decoded);
  }

  /// List every published survey the API key's project owns. Each
  /// summary carries the targeting rules so callers can run local
  /// eligibility evaluation without per-survey round-trips. Powers
  /// `getActiveMatchingSurveys()`. Returns an empty list on 404 so
  /// older engines without this endpoint don't break the SDK.
  Future<List<PulseSurveySummary>> listSurveys() async {
    final uri = Uri.parse('$_base/api/pulse/surveys');
    final res = await _http.get(uri, headers: _headers()).timeout(timeout);
    if (res.statusCode == 404) return const [];
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw PulseHttpException(res.statusCode, res.body);
    }
    if (res.body.isEmpty) return const [];
    final decoded = jsonDecode(res.body);
    final raw = decoded is Map<String, dynamic>
        ? (decoded['surveys'] as List?) ?? const []
        : decoded is List
            ? decoded
            : const [];
    return raw
        .whereType<Map<String, dynamic>>()
        .map(PulseSurveySummary.fromJson)
        .toList(growable: false);
  }

  /// Load the full survey bundle (survey row + targeting rules) for
  /// one survey. The SDK calls this right before presenting so it
  /// can run the targeting evaluator locally and skip the show if
  /// the respondent isn't eligible.
  Future<PulseSurveyBundle> loadSurveyBundle(String surveyId) async {
    final uri = Uri.parse('$_base/api/pulse/surveys/$surveyId');
    final res = await _http.get(uri, headers: _headers()).timeout(timeout);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw PulseHttpException(res.statusCode, res.body);
    }
    if (res.body.isEmpty) return const PulseSurveyBundle();
    final decoded = jsonDecode(res.body);
    if (decoded is! Map<String, dynamic>) return const PulseSurveyBundle();
    return PulseSurveyBundle.fromJson(decoded);
  }

  Future<PulseSubmitResponse> submit(PulseSubmitPayload payload) async {
    final uri = Uri.parse('$_base/api/pulse/responses');
    final res = await _http
        .post(
          uri,
          headers: {
            ..._headers(),
            'Content-Type': 'application/json',
          },
          body: jsonEncode(payload.toJson()),
        )
        .timeout(timeout);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw PulseHttpException(res.statusCode, res.body);
    }
    if (res.body.isEmpty) return const PulseSubmitResponse();
    final decoded = jsonDecode(res.body);
    if (decoded is! Map<String, dynamic>) return const PulseSubmitResponse();
    return PulseSubmitResponse.fromJson(decoded);
  }

  /// Upsert the in-progress partial for (survey_id, external_id).
  Future<PulsePartialAck> savePartial(PulsePartialUpsert payload) async {
    final uri = Uri.parse('$_base/api/pulse/partial');
    final res = await _http
        .post(
          uri,
          headers: {
            ..._headers(),
            'Content-Type': 'application/json',
          },
          body: jsonEncode(payload.toJson()),
        )
        .timeout(timeout);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw PulseHttpException(res.statusCode, res.body);
    }
    if (res.body.isEmpty) return const PulsePartialAck();
    final decoded = jsonDecode(res.body);
    if (decoded is! Map<String, dynamic>) return const PulsePartialAck();
    return PulsePartialAck.fromJson(decoded);
  }

  /// Load the partial for (survey_id, external_id). Returns null on
  /// 404 — distinguishes a clean miss from a network failure, which
  /// still throws.
  Future<PulsePartial?> loadPartial({
    required String surveyId,
    required String externalId,
  }) async {
    final uri = Uri.parse('$_base/api/pulse/partial')
        .replace(queryParameters: {
      'survey_id': surveyId,
      'external_id': externalId,
    });
    final res = await _http.get(uri, headers: _headers()).timeout(timeout);
    if (res.statusCode == 404) return null;
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw PulseHttpException(res.statusCode, res.body);
    }
    if (res.body.isEmpty) return null;
    final decoded = jsonDecode(res.body);
    if (decoded is! Map<String, dynamic>) return null;
    return PulsePartial.fromJson(decoded);
  }

  /// Idempotent clear of the partial for (survey_id, external_id).
  /// The server also auto-cleans on successful submit, so the SDK
  /// only calls this on explicit dismiss / "start over".
  Future<void> deletePartial({
    required String surveyId,
    required String externalId,
  }) async {
    final uri = Uri.parse('$_base/api/pulse/partial')
        .replace(queryParameters: {
      'survey_id': surveyId,
      'external_id': externalId,
    });
    final res = await _http.delete(uri, headers: _headers()).timeout(timeout);
    if (res.statusCode != 404 &&
        (res.statusCode < 200 || res.statusCode >= 300)) {
      throw PulseHttpException(res.statusCode, res.body);
    }
  }

  Map<String, String> _headers() => {
        'x-api-key': apiKey,
        'Accept': 'application/json',
      };

  void close() => _http.close();
}

class PulseHttpException implements Exception {
  final int status;
  final String body;
  const PulseHttpException(this.status, this.body);

  @override
  String toString() => 'PulseHttpException($status): $body';
}
