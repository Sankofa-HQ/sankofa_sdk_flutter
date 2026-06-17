import 'package:flutter_test/flutter_test.dart';
import 'package:sankofa_flutter/src/pulse/pulse_models.dart';
import 'package:sankofa_flutter/src/pulse/targeting.dart';

/// Coverage for the `session` targeting rule kind + the version /
/// session fields the SDK now carries on the survey summary. These are
/// Flutter-side additions (the web-parity suite lives in
/// pulse_targeting_test.dart and stays a verbatim mirror).
void main() {
  PulseEligibilityContext ctx({int? sessionNumber}) => PulseEligibilityContext(
        surveyId: 'psv_x',
        respondentExternalId: 'user_42',
        sessionNumber: sessionNumber,
      );

  group('session rule', () {
    test('session_every matches on the Nth session only', () {
      const rule = PulseTargetingRule(
        kind: PulseRuleKind.session,
        sessionEvery: 5,
      );
      // 5th and 10th match; in-between sessions do not.
      expect(evaluatePulseTargeting([rule], ctx(sessionNumber: 5)).eligible,
          isTrue);
      expect(evaluatePulseTargeting([rule], ctx(sessionNumber: 10)).eligible,
          isTrue);
      for (final n in [1, 2, 3, 4, 6, 7, 9, 11]) {
        expect(
          evaluatePulseTargeting([rule], ctx(sessionNumber: n)).eligible,
          isFalse,
          reason: 'session $n should not match every-5th',
        );
      }
    });

    test('session_min gates on a minimum session count', () {
      const rule = PulseTargetingRule(
        kind: PulseRuleKind.session,
        sessionMin: 3,
      );
      expect(evaluatePulseTargeting([rule], ctx(sessionNumber: 2)).eligible,
          isFalse);
      expect(evaluatePulseTargeting([rule], ctx(sessionNumber: 3)).eligible,
          isTrue);
      expect(evaluatePulseTargeting([rule], ctx(sessionNumber: 9)).eligible,
          isTrue);
    });

    test('session_min AND session_every must both hold', () {
      const rule = PulseTargetingRule(
        kind: PulseRuleKind.session,
        sessionMin: 6,
        sessionEvery: 5,
      );
      // 5 is a multiple of 5 but below the min of 6 → fail.
      expect(evaluatePulseTargeting([rule], ctx(sessionNumber: 5)).eligible,
          isFalse);
      // 10 is >= 6 AND a multiple of 5 → pass.
      expect(evaluatePulseTargeting([rule], ctx(sessionNumber: 10)).eligible,
          isTrue);
      // 7 is >= 6 but not a multiple of 5 → fail.
      expect(evaluatePulseTargeting([rule], ctx(sessionNumber: 7)).eligible,
          isFalse);
    });

    test('unknown session count (0/null) never matches', () {
      const rule = PulseTargetingRule(
        kind: PulseRuleKind.session,
        sessionEvery: 1,
      );
      expect(evaluatePulseTargeting([rule], ctx(sessionNumber: 0)).eligible,
          isFalse);
      expect(evaluatePulseTargeting([rule], ctx(sessionNumber: null)).eligible,
          isFalse);
    });

    test('a session rule with no bounds fails closed', () {
      const rule = PulseTargetingRule(kind: PulseRuleKind.session);
      expect(evaluatePulseTargeting([rule], ctx(sessionNumber: 3)).eligible,
          isFalse);
    });
  });

  group('PulseSurveySummary round-trip', () {
    test('version_number + session rule fields survive toJson/fromJson', () {
      const summary = PulseSurveySummary(
        id: 'psv_1',
        name: 'NPS',
        kind: 'nps',
        status: 'published',
        versionNumber: 7,
        targetingRules: [
          PulseTargetingRule(
            kind: PulseRuleKind.session,
            sessionEvery: 5,
            sessionMin: 2,
          ),
        ],
      );

      final restored = PulseSurveySummary.fromJson(summary.toJson());

      expect(restored.versionNumber, 7);
      expect(restored.targetingRules, hasLength(1));
      final rule = restored.targetingRules.single;
      expect(rule.kind, PulseRuleKind.session);
      expect(rule.sessionEvery, 5);
      expect(rule.sessionMin, 2);
    });

    test('absent version_number parses to 0 (legacy server)', () {
      final restored = PulseSurveySummary.fromJson(const {
        'id': 'psv_1',
        'name': 'X',
        'kind': 'nps',
        'status': 'published',
      });
      expect(restored.versionNumber, 0);
    });
  });
}
