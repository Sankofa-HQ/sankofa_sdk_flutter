// Copyright (c) 2026, Sankofa. All rights reserved.
//
// Sankofa SDK — KBC patch in-app fetch + apply (sub-phase η v1).
//
// Bridges the on-device Sankofa runtime to the server's
// `GET /api/deploy/check` endpoint so a patch released via
// `sankofa patch ios` lands on the device in one round-trip, no
// manual `xcrun devicectl device copy to` required.
//
// Flow:
//   1. GET <endpoint>/api/deploy/check?api_key=...&app_version=...
//      &platform=ios&engine_version=...&distinct_id=...
//      [&current_bundle_label=...]
//   2. If `has_update == false` → return CheckResult(applied: null).
//   3. Else download `download_url` (signed B2/S3 URL, valid for ~4h).
//   4. Verify sha-256 of the downloaded bytes matches the `sha256`
//      from the check response (transport integrity check on top of
//      the envelope's own payload-sha verification).
//   5. Write bytes to
//      `<Documents>/sankofa-deploy/patches/active/patch.skdp`
//      (persisted on disk so the next boot can read it back without
//      re-fetching; future η.2 can defer disk write until apply).
//   6. Call `applyKbcEnvelopeFromFile` — this parses, verifies the
//      envelope's payload-sha, sanity-checks inner KBC magic, then
//      hands the bytes to the host-provided `loader` callback.
//
// All HTTP failures, sha mismatches, and apply errors throw
// `KbcFetchException` with a message naming the failure mode for the
// host to surface to the user.

import 'dart:convert' show jsonDecode;
import 'dart:io' show File, Directory;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart' show getApplicationDocumentsDirectory;

import 'kbc_loader.dart';

/// Outcome of [fetchAndApplyKbcPatch].
///
/// When `hasUpdate` is true and the fetch+apply succeeded, [applied]
/// carries the dyn-module entry-point's return value + envelope
/// metadata. When `hasUpdate` is false, [applied] is null and [reason]
/// explains why (e.g. `already_on_latest`, `not_in_rollout`, `no_matching_release`).
class KbcFetchResult {
  KbcFetchResult({
    required this.hasUpdate,
    this.applied,
    this.reason,
    this.releaseId,
    this.label,
    this.sha256,
    this.sizeBytes,
    this.savedToPath,
  });

  final bool hasUpdate;
  /// Result of the apply pipeline. Null when hasUpdate=false.
  final KbcPatchResult? applied;
  /// Server-supplied reason when hasUpdate=false (e.g. `not_in_rollout`).
  final String? reason;
  final String? releaseId;
  final String? label;
  final String? sha256;
  final int? sizeBytes;
  /// On-disk path the envelope was persisted to. Null when hasUpdate=false
  /// or when the caller passed `persistToDisk: false`.
  final String? savedToPath;

  @override
  String toString() => hasUpdate
      ? 'KbcFetchResult(hasUpdate, label=$label, applied=$applied)'
      : 'KbcFetchResult(no update, reason=$reason)';
}

/// Raised for any failure inside [fetchAndApplyKbcPatch].
class KbcFetchException implements Exception {
  KbcFetchException(this.message, {this.cause, this.statusCode});
  final String message;
  final Object? cause;
  final int? statusCode;
  @override
  String toString() => 'KbcFetchException: $message'
      '${statusCode != null ? ' (HTTP $statusCode)' : ''}'
      '${cause != null ? ' (caused by $cause)' : ''}';
}

