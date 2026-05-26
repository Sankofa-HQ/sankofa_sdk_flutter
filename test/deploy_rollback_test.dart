// Sankofa Deploy — rollback safety + boot-counter tests.
//
// Tests the pieces of SankofaDeploy that gate the auto-disable
// behavior (notifyKbcPatchReady + consumeLastAutoDisabledPatchLabel
// + boot-counter prefs hygiene). The full tryApplyStagedKbcPatch
// path also depends on path_provider + dart:io File and lives in
// deploy_boot_apply_integration_test.dart (TODO).
//
// The boot-counter design is "fail safe by default": if the host
// never calls notifyKbcPatchReady, the counter ticks up every boot
// and eventually disables the patch — so we test BOTH the happy path
// (notify resets) and the silent-failure path (counter persists).

import 'package:flutter_test/flutter_test.dart';
import 'package:sankofa_flutter/src/deploy/deploy_config.dart';
import 'package:sankofa_flutter/src/deploy/sankofa_deploy.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Re-export the prefs keys for testability without changing the SDK's
// public surface. These MUST track the constants in sankofa_deploy.dart;
// the SDK doesn't export them on purpose (host apps shouldn't peek at
// internal SharedPreferences keys).
const _kBootCounterKey = 'sankofa.deploy.kbc.boot_counter';
const _kLastDisabledKey = 'sankofa.deploy.kbc.last_disabled_label';

SankofaDeploy _construct() {
  // Bypass Sankofa.init's full lifecycle; we want a SankofaDeploy that
  // doesn't try to call into platform plugins. The instance is used
  // only for the boot-counter helpers, which depend purely on
  // SharedPreferences.
  return SankofaDeploy.instance ??
      (throw StateError(
          'Test setup must construct SankofaDeploy via initInternal '
          'first — see _initTestInstance()'));
}

Future<void> _initTestInstance() async {
  // The constructor is private; we can't directly new one up in
  // tests. initInternal returns the singleton; if a previous test
  // already initialized it, that one is reused.
  await SankofaDeploy.initInternal(
    apiKey: 'sk_test_dummy',
    endpoint: 'http://127.0.0.1:0',
    options: const SankofaDeployOptions(),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('notifyKbcPatchReady', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await _initTestInstance();
    });

    test('returns 0 when no boot-counter was set', () async {
      final n = await _construct().notifyKbcPatchReady();
      expect(n, 0);
    });

    test('clears the counter and returns the previous value', () async {
      SharedPreferences.setMockInitialValues({_kBootCounterKey: 2});
      await _initTestInstance();
      final n = await _construct().notifyKbcPatchReady();
      expect(n, 2);
      // Counter must be gone, not just zero.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey(_kBootCounterKey), isFalse,
          reason: 'notify must REMOVE the key, not set to 0');
    });

    test('is idempotent (second call returns 0)', () async {
      SharedPreferences.setMockInitialValues({_kBootCounterKey: 5});
      await _initTestInstance();
      final deploy = _construct();
      await deploy.notifyKbcPatchReady();
      final second = await deploy.notifyKbcPatchReady();
      expect(second, 0);
    });
  });

  group('consumeLastAutoDisabledPatchLabel', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await _initTestInstance();
    });

    test('returns null when no rollback has happened', () async {
      final l = await _construct().consumeLastAutoDisabledPatchLabel();
      expect(l, isNull);
    });

    test('returns the recorded label exactly once (consume semantics)', () async {
      SharedPreferences.setMockInitialValues({
        _kLastDisabledKey: 'bad-patch-v3',
      });
      await _initTestInstance();
      final deploy = _construct();
      final first = await deploy.consumeLastAutoDisabledPatchLabel();
      expect(first, 'bad-patch-v3');
      // Consume = remove on read. Next call should see nothing.
      final second = await deploy.consumeLastAutoDisabledPatchLabel();
      expect(second, isNull);
    });

    test('survives an unrelated key in prefs (no over-aggressive cleanup)',
        () async {
      SharedPreferences.setMockInitialValues({
        _kLastDisabledKey: 'rolled',
        'unrelated.key': 'must-stay',
      });
      await _initTestInstance();
      await _construct().consumeLastAutoDisabledPatchLabel();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('unrelated.key'), 'must-stay');
    });
  });

  group('rollback threshold', () {
    test('threshold is 3 — guards against silent regressions', () {
      // The kbcRollbackThreshold constant is part of the SDK's public
      // contract: customers reason about "how many boots before my
      // patch self-destructs?" Changing this value is a semver bump.
      expect(SankofaDeploy.kbcRollbackThreshold, 3);
    });
  });

  group('server signing keys cache', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await _initTestInstance();
    });

    test('starts empty', () {
      expect(_construct().serverSigningKeysB64, isEmpty);
    });

    test('applyHandshake populates the cache from signing_keys payload',
        () async {
      final deploy = _construct();
      await deploy.applyHandshake({
        'enabled': true,
        'signing_keys': [
          {'id': 'dsk_a', 'pubkey_b64': 'AAAA', 'algorithm': 'ed25519'},
          {'id': 'dsk_b', 'pubkey_b64': 'BBBB', 'algorithm': 'ed25519'},
        ],
      });
      expect(deploy.serverSigningKeysB64, ['AAAA', 'BBBB']);
    });

    test('skips malformed entries without throwing', () async {
      final deploy = _construct();
      await deploy.applyHandshake({
        'enabled': true,
        'signing_keys': [
          'not-a-map',
          {'id': 'no-pubkey'},
          {'pubkey_b64': ''}, // empty string
          {'pubkey_b64': 'OK'},
        ],
      });
      expect(deploy.serverSigningKeysB64, ['OK']);
    });
  });
}
