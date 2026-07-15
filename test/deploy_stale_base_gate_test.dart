// Stale-base gate: a staged envelope whose `targetBinaryVersion` does not
// match the running app version must be DISCARDED before apply — never
// crash-tested. The app data container survives a store update, so without
// this gate a patch staged for v1.0 gets transplanted into the v1.1 binary
// (its bytecode was compiled against v1.0's base kernel → boot crash).
//
// These tests run on stock Flutter: the gate fires BEFORE the engine check,
// so a discard is observable as "file deleted"; a gate pass is observable as
// "file still present" (the apply then fails on the stock engine and the
// failure path leaves the file in place).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sankofa_flutter/src/deploy/deploy_config.dart';
import 'package:sankofa_flutter/src/deploy/sankofa_deploy.dart';
import 'package:shared_preferences/shared_preferences.dart';

Uint8List buildUnsignedEnvelope({
  required Uint8List kbcPayload,
  required Map<String, dynamic> metadata,
}) {
  final metaBytes = Uint8List.fromList(utf8.encode(jsonEncode(metadata)));
  const headerSize = 52;
  const trailerFixed = 4;
  final bodySize = headerSize + metaBytes.length + kbcPayload.length;
  final buf = Uint8List(bodySize + trailerFixed);
  buf.setRange(0, 4, [0x53, 0x4b, 0x44, 0x50]); // SKDP
  final bd = ByteData.sublistView(buf);
  bd.setUint16(4, 1, Endian.little);
  bd.setUint16(6, 0, Endian.little);
  bd.setUint32(8, kbcPayload.length, Endian.little);
  bd.setUint32(12, metaBytes.length, Endian.little);
  bd.setUint32(16, 0, Endian.little);
  buf.setRange(20, 52, sha256.convert(kbcPayload).bytes);
  buf.setRange(headerSize, headerSize + metaBytes.length, metaBytes);
  buf.setRange(
    headerSize + metaBytes.length,
    headerSize + metaBytes.length + kbcPayload.length,
    kbcPayload,
  );
  return buf;
}

late Directory _tempDocs;
late String _patchDir;
late String _patchPath;
late String _lastGoodPath;

void _mockPathProvider() {
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
    if (call.method == 'getApplicationDocumentsDirectory') {
      return _tempDocs.path;
    }
    return null;
  });
}

Future<SankofaDeploy> _initTestDeploy({String? appVersion}) async {
  return SankofaDeploy.initInternal(
    apiKey: 'sk_test_dummy',
    endpoint: 'http://127.0.0.1:0',
    options: const SankofaDeployOptions(),
    appVersion: appVersion,
  );
}

void _stagePatch({String? targetBinaryVersion, String label = 'gate-test'}) {
  final kbc = Uint8List.fromList([0x33, 0x43, 0x42, 0x44, 1, 2, 3]); // DBC3
  final env = buildUnsignedEnvelope(
    kbcPayload: kbc,
    metadata: {
      'label': label,
      'dartVersion': '3.11.5',
      if (targetBinaryVersion != null) 'targetBinaryVersion': targetBinaryVersion,
    },
  );
  Directory(_patchDir).createSync(recursive: true);
  File(_patchPath).writeAsBytesSync(env, flush: true);
}

void _stageLastGood() {
  final kbc = Uint8List.fromList([0x33, 0x43, 0x42, 0x44, 9, 9, 9]);
  final env = buildUnsignedEnvelope(
    kbcPayload: kbc,
    metadata: {'label': 'gate-last-good', 'targetBinaryVersion': '1.0.0'},
  );
  Directory(File(_lastGoodPath).parent.path).createSync(recursive: true);
  File(_lastGoodPath).writeAsBytesSync(env, flush: true);
}

Future<Object?> _fakeLoader(Uint8List _) async => '{"applied":true}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _tempDocs = await Directory.systemTemp.createTemp('sankofa-gate-test-');
    _patchDir = '${_tempDocs.path}/sankofa-deploy/patches/active';
    _patchPath = '$_patchDir/patch.skdp';
    _lastGoodPath = '${_tempDocs.path}/sankofa-deploy/patches/last_good/patch.skdp';
    _mockPathProvider();
  });

  tearDown(() async {
    await SankofaDeploy.instance?.shutdown();
    try {
      _tempDocs.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('stale-base gate', () {
    test('fails open when no appVersion is in scope (unknown binary)', () async {
      final deploy = await _initTestDeploy(); // no appVersion
      _stagePatch(targetBinaryVersion: '1.0.0');
      await deploy.tryApplyStagedKbcPatch(loader: _fakeLoader);
      // Gate passed (apply then failed on the stock engine) — file kept.
      expect(File(_patchPath).existsSync(), isTrue,
          reason: 'unknown app version must not discard the patch');
    });

    test('discards a patch built for a DIFFERENT binary + clears last_good',
        () async {
      final deploy = await _initTestDeploy(appVersion: '2.0.0');
      _stagePatch(targetBinaryVersion: '1.0.0', label: 'stale-v1-patch');
      _stageLastGood();
      final result = await deploy.tryApplyStagedKbcPatch(loader: _fakeLoader);
      expect(result, isNull);
      expect(File(_patchPath).existsSync(), isFalse,
          reason: 'a provably-foreign patch must be deleted, not applied');
      expect(File(_lastGoodPath).existsSync(), isFalse,
          reason: 'a stale last_good must not be restorable over the discard');
      // The discard must not poison the rollback machinery: no crash counted,
      // no label banned.
      expect(await deploy.getBannedKbcLabels(), isEmpty);
    });

    test('passes a patch whose targetBinaryVersion matches this binary',
        () async {
      final deploy = await _initTestDeploy(appVersion: '2.0.0');
      _stagePatch(targetBinaryVersion: '2.0.0');
      await deploy.tryApplyStagedKbcPatch(loader: _fakeLoader);
      expect(File(_patchPath).existsSync(), isTrue,
          reason: 'a matching patch must reach the apply path untouched');
    });

    test('fails open for a legacy envelope without targetBinaryVersion',
        () async {
      final deploy = await _initTestDeploy(appVersion: '2.0.0');
      _stagePatch(targetBinaryVersion: null);
      await deploy.tryApplyStagedKbcPatch(loader: _fakeLoader);
      expect(File(_patchPath).existsSync(), isTrue,
          reason: 'pre-metadata patches must behave exactly as before');
    });
  });
}
