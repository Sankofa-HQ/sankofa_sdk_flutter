// Copyright (c) 2026, Sankofa. All rights reserved.
//
// Dart-side parser for the SANKOFA_KBC_ENVELOPE format produced by
// `sankofa kbc wrap` in the CLI. MUST stay byte-compatible with the
// TypeScript spec at
// `cli/sankofa-cli/src/utils/flutterKbcEnvelope.ts`.
//
// Format SANKOFA_KBC_ENVELOPE v1 (little-endian throughout):
//
//   offset  size  field
//   ------  ----  -----
//   0       4     magic "SKDP"
//   4       2     env_version u16 = 1
//   6       2     flags u16 (reserved)
//   8       4     kbc_length u32
//   12      4     meta_length u32
//   16      4     reserved u32 = 0
//   20      32    payload_sha (sha-256 of KBC payload)
//   52      M     metadata (utf-8 JSON, meta_length bytes)
//   52+M    N     kbc_payload (kbc_length bytes)
//
//   Signature trailer (always present, alg=0 means unsigned in v1):
//   X       1     sig_alg u8 (0 = unsigned, 1 = Ed25519 [future])
//   X+1     1     reserved u8 = 0
//   X+2     2     sig_length u16
//   X+4     S     sig_bytes (signature over bytes [0..X), empty if alg=0)
//
// Why a dual implementation (TS + Dart): producer-side validation
// happens in the CLI; consumer-side validation happens on the device
// before the bytes touch the interpreter. The same wire format means
// either side can be evolved independently as long as the spec moves
// together.

import 'dart:convert' show base64, jsonDecode, utf8;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:cryptography/cryptography.dart' show Ed25519, SimplePublicKey, KeyPairType, Signature;

const int envelopeVersion = 1;
const int _headerSize = 52;
const int _trailerFixedSize = 4;
const List<int> _magicBytes = [0x53, 0x4b, 0x44, 0x50]; // "SKDP"

/// Signature algorithm identifiers carried in the trailer.
///
/// v1 only ships `unsigned`. `ed25519` is reserved for v2 — when the
/// Sankofa key-management story lands the SDK can refuse patches that
/// aren't signed by a project-bound public key.
enum KbcSigAlg {
  unsigned, // 0
  ed25519, // 1 (future)
}

/// Result of parsing a SANKOFA_KBC_ENVELOPE.
///
/// Callers should fail-closed if [payloadShaValid] is false — a SHA
/// mismatch means the envelope is tampered or truncated; the KBC
/// payload MUST NOT be handed to the interpreter.
class ParsedKbcEnvelope {
  ParsedKbcEnvelope({
    required this.envelopeVersion,
    required this.flags,
    required this.payloadSha,
    required this.metadata,
    required this.kbcPayload,
    required this.sigAlg,
    required this.sigBytes,
    required this.payloadShaValid,
    required this.totalSize,
  });

  final int envelopeVersion;
  final int flags;
  final Uint8List payloadSha;
  final Map<String, dynamic> metadata;
  final Uint8List kbcPayload;
  final KbcSigAlg sigAlg;
  final Uint8List sigBytes;

  /// True iff sha-256(kbcPayload) matches the SHA carried in the
  /// header. Always check this before passing kbcPayload onward.
  final bool payloadShaValid;

  /// Total bytes consumed from the input buffer (= envelope file size).
  final int totalSize;
}

/// Raised when an envelope is malformed or fails integrity checks.
///
/// The message is suitable for logging — it identifies which field
/// failed without leaking sensitive payload data.
class KbcEnvelopeFormatException implements Exception {
  KbcEnvelopeFormatException(this.message);
  final String message;
  @override
  String toString() => 'KbcEnvelopeFormatException: $message';
}

