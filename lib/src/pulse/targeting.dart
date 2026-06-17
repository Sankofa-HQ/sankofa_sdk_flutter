/// Targeting evaluator — Dart port of
/// `sdks/sankofa_sdk_web/packages/pulse/src/targeting.ts` and
/// `server/engine/ee/pulse/targeting/evaluator.go`.
///
/// Behavioural contract: every (rules, ctx) pair MUST produce the
/// same Decision the Web + Go evaluators produce. Sampling decisions
/// in particular must agree across server + client — a server-says-in
/// / client-says-out split produces zero exposure rows and breaks
/// A/B reasoning.
library;

import 'dart:convert';
import 'dart:typed_data';

class PulseRuleKind {
  static const url = 'url';
  static const screen = 'screen';
  static const event = 'event';
  static const userProperty = 'user_property';
  static const cohort = 'cohort';
  static const sampling = 'sampling';
  static const frequencyCap = 'frequency_cap';
  static const featureFlag = 'feature_flag';

  /// Session-count targeting — e.g. "show on every 5th session" or
  /// "only after the respondent's 3rd session". Resolves against the
  /// SDK's persisted session counter (see `SankofaSessionManager`).
  ///
  /// This is a CLIENT-ONLY rule: the session count is a per-device value
  /// the server never holds, so the server-side Go evaluator DEFERS
  /// (passes) on a `session` rule and ships the survey, leaving the real
  /// decision to [_evalSession] against the local counter. The server's
  /// `targeting.KindSession` + `session_every`/`session_min` fields and
  /// validation already match this — keep the two evaluators in lockstep.
  static const session = 'session';
}

class PulseMatchOp {
  static const equals = 'equals';
  static const notEquals = 'not_equals';
  static const contains = 'contains';
  static const notContains = 'not_contains';
  static const prefix = 'prefix';
  static const regex = 'regex';
  static const inOp = 'in';
  static const notInOp = 'not_in';
  static const exists = 'exists';
  static const notExists = 'not_exists';
  static const gt = 'gt';
  static const lt = 'lt';
  static const gte = 'gte';
  static const lte = 'lte';
}

/// One targeting rule. Loosely-typed by design — relevant fields
/// depend on `kind`; absent fields are simply unused.
class PulseTargetingRule {
  final String kind;
  // url
  final String? urlMatch;
  final String? urlValue;
  // screen — same comparator set as url, OR-matched against the
  // native screen / route name. screenNames is the target set.
  final String? screenMatch;
  final List<String>? screenNames;
  // event
  final String? eventName;
  final int? eventMinCount;
  final int? eventWindowDays;
  // user_property
  final String? propertyKey;
  final String? propertyOp;
  final Object? propertyValue;
  // cohort
  final String? cohortId;
  // sampling
  final double? samplingRate;
  // frequency_cap
  final String? frequencyScope;
  final int? frequencyMax;
  final int? frequencyWindowDays;
  // feature_flag
  final String? flagKey;
  final Object? flagValue;
  // session — count-based recurrence. `sessionEvery` matches on every
  // Nth session (session_number % every == 0); `sessionMin` gates on a
  // minimum session count (session_number >= min). Both may be set and
  // are AND-ed; at least one must be present for the rule to match.
  final int? sessionEvery;
  final int? sessionMin;

  const PulseTargetingRule({
    required this.kind,
    this.urlMatch,
    this.urlValue,
    this.screenMatch,
    this.screenNames,
    this.eventName,
    this.eventMinCount,
    this.eventWindowDays,
    this.propertyKey,
    this.propertyOp,
    this.propertyValue,
    this.cohortId,
    this.samplingRate,
    this.frequencyScope,
    this.frequencyMax,
    this.frequencyWindowDays,
    this.flagKey,
    this.flagValue,
    this.sessionEvery,
    this.sessionMin,
  });

