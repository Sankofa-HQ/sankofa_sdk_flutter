import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'pulse_models.dart';

/// Cached survey list — written to SharedPreferences on every full
/// fetch so the SDK can serve subsequent calls from disk and 304
/// the network when the server hasn't changed anything. Same
/// server-load posture as the Web / RN SDKs.
class _CachedSurveysList {
  final String etag;
  final int fetchedAtMs;
  final List<PulseSurveySummary> surveys;
  const _CachedSurveysList({
    required this.etag,
    required this.fetchedAtMs,
    required this.surveys,
  });

  Map<String, dynamic> toJson() => {
        'etag': etag,
        'fetched_at_ms': fetchedAtMs,
        'surveys': surveys.map((s) => s.toJson()).toList(),
      };

  factory _CachedSurveysList.fromJson(Map<String, dynamic> json) {
    final raw = json['surveys'] as List<dynamic>? ?? const [];
    return _CachedSurveysList(
      etag: json['etag'] as String? ?? '',
      fetchedAtMs: (json['fetched_at_ms'] as num?)?.toInt() ?? 0,
      surveys: raw
          .whereType<Map<String, dynamic>>()
          .map(PulseSurveySummary.fromJson)
          .toList(),
    );
  }
}

const _surveysCachePrefix = 'sankofa.pulse.surveys.';
const _defaultListTtlMs = 5 * 60 * 1000;

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

  /// List every published survey the API key's project owns.
  /// Cached in SharedPreferences with ETag + TTL — reads after the
  /// first fetch are instant, and revalidations short-circuit to a
  /// 304 + zero body when the server hasn't changed anything. Same
  /// posture as the Web / RN SDKs: one full fetch per device per
  /// few minutes, 304 the rest. Returns an empty list on 404 so
  /// older engines without this endpoint don't break the SDK.
  Future<List<PulseSurveySummary>> listSurveys({
    bool forceRefresh = false,
    Duration? ttl,
  }) async {
    final ttlMs = (ttl ?? const Duration(milliseconds: _defaultListTtlMs))
        .inMilliseconds;
    final cacheKey = '$_surveysCachePrefix$_base|$apiKey';

    final prefs = await SharedPreferences.getInstance();
    final cached = _readCache(prefs, cacheKey);
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!forceRefresh &&
        cached != null &&
        now - cached.fetchedAtMs < ttlMs) {
      return cached.surveys;
    }

    final headers = <String, String>{..._headers()};
    if (cached != null && cached.etag.isNotEmpty) {
      headers['If-None-Match'] = cached.etag;
    }

    final uri = Uri.parse('$_base/api/pulse/surveys');
    try {
      final res = await _http.get(uri, headers: headers).timeout(timeout);
      if (res.statusCode == 304 && cached != null) {
        await _writeCache(
          prefs,
          cacheKey,
          _CachedSurveysList(
            etag: cached.etag,
            fetchedAtMs: now,
            surveys: cached.surveys,
          ),
        );
        return cached.surveys;
      }
      if (res.statusCode == 404) return const [];
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw PulseHttpException(res.statusCode, res.body);
      }
      final etag = res.headers['etag'] ?? '';
      if (res.body.isEmpty) return const [];
      final decoded = jsonDecode(res.body);
      final raw = decoded is Map<String, dynamic>
          ? (decoded['surveys'] as List?) ?? const []
          : decoded is List
              ? decoded
              : const [];
      final surveys = raw
          .whereType<Map<String, dynamic>>()
          .map(PulseSurveySummary.fromJson)
          .toList(growable: false);
      await _writeCache(
        prefs,
        cacheKey,
        _CachedSurveysList(
          etag: etag,
          fetchedAtMs: now,
          surveys: surveys,
        ),
      );
      return surveys;
    } catch (e) {
      // Network failed but we have a stale cache — return it rather
      // than blocking the host. Better stale surveys for one tick
      // than a broken modal during a flaky moment.
      if (cached != null) return cached.surveys;
      rethrow;
    }
  }

  _CachedSurveysList? _readCache(SharedPreferences prefs, String key) {
    try {
      final raw = prefs.getString(key);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return _CachedSurveysList.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeCache(
    SharedPreferences prefs,
    String key,
    _CachedSurveysList value,
  ) async {
    try {
      await prefs.setString(key, jsonEncode(value.toJson()));
    } catch (_) {
      /* swallow — fall back to per-call fetch */
    }
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
