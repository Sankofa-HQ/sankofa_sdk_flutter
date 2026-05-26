// Copyright (c) 2026, Sankofa. All rights reserved.
//
// Sankofa SDK — KBC patch apply pipeline (sub-phase η).
//
// Bridges a SANKOFA_KBC_ENVELOPE on disk (or in memory) to the running
// Sankofa β.1 Flutter engine's `dart:_internal.loadDynamicModule` via
// a host-supplied loader callback.
//
// Why the loader is host-supplied (instead of importing `dart:_internal`
// directly from the SDK): `dart:_internal` is sealed to non-SDK packages.
// `pkg/dynamic_modules` is the public wrapper but it lives inside the
// Dart SDK fork as a path-dep (not on pub.dev). Asking every host app
// to declare that path-dep in its pubspec is reasonable; baking it into
// the Sankofa SDK would couple every consumer to our fork checkout.
//
// Host integration:
//
//   import 'package:dynamic_modules/dynamic_modules.dart';
//   import 'package:sankofa_flutter/sankofa_flutter.dart';
//
//   final result = await Sankofa.deploy!.applyKbcPatchFromBytes(
//     envelopeBytes,
//     loader: loadModuleFromBytes,
//   );
//
// The SDK handles envelope parsing, SHA verification, error mapping,
// and (future) signature checking. The host handles the actual VM
// call into `loadDynamicModule`.

import 'dart:io' show File, Platform;
import 'dart:typed_data';

import 'kbc_envelope.dart';

/// Loader signature host apps wire in. Almost always
/// `loadModuleFromBytes` from `package:dynamic_modules/dynamic_modules.dart`.
typedef KbcLoaderFn = Future<Object?> Function(Uint8List kbcBytes);

/// Outcome of [SankofaDeploy.applyKbcPatchFromBytes] /
/// [SankofaDeploy.applyKbcPatchFromFile].
///
/// On success, [returnValue] is whatever the patch's
/// `@pragma('dyn-module:entry-point')` function returned (an Object?).
/// [metadata] is the envelope's metadata map (release id, label, etc.)
/// so the caller doesn't have to re-parse to read it.
class KbcPatchResult {
  KbcPatchResult({
    required this.returnValue,
    required this.metadata,
    required this.kbcSize,
    required this.envelopeSize,
  });

  final Object? returnValue;
  final Map<String, dynamic> metadata;
  final int kbcSize;
  final int envelopeSize;

  @override
  String toString() =>
      'KbcPatchResult(returnValue: $returnValue, kbcSize: $kbcSize, '
      'envelopeSize: $envelopeSize, metadata: $metadata)';
}

/// Raised when an envelope fails any pre-load check: bad magic, wrong
/// version, SHA mismatch, malformed metadata, unsupported signature.
///
/// `loadModuleFromBytes` is NOT called when this is thrown — the SDK
/// fails closed so a tampered or corrupt patch never reaches the
/// interpreter.
class KbcApplyException implements Exception {
  KbcApplyException(this.message, {this.cause, this.causeStackTrace});
  final String message;
  final Object? cause;

  /// Stack trace of the original throw that triggered this exception.
  /// Preserved through the apply pipeline so ζ.2 telemetry can report
  /// the interpreter frames (Dart's StackTrace.toString() symbolicates
  /// down through `dart::Interpreter::Run` to the patch's source
  /// position when source-positions are baked into the KBC — which is
  /// the default for `sankofa patch`).
  final StackTrace? causeStackTrace;
  @override
  String toString() =>
      cause == null ? 'KbcApplyException: $message' : 'KbcApplyException: $message (caused by $cause)';
}