  factory PulseTargetingRule.fromJson(Map<String, dynamic> json) =>
      PulseTargetingRule(
        kind: json['kind'] as String? ?? '',
        urlMatch: json['url_match'] as String?,
        urlValue: json['url_value'] as String?,
        screenMatch: json['screen_match'] as String?,
        screenNames: (json['screen_names'] as List?)
            ?.whereType<String>()
            .toList(growable: false),
        eventName: json['event_name'] as String?,
        eventMinCount: (json['event_min_count'] as num?)?.toInt(),
        eventWindowDays: (json['event_window_days'] as num?)?.toInt(),
        propertyKey: json['property_key'] as String?,
        propertyOp: json['property_op'] as String?,
        propertyValue: json['property_value'],
        cohortId: json['cohort_id'] as String?,
        samplingRate: (json['sampling_rate'] as num?)?.toDouble(),
        frequencyScope: json['frequency_scope'] as String?,
        frequencyMax: (json['frequency_max'] as num?)?.toInt(),
        frequencyWindowDays:
            (json['frequency_window_days'] as num?)?.toInt(),
        flagKey: json['flag_key'] as String?,
        flagValue: json['flag_value'],
        sessionEvery: (json['session_every'] as num?)?.toInt(),
        sessionMin: (json['session_min'] as num?)?.toInt(),
      );
}

/// Full eligibility context — mirrors server `EligibilityContext`.
class PulseEligibilityContext {
  final String surveyId;
  final String respondentExternalId;
  final String? pageUrl;

  /// Native screen / route name. Sourced from
  /// `SankofaNavigatorObserver` so the most-recently-pushed route's
  /// name flows here. Empty before any navigation event fires —
  /// KindScreen rules will not match until the SDK has observed at
  /// least one screen.
  final String? screenName;

  final Map<String, int>? recentEvents;
  final Map<String, Object?>? userProperties;
  final Map<String, bool>? cohorts;
  final Map<String, Object?>? flagValues;
  final Map<String, int>? priorResponseCount;

  /// 1-based count of distinct sessions this respondent has started on
  /// this device. 0 means "unknown" (pre-init) and never matches a
  /// `session` rule. Sourced from `SankofaSessionManager.sessionCount`.
  final int? sessionNumber;

  const PulseEligibilityContext({
    required this.surveyId,
    required this.respondentExternalId,
    this.pageUrl,
    this.screenName,
    this.recentEvents,
    this.userProperties,
    this.cohorts,
    this.flagValues,
    this.priorResponseCount,
    this.sessionNumber,
  });
}

class PulseDecision {
  final bool eligible;
  final String? reason;
  const PulseDecision({required this.eligible, this.reason});
}

PulseDecision evaluatePulseTargeting(
  List<PulseTargetingRule> rules,
  PulseEligibilityContext ctx,
) {
  for (var i = 0; i < rules.length; i++) {
    final rule = rules[i];
    final result = _evaluateOne(rule, ctx);
    if (!result.$1) {
      return PulseDecision(
        eligible: false,
        reason: 'rule[$i] ${rule.kind}: ${result.$2}',
      );
    }
  }
  return const PulseDecision(eligible: true);
}

(bool, String) _evaluateOne(
  PulseTargetingRule rule,
  PulseEligibilityContext ctx,
) {
  switch (rule.kind) {
    case PulseRuleKind.url:
      return _evalUrl(rule, ctx);
    case PulseRuleKind.screen:
      return _evalScreen(rule, ctx);
    case PulseRuleKind.event:
      return _evalEvent(rule, ctx);
    case PulseRuleKind.userProperty:
      return _evalUserProperty(rule, ctx);
    case PulseRuleKind.cohort:
      return _evalCohort(rule, ctx);
    case PulseRuleKind.sampling:
      return _evalSampling(rule, ctx);
    case PulseRuleKind.frequencyCap:
      return _evalFrequencyCap(rule, ctx);
    case PulseRuleKind.featureFlag:
      return _evalFeatureFlag(rule, ctx);
    case PulseRuleKind.session:
      return _evalSession(rule, ctx);
    default:
      return (false, 'unknown rule kind');
  }
}

// ── Session ──────────────────────────────────────────────────────────

(bool, String) _evalSession(
  PulseTargetingRule rule,
  PulseEligibilityContext ctx,
) {
  final n = ctx.sessionNumber ?? 0;
  if (n <= 0) return (false, 'session count unknown');
  final every = rule.sessionEvery;
  final min = rule.sessionMin;
  final hasEvery = every != null && every > 0;
  final hasMin = min != null && min > 0;
  if (!hasEvery && !hasMin) {
    return (false, 'session rule has neither session_every nor session_min');
  }
  if (hasMin && n < min) {
    return (false, 'session $n below minimum $min');
  }
  if (hasEvery && n % every != 0) {
    return (false, 'session $n is not a multiple of $every');
  }
  return (true, '');
}

