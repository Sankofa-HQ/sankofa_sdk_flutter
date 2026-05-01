import 'package:flutter_test/flutter_test.dart';
import 'package:sankofa_flutter/src/pulse/branching.dart';

/// Branching evaluator parity test suite. Mirrors
/// `sdks/sankofa_sdk_web/packages/pulse/src/__tests__/branching.test.ts`
/// verbatim — failures here mean the Flutter SDK will disagree with
/// the Web SDK and Go server about which question to show next.
void main() {
  test('empty rules → fall through', () {
    final out = resolvePulseBranching(const [], 'psq_q1', const {});
    expect(out.nextQuestionId, '');
  });

  test('no matching rule → fall through', () {
    final rules = [
      const PulseBranchingRule(
        fromQuestionId: 'psq_q1',
        condition: PulseBranchingCondition(
          kind: PulseBranchingCondKind.answer,
          questionId: 'psq_q1',
          op: PulseBranchingCondOp.equals,
          value: 'never',
        ),
        action: PulseBranchingActionKind.skipTo,
        toQuestionId: 'psq_q5',
      ),
    ];
    final out = resolvePulseBranching(
        rules, 'psq_q1', const {'psq_q1': 'always'});
    expect(out.nextQuestionId, '');
  });

  test('skip_to fires on match', () {
    final rules = [
      const PulseBranchingRule(
        fromQuestionId: 'psq_nps',
        condition: PulseBranchingCondition(
          kind: PulseBranchingCondKind.answer,
          questionId: 'psq_nps',
          op: PulseBranchingCondOp.lt,
          value: 7,
        ),
        action: PulseBranchingActionKind.skipTo,
        toQuestionId: 'psq_why',
      ),
    ];
    final out = resolvePulseBranching(rules, 'psq_nps', const {'psq_nps': 3});
    expect(out.nextQuestionId, 'psq_why');
  });

  test('end_survey fires on match', () {
    final rules = [
      const PulseBranchingRule(
        fromQuestionId: 'psq_consent',
        condition: PulseBranchingCondition(
          kind: PulseBranchingCondKind.answer,
          questionId: 'psq_consent',
          op: PulseBranchingCondOp.notAnswered,
        ),
        action: PulseBranchingActionKind.endSurvey,
      ),
    ];
    final out = resolvePulseBranching(rules, 'psq_consent', const {});
    expect(out.nextQuestionId, pulseBranchingEndOfSurvey);
  });

  test('first matching rule wins', () {
    final rules = [
      const PulseBranchingRule(
        fromQuestionId: 'psq_q1',
        condition: PulseBranchingCondition(
          kind: PulseBranchingCondKind.answer,
          questionId: 'psq_q1',
          op: PulseBranchingCondOp.answered,
        ),
        action: PulseBranchingActionKind.skipTo,
        toQuestionId: 'psq_a',
      ),
      const PulseBranchingRule(
        fromQuestionId: 'psq_q1',
        condition: PulseBranchingCondition(
          kind: PulseBranchingCondKind.answer,
          questionId: 'psq_q1',
          op: PulseBranchingCondOp.equals,
          value: 'x',
        ),
        action: PulseBranchingActionKind.skipTo,
        toQuestionId: 'psq_b',
      ),
    ];
    final out = resolvePulseBranching(rules, 'psq_q1', const {'psq_q1': 'x'});
    expect(out.nextQuestionId, 'psq_a');
  });

  test('rules for other from-questions are ignored', () {
    final rules = [
      const PulseBranchingRule(
        fromQuestionId: 'psq_q2',
        condition: PulseBranchingCondition(
          kind: PulseBranchingCondKind.answer,
          questionId: 'psq_q2',
          op: PulseBranchingCondOp.answered,
        ),
        action: PulseBranchingActionKind.skipTo,
        toQuestionId: 'psq_z',
      ),
    ];
    final out = resolvePulseBranching(rules, 'psq_q1', const {'psq_q2': 'x'});
    expect(out.nextQuestionId, '');
  });

  test('numeric comparators (incl. string-coerced)', () {
    final cases = <Map<String, Object>>[
      {'op': PulseBranchingCondOp.lt, 'val': 7, 'answer': 3, 'want': true},
      {'op': PulseBranchingCondOp.lt, 'val': 7, 'answer': 7, 'want': false},
      {'op': PulseBranchingCondOp.lte, 'val': 7, 'answer': 7, 'want': true},
      {'op': PulseBranchingCondOp.gt, 'val': 7, 'answer': 8, 'want': true},
      {'op': PulseBranchingCondOp.gte, 'val': 7, 'answer': 7, 'want': true},
      {'op': PulseBranchingCondOp.gt, 'val': 7, 'answer': '10', 'want': true},
      {'op': PulseBranchingCondOp.gt, 'val': 7, 'answer': 'abc', 'want': false},
    ];
    for (final c in cases) {
      final ok = evaluatePulseBranchingCondition(
        PulseBranchingCondition(
          kind: PulseBranchingCondKind.answer,
          questionId: 'q',
          op: c['op'] as String,
          value: c['val'],
        ),
        {'q': c['answer']},
      );
      expect(ok, c['want'] as bool,
          reason: 'op=${c['op']} val=${c['val']} answer=${c['answer']}');
    }
  });

  test('contains works for arrays + strings', () {
    const arrCond = PulseBranchingCondition(
      kind: PulseBranchingCondKind.answer,
      questionId: 'q',
      op: PulseBranchingCondOp.contains,
      value: 'key_b',
    );
    expect(
      evaluatePulseBranchingCondition(
        arrCond, const {'q': ['key_a', 'key_b', 'key_c']}),
      isTrue,
    );
    expect(
      evaluatePulseBranchingCondition(
        arrCond, const {'q': ['key_a', 'key_c']}),
      isFalse,
    );

    const strCond = PulseBranchingCondition(
      kind: PulseBranchingCondKind.answer,
      questionId: 'q',
      op: PulseBranchingCondOp.contains,
      value: 'slow',
    );
    expect(
      evaluatePulseBranchingCondition(strCond, const {'q': 'the app feels slow'}),
      isTrue,
    );
    expect(
      evaluatePulseBranchingCondition(strCond, const {'q': 'the app feels fast'}),
      isFalse,
    );
  });

  test('in matches array values', () {
    const cond = PulseBranchingCondition(
      kind: PulseBranchingCondKind.answer,
      questionId: 'q',
      op: PulseBranchingCondOp.inOp,
      value: ['pro', 'enterprise'],
    );
    expect(evaluatePulseBranchingCondition(cond, const {'q': 'pro'}), isTrue);
    expect(evaluatePulseBranchingCondition(cond, const {'q': 'free'}), isFalse);
  });

  test('answered + not_answered handle empty / missing', () {
    const answered = PulseBranchingCondition(
      kind: PulseBranchingCondKind.answer,
      questionId: 'q',
      op: PulseBranchingCondOp.answered,
    );
    const notAnswered = PulseBranchingCondition(
      kind: PulseBranchingCondKind.answer,
      questionId: 'q',
      op: PulseBranchingCondOp.notAnswered,
    );

    expect(evaluatePulseBranchingCondition(answered, const {'q': 'x'}), isTrue);
    expect(evaluatePulseBranchingCondition(notAnswered, const {'q': 'x'}), isFalse);

    expect(evaluatePulseBranchingCondition(answered, const {'q': ''}), isFalse);
    expect(evaluatePulseBranchingCondition(notAnswered, const {'q': ''}), isTrue);

    expect(evaluatePulseBranchingCondition(answered, const {'q': []}), isFalse);

    expect(evaluatePulseBranchingCondition(answered, const {}), isFalse);
    expect(evaluatePulseBranchingCondition(notAnswered, const {}), isTrue);
  });

  test('value-needing ops fail closed when answer is missing', () {
    const cond = PulseBranchingCondition(
      kind: PulseBranchingCondKind.answer,
      questionId: 'q',
      op: PulseBranchingCondOp.equals,
      value: 'x',
    );
    expect(evaluatePulseBranchingCondition(cond, const {}), isFalse);
  });

  test('boolean answers coerce to numeric', () {
    const cond = PulseBranchingCondition(
      kind: PulseBranchingCondKind.answer,
      questionId: 'q',
      op: PulseBranchingCondOp.gt,
      value: 0,
    );
    expect(evaluatePulseBranchingCondition(cond, const {'q': true}), isTrue);
    expect(evaluatePulseBranchingCondition(cond, const {'q': false}), isFalse);
  });
}
