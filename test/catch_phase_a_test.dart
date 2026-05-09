import 'package:flutter_test/flutter_test.dart';
import 'package:sankofa_flutter/sankofa_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Phase-A contract tests for the Crashlytics+Sentry-merged ergonomic
/// surface — pins the singleton + static-helper behaviour so future
/// refactors don't quietly break the ONE-LINE host integration.
///
/// These don't go over the network — we just verify the JS-equivalent
/// "did the helper find the singleton, did it route correctly" path.
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // Flush any singleton left from a previous test so each starts clean.
    SankofaCatch.instance?.shutdown();
  });

  tearDown(() {
    SankofaCatch.instance?.shutdown();
  });

  group('SankofaCatch singleton', () {
    test('first construction wins; second construction is a no-op', () {
      final first = SankofaCatch(environment: 'test');
      expect(SankofaCatch.instance, same(first));

      // A second construction (e.g. accidental host duplication, hot-
      // reload race) must not shadow the active instance.
      final second = SankofaCatch(environment: 'test');
      expect(SankofaCatch.instance, same(first));
      // The constructor still returned a separate object, but it's
      // not reachable from the singleton — host code that reaches
      // through `SankofaCatch.instance` always gets the original.
      expect(identical(first, second), isFalse);
    });

    test('shutdown clears the singleton and a fresh instance can take over', () {
      final first = SankofaCatch(environment: 'test');
      first.shutdown();
      expect(SankofaCatch.instance, isNull);

      final second = SankofaCatch(environment: 'test');
      expect(SankofaCatch.instance, same(second));
    });
  });

  group('Sankofa static helpers', () {
    test('all helpers degrade to no-op when Catch is not initialised', () {
      // No SankofaCatch constructed — everything below should do
      // nothing instead of throwing.  This is the "host called
      // Sankofa.captureException too early or with catch disabled"
      // case and it MUST be safe.
      expect(SankofaCatch.instance, isNull);

      expect(() => Sankofa.captureException(StateError('handled')), returnsNormally);
      expect(() => Sankofa.captureMessage('hello'), returnsNormally);
      expect(() => Sankofa.log('breadcrumb'), returnsNormally);
      expect(() => Sankofa.setTag('feature', 'billing'), returnsNormally);
      expect(() => Sankofa.setTags({'a': 'b'}), returnsNormally);
      expect(() => Sankofa.setExtra('key', 42), returnsNormally);
      expect(() => Sankofa.setUser(const CatchUserContext(id: 'u1')), returnsNormally);
      expect(() => Sankofa.addBreadcrumb(CatchBreadcrumb(type: 'log')), returnsNormally);
      expect(Sankofa.captureException(StateError('handled')), '');
      expect(Sankofa.captureMessage('hello'), '');
    });

    test('helpers route to the active SankofaCatch singleton', () async {
      final catcher = SankofaCatch(environment: 'test');

      Sankofa.setUser(const CatchUserContext(id: 'user_42'));
      Sankofa.setTag('feature', 'billing');
      Sankofa.log('user clicked checkout');

      // captureException returns a non-empty event id when wired up.
      final id = Sankofa.captureException(StateError('handled'));
      expect(id, isNotEmpty);

      // The helpers all read from the SAME instance — capturing once
      // through the static path and once through the instance path
      // should land in the same buffer.
      Sankofa.captureMessage('static path');
      catcher.captureMessage('instance path');
      // (We're not asserting buffer contents here — that would couple
      // to internal state — but both calls must return without error
      // and the singleton stays intact.)
      expect(SankofaCatch.instance, same(catcher));
    });
  });
}