// ── URL ──────────────────────────────────────────────────────────────

(bool, String) _evalUrl(
  PulseTargetingRule rule,
  PulseEligibilityContext ctx,
) {
  final url = ctx.pageUrl ?? '';
  final value = rule.urlValue ?? '';
  switch (rule.urlMatch) {
    case PulseMatchOp.equals:
      return url == value
          ? (true, '')
          : (false, 'url not equal to target');
    case PulseMatchOp.contains:
      return url.contains(value)
          ? (true, '')
          : (false, 'url does not contain target');
    case PulseMatchOp.prefix:
      return url.startsWith(value)
          ? (true, '')
          : (false, 'url does not start with target');
    case PulseMatchOp.regex:
      RegExp re;
      try {
        re = RegExp(value);
      } catch (_) {
        return (false, 'url regex did not compile');
      }
      return re.hasMatch(url)
          ? (true, '')
          : (false, 'url does not match regex');
  }
  return (false, 'url_match unknown');
}

// ── Screen ───────────────────────────────────────────────────────────

(bool, String) _evalScreen(
  PulseTargetingRule rule,
  PulseEligibilityContext ctx,
) {
  final screen = ctx.screenName ?? '';
  if (screen.isEmpty) return (false, 'screen unknown');
  final targets = (rule.screenNames ?? const <String>[])
      .where((t) => t.isNotEmpty)
      .toList(growable: false);
  if (targets.isEmpty) return (false, 'screen rule has no targets');
  for (final target in targets) {
    if (_matchScreen(screen, target, rule.screenMatch)) return (true, '');
  }
  return (false, 'screen does not match any target');
}

bool _matchScreen(String screen, String target, String? op) {
  switch (op) {
    case PulseMatchOp.equals:
      return screen == target;
    case PulseMatchOp.contains:
      return screen.contains(target);
    case PulseMatchOp.prefix:
      return screen.startsWith(target);
    case PulseMatchOp.regex:
      try {
        return RegExp(target).hasMatch(screen);
      } catch (_) {
        return false;
      }
  }
  return false;
}

// ── Event ────────────────────────────────────────────────────────────

(bool, String) _evalEvent(
  PulseTargetingRule rule,
  PulseEligibilityContext ctx,
) {
  final min = (rule.eventMinCount != null && rule.eventMinCount! >= 1)
      ? rule.eventMinCount!
      : 1;
  final events = ctx.recentEvents ?? const {};
  final count = events[rule.eventName ?? ''] ?? 0;
  if (count >= min) return (true, '');
  return (false, 'event "${rule.eventName}" seen $count times, need $min');
}

// ── User Property ────────────────────────────────────────────────────

(bool, String) _evalUserProperty(
  PulseTargetingRule rule,
  PulseEligibilityContext ctx,
) {
  final key = rule.propertyKey ?? '';
  final props = ctx.userProperties ?? const {};
  final present = props.containsKey(key);
  final v = props[key];

  switch (rule.propertyOp) {
    case PulseMatchOp.exists:
      return present ? (true, '') : (false, 'property absent');
    case PulseMatchOp.notExists:
      return !present ? (true, '') : (false, 'property present');
  }

  if (!present) return (false, 'property absent');
  final target = rule.propertyValue;
  switch (rule.propertyOp) {
    case PulseMatchOp.equals:
      return _jsonEqual(v, target)
          ? (true, '')
          : (false, 'property not equal');
    case PulseMatchOp.notEquals:
      return !_jsonEqual(v, target)
          ? (true, '')
          : (false, 'property equal');
    case PulseMatchOp.contains:
      return _strContains(v, target)
          ? (true, '')
          : (false, 'property does not contain target');
    case PulseMatchOp.notContains:
      return !_strContains(v, target)
          ? (true, '')
          : (false, 'property contains target');
    case PulseMatchOp.inOp:
      return _jsonInArray(v, target)
          ? (true, '')
          : (false, 'property not in target list');
    case PulseMatchOp.notInOp:
      return !_jsonInArray(v, target)
          ? (true, '')
          : (false, 'property in target list');
    case PulseMatchOp.gt:
    case PulseMatchOp.lt:
    case PulseMatchOp.gte:
    case PulseMatchOp.lte:
      return _compareNumbers(v, target, rule.propertyOp!);
  }
  return (false, 'property_op unknown');
}

