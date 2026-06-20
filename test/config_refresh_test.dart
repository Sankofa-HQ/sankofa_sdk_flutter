import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sankofa_flutter/src/config/sankofa_config.dart';

/// Locks the user-facing `SankofaConfig.refresh()` contract — the
/// Firebase-style manual fetch with a per-call `minimumFetchInterval`
/// override. The throttle itself lives in the core (handshake re-fetch)
/// and is exercised end-to-end; here we pin the delegation so a refactor
/// can't silently break the public API call sites depend on.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('SankofaConfig.refresh', () {
    test('returns false when no refresher is bound (pre-init)', () async {
      final cfg = SankofaConfig();
      expect(await cfg.refresh(), isFalse);
      expect(await cfg.refresh(force: true), isFalse);
    });

    test('forwards the per-call interval + force to the bound refresher',
        () async {
      final cfg = SankofaConfig();
      Duration? seenInterval;
      bool? seenForce;
      cfg.bindRefresher((interval, force) async {
        seenInterval = interval;
        seenForce = force;
        return true;
      });

      final ran = await cfg.refresh(
        minimumFetchInterval: const Duration(minutes: 5),
        force: true,
      );

      expect(ran, isTrue, reason: 'returns the refresher result');
      expect(seenInterval, const Duration(minutes: 5));
      expect(seenForce, isTrue);
    });

    test('defaults to null interval + false force (use init default, honor throttle)',
        () async {
      final cfg = SankofaConfig();
      Duration? seenInterval = const Duration(days: 1); // sentinel
      bool seenForce = true; // sentinel
      cfg.bindRefresher((interval, force) async {
        seenInterval = interval;
        seenForce = force;
        return false;
      });

      final ran = await cfg.refresh();

      expect(ran, isFalse);
      expect(seenInterval, isNull,
          reason: 'null → core falls back to configFetchInterval');
      expect(seenForce, isFalse);
    });
  });
}
