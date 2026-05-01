/// Branching evaluator — Dart port of
/// `sdks/sankofa_sdk_web/packages/pulse/src/branching.ts` and
/// `server/engine/ee/pulse/branching/evaluator.go`.
///
/// Behavioural contract: every (rules, currentQuestionId, answers)
/// triple MUST produce the same Outcome the Web + Go evaluators
/// produce. Tests in `test/pulse_branching_test.dart` mirror the
/// Web suite verbatim.
///
/// Composition: first matching rule attached to currentQuestionId
/// wins. When no rule matches, returns nextQuestionId="" so the SDK
/// falls through to the natural next question (by order_index).
/// When the matching rule has action="end_survey", returns the
/// [pulseBranchingEndOfSurvey] sentinel.
library;

/// Sentinel: when [PulseOutcome.nextQuestionId] equals this string,
/// the survey should end immediately.
const String pulseBranchingEndOfSurvey = '__end__';

class PulseBranchingActionKind {
  static const skipTo = 'skip_to';
  static const endSurvey = 'end_survey';
}

class PulseBranchingCondKind {
  static const answer = 'answer';
}

class PulseBranchingCondOp {
  static const equals = 'equals';
  static const notEquals = 'not_equals';
  static const gt = 'gt';
  static const lt = 'lt';
  static const gte = 'gte';
  static const lte = 'lte';
  static const contains = 'contains';
  static const notContains = 'not_contains';
  static const inOp = 'in';
  static const notInOp = 'not_in';
  static const answered = 'answered';
  static const notAnswered = 'not_answered';
}

class PulseBranchingCondition {
  final String kind;
  final String questionId;
  final String op;
  final Object? value;

  const PulseBranchingCondition({
    required this.kind,
    required this.questionId,
    required this.op,
    this.value,
  });

  factory PulseBranchingCondition.fromJson(Map<String, dynamic> json) =>
      PulseBranchingCondition(
        kind: json['kind'] as String? ?? '',
        questionId: json['question_id'] as String? ?? '',
        op: json['op'] as String? ?? '',
        value: json['value'],
      );
}

class PulseBranchingRule {
  final String fromQuestionId;
  final PulseBranchingCondition condition;
  final String action;
  final String? toQuestionId;

  const PulseBranchingRule({
    required this.fromQuestionId,
    required this.condition,
    required this.action,
    this.toQuestionId,
  });

  factory PulseBranchingRule.fromJson(Map<String, dynamic> json) =>
      PulseBranchingRule(
        fromQuestionId: json['from_question_id'] as String? ?? '',
        condition: json['condition'] is Map<String, dynamic>
            ? PulseBranchingCondition.fromJson(
                json['condition'] as Map<String, dynamic>)
            : const PulseBranchingCondition(
                kind: '', questionId: '', op: ''),
        action: json['action'] as String? ?? '',
        toQuestionId: json['to_question_id'] as String?,
      );
}

class PulseOutcome {
  final String nextQuestionId;
  final String? reason;
  const PulseOutcome({required this.nextQuestionId, this.reason});
}

PulseOutcome resolvePulseBranching(
  List<PulseBranchingRule> rules,
  String currentQuestionId,
  Map<String, Object?> answers,
) {
  for (var i = 0; i < rules.length; i++) {
    final rule = rules[i];
    if (rule.fromQuestionId != currentQuestionId) continue;
    if (!evaluatePulseBranchingCondition(rule.condition, answers)) continue;
    switch (rule.action) {
      case PulseBranchingActionKind.skipTo:
        return PulseOutcome(
          nextQuestionId: rule.toQuestionId ?? '',
          reason: 'rule[$i] skip_to ${rule.toQuestionId}',
        );
      case PulseBranchingActionKind.endSurvey:
        return PulseOutcome(
          nextQuestionId: pulseBranchingEndOfSurvey,
          reason: 'rule[$i] end_survey',
        );
    }
  }
  return const PulseOutcome(
    nextQuestionId: '',
    reason: 'fall through (no rule matched)',
  );
}

bool evaluatePulseBranchingCondition(
  PulseBranchingCondition cond,
  Map<String, Object?> answers,
) {
  switch (cond.kind) {
    case PulseBranchingCondKind.answer:
      return _evalAnswerCondition(cond, answers);
  }
  return false;
}

bool _evalAnswerCondition(
  PulseBranchingCondition cond,
  Map<String, Object?> answers,
) {
  final present = answers.containsKey(cond.questionId);
  final v = answers[cond.questionId];
  switch (cond.op) {
    case PulseBranchingCondOp.answered:
      return present && !_isEmptyAnswer(v);
    case PulseBranchingCondOp.notAnswered:
      return !present || _isEmptyAnswer(v);
  }
  if (!present || _isEmptyAnswer(v)) return false;
  switch (cond.op) {
    case PulseBranchingCondOp.equals:
      return _jsonEqual(v, cond.value);
    case PulseBranchingCondOp.notEquals:
      return !_jsonEqual(v, cond.value);
    case PulseBranchingCondOp.contains:
      return _jsonContains(v, cond.value);
    case PulseBranchingCondOp.notContains:
      return !_jsonContains(v, cond.value);
    case PulseBranchingCondOp.inOp:
      return _jsonInArray(v, cond.value);
    case PulseBranchingCondOp.notInOp:
      return !_jsonInArray(v, cond.value);
    case PulseBranchingCondOp.gt:
    case PulseBranchingCondOp.lt:
    case PulseBranchingCondOp.gte:
    case PulseBranchingCondOp.lte:
      return _compareNumeric(v, cond.value, cond.op);
  }
  return false;
}

bool _isEmptyAnswer(Object? v) {
  if (v == null) return true;
  if (v is String) return v.trim().isEmpty;
  if (v is List) return v.isEmpty;
  return false;
}

bool _jsonEqual(Object? a, Object? b) {
  if (a == null && b == null) return true;
  if (a == null || b == null) return false;
  if (a is num && b is num) return a.toDouble() == b.toDouble();
  if (a.runtimeType != b.runtimeType) return false;
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_jsonEqual(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (!b.containsKey(entry.key)) return false;
      if (!_jsonEqual(entry.value, b[entry.key])) return false;
    }
    return true;
  }
  return a == b;
}

bool _jsonContains(Object? v, Object? target) {
  if (v is List) {
    return v.any((item) => _jsonEqual(item, target));
  }
  if (v is String && target is String) {
    return v.contains(target);
  }
  return false;
}

bool _jsonInArray(Object? v, Object? target) {
  if (target is! List) return false;
  return target.any((item) => _jsonEqual(v, item));
}

bool _compareNumeric(Object? v, Object? target, String op) {
  final left = _numericValue(v);
  if (left == null) return false;
  final right = _numericValue(target);
  if (right == null) return false;
  switch (op) {
    case PulseBranchingCondOp.gt:
      return left > right;
    case PulseBranchingCondOp.lt:
      return left < right;
    case PulseBranchingCondOp.gte:
      return left >= right;
    case PulseBranchingCondOp.lte:
      return left <= right;
  }
  return false;
}

/// Same numeric coercion shape as the Go side: numbers, strings
/// that parse as numbers, and booleans (true → 1, false → 0). The
/// boolean coercion is defensive — a boolean question wired to a
/// numeric op shouldn't crash the evaluator.
double? _numericValue(Object? v) {
  if (v is num) return v.isFinite ? v.toDouble() : null;
  if (v is bool) return v ? 1.0 : 0.0;
  if (v is String) {
    final t = v.trim();
    if (t.isEmpty) return null;
    return double.tryParse(t);
  }
  return null;
}