/// ζ — engine compatibility check.
///
/// Pulls the running Dart VM version from `Platform.version` (e.g.
/// `"3.11.5+sankofa-1 (stable) (...) on \"ios_arm64\""`) and compares
/// against the envelope's `dartVersion` metadata. Refuses to apply a
/// patch whose KBC was emitted by a different Dart version: KBC
/// bytecode format is version-sensitive and dispatch tables can shift
/// between minors. Fail-closed is safer than the alternative — a
/// silent crash deep inside `Interpreter::Run` with no breadcrumbs.
///
/// Also refuses to apply on a non-Sankofa engine: stock Flutter's
/// `loadDynamicModule` throws `Unsupported operation` (the
/// `runtime/lib/object.cc:617` `#else` branch), but checking up-front
/// surfaces the cause cleanly instead of letting the host see a
/// generic UnsupportedError.
///
/// Build-time bypass. Set `--dart-define=SANKOFA_SKIP_ENGINE_CHECK=1` to
/// skip the Platform.version sankofa-marker check. Useful while the Dart
/// SDK fork doesn't yet stamp `+sankofa-N` into `tools/VERSION` — the
/// Flutter engine binary IS forked (verified via FLUTTER_ENGINE_VERSION
/// in Flutter.framework), but Platform.version reflects the bundled
/// Dart SDK version, which is unmodified.
const bool _skipEngineCheck = bool.fromEnvironment(
  'SANKOFA_SKIP_ENGINE_CHECK',
  defaultValue: false,
);

/// Returns null on success, an error message on failure.
String? _engineCompatError(Map<String, dynamic> metadata) {
  final platformVersion = Platform.version;
  // Stock Flutter has no `+sankofa-` marker in its version string;
  // refuse to even attempt the apply if it's missing — unless the
  // SANKOFA_SKIP_ENGINE_CHECK dart-define is set (dev/test escape hatch
  // while the Dart SDK fork hasn't stamped its version yet).
  if (!_skipEngineCheck && !platformVersion.contains('+sankofa-')) {
    return 'running engine is not a Sankofa fork build '
        '(Platform.version = "$platformVersion" — expected to contain '
        '"+sankofa-N"). KBC patches will not load on stock Flutter. '
        'If your engine IS forked but Dart version is unstamped, rebuild '
        'with --dart-define=SANKOFA_SKIP_ENGINE_CHECK=1.';
  }
  // Compare envelope's dartVersion to the engine's Dart minor.
  // Envelope dartVersion typically comes back as just "3.11.5";
  // Platform.version is "3.11.5+sankofa-1 (...)". We compare the
  // leading dotted-numeric prefix only, since the +sankofa-N marker is
  // engine-fork build identity, not Dart language version.
  final envelopeDart = metadata['dartVersion']?.toString();
  if (envelopeDart != null && envelopeDart.isNotEmpty) {
    final engineDart = platformVersion.split('+').first.split(' ').first;
    if (envelopeDart != engineDart) {
      return 'envelope Dart version "$envelopeDart" does not match running '
          'engine "$engineDart" (Platform.version = "$platformVersion"). '
          'Rebuild the patch with the same Dart SDK the engine ships.';
    }
  }
  return null;
}