// ── Cohort ───────────────────────────────────────────────────────────

(bool, String) _evalCohort(
  PulseTargetingRule rule,
  PulseEligibilityContext ctx,
) {
  final id = rule.cohortId ?? '';
  final cohorts = ctx.cohorts ?? const {};
  if (cohorts[id] == true) return (true, '');
  return (false, 'respondent not in cohort "$id"');
}

// ── Sampling ─────────────────────────────────────────────────────────

(bool, String) _evalSampling(
  PulseTargetingRule rule,
  PulseEligibilityContext ctx,
) {
  final rate = rule.samplingRate ?? 0.0;
  if (rate <= 0.0) return (false, 'sampling rate is 0');
  if (rate >= 1.0) return (true, '');
  if (ctx.respondentExternalId.isEmpty) {
    return (false, 'no external_id; cannot sample deterministically');
  }
  final score = pulseStableHash('${ctx.surveyId}:${ctx.respondentExternalId}');
  return score < rate
      ? (true, '')
      : (
          false,
          'sampling miss (score=${score.toStringAsFixed(3)}, '
              'rate=${rate.toStringAsFixed(3)})'
        );
}

/// Synchronous SHA-256 over a UTF-8 string, returning the top 64
/// bits as a value in [0, 1). Same construction the Go + Web sides
/// use — top 4 bytes form `hi`, next 4 form `lo`, then
/// `hi / 2^32 + lo / 2^64`. Critical for cross-language parity:
/// the same input MUST produce the same score in every SDK.
double pulseStableHash(String input) {
  final bytes = _sha256(utf8.encode(input));
  // First 8 bytes interpreted as two unsigned 32-bit ints, big-endian.
  final hi = ((bytes[0] & 0xFF) << 24) |
      ((bytes[1] & 0xFF) << 16) |
      ((bytes[2] & 0xFF) << 8) |
      (bytes[3] & 0xFF);
  final lo = ((bytes[4] & 0xFF) << 24) |
      ((bytes[5] & 0xFF) << 16) |
      ((bytes[6] & 0xFF) << 8) |
      (bytes[7] & 0xFF);
  return hi.toUnsigned(32) / 4294967296.0 +
      lo.toUnsigned(32) / 18446744073709552000.0;
}

// ── Frequency cap ────────────────────────────────────────────────────

(bool, String) _evalFrequencyCap(
  PulseTargetingRule rule,
  PulseEligibilityContext ctx,
) {
  final max = (rule.frequencyMax != null && rule.frequencyMax! >= 1)
      ? rule.frequencyMax!
      : 1;
  final prior = (ctx.priorResponseCount ?? const {})[ctx.surveyId] ?? 0;
  if (prior < max) return (true, '');
  return (
    false,
    'respondent has $prior prior responses (cap=$max, '
        'window=${rule.frequencyWindowDays}d)'
  );
}

// ── Feature flag ─────────────────────────────────────────────────────

(bool, String) _evalFeatureFlag(
  PulseTargetingRule rule,
  PulseEligibilityContext ctx,
) {
  final key = rule.flagKey ?? '';
  final flags = ctx.flagValues ?? const {};
  if (!flags.containsKey(key)) return (false, 'flag "$key" not in context');
  if (_jsonEqual(flags[key], rule.flagValue)) return (true, '');
  return (false, 'flag "$key" value ${flags[key]} != ${rule.flagValue}');
}

// ── Helpers ──────────────────────────────────────────────────────────

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

bool _strContains(Object? v, Object? target) {
  final haystack = v is String ? v : v?.toString() ?? '';
  final needle = target is String ? target : target?.toString() ?? '';
  return haystack.contains(needle);
}

bool _jsonInArray(Object? v, Object? target) {
  if (target is! List) return false;
  return target.any((item) => _jsonEqual(v, item));
}

