// Wire shape that mirrors server/engine/ee/configmod/evaluator_batch.go.

/// Concrete data type of a config item. Declared on the server and
/// echoed in every decision so the SDK doesn't need to re-parse JSON
/// values.
enum ConfigType { string, int_, float, bool_, json }

extension ConfigTypeExt on ConfigType {
  String get wireName {
    switch (this) {
      case ConfigType.string:
        return 'string';
      case ConfigType.int_:
        return 'int';
      case ConfigType.float:
        return 'float';
      case ConfigType.bool_:
        return 'bool';
      case ConfigType.json:
        return 'json';
    }
  }
}

ConfigType _typeFromWire(String? raw) {
  switch (raw) {
    case 'string':
      return ConfigType.string;
    case 'int':
      return ConfigType.int_;
    case 'float':
      return ConfigType.float;
    case 'bool':
      return ConfigType.bool_;
    case 'json':
      return ConfigType.json;
    default:
      return ConfigType.string;
  }
}

/// Reason an item resolved the way it did. Stable across server
/// releases; unknown reasons fall into [ItemReason.unknown].
enum ItemReason {
  archived,
  noRule,
  ruleMatched,
  notInRollout,
  inExcludedCohort,
  notInTargetCohort,
  cohortLookupFailed,
  countryBlocked,
  countryNotInAllow,
  countryUnknown,
  appVersionBelowMin,
  appVersionAboveMax,
  osVersionBelowMin,
  osVersionAboveMax,
  notInUserAllowList,
  unknown,
}

ItemReason _reasonFromWire(String? raw) {
  switch (raw) {
    case 'archived':
      return ItemReason.archived;
    case 'no_rule':
      return ItemReason.noRule;
    case 'rule_matched':
      return ItemReason.ruleMatched;
    case 'not_in_rollout':
      return ItemReason.notInRollout;
    case 'in_excluded_cohort':
      return ItemReason.inExcludedCohort;
    case 'not_in_target_cohort':
      return ItemReason.notInTargetCohort;
    case 'cohort_lookup_failed':
      return ItemReason.cohortLookupFailed;
    case 'country_blocked':
      return ItemReason.countryBlocked;
    case 'country_not_in_allow':
      return ItemReason.countryNotInAllow;
    case 'country_unknown':
      return ItemReason.countryUnknown;
    case 'app_version_below_min':
      return ItemReason.appVersionBelowMin;
    case 'app_version_above_max':
      return ItemReason.appVersionAboveMax;
    case 'os_version_below_min':
      return ItemReason.osVersionBelowMin;
    case 'os_version_above_max':
      return ItemReason.osVersionAboveMax;
    case 'not_in_user_allow_list':
      return ItemReason.notInUserAllowList;
    default:
      return ItemReason.unknown;
  }
}

String _reasonToWire(ItemReason r) {
  switch (r) {
    case ItemReason.archived:
      return 'archived';
    case ItemReason.noRule:
      return 'no_rule';
    case ItemReason.ruleMatched:
      return 'rule_matched';
    case ItemReason.notInRollout:
      return 'not_in_rollout';
    case ItemReason.inExcludedCohort:
      return 'in_excluded_cohort';
    case ItemReason.notInTargetCohort:
      return 'not_in_target_cohort';
    case ItemReason.cohortLookupFailed:
      return 'cohort_lookup_failed';
    case ItemReason.countryBlocked:
      return 'country_blocked';
    case ItemReason.countryNotInAllow:
      return 'country_not_in_allow';
    case ItemReason.countryUnknown:
      return 'country_unknown';
    case ItemReason.appVersionBelowMin:
      return 'app_version_below_min';
    case ItemReason.appVersionAboveMax:
      return 'app_version_above_max';
    case ItemReason.osVersionBelowMin:
      return 'os_version_below_min';
    case ItemReason.osVersionAboveMax:
      return 'os_version_above_max';
    case ItemReason.notInUserAllowList:
      return 'not_in_user_allow_list';
    case ItemReason.unknown:
      return 'unknown';
  }
}

/// One decision per config item. [value] is already typed per [type]
/// — server decodes JSON before emitting, so the SDK doesn't re-parse.
class ItemDecision {
  /// Stored as [dynamic] on purpose — the wire shape is String for
  /// string, num for int/float, bool for bool, and arbitrary JSON
  /// (Map/List/primitive) for json. Callers use [SankofaConfig.get<T>]
  /// to get a strongly-typed value back.
  final Object? value;
  final ConfigType type;
  final ItemReason reason;
  final int version;

  const ItemDecision({
    required this.value,
    required this.type,
    required this.reason,
    required this.version,
  });

  factory ItemDecision.fromJson(Map<String, dynamic> json) {
    return ItemDecision(
      value: json['value'],
      type: _typeFromWire(json['type'] as String?),
      reason: _reasonFromWire(json['reason'] as String?),
      version: json['version'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'value': value,
        'type': type.wireName,
        'reason': _reasonToWire(reason),
        'version': version,
      };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! ItemDecision) return false;
    return other.version == version &&
        other.type == type &&
        other.reason == reason &&
        _valueEquals(other.value, value);
  }

  @override
  int get hashCode => Object.hash(
        version,
        type,
        reason,
        _valueHash(value),
      );
}

bool _valueEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return a == b;
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (!_valueEquals(entry.value, b[entry.key])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_valueEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

int _valueHash(Object? v) {
  if (v is Map) {
    return Object.hashAllUnordered(
      v.entries.map((e) => Object.hash(e.key, _valueHash(e.value))),
    );
  }
  if (v is List) {
    return Object.hashAll(v.map(_valueHash));
  }
  return v.hashCode;
}

/// Callback fired when an item's decision changes after a handshake
/// refresh. `decision` is `null` when the item was removed remotely.
typedef ConfigChangeListener = void Function(ItemDecision? decision);
