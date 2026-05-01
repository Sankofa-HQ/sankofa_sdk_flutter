import 'package:flutter_test/flutter_test.dart';
import 'package:sankofa_flutter/src/pulse/targeting.dart';

/// Targeting evaluator parity test suite. Mirrors
/// `sdks/sankofa_sdk_web/packages/pulse/src/__tests__/targeting.test.ts`
/// verbatim — failures here mean the Flutter SDK will disagree with
/// the Web SDK and Go server about whether a respondent is eligible.
void main() {
  PulseEligibilityContext ctx({
    String surveyId = 'psv_x',
    String respondentExternalId = 'user_42',
    String? pageUrl = 'https://x.com/checkout',
    Map<String, Object?>? userProperties = const {},
    Map<String, bool>? cohorts = const {},
    Map<String, Object?>? flagValues = const {},
    Map<String, int>? recentEvents = const {},
    Map<String, int>? priorResponseCount = const {},
  }) =>
      PulseEligibilityContext(
        surveyId: surveyId,
        respondentExternalId: respondentExternalId,
        pageUrl: pageUrl,
        userProperties: userProperties,
        cohorts: cohorts,
        flagValues: flagValues,
        recentEvents: recentEvents,
        priorResponseCount: priorResponseCount,
      );

  test('empty rules → eligible', () {
    expect(evaluatePulseTargeting(const [], ctx()).eligible, isTrue);
  });

  test('AND-of-rules: all must match', () {
    final rules = [
      const PulseTargetingRule(
        kind: PulseRuleKind.url,
        urlMatch: PulseMatchOp.contains,
        urlValue: '/checkout',
      ),
      const PulseTargetingRule(
        kind: PulseRuleKind.userProperty,
        propertyKey: 'plan',
        propertyOp: PulseMatchOp.equals,
        propertyValue: 'pro',
      ),
    ];
    expect(
      evaluatePulseTargeting(
        rules,
        ctx(userProperties: const {'plan': 'pro'}),
      ).eligible,
      isTrue,
    );
    expect(
      evaluatePulseTargeting(
        rules,
        ctx(userProperties: const {'plan': 'free'}),
      ).eligible,
      isFalse,
    );
  });

  test('url match operations', () {
    final cases = <Map<String, Object>>[
      {'match': PulseMatchOp.equals, 'value': 'https://x.com/', 'url': 'https://x.com/', 'want': true},
      {'match': PulseMatchOp.equals, 'value': 'https://x.com/', 'url': 'https://x.com/checkout', 'want': false},
      {'match': PulseMatchOp.contains, 'value': '/checkout', 'url': 'https://x.com/app/checkout/v2', 'want': true},
      {'match': PulseMatchOp.contains, 'value': '/checkout', 'url': 'https://x.com/app/cart', 'want': false},
      {'match': PulseMatchOp.prefix, 'value': 'https://x.com/', 'url': 'https://x.com/checkout', 'want': true},
      {'match': PulseMatchOp.prefix, 'value': 'https://x.com/', 'url': 'https://other.com/x', 'want': false},
      {'match': PulseMatchOp.regex, 'value': r'\.com/(\w+)/checkout', 'url': 'https://x.com/app/checkout', 'want': true},
      {'match': PulseMatchOp.regex, 'value': r'\.com/(\w+)/checkout', 'url': 'https://x.com/checkout', 'want': false},
    ];
    for (final c in cases) {
      final rule = PulseTargetingRule(
        kind: PulseRuleKind.url,
        urlMatch: c['match'] as String,
        urlValue: c['value'] as String,
      );
      final d = evaluatePulseTargeting([rule], ctx(pageUrl: c['url'] as String));
      expect(d.eligible, c['want'], reason: 'url ${c['match']} ${c['value']} ${c['url']}');
    }
  });

  test('event respects min count', () {
    final cases = [
      [0, false],
      [1, false],
      [2, false],
      [3, true],
      [10, true],
    ];
    for (final c in cases) {
      const rule = PulseTargetingRule(
        kind: PulseRuleKind.event,
        eventName: 'purchased',
        eventMinCount: 3,
      );
      final d = evaluatePulseTargeting(
        [rule],
        ctx(recentEvents: {'purchased': c[0] as int}),
      );
      expect(d.eligible, c[1] as bool, reason: 'count=${c[0]}');
    }
  });

  test('event default min count = 1', () {
    const rule = PulseTargetingRule(
      kind: PulseRuleKind.event,
      eventName: 'signup',
    );
    expect(
      evaluatePulseTargeting(
        const [rule],
        ctx(recentEvents: const {'signup': 1}),
      ).eligible,
      isTrue,
    );
    expect(
      evaluatePulseTargeting(
        const [rule],
        ctx(recentEvents: const {'signup': 0}),
      ).eligible,
      isFalse,
    );
  });

  test('user_property equals + numeric ops + in', () {
    PulseTargetingRule equalsRule(Object? v) => PulseTargetingRule(
          kind: PulseRuleKind.userProperty,
          propertyKey: 'k',
          propertyOp: PulseMatchOp.equals,
          propertyValue: v,
        );
    expect(
      evaluatePulseTargeting(
        [equalsRule('pro')],
        ctx(userProperties: const {'k': 'pro'}),
      ).eligible,
      isTrue,
    );
    expect(
      evaluatePulseTargeting(
        [equalsRule('pro')],
        ctx(userProperties: const {'k': 'free'}),
      ).eligible,
      isFalse,
    );

    final numericCases = <Map<String, Object>>[
      {'op': PulseMatchOp.gt, 'val': 5, 'actual': 10, 'want': true},
      {'op': PulseMatchOp.gt, 'val': 5, 'actual': 5, 'want': false},
      {'op': PulseMatchOp.gte, 'val': 5, 'actual': 5, 'want': true},
      {'op': PulseMatchOp.lt, 'val': 100, 'actual': 99, 'want': true},
      {'op': PulseMatchOp.lte, 'val': 100, 'actual': 100, 'want': true},
      {'op': PulseMatchOp.gt, 'val': 5, 'actual': '10', 'want': true},
      {'op': PulseMatchOp.gt, 'val': 5, 'actual': 'abc', 'want': false},
    ];
    for (final c in numericCases) {
      final rule = PulseTargetingRule(
        kind: PulseRuleKind.userProperty,
        propertyKey: 'k',
        propertyOp: c['op'] as String,
        propertyValue: c['val'],
      );
      final d = evaluatePulseTargeting(
        [rule],
        ctx(userProperties: {'k': c['actual']}),
      );
      expect(d.eligible, c['want'],
          reason: 'op=${c['op']} val=${c['val']} actual=${c['actual']}');
    }

    const inRule = PulseTargetingRule(
      kind: PulseRuleKind.userProperty,
      propertyKey: 'plan',
      propertyOp: PulseMatchOp.inOp,
      propertyValue: ['pro', 'enterprise'],
    );
    final inCases = [
      ['pro', true],
      ['enterprise', true],
      ['free', false],
      ['trial', false],
    ];
    for (final c in inCases) {
      expect(
        evaluatePulseTargeting(
          const [inRule],
          ctx(userProperties: {'plan': c[0] as String}),
        ).eligible,
        c[1] as bool,
        reason: 'in: ${c[0]}',
      );
    }
  });

  test('user_property exists / not_exists', () {
    const exists = PulseTargetingRule(
      kind: PulseRuleKind.userProperty,
      propertyKey: 'k',
      propertyOp: PulseMatchOp.exists,
    );
    const notExists = PulseTargetingRule(
      kind: PulseRuleKind.userProperty,
      propertyKey: 'k',
      propertyOp: PulseMatchOp.notExists,
    );
    final present = ctx(userProperties: const {'k': 'v'});
    final absent = ctx(userProperties: const {'other': 'v'});
    expect(evaluatePulseTargeting(const [exists], present).eligible, isTrue);
    expect(evaluatePulseTargeting(const [exists], absent).eligible, isFalse);
    expect(evaluatePulseTargeting(const [notExists], present).eligible, isFalse);
    expect(evaluatePulseTargeting(const [notExists], absent).eligible, isTrue);
  });

  test('sampling is deterministic for same user', () {
    const rule = PulseTargetingRule(
      kind: PulseRuleKind.sampling,
      samplingRate: 0.5,
    );
    final c = ctx();
    final first = evaluatePulseTargeting(const [rule], c).eligible;
    for (var i = 0; i < 100; i++) {
      expect(
        evaluatePulseTargeting(const [rule], c).eligible,
        first,
        reason: 'sampling drifted on iteration $i',
      );
    }
  });

  test('sampling distributes near target rate ±5%', () {
    const rule = PulseTargetingRule(
      kind: PulseRuleKind.sampling,
      samplingRate: 0.5,
    );
    var admitted = 0;
    const n = 5000;
    for (var i = 0; i < n; i++) {
      final c = ctx(respondentExternalId: 'user_$i');
      if (evaluatePulseTargeting(const [rule], c).eligible) admitted++;
    }
    final rate = admitted / n;
    expect(rate >= 0.45 && rate <= 0.55, isTrue,
        reason: 'rate=$rate drift outside ±5%');
  });

  test('sampling rate 0 never admits', () {
    const rule = PulseTargetingRule(
      kind: PulseRuleKind.sampling,
      samplingRate: 0,
    );
    for (var i = 0; i < 100; i++) {
      expect(
        evaluatePulseTargeting(
          const [rule],
          ctx(respondentExternalId: 'u$i'),
        ).eligible,
        isFalse,
      );
    }
  });

  test('sampling rate 1 always admits', () {
    const rule = PulseTargetingRule(
      kind: PulseRuleKind.sampling,
      samplingRate: 1,
    );
    for (var i = 0; i < 100; i++) {
      expect(
        evaluatePulseTargeting(
          const [rule],
          ctx(respondentExternalId: 'u$i'),
        ).eligible,
        isTrue,
      );
    }
  });

  test('sampling: anonymous respondent fails closed', () {
    const rule = PulseTargetingRule(
      kind: PulseRuleKind.sampling,
      samplingRate: 0.5,
    );
    expect(
      evaluatePulseTargeting(
        const [rule],
        ctx(respondentExternalId: ''),
      ).eligible,
      isFalse,
    );
  });

  test('frequency cap enforces prior count', () {
    const rule = PulseTargetingRule(
      kind: PulseRuleKind.frequencyCap,
      frequencyScope: 'per_user',
      frequencyMax: 2,
      frequencyWindowDays: 30,
    );
    final cases = [
      [0, true],
      [1, true],
      [2, false],
    ];
    for (final c in cases) {
      final d = evaluatePulseTargeting(
        const [rule],
        ctx(priorResponseCount: {'psv_x': c[0] as int}),
      );
      expect(d.eligible, c[1] as bool, reason: 'prior=${c[0]}');
    }
  });

  test('feature_flag matches when value equal', () {
    const rule = PulseTargetingRule(
      kind: PulseRuleKind.featureFlag,
      flagKey: 'show_survey',
      flagValue: true,
    );
    expect(
      evaluatePulseTargeting(
        const [rule],
        ctx(flagValues: const {'show_survey': true}),
      ).eligible,
      isTrue,
    );
    expect(
      evaluatePulseTargeting(
        const [rule],
        ctx(flagValues: const {'show_survey': false}),
      ).eligible,
      isFalse,
    );
    expect(
      evaluatePulseTargeting(
        const [rule],
        ctx(flagValues: const {}),
      ).eligible,
      isFalse,
    );
  });

  test('stableHash produces a value in [0, 1)', () {
    for (var i = 0; i < 100; i++) {
      final score = pulseStableHash('survey:$i');
      expect(score >= 0 && score < 1, isTrue, reason: 'score=$score out of range');
    }
  });

  test('stableHash is deterministic', () {
    final a = pulseStableHash('psv_x:user_42');
    final b = pulseStableHash('psv_x:user_42');
    expect(a, b);
    final c = pulseStableHash('psv_x:user_43');
    expect(a, isNot(c));
  });
}