(bool, String) _compareNumbers(Object? v, Object? target, String op) {
  final left = _numericValue(v);
  if (left == null) return (false, 'property is not numeric');
  final right = _numericValue(target);
  if (right == null) return (false, 'target is not numeric');
  switch (op) {
    case PulseMatchOp.gt:
      return left > right ? (true, '') : (false, '$left $op $right fails');
    case PulseMatchOp.lt:
      return left < right ? (true, '') : (false, '$left $op $right fails');
    case PulseMatchOp.gte:
      return left >= right ? (true, '') : (false, '$left $op $right fails');
    case PulseMatchOp.lte:
      return left <= right ? (true, '') : (false, '$left $op $right fails');
  }
  return (false, 'op $op not numeric');
}

double? _numericValue(Object? v) {
  if (v is num && v.isFinite) return v.toDouble();
  if (v is String) {
    final t = v.trim();
    if (t.isEmpty) return null;
    return double.tryParse(t);
  }
  return null;
}

// ── SHA-256 (sync, self-contained) ───────────────────────────────────
//
// We deliberately avoid `package:crypto` so this evaluator stays a
// zero-dep file — the SDK already keeps its dependency surface small,
// and a 60-line SHA-256 in a hot eligibility path is fine.

const List<int> _k = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
  0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
  0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
  0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
  0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
  0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

Uint8List _sha256(List<int> data) {
  final bitLen = data.length * 8;
  final paddedLen = ((data.length + 9 + 63) >> 6) << 6;
  final padded = Uint8List(paddedLen);
  padded.setAll(0, data);
  padded[data.length] = 0x80;
  // 64-bit big-endian length at the very end.
  final dv = ByteData.view(padded.buffer);
  dv.setUint32(paddedLen - 8, bitLen ~/ 4294967296, Endian.big);
  dv.setUint32(paddedLen - 4, bitLen & 0xFFFFFFFF, Endian.big);

  final h = Uint32List.fromList([
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c,
    0x1f83d9ab, 0x5be0cd19,
  ]);
  final w = Uint32List(64);

  for (var off = 0; off < paddedLen; off += 64) {
    for (var t = 0; t < 16; t++) {
      w[t] = dv.getUint32(off + t * 4, Endian.big);
    }
    for (var t = 16; t < 64; t++) {
      final s0 =
          _rotr(w[t - 15], 7) ^ _rotr(w[t - 15], 18) ^ (w[t - 15] >> 3);
      final s1 =
          _rotr(w[t - 2], 17) ^ _rotr(w[t - 2], 19) ^ (w[t - 2] >> 10);
      w[t] = (w[t - 16] + s0 + w[t - 7] + s1) & 0xFFFFFFFF;
    }
    var a = h[0], b = h[1], c = h[2], d = h[3];
    var e = h[4], f = h[5], g = h[6], hh = h[7];
    for (var t = 0; t < 64; t++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = (e & f) ^ ((~e & 0xFFFFFFFF) & g);
      final temp1 = (hh + s1 + ch + _k[t] + w[t]) & 0xFFFFFFFF;
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final temp2 = (s0 + maj) & 0xFFFFFFFF;
      hh = g;
      g = f;
      f = e;
      e = (d + temp1) & 0xFFFFFFFF;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) & 0xFFFFFFFF;
    }
    h[0] = (h[0] + a) & 0xFFFFFFFF;
    h[1] = (h[1] + b) & 0xFFFFFFFF;
    h[2] = (h[2] + c) & 0xFFFFFFFF;
    h[3] = (h[3] + d) & 0xFFFFFFFF;
    h[4] = (h[4] + e) & 0xFFFFFFFF;
    h[5] = (h[5] + f) & 0xFFFFFFFF;
    h[6] = (h[6] + g) & 0xFFFFFFFF;
    h[7] = (h[7] + hh) & 0xFFFFFFFF;
  }

  final out = Uint8List(32);
  final odv = ByteData.view(out.buffer);
  for (var i = 0; i < 8; i++) {
    odv.setUint32(i * 4, h[i], Endian.big);
  }
  return out;
}

int _rotr(int x, int n) =>
    (((x >> n) | (x << (32 - n))) & 0xFFFFFFFF);
