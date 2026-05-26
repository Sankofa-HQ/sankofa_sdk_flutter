// Sankofa Deploy — boot-apply + auto-rollback integration tests.
//
// Exercises tryApplyStagedKbcPatch end-to-end with mocked path_provider
// and a real file on disk. Validates the safety machinery that
// prevents one bad patch from crash-looping every device:
//
//   - missing patch file → returns null cleanly
//   - valid envelope     → applies, returns result
//   - boot counter ticks → repeated cold-boots without notifyKbcPatch
//                          Ready accumulate
//   - threshold crossed  → patch moves to .disabled-<ts>, returns null
//   - notifyKbcPatchReady resets the counter so a clean patch survives
//
// path_provider is mocked via TestDefaultBinaryMessenger so the test
// runs without a real ApplicationDocumentsDirectory.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sankofa_flutter/src/deploy/deploy_config.dart';
import 'package:sankofa_flutter/src/deploy/kbc_loader.dart' show KbcPatchResult;
import 'package:sankofa_flutter/src/deploy/sankofa_deploy.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Wire-format helper. Same envelope shape as the CLI's wrapKbc, just
/// the unsigned variant — we're not testing signature verify here.
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
  // Trailer (sig_alg=0, reserved=0, sig_length=0) — zero-init already.
  return buf;
}

late Directory _tempDocs;
late String _patchDir;
late String _patchPath;
late String _lastGoodPath;
const _kBootCounterKey = 'sankofa.deploy.kbc.boot_counter';
const _kBannedLabelsKey = 'sankofa.deploy.kbc.banned_labels';

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

Future<SankofaDeploy> _initTestDeploy({String? pubkeyB64}) async {
  return SankofaDeploy.initInternal(
    apiKey: 'sk_test_dummy',
    endpoint: 'http://127.0.0.1:0',
    options: SankofaDeployOptions(signingPubkeyB64: pubkeyB64),
  );
}

void _stageValidPatch({String label = 'cold-boot-test'}) {
  // Inner KBC payload must start with DBC3 magic, otherwise
  // applyKbcEnvelope rejects with "envelope wraps non-KBC payload".
  final kbc = Uint8List.fromList([0x33, 0x43, 0x42, 0x44, 1, 2, 3]);
  final env = buildUnsignedEnvelope(
    kbcPayload: kbc,
    metadata: {'label': label, 'dartVersion': '3.11.5'},
  );
  Directory(_patchDir).createSync(recursive: true);
  File(_patchPath).writeAsBytesSync(env, flush: true);
}

/// A loader that pretends Interpreter::Run returned a fixed JSON. Lets
/// the apply pipeline exercise its post-loader plumbing (telemetry,
/// boot-counter, etc.) without needing the real engine.
Future<Object?> _fakeLoader(Uint8List _) async {
  return '{"applied":true}';
}

