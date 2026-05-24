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

import 'dart:io' show File;
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
  KbcApplyException(this.message, {this.cause});
  final String message;
  final Object? cause;
  @override
  String toString() =>
      cause == null ? 'KbcApplyException: $message' : 'KbcApplyException: $message (caused by $cause)';
}

/// Internal apply pipeline. Exposed publicly via SankofaDeploy.
Future<KbcPatchResult> applyKbcEnvelope(
  Uint8List envelopeBytes, {
  required KbcLoaderFn loader,
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
  if (parsed.sigAlg != KbcSigAlg.unsigned) {
    // v1 only supports unsigned. When v2 + signature verification lands
    // this will dispatch to the appropriate verifier.
    throw KbcApplyException(
      'envelope signature algorithm ${parsed.sigAlg} not supported by this SDK '
      '(parser handles v1 unsigned only).',
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

  Object? returnValue;
  try {
    returnValue = await loader(parsed.kbcPayload);
  } catch (err) {
    throw KbcApplyException(
      'loader threw — likely the running Flutter engine was NOT built '
      'with dart_dynamic_modules=true (the Sankofa β.1 engine fork). '
      'Stock Flutter throws "Loading of dynamic modules is not supported".',
      cause: err,
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
}) async {
  final file = File(path);
  if (!file.existsSync()) {
    throw KbcApplyException('envelope file not found: $path');
  }
  final bytes = await file.readAsBytes();
  return applyKbcEnvelope(bytes, loader: loader);
}
