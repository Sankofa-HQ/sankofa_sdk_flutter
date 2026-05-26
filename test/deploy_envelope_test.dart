// Sankofa Deploy — Dart-side parser + verifier tests.
//
// Covers the pure-function surface (envelope parse + Ed25519 verify);
// the SankofaDeploy boot-apply / rollback / telemetry paths depend on
// Flutter platform channels and live in deploy_boot_apply_test.dart
// (TODO).
//
// Wire-format compat is the load-bearing thing: producer (CLI),
// consumer (this SDK), and gate (server) all hand-roll the same
// SANKOFA_KBC_ENVELOPE layout, so any drift here is a real bug we
// catch at compile time but the byte-level tests double-check.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:cryptography/cryptography.dart' show Ed25519;
import 'package:flutter_test/flutter_test.dart';
import 'package:sankofa_flutter/src/deploy/kbc_envelope.dart';

const _magic = [0x53, 0x4b, 0x44, 0x50]; // SKDP

/// Builds a sig_alg=0 (unsigned) envelope by hand. Mirrors the CLI's
/// wrapKbc — keeps these tests as a real cross-implementation oracle.
Uint8List buildUnsignedEnvelope({
  required Uint8List kbcPayload,
  required Map<String, dynamic> metadata,
}) {
  final metaBytes = Uint8List.fromList(utf8.encode(jsonEncode(metadata)));
  const headerSize = 52;
  const trailerFixed = 4;
  final bodySize = headerSize + metaBytes.length + kbcPayload.length;
  final total = bodySize + trailerFixed;
  final buf = Uint8List(total);

  buf.setRange(0, 4, _magic);
  final bd = ByteData.sublistView(buf);
  bd.setUint16(4, 1, Endian.little); // version
  bd.setUint16(6, 0, Endian.little); // flags
  bd.setUint32(8, kbcPayload.length, Endian.little);
  bd.setUint32(12, metaBytes.length, Endian.little);
  bd.setUint32(16, 0, Endian.little);

  final sha = sha256.convert(kbcPayload).bytes;
  buf.setRange(20, 52, sha);
  buf.setRange(headerSize, headerSize + metaBytes.length, metaBytes);
  buf.setRange(
    headerSize + metaBytes.length,
    headerSize + metaBytes.length + kbcPayload.length,
    kbcPayload,
  );
  // Trailer (sig_alg=0, reserved=0, sig_length=0) — zero-init.
  return buf;
}

/// Builds a sig_alg=1 (Ed25519) envelope signed with [signKey]. The
/// host of the test passes back the raw 32-byte pubkey so verify can
/// be exercised against the matching key.
Future<Uint8List> buildSignedEnvelope({
  required Uint8List kbcPayload,
  required Map<String, dynamic> metadata,
  required dynamic signKeyPair,
  required Ed25519 ed,
}) async {
  final metaBytes = Uint8List.fromList(utf8.encode(jsonEncode(metadata)));
  const headerSize = 52;
  const trailerFixed = 4;
  const sigLen = 64;
  final bodySize = headerSize + metaBytes.length + kbcPayload.length;
  final total = bodySize + trailerFixed + sigLen;
  final buf = Uint8List(total);

  buf.setRange(0, 4, _magic);
  final bd = ByteData.sublistView(buf);
  bd.setUint16(4, 1, Endian.little);
  bd.setUint16(6, 0, Endian.little);
  bd.setUint32(8, kbcPayload.length, Endian.little);
  bd.setUint32(12, metaBytes.length, Endian.little);
  bd.setUint32(16, 0, Endian.little);
  final sha = sha256.convert(kbcPayload).bytes;
  buf.setRange(20, 52, sha);
  buf.setRange(headerSize, headerSize + metaBytes.length, metaBytes);
  buf.setRange(
    headerSize + metaBytes.length,
    headerSize + metaBytes.length + kbcPayload.length,
    kbcPayload,
  );
  // Trailer header: sig_alg=1, reserved=0, sig_length=64.
  buf[bodySize] = 1;
  buf[bodySize + 1] = 0;
  bd.setUint16(bodySize + 2, sigLen, Endian.little);
  // Sign bytes[0..bodySize).
  final signedBytes = Uint8List.sublistView(buf, 0, bodySize);
  final signature = await ed.sign(signedBytes, keyPair: signKeyPair);
  buf.setRange(bodySize + trailerFixed, bodySize + trailerFixed + sigLen, signature.bytes);
  return buf;
}

