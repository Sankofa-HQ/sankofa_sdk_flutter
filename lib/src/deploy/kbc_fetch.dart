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

import 'package:crypto/crypto.dart' show Digest, sha256;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart' show getApplicationDocumentsDirectory;

import 'kbc_loader.dart';
import 'sankofa_update.dart';

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

/// Shorebird-style "is there a patch?" probe — checks the server and
/// returns metadata WITHOUT downloading. Use this when you want to
/// gate the actual download behind a user prompt (optional updates)
/// or to skip the prompt entirely (mandatory updates).
///
/// Returns a [SankofaUpdateCheckResult] whose `status` is one of:
///
///   - [SankofaUpdateStatus.upToDate]      — no new patch
///   - [SankofaUpdateStatus.outdated]      — new patch in `update`
///   - [SankofaUpdateStatus.unavailable]   — transient network/5xx
///   - [SankofaUpdateStatus.invalidConfig] — 4xx (bad apiKey, etc.)
///   - [SankofaUpdateStatus.bannedLocally] — server's latest matches a
///                                            label the device's
///                                            auto-rollback subsystem
///                                            has flagged bad
///
/// Args mirror [fetchAndApplyKbcPatch] — same endpoint, same apiKey,
/// same app/engine/distinct ids.
Future<SankofaUpdateCheckResult> checkForKbcUpdate({
  required String endpoint,
  required String apiKey,
  required String appVersion,
  required String engineVersion,
  required String distinctId,
  String platform = 'ios',
  String? currentLabel,
  String? flavor,
  Duration timeout = const Duration(seconds: 30),
  Set<String>? bannedLabels,
}) async {
  final base = endpoint.endsWith('/')
      ? endpoint.substring(0, endpoint.length - 1)
      : endpoint;
  final qp = <String, String>{
    'app_version': appVersion,
    'distinct_id': distinctId,
    'platform': platform,
    // Empty = unknown (sankofa.yaml without engine_version) — omit so
    // the server applies its missing-engine wildcard instead of
    // matching releases against the literal empty string.
    if (engineVersion.isNotEmpty) 'engine_version': engineVersion,
    'runtime': 'flutter-code',
    if (currentLabel != null) 'current_bundle_label': currentLabel,
    // Flavor scopes the patch per product flavor (empty = wildcard, so
    // unflavored apps + legacy releases are unaffected).
    if (flavor != null && flavor.isNotEmpty) 'flavor': flavor,
  };
  final checkUri = Uri.parse('$base/api/deploy/check')
      .replace(queryParameters: qp);

  http.Response checkResp;
  try {
    checkResp = await http.get(
      checkUri,
      headers: {'x-api-key': apiKey},
    ).timeout(timeout);
  } catch (err) {
    return SankofaUpdateCheckResult(
      status: SankofaUpdateStatus.unavailable,
      reason: 'network_error:check:$err',
    );
  }
  if (checkResp.statusCode >= 500) {
    return SankofaUpdateCheckResult(
      status: SankofaUpdateStatus.unavailable,
      reason: 'server_error:check:HTTP ${checkResp.statusCode}',
    );
  }
  if (checkResp.statusCode != 200) {
    return SankofaUpdateCheckResult(
      status: SankofaUpdateStatus.invalidConfig,
      reason: 'check returned HTTP ${checkResp.statusCode}: ${checkResp.body}',
    );
  }

  Map<String, dynamic> body;
  try {
    final decoded = jsonDecode(checkResp.body);
    if (decoded is! Map) {
      return const SankofaUpdateCheckResult(
        status: SankofaUpdateStatus.invalidConfig,
        reason: 'check response not a JSON object',
      );
    }
    body = Map<String, dynamic>.from(decoded);
  } catch (err) {
    return SankofaUpdateCheckResult(
      status: SankofaUpdateStatus.invalidConfig,
      reason: 'check response malformed: $err',
    );
  }

  if (body['has_update'] != true) {
    return SankofaUpdateCheckResult(
      status: SankofaUpdateStatus.upToDate,
      reason: body['reason']?.toString(),
    );
  }

  final label = body['label']?.toString() ?? '';
  if (bannedLabels != null && bannedLabels.contains(label)) {
    return const SankofaUpdateCheckResult(
      status: SankofaUpdateStatus.bannedLocally,
      reason: 'label_banned_locally',
    );
  }

  final downloadUrl = body['download_url']?.toString() ?? '';
  final expectedSha = body['sha256']?.toString() ?? '';
  if (downloadUrl.isEmpty || expectedSha.isEmpty) {
    return const SankofaUpdateCheckResult(
      status: SankofaUpdateStatus.invalidConfig,
      reason: 'check response missing download_url or sha256',
    );
  }

  return SankofaUpdateCheckResult(
    status: SankofaUpdateStatus.outdated,
    update: SankofaUpdate(
      label: label,
      releaseId: body['release_id']?.toString() ?? '',
      downloadUrl: downloadUrl,
      sha256: expectedSha,
      sizeBytes: (body['size'] as num?)?.toInt() ?? 0,
      isMandatory: body['is_mandatory'] == true,
    ),
  );
}