/// Hit the server, fetch a KBC patch envelope if one is available,
/// verify integrity, and apply it via the supplied [loader].
///
/// `endpoint` should NOT include a trailing slash and is expected to
/// be reachable from the device (e.g. the Mac's LAN IP during local
/// development, the production API host in shipping builds).
///
/// `engineVersion` should match the running Flutter engine's Sankofa
/// version string (e.g. `3.41.9+sankofa-1`). The server filters
/// available releases by this so a device on engine X can't be served
/// a patch compiled for engine Y.
///
/// `distinctId` is a stable device identifier used for rollout
/// hashing. The on-device SDK already keeps one for analytics; reuse
/// it here for rollout consistency.
///
/// `currentLabel` is the label of the patch the device is currently
/// running (null on first install). Letting the server short-circuit
/// with `already_on_latest` saves a B2 round-trip.
///
/// `loader` MUST be `loadModuleFromBytes` from
/// `package:dynamic_modules/dynamic_modules.dart` (or another binding
/// to `dart:_internal.loadDynamicModule`).
///
/// `persistToDisk` controls whether the envelope is saved to
/// `<Documents>/sankofa-deploy/patches/active/patch.skdp` after a
/// successful fetch. Default true — keeps the patch available for the
/// next boot, matches the on-disk shape the on-device demo + dev
/// workflows expect.
Future<KbcFetchResult> fetchAndApplyKbcPatch({
  required String endpoint,
  required String apiKey,
  required String appVersion,
  required String engineVersion,
  required String distinctId,
  required KbcLoaderFn loader,
  String platform = 'ios',
  String? currentLabel,
  bool persistToDisk = true,
  Duration timeout = const Duration(seconds: 30),
  String? signingPubkeyB64,
}) async {
  final base = endpoint.endsWith('/')
      ? endpoint.substring(0, endpoint.length - 1)
      : endpoint;
  final qp = <String, String>{
    'app_version': appVersion,
    'distinct_id': distinctId,
    'platform': platform,
    'engine_version': engineVersion,
    // Force runtime=flutter-code so a project that publishes both RN
    // and Flutter Code releases for this app version doesn't accidentally
    // hand us an RN OTA bundle (which our envelope parser would reject
    // anyway — fail-closed — but this saves a B2 round-trip).
    'runtime': 'flutter-code',
    if (currentLabel != null) 'current_bundle_label': currentLabel,
  };
  final checkUri = Uri.parse('$base/api/deploy/check')
      .replace(queryParameters: qp);

  // ── 1. GET /api/deploy/check ─────────────────────────────────────────
  http.Response checkResp;
  try {
    checkResp = await http.get(
      checkUri,
      headers: {'x-api-key': apiKey},
    ).timeout(timeout);
  } catch (err) {
    throw KbcFetchException(
      'check request failed: $err',
      cause: err,
    );
  }
  if (checkResp.statusCode != 200) {
    throw KbcFetchException(
      'check returned HTTP ${checkResp.statusCode}: ${checkResp.body}',
      statusCode: checkResp.statusCode,
    );
  }

  Map<String, dynamic> body;
  try {
    final decoded = jsonDecode(checkResp.body);
    if (decoded is! Map) {
      throw const FormatException('check response is not a JSON object');
    }
    body = Map<String, dynamic>.from(decoded);
  } catch (err) {
    throw KbcFetchException('check response malformed: $err', cause: err);
  }

  if (body['has_update'] != true) {
    return KbcFetchResult(
      hasUpdate: false,
      reason: body['reason']?.toString(),
      label: body['label']?.toString(),
    );
  }

  final downloadUrl = body['download_url']?.toString();
  final expectedSha = body['sha256']?.toString();
  final releaseId = body['release_id']?.toString();
  final label = body['label']?.toString();
  final size = (body['size'] as num?)?.toInt();
  if (downloadUrl == null || downloadUrl.isEmpty) {
    throw KbcFetchException('check response missing download_url');
  }
  if (expectedSha == null || expectedSha.isEmpty) {
    throw KbcFetchException('check response missing sha256');
  }

  // ── 2. GET download_url (signed B2/S3 URL) ───────────────────────────
  http.Response bundleResp;
  try {
    bundleResp = await http.get(Uri.parse(downloadUrl)).timeout(timeout);
  } catch (err) {
    throw KbcFetchException(
      'envelope download failed: $err',
      cause: err,
    );
  }
  if (bundleResp.statusCode != 200) {
    throw KbcFetchException(
      'envelope download returned HTTP ${bundleResp.statusCode}',
      statusCode: bundleResp.statusCode,
    );
  }
  final bytes = bundleResp.bodyBytes;

  // ── 3. Verify transport sha against the check response's sha256 ──────
  final actualSha = sha256.convert(bytes).toString();
  if (actualSha != expectedSha) {
    throw KbcFetchException(
      'transport sha mismatch: server said $expectedSha, got $actualSha — '
      'envelope is corrupt or download was tampered',
    );
  }

  // ── 4. Persist to disk (optional) ────────────────────────────────────
  String? savedToPath;
  if (persistToDisk) {
    final docsDir = await getApplicationDocumentsDirectory();
    final patchDir = Directory(
        '${docsDir.path}/sankofa-deploy/patches/active');
    if (!patchDir.existsSync()) {
      patchDir.createSync(recursive: true);
    }
    final patchFile = File('${patchDir.path}/patch.skdp');
    patchFile.writeAsBytesSync(bytes, flush: true);
    savedToPath = patchFile.path;
  }

  // ── 5. Apply via the standard envelope pipeline ──────────────────────
  late final KbcPatchResult applied;
  try {
    applied = await applyKbcEnvelope(
      Uint8List.fromList(bytes),
      loader: loader,
      signingPubkeyB64: signingPubkeyB64,
    );
  } on KbcApplyException catch (err) {
    throw KbcFetchException(
      'apply failed after fetch: ${err.message}',
      cause: err,
    );
  }

  return KbcFetchResult(
    hasUpdate: true,
    applied: applied,
    releaseId: releaseId,
    label: label,
    sha256: expectedSha,
    sizeBytes: size ?? bytes.length,
    savedToPath: savedToPath,
  );
}