void main() {
  group('parseKbcEnvelope', () {
    test('round-trips an unsigned envelope', () {
      final payload = Uint8List.fromList([0x33, 0x43, 0x42, 0x44, 1, 2, 3]); // DBC3 + body
      final env = buildUnsignedEnvelope(
        kbcPayload: payload,
        metadata: {'label': 'beta3-test', 'engineCommit': 'abc123'},
      );
      final parsed = parseKbcEnvelope(env);
      expect(parsed.envelopeVersion, 1);
      expect(parsed.kbcPayload, equals(payload));
      expect(parsed.payloadShaValid, isTrue);
      expect(parsed.sigAlg, KbcSigAlg.unsigned);
      expect(parsed.metadata['label'], 'beta3-test');
    });

    test('rejects bad magic', () {
      final env = buildUnsignedEnvelope(
        kbcPayload: Uint8List.fromList([0x33, 0x43, 0x42, 0x44]),
        metadata: {},
      );
      env[0] = 0x00; // break the magic
      expect(() => parseKbcEnvelope(env), throwsA(isA<KbcEnvelopeFormatException>()));
    });

    test('rejects truncated body', () {
      final env = buildUnsignedEnvelope(
        kbcPayload: Uint8List.fromList([0x33, 0x43, 0x42, 0x44]),
        metadata: {},
      );
      final truncated = Uint8List.sublistView(env, 0, env.length - 10);
      expect(() => parseKbcEnvelope(truncated), throwsA(isA<KbcEnvelopeFormatException>()));
    });

    test('flags sha mismatch (does NOT throw)', () {
      final env = buildUnsignedEnvelope(
        kbcPayload: Uint8List.fromList([0x33, 0x43, 0x42, 0x44, 9, 9]),
        metadata: {},
      );
      // Flip a byte INSIDE the kbc payload region — sha header field
      // stays the same so the recomputed sha differs.
      env[57] ^= 0xff; // mid-payload
      final parsed = parseKbcEnvelope(env);
      expect(parsed.payloadShaValid, isFalse);
    });
  });

  group('verifyKbcEnvelopeSignature', () {
    late Ed25519 ed;
    setUp(() {
      ed = Ed25519();
    });

    test('returns false for unsigned envelopes', () async {
      final env = buildUnsignedEnvelope(
        kbcPayload: Uint8List.fromList([0x33, 0x43, 0x42, 0x44]),
        metadata: {},
      );
      final parsed = parseKbcEnvelope(env);
      final ok = await verifyKbcEnvelopeSignature(
        envelopeBytes: env,
        parsed: parsed,
        pubkeysB64: ['anything'],
      );
      expect(ok, isFalse);
    });

    test('returns false when pubkey list is empty', () async {
      final keyPair = await ed.newKeyPair();
      final env = await buildSignedEnvelope(
        kbcPayload: Uint8List.fromList([0x33, 0x43, 0x42, 0x44]),
        metadata: {},
        signKeyPair: keyPair,
        ed: ed,
      );
      final parsed = parseKbcEnvelope(env);
      final ok = await verifyKbcEnvelopeSignature(
        envelopeBytes: env,
        parsed: parsed,
        pubkeysB64: const [],
      );
      expect(ok, isFalse);
    });

    test('accepts valid signature against matching pubkey', () async {
      final keyPair = await ed.newKeyPair();
      final pub = await keyPair.extractPublicKey();
      final pubB64 = base64.encode(pub.bytes);
      final env = await buildSignedEnvelope(
        kbcPayload: Uint8List.fromList([0x33, 0x43, 0x42, 0x44, 1, 2, 3]),
        metadata: {'label': 'signed-test'},
        signKeyPair: keyPair,
        ed: ed,
      );
      final parsed = parseKbcEnvelope(env);
      final ok = await verifyKbcEnvelopeSignature(
        envelopeBytes: env,
        parsed: parsed,
        pubkeysB64: [pubB64],
      );
      expect(ok, isTrue);
    });

    test('rejects signature under different pubkey', () async {
      final signer = await ed.newKeyPair();
      final other = await ed.newKeyPair();
      final otherPub = await other.extractPublicKey();
      final env = await buildSignedEnvelope(
        kbcPayload: Uint8List.fromList([0x33, 0x43, 0x42, 0x44]),
        metadata: {},
        signKeyPair: signer,
        ed: ed,
      );
      final parsed = parseKbcEnvelope(env);
      final ok = await verifyKbcEnvelopeSignature(
        envelopeBytes: env,
        parsed: parsed,
        pubkeysB64: [base64.encode(otherPub.bytes)],
      );
      expect(ok, isFalse);
    });

    test('any-match across multi-key list (rotation)', () async {
      final wrong = await ed.newKeyPair();
      final wrongPub = await wrong.extractPublicKey();
      final right = await ed.newKeyPair();
      final rightPub = await right.extractPublicKey();
      final env = await buildSignedEnvelope(
        kbcPayload: Uint8List.fromList([0x33, 0x43, 0x42, 0x44]),
        metadata: {},
        signKeyPair: right,
        ed: ed,
      );
      final parsed = parseKbcEnvelope(env);
      final ok = await verifyKbcEnvelopeSignature(
        envelopeBytes: env,
        parsed: parsed,
        pubkeysB64: [base64.encode(wrongPub.bytes), base64.encode(rightPub.bytes)],
      );
      expect(ok, isTrue);
    });

    test('rejects tampered envelope', () async {
      final keyPair = await ed.newKeyPair();
      final pub = await keyPair.extractPublicKey();
      final env = await buildSignedEnvelope(
        kbcPayload: Uint8List.fromList([0x33, 0x43, 0x42, 0x44, 1, 2, 3]),
        metadata: {'label': 'signed'},
        signKeyPair: keyPair,
        ed: ed,
      );
      // Flip a byte INSIDE the metadata JSON. May break JSON parse;
      // if so we skip. Otherwise the signature should fail to verify.
      env[55] ^= 0x01;
      try {
        final parsed = parseKbcEnvelope(env);
        final ok = await verifyKbcEnvelopeSignature(
          envelopeBytes: env,
          parsed: parsed,
          pubkeysB64: [base64.encode(pub.bytes)],
        );
        expect(ok, isFalse, reason: 'tampered body should NOT verify');
      } on KbcEnvelopeFormatException {
        // Parse-level rejection is also a valid fail-closed outcome.
      }
    });

    test('tolerates missing base64 padding in pubkey', () async {
      final keyPair = await ed.newKeyPair();
      final pub = await keyPair.extractPublicKey();
      final padded = base64.encode(pub.bytes);
      final unpadded = padded.replaceAll('=', '');
      final env = await buildSignedEnvelope(
        kbcPayload: Uint8List.fromList([0x33, 0x43, 0x42, 0x44]),
        metadata: {},
        signKeyPair: keyPair,
        ed: ed,
      );
      final parsed = parseKbcEnvelope(env);
      final ok = await verifyKbcEnvelopeSignature(
        envelopeBytes: env,
        parsed: parsed,
        pubkeysB64: [unpadded],
      );
      expect(ok, isTrue);
    });
  });
}