/// Download an envelope previously discovered via [checkForKbcUpdate]
/// to the conventional staged path so [SankofaDeploy.tryApplyStagedKbcPatch]
/// picks it up on the next launch.
///
/// Uses HTTP streaming so [onProgress] fires once per chunk with the
/// running `(received, total)` byte counts. `total` matches
/// [SankofaUpdate.sizeBytes] when the server included a Content-Length;
/// otherwise it falls back to that field.
///
/// Verifies the streamed bytes against [SankofaUpdate.sha256] before
/// persisting — a mid-flight corruption raises [KbcFetchException]
/// and the partial file is deleted.
///
/// Returns the absolute on-disk path where the envelope was persisted.
Future<String> downloadKbcUpdateToFile(
  SankofaUpdate update, {
  void Function(int received, int total)? onProgress,
  Duration timeout = const Duration(minutes: 5),
}) async {
  final docsDir = await getApplicationDocumentsDirectory();
  final patchDir = Directory(
      '${docsDir.path}/sankofa-deploy/patches/active');
  if (!patchDir.existsSync()) {
    patchDir.createSync(recursive: true);
  }
  final patchFile = File('${patchDir.path}/patch.skdp');
  final tmpFile = File('${patchFile.path}.partial');
  if (tmpFile.existsSync()) {
    tmpFile.deleteSync();
  }

  final client = http.Client();
  try {
    final req = http.Request('GET', Uri.parse(update.downloadUrl));
    final resp = await client.send(req).timeout(timeout);
    if (resp.statusCode >= 500 || resp.statusCode == 403) {
      throw KbcFetchException(
        'storage_error:download:HTTP ${resp.statusCode}',
        statusCode: resp.statusCode,
      );
    }
    if (resp.statusCode != 200) {
      throw KbcFetchException(
        'envelope download returned HTTP ${resp.statusCode}',
        statusCode: resp.statusCode,
      );
    }

    final total = resp.contentLength ?? update.sizeBytes;
    int received = 0;
    final sink = tmpFile.openWrite();
    final hasher = sha256.startChunkedConversion(_HashSink());

    try {
      await for (final chunk in resp.stream) {
        sink.add(chunk);
        hasher.add(chunk);
        received += chunk.length;
        if (onProgress != null) {
          onProgress(received, total);
        }
      }
      await sink.flush();
      await sink.close();
      hasher.close();
    } catch (err) {
      try {
        await sink.close();
      } catch (_) {}
      if (tmpFile.existsSync()) tmpFile.deleteSync();
      rethrow;
    }

    final actualSha = (hasher as dynamic).result;
    if (actualSha != update.sha256) {
      if (tmpFile.existsSync()) tmpFile.deleteSync();
      throw KbcFetchException(
        'transport sha mismatch: server said ${update.sha256}, got $actualSha — '
        'envelope is corrupt or download was tampered',
      );
    }

    // Atomic rename: only swap into place once the bytes are fully verified.
    if (patchFile.existsSync()) {
      patchFile.deleteSync();
    }
    tmpFile.renameSync(patchFile.path);
    return patchFile.path;
  } finally {
    client.close();
  }
}

/// Capture-style sink that accumulates a SHA-256 digest from chunked
/// input. Used by [downloadKbcUpdateToFile] to verify the streamed
/// envelope without buffering the whole file in memory.
class _HashSink implements Sink<Digest> {
  String? _hex;
  String? get result => _hex;
  @override
  void add(Digest data) {
    _hex = data.toString();
  }