/// A loader that throws — simulates a patch crashing in
/// Interpreter::Run. The SDK should propagate it through KbcApplyException
/// AND the next boot should see the counter still ticking up.
Future<Object?> _throwingLoader(Uint8List _) async {
  throw StateError('interpreter went boom');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _tempDocs = await Directory.systemTemp.createTemp('sankofa-test-');
    _patchDir = '${_tempDocs.path}/sankofa-deploy/patches/active';
    _patchPath = '$_patchDir/patch.skdp';
    _lastGoodPath = '${_tempDocs.path}/sankofa-deploy/patches/last_good/patch.skdp';
    _mockPathProvider();
  });

  tearDown(() async {
    try {
      _tempDocs.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('tryApplyStagedKbcPatch', () {
    test('returns null when no patch is staged', () async {
      final deploy = await _initTestDeploy();
      final result = await deploy.tryApplyStagedKbcPatch(loader: _fakeLoader);
      expect(result, isNull);
      // No patch + no apply attempt means the boot-counter should NOT
      // have ticked. Critical: we should never count a missing file
      // against the rollback threshold.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey(_kBootCounterKey), isFalse);
    });

    test('applies a valid staged patch and returns the result', () async {
      _stageValidPatch();
      final deploy = await _initTestDeploy();
      final result = await deploy.tryApplyStagedKbcPatch(loader: _fakeLoader);
      expect(result, isA<KbcPatchResult>());
      expect(result!.returnValue, '{"applied":true}');
      expect(result.metadata['label'], 'cold-boot-test');
    });

    test('boot counter ticks up on every cold-boot apply', () async {
      _stageValidPatch();
      final deploy = await _initTestDeploy();
      for (var i = 0; i < 3; i++) {
        final r = await deploy.tryApplyStagedKbcPatch(loader: _fakeLoader);
        expect(r, isNotNull, reason: 'boot $i should still apply');
      }
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(_kBootCounterKey), 3);
    });

    test('auto-disables after threshold (kbcRollbackThreshold + 1)', () async {
      _stageValidPatch(label: 'crashy-patch-v9');
      final deploy = await _initTestDeploy();
      // Simulate the threshold being already crossed by seeding the
      // counter directly — same effect as N consecutive boots that
      // never reached notifyKbcPatchReady.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kBootCounterKey, SankofaDeploy.kbcRollbackThreshold);

      // The NEXT boot (threshold+1) trips the gate.
      final result = await deploy.tryApplyStagedKbcPatch(loader: _fakeLoader);
      expect(result, isNull, reason: 'auto-disable should refuse to apply');

      // The patch.skdp must have been renamed aside, not left in place
      // to crash on subsequent boots.
      expect(File(_patchPath).existsSync(), isFalse,
          reason: 'auto-disable should move patch.skdp out of the active slot');
      // Disabled files now live in a sibling `disabled/` subdir, not
      // under active/ — keeps the active dir clean for the next patch.
      final disabledDir = Directory('${_tempDocs.path}/sankofa-deploy/patches/disabled');
      final disabledFiles = disabledDir.existsSync()
          ? disabledDir
              .listSync()
              .where((f) => f.path.contains('patch.skdp.disabled-'))
              .toList()
          : <FileSystemEntity>[];
      expect(disabledFiles, isNotEmpty,
          reason: 'auto-disabled patch must land at disabled/patch.skdp.disabled-<ts>');

      // Boot counter must reset so a NEW staged patch isn't immediately
      // killed by the previous one's leftover boot count.
      expect(prefs.containsKey(_kBootCounterKey), isFalse);

      // The label of the rolled-back patch is preserved for the next
      // consume call.
      final label = await deploy.consumeLastAutoDisabledPatchLabel();
      expect(label, 'crashy-patch-v9');
    });

    test('notifyKbcPatchReady prevents auto-disable on a clean patch',
        () async {
      _stageValidPatch();
      final deploy = await _initTestDeploy();
      // Apply + notify several times — simulates a clean patch
      // surviving many cold boots. Counter should never accumulate
      // because notify always clears it.
      for (var i = 0; i < 10; i++) {
        await deploy.tryApplyStagedKbcPatch(loader: _fakeLoader);
        await deploy.notifyKbcPatchReady();
      }
      // Patch must still be on disk, counter must be 0.
      expect(File(_patchPath).existsSync(), isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(_kBootCounterKey) ?? 0, 0);
    });

    test('loader throws → returns null (rollback path stays active)', () async {
      _stageValidPatch();
      final deploy = await _initTestDeploy();
      final result =
          await deploy.tryApplyStagedKbcPatch(loader: _throwingLoader);
      expect(result, isNull, reason: 'loader throw must be swallowed');
      // Counter still ticked — that's the whole point of the rollback
      // safety net. After enough throws, the rollback kicks in.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(_kBootCounterKey), 1);
      // Patch still on disk; only the threshold gate moves it aside.
      expect(File(_patchPath).existsSync(), isTrue);
    });

    test('missing patch file does not interact with prefs', () async {
      // Ensure tryApplyStagedKbcPatch is fully no-op when there's no
      // file, even after a previous boot's counter sat in prefs.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kBootCounterKey, 2);
      final deploy = await _initTestDeploy();
      final result = await deploy.tryApplyStagedKbcPatch(loader: _fakeLoader);
      expect(result, isNull);
      // Counter unchanged — we didn't apply, didn't tick, didn't reset.
      expect(prefs.getInt(_kBootCounterKey), 2);
    });
  });

  group('last_good slot + auto-restore on rollback', () {
    test('notifyKbcPatchReady promotes active → last_good', () async {
      _stageValidPatch(label: 'p1');
      final deploy = await _initTestDeploy();
      await deploy.tryApplyStagedKbcPatch(loader: _fakeLoader);
      // Pre-promote: last_good must not exist.
      expect(File(_lastGoodPath).existsSync(), isFalse);
      await deploy.notifyKbcPatchReady();
      expect(File(_lastGoodPath).existsSync(), isTrue,
          reason: 'notify must copy active → last_good');
      // File bytes must match — promote is a copy, not just a marker.
      expect(File(_lastGoodPath).readAsBytesSync(),
          equals(File(_patchPath).readAsBytesSync()));
    });

    test('rollback restores last_good when threshold trips', () async {
      // p1 was promoted (stored under last_good).
      _stageValidPatch(label: 'p1-good');
      final deploy = await _initTestDeploy();
      await deploy.tryApplyStagedKbcPatch(loader: _fakeLoader);
      await deploy.notifyKbcPatchReady();
      final p1Bytes = File(_lastGoodPath).readAsBytesSync();

      // p2 ships, replaces active. Three crashes later, the rollback
      // gate trips and restores last_good (= p1).
      _stageValidPatch(label: 'p2-bad');
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kBootCounterKey, SankofaDeploy.kbcRollbackThreshold);
      final result = await deploy.tryApplyStagedKbcPatch(loader: _fakeLoader);
      expect(result, isNull, reason: 'rollback should skip apply');

      // active must now equal p1 (restored), NOT p2 (rolled back), and
      // NOT empty (no full-baseline drop).
      expect(File(_patchPath).existsSync(), isTrue,
          reason: 'active must be restored, not just emptied');
      expect(File(_patchPath).readAsBytesSync(), equals(p1Bytes),
          reason: 'restored active must match last_good content');

      // p2 label should be in the banned set so the next fetch
      // doesn't re-download it.
      final banned = await deploy.getBannedKbcLabels();
      expect(banned, contains('p2-bad'));
      expect(banned, isNot(contains('p1-good')));
    });

    test('rollback falls to baseline when no last_good exists', () async {
      // First-ever patch crashes immediately — no last_good to fall
      // back to. Legacy behavior: active is moved aside, baseline boots.
      _stageValidPatch(label: 'first-patch-crashy');
      final deploy = await _initTestDeploy();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kBootCounterKey, SankofaDeploy.kbcRollbackThreshold);
      await deploy.tryApplyStagedKbcPatch(loader: _fakeLoader);
      // active is gone, no last_good to restore from.
      expect(File(_patchPath).existsSync(), isFalse);
      expect(File(_lastGoodPath).existsSync(), isFalse);
      // Label is still banned.
      final banned = await deploy.getBannedKbcLabels();
      expect(banned, contains('first-patch-crashy'));
    });

    test('rollback refuses to restore a last_good that is itself banned',
        () async {
      // Pathological: last_good label was somehow added to banned set
      // (e.g. customer manually banned it via API in a future build).
      // Restore should bail rather than apply a banned patch.
      _stageValidPatch(label: 'p1');
      final deploy = await _initTestDeploy();
      await deploy.tryApplyStagedKbcPatch(loader: _fakeLoader);
      await deploy.notifyKbcPatchReady();
      // p1 is now in last_good. Ban it.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kBannedLabelsKey, 'p1');

      // Trip rollback on a different active patch.
      _stageValidPatch(label: 'p2');
      await prefs.setInt(_kBootCounterKey, SankofaDeploy.kbcRollbackThreshold);
      await deploy.tryApplyStagedKbcPatch(loader: _fakeLoader);
      // active should be EMPTY — last_good (p1) was rejected because banned.
      expect(File(_patchPath).existsSync(), isFalse);
    });
  });

  group('banned-labels API', () {
    test('getBannedKbcLabels returns empty when none banned', () async {
      final deploy = await _initTestDeploy();
      expect(await deploy.getBannedKbcLabels(), isEmpty);
    });

    test('clearBannedKbcLabels removes the set + returns previous contents',
        () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kBannedLabelsKey, 'a,b,c');
      final deploy = await _initTestDeploy();
      final cleared = await deploy.clearBannedKbcLabels();
      expect(cleared, equals({'a', 'b', 'c'}));
      expect(await deploy.getBannedKbcLabels(), isEmpty);
    });
  });

  group('getStagedKbcPatchInfo', () {
    setUp(() async {
      _mockPathProvider();
    });

    test('returns null when no patch is staged', () async {
      final deploy = await _initTestDeploy();
      final info = await deploy.getStagedKbcPatchInfo();
      expect(info, isNull);
    });

    test('reports label / signed / size for a staged patch', () async {
      _stageValidPatch(label: 'info-test');
      final deploy = await _initTestDeploy();
      final info = await deploy.getStagedKbcPatchInfo();
      expect(info, isNotNull);
      expect(info!.label, 'info-test');
      expect(info.signed, isFalse);
      expect(info.sizeBytes, greaterThan(52));
      expect(info.path, endsWith('/sankofa-deploy/patches/active/patch.skdp'));
    });
  });
}