/// Internal apply pipeline. Exposed publicly via SankofaDeploy.
///
/// Signature verification: pass one or both of [signingPubkeyB64] (a
/// single pubkey, host-app-embedded) and [signingPubkeysB64] (multiple
/// pubkeys, typically server-distributed via handshake). They're
/// concatenated and verification accepts on any-match — supports
/// graceful rotation. When BOTH are null/empty, signature verification
/// is skipped entirely (dev / unsigned mode). When EITHER is set,
/// the envelope MUST be sig_alg=ed25519 with a signature that verifies
/// against one of the supplied keys, or KbcApplyException is thrown.
Future<KbcPatchResult> applyKbcEnvelope(
  Uint8List envelopeBytes, {
  required KbcLoaderFn loader,
  String? signingPubkeyB64,
  List<String>? signingPubkeysB64,
}) async {
  ParsedKbcEnvelope parsed;
  try {
    parsed = parseKbcEnvelope(envelopeBytes);
  } on KbcEnvelopeFormatException catch (err) {
    throw KbcApplyException('envelope format error: ${err.message}', cause: err);
  }

  if (!parsed.payloadShaValid) {
    throw KbcApplyException(
      'envelope payload sha-256 mismatch — patch is tampered or corrupt',
    );
  }

  // v2 MVP + v2.2: Ed25519 signature verification. Merge the host-app-
  // embedded pubkey (v2 MVP, single) with the server-distributed pubkeys
  // (v2.2, list — fetched via /api/v1/handshake's modules.deploy.
  // signing_keys). Verification accepts on any-match so a project can
  // rotate keys server-side without rebuilding the host app.
  final mergedPubkeys = <String>[
    if (signingPubkeyB64 != null && signingPubkeyB64.isNotEmpty)
      signingPubkeyB64,
    if (signingPubkeysB64 != null) ...signingPubkeysB64,
  ];
  if (mergedPubkeys.isNotEmpty) {
    if (parsed.sigAlg != KbcSigAlg.ed25519) {
      throw KbcApplyException(
        'envelope is unsigned but app requires Ed25519-signed patches. '
        'Rebuild the patch with `sankofa keys generate` configured for '
        'project ${parsed.metadata['projectId'] ?? '<unknown>'}.',
      );
    }
    final ok = await verifyKbcEnvelopeSignature(
      envelopeBytes: envelopeBytes,
      parsed: parsed,
      pubkeysB64: mergedPubkeys,
    );
    if (!ok) {
      throw KbcApplyException(
        'envelope Ed25519 signature did not verify against any of the '
        '${mergedPubkeys.length} authorized pubkey(s) for this project. '
        'Either the patch was tampered with in transit, the signing key '
        'changed without rebuilding the host app, or the key was revoked '
        'server-side without the device receiving a fresh handshake.',
      );
    }
  } else if (parsed.sigAlg != KbcSigAlg.unsigned &&
      parsed.sigAlg != KbcSigAlg.ed25519) {
    // Unknown algorithm — parser would already throw on a value outside
    // the enum, so this only fires on a future v3+ alg we don't grok.
    throw KbcApplyException(
      'envelope signature algorithm ${parsed.sigAlg} not supported by this SDK.',
    );
  }

  // Sanity-check the KBC payload's own magic — catches the case where
  // someone wrapped non-KBC bytes (the dart2bytecode magic is
  // 'DBC3' = 33 43 42 44 little-endian).
  if (parsed.kbcPayload.length < 4 ||
      parsed.kbcPayload[0] != 0x33 ||
      parsed.kbcPayload[1] != 0x43 ||
      parsed.kbcPayload[2] != 0x42 ||
      parsed.kbcPayload[3] != 0x44) {
    throw KbcApplyException(
      'envelope wraps non-KBC payload (magic mismatch in inner payload)',
    );
  }

  // ζ — engine version pinning. Refuse mismatch BEFORE handing bytes
  // to the loader. Cleaner failure mode than the loader's deep crash.
  final compatErr = _engineCompatError(parsed.metadata);
  if (compatErr != null) {
    throw KbcApplyException(compatErr);
  }

  Object? returnValue;
  try {
    returnValue = await loader(parsed.kbcPayload);
  } catch (err, st) {
    throw KbcApplyException(
      'loader threw — could be the running Flutter engine was NOT built '
      'with dart_dynamic_modules=true (the Sankofa β.1 engine fork — '
      'stock Flutter throws "Loading of dynamic modules is not supported"), '
      'OR the patch itself threw at top level (see causeStackTrace).',
      cause: err,
      causeStackTrace: st,
    );
  }

  return KbcPatchResult(
    returnValue: returnValue,
    metadata: parsed.metadata,
    kbcSize: parsed.kbcPayload.length,
    envelopeSize: parsed.totalSize,
  );
}

/// Read a file from disk, parse + verify, hand the inner KBC bytes
/// to [loader]. See [applyKbcEnvelope].
Future<KbcPatchResult> applyKbcEnvelopeFromFile(
  String path, {
  required KbcLoaderFn loader,
  String? signingPubkeyB64,
  List<String>? signingPubkeysB64,
}) async {
  final file = File(path);
  if (!file.existsSync()) {
    throw KbcApplyException('envelope file not found: $path');
  }
  final bytes = await file.readAsBytes();
  return applyKbcEnvelope(
    bytes,
    loader: loader,
    signingPubkeyB64: signingPubkeyB64,
    signingPubkeysB64: signingPubkeysB64,
  );
}