/// Parse + validate a SANKOFA_KBC_ENVELOPE buffer.
///
/// Throws [KbcEnvelopeFormatException] on:
///  * truncated input (< header + trailer)
///  * wrong magic
///  * unsupported envelope version
///  * truncated body / signature trailer
///  * malformed metadata JSON
///
/// Does NOT verify the signature. v1 always ships unsigned;
/// signature verification belongs to a future helper that knows the
/// project's pubkey.
ParsedKbcEnvelope parseKbcEnvelope(Uint8List input) {
  if (input.length < _headerSize + _trailerFixedSize) {
    throw KbcEnvelopeFormatException(
      'envelope too short: ${input.length} bytes < ${_headerSize + _trailerFixedSize}',
    );
  }

  for (var i = 0; i < 4; i++) {
    if (input[i] != _magicBytes[i]) {
      final got =
          input.sublist(0, 4).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      throw KbcEnvelopeFormatException(
        'envelope magic mismatch: got 0x$got, expected 0x534b4450 ("SKDP")',
      );
    }
  }

  final bd = ByteData.sublistView(input);
  final version = bd.getUint16(4, Endian.little);
  if (version != envelopeVersion) {
    throw KbcEnvelopeFormatException(
      'envelope version $version not supported (parser handles v$envelopeVersion)',
    );
  }
  final flags = bd.getUint16(6, Endian.little);
  final kbcLength = bd.getUint32(8, Endian.little);
  final metaLength = bd.getUint32(12, Endian.little);
  // 16..20 reserved
  final payloadSha = Uint8List.fromList(input.sublist(20, 52));

  final expectedBodySize = _headerSize + metaLength + kbcLength;
  if (input.length < expectedBodySize + _trailerFixedSize) {
    throw KbcEnvelopeFormatException(
      'envelope truncated: body+trailer should be ${expectedBodySize + _trailerFixedSize} bytes, file is ${input.length}',
    );
  }

  final metaBytes = input.sublist(_headerSize, _headerSize + metaLength);
  final kbcPayload =
      Uint8List.fromList(input.sublist(_headerSize + metaLength, _headerSize + metaLength + kbcLength));

  Map<String, dynamic> metadata;
  try {
    final decoded = jsonDecode(utf8.decode(metaBytes));
    if (decoded is! Map) {
      throw const FormatException('metadata is not a JSON object');
    }
    metadata = Map<String, dynamic>.from(decoded);
  } on FormatException catch (err) {
    throw KbcEnvelopeFormatException('metadata JSON malformed: ${err.message}');
  }

  final trailerOffset = expectedBodySize;
  final sigAlgRaw = input[trailerOffset];
  // skip reserved at trailerOffset+1
  final sigLength = bd.getUint16(trailerOffset + 2, Endian.little);
  final sigStart = trailerOffset + _trailerFixedSize;
  final sigEnd = sigStart + sigLength;
  if (input.length < sigEnd) {
    throw KbcEnvelopeFormatException(
      'signature trailer truncated: declared $sigLength bytes, but ${input.length - sigStart} bytes remaining',
    );
  }
  final sigBytes = Uint8List.fromList(input.sublist(sigStart, sigEnd));
  final sigAlg = switch (sigAlgRaw) {
    0 => KbcSigAlg.unsigned,
    1 => KbcSigAlg.ed25519,
    _ => throw KbcEnvelopeFormatException(
          'unknown signature algorithm $sigAlgRaw',
        ),
  };

  final actualSha = Uint8List.fromList(sha256.convert(kbcPayload).bytes);
  final payloadShaValid = _bytesEqual(actualSha, payloadSha);

  return ParsedKbcEnvelope(
    envelopeVersion: version,
    flags: flags,
    payloadSha: payloadSha,
    metadata: metadata,
    kbcPayload: kbcPayload,
    sigAlg: sigAlg,
    sigBytes: sigBytes,
    payloadShaValid: payloadShaValid,
    totalSize: sigEnd,
  );
}

/// Verify the Ed25519 signature carried in the envelope trailer against
/// a 32-byte Ed25519 public key. Returns true iff the signature is valid
/// over bytes [0..trailerOffset) of the original envelope buffer.
///
/// MUST be called with the raw bytes of the envelope file (not the
/// parsed view), since the parser doesn't retain the original buffer.
/// Pass `pubkeyB64` as standard base64 of the 32-byte raw point — same
/// format `sankofa keys generate` emits.
///
/// Returns false on any failure (wrong sig_alg, malformed pubkey,
/// signature mismatch) — never throws so callers can fail-closed
/// without try/catch noise.
Future<bool> verifyKbcEnvelopeSignature({
  required Uint8List envelopeBytes,
  required ParsedKbcEnvelope parsed,
  required String pubkeyB64,
}) async {
  if (parsed.sigAlg != KbcSigAlg.ed25519) return false;
  if (parsed.sigBytes.length != 64) return false;
  final Uint8List rawPub;
  try {
    // Tolerate missing trailing `=` padding — some sources strip it.
    final trimmed = pubkeyB64.trim();
    final padded = trimmed.padRight((trimmed.length + 3) & ~3, '=');
    rawPub = base64.decode(padded);
  } catch (_) {
    return false;
  }
  if (rawPub.length != 32) return false;
  // The signature covers everything before the trailer. trailerOffset =
  // totalSize - (4 fixed trailer bytes + sigBytes.length). We don't store
  // trailerOffset on ParsedKbcEnvelope, so recompute from totalSize.
  final trailerOffset = parsed.totalSize - 4 - parsed.sigBytes.length;
  if (trailerOffset < 0 || trailerOffset > envelopeBytes.length) return false;
  final signedBytes = Uint8List.sublistView(envelopeBytes, 0, trailerOffset);

  final ed = Ed25519();
  final pubKey = SimplePublicKey(rawPub, type: KeyPairType.ed25519);
  final signature = Signature(parsed.sigBytes, publicKey: pubKey);
  try {
    return await ed.verify(signedBytes, signature: signature);
  } catch (_) {
    return false;
  }
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