  @override
  void close() {}
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
  List<String>? signingPubkeysB64,
  Set<String>? bannedLabels,
}) async {
  final base = endpoint.endsWith('/')
      ? endpoint.substring(0, endpoint.length - 1)
      : endpoint;
  final qp = <String, String>{
    'app_version': appVersion,
    'distinct_id': distinctId,
    'platform': platform,
    // Empty = unknown (sankofa.yaml without engine_version) — omit so
    // the server applies its missing-engine wildcard instead of
    // matching releases against the literal empty string.
    if (engineVersion.isNotEmpty) 'engine_version': engineVersion,
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
    // Network-layer failure (DNS, TCP refused, timeout, TLS). Return
    // a structured "no update" instead of throwing — matches RN SDK's
    // offline tolerance (sankofa_sdk_react_native/SankofaDeploy.ts).
    // Hosts that want to surface this can read result.reason; hosts
    // that just want UX should treat it as "Up to date / offline".
    return KbcFetchResult(
      hasUpdate: false,
      reason: 'network_error:check:$err',
    );
  }
  if (checkResp.statusCode >= 500) {
    // Server-side failure — return structured so the host doesn't
    // crash on every transient 5xx. Same rationale as network errors.
    return KbcFetchResult(
      hasUpdate: false,
      reason: 'server_error:check:HTTP ${checkResp.statusCode}',
    );
  }
  if (checkResp.statusCode != 200) {
    // 4xx — configuration error (bad apiKey, unknown project, etc.).
    // Keep as exception: these indicate integration bugs the customer
    // needs to fix, not transient failures to ignore.
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

  // Banned-labels gate: if a previous boot auto-rolled-back this label,
  // refuse to re-download + re-apply. Without this the user crash-loops
  // on every fetch (server still serves the bad patch as "latest").
  // Customer can clear via Sankofa.deploy.clearBannedKbcLabels().
  if (label != null &&
      bannedLabels != null &&
      bannedLabels.contains(label)) {
    return KbcFetchResult(
      hasUpdate: false,
      reason: 'label_banned_locally',
      label: label,
      releaseId: releaseId,
    );
  }
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
    // Network-layer failure pulling the envelope from B2/S3. Return
    // structured (RN parity) — the device can retry next check.
    return KbcFetchResult(
      hasUpdate: false,
      reason: 'network_error:download:$err',
      releaseId: releaseId,
      label: label,
    );
  }
  if (bundleResp.statusCode >= 500 || bundleResp.statusCode == 403) {
    // 5xx from CDN, or 403 (presigned URL expired) — transient, retry next check.
    return KbcFetchResult(
      hasUpdate: false,
      reason: 'storage_error:download:HTTP ${bundleResp.statusCode}',
      releaseId: releaseId,
      label: label,
    );
  }
  if (bundleResp.statusCode != 200) {
    // 4xx other than 403 — bad URL or malformed presign. Programmer error.
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
      signingPubkeysB64: signingPubkeysB64,
    );
  } on KbcApplyException catch (err) {
    throw KbcFetchException(
      'apply failed after fetch: ${err.message}',
      cause: err,
    );
  }

  // BREADCRUMB (temporary): observe the PATCH's entry-point return value. This
  // is the fetch-then-apply path — the one a fresh patch actually takes. If the
  // engine runs the patch module's entry point, returnValue is the sentinel the
  // extractor emits ('SANKOFA_ENTRY_RAN'); the baseline path returns
  // 'sankofa-baseline-<ver>'. Written to a readable file, no plugin needed.
  try {
    final dd = await getApplicationDocumentsDirectory();
    File('${dd.path}/sankofa-deploy/patches/fetch_apply_breadcrumb.txt')
        .writeAsStringSync(
      'FETCH-APPLY OK. label=$label returnValue=${applied.returnValue}',
      flush: true,
    );
    // The patch's return value, alone, for the host to consume. This is the
    // supported channel: a pure patched function returns a value, applyKbcEnvelope
    // surfaces it, and the host reads it here — no in-module I/O required (which
    // aborts on load) and no reliance on the method reroute (which does not fire).
    if (applied.returnValue != null) {
      File('${dd.path}/sankofa-deploy/patch_result.txt')
          .writeAsStringSync(applied.returnValue.toString(), flush: true);
    }
  } catch (_) {}

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
