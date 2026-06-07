import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sankofa_flutter/sankofa_flutter.dart';

/// Covers the targeting fixes:
///  1. URL rules are dropped on Flutter (web-only) so they can't block a
///     survey under the dashboard's AND semantics.
///  2. Cohort / user_property / feature_flag context is honored via the
///     default + per-call override paths.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final pulse = SankofaPulse.instance;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // Reset host-default context between tests.
    pulse.setDefaultTargetingContext(
      userProperties: {},
      cohorts: {},
      flagValues: {},
    );
    pulse.debugSetServerCohorts({});
  });

  test('a URL-only rule is dropped → survey is eligible', () {
    final d = pulse.debugEligible('s1', const [
      PulseTargetingRule(
          kind: PulseRuleKind.url, urlMatch: 'contains', urlValue: '/checkout'),
    ]);
    expect(d.eligible, isTrue,
        reason: 'URL rules are web-only and must be ignored on Flutter');
  });

  test('URL + Screen (the NPS case): URL dropped, Screen governs', () {
    // No screen has been tagged on the host, so the Screen rule fails —
    // proving the URL rule was dropped (not satisfied) and Screen now
    // decides eligibility on its own.
    const rules = [
      PulseTargetingRule(
          kind: PulseRuleKind.url, urlMatch: 'contains', urlValue: '/checkout'),
      PulseTargetingRule(
          kind: PulseRuleKind.screen,
          screenMatch: 'equals',
          screenNames: ['Vendor Details']),
    ];
    expect(pulse.debugEligible('nps', rules).eligible, isFalse);
  });

  test('user_property rule matches from default targeting context', () {
    pulse.setDefaultTargetingContext(userProperties: {'plan': 'pro'});
    const ruleHit = PulseTargetingRule(
      kind: PulseRuleKind.userProperty,
      propertyKey: 'plan',
      propertyOp: 'equals',
      propertyValue: 'pro',
    );
    expect(pulse.debugEligible('s', const [ruleHit]).eligible, isTrue);
    const ruleMiss = PulseTargetingRule(
      kind: PulseRuleKind.userProperty,
      propertyKey: 'plan',
      propertyOp: 'equals',
      propertyValue: 'free',
    );
    expect(pulse.debugEligible('s', const [ruleMiss]).eligible, isFalse);
  });

  test('cohort rule matches from server-delivered membership', () {
    pulse.debugSetServerCohorts({'coh_vip': true});
    const hit = PulseTargetingRule(kind: PulseRuleKind.cohort, cohortId: 'coh_vip');
    expect(pulse.debugEligible('s', const [hit]).eligible, isTrue);
    const miss = PulseTargetingRule(kind: PulseRuleKind.cohort, cohortId: 'coh_other');
    expect(pulse.debugEligible('s', const [miss]).eligible, isFalse);
  });

  test('per-call cohort override beats empty server membership', () {
    const rule = PulseTargetingRule(kind: PulseRuleKind.cohort, cohortId: 'coh_beta');
    expect(pulse.debugEligible('s', const [rule]).eligible, isFalse);
    expect(
      pulse.debugEligible('s', const [rule], cohorts: {'coh_beta': true}).eligible,
      isTrue,
    );
  });

  test('empty rule list is eligible', () {
    expect(pulse.debugEligible('s', const []).eligible, isTrue);
  });
}
