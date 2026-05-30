// # Integration health reporter — Flutter SDK
//
// Companion to the GET /api/v1/handshake call. After each module's
// `checkIntegration()` audit resolves, this fires a fire-and-forget
// POST to `/api/v1/handshake/integrations` with the result so the
// dashboard can show a per-app "Integration Health" panel.
//
// Why a separate POST instead of piggybacking the handshake:
//   - The handshake is GET-with-query-params (cacheable, ETag-friendly).
//   - Integration statuses carry arrays of human-readable strings that
//     don't fit cleanly in a URL.
//   - Audits are async — bundling them into the handshake would delay
//     module activation. Reporting separately keeps the hot path lean.
//
// Mirrors `sdks/sankofa_sdk_react_native/src/core/integrationReporter.ts`
// — keep them in lockstep.
//
// Failure mode: every error is swallowed. The audit result also lives
// in `_lastDeployIntegrationStatus` (and equivalents for future
// modules), so the next launch re-runs the audit and tries again.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:http/http.dart' as http;

import 'module_registry.dart';
import '../sankofa_constants.dart';

/// Single source of truth for the SDK version (see [kSdkVersion]); the server
/// correlates report-shape changes with SDK versions.
const String _sdkVersion = kSdkVersion;

/// Fire-and-forget POST of one or more module integration statuses.
///
/// Returns the parsed `{ stored }` count on success, or `null` on any
/// error (errors are swallowed — the caller never blocks on this).
Future<int?> reportIntegrationStatuses({
  required String apiKey,
  required Uri serverBaseUri,
  required List<ModuleIntegrationStatus> statuses,
  required String? appVersion,
  bool debug = false,
}) async {
  if (apiKey.isEmpty) return null;
  if (statuses.isEmpty) return null;

  final uri = serverBaseUri.replace(path: '/api/v1/handshake/integrations');

  final body = <String, dynamic>{
    'sdk': 'flutter',
    'sdk_version': _sdkVersion,
    'platform': Platform.operatingSystem, // 'ios' | 'android' | 'macos' | …
    'app_version': appVersion ?? '',
    'integrations': statuses
        .map((s) => <String, dynamic>{
              'module': s.module.wireName,
              'level': s.level.name, // 'full' | 'partial' | 'broken'
              'missing': s.missing,
              'warnings': s.warnings,
            })
        .toList(),
  };

  try {
    final res = await http
        .post(
          uri,
          headers: <String, String>{
            'Content-Type': 'application/json',
            'x-api-key': apiKey,
          },
          body: json.encode(body),
        )
        .timeout(const Duration(seconds: 10));

    if (res.statusCode < 200 || res.statusCode >= 300) {
      if (debug) {
        // ignore: avoid_print
        print(
            '[Sankofa] Integration report rejected (${res.statusCode})');
      }
      return null;
    }
    try {
      final parsed = json.decode(res.body) as Map<String, dynamic>;
      final stored = parsed['stored'];
      if (debug) {
        // ignore: avoid_print
        print(
            '[Sankofa] Integration report OK — stored ${stored ?? 0} module status(es)');
      }
      return stored is int ? stored : 0;
    } catch (_) {
      return 0;
    }
  } catch (err) {
    if (debug) {
      // ignore: avoid_print
      print('[Sankofa] Integration report failed: $err');
    }
    return null;
  }
}
