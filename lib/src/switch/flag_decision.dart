// Wire shape that mirrors server/engine/ee/switchmod/evaluator_batch.go.
// Kept colocated with the module so a server rename breaks the Dart
// analyze — silent drift is the worst failure mode for feature-flag
// contracts.

/// Reason tag returned alongside a flag decision. Stable across server
/// releases — SDKs and dashboards may key off these values. Unknown
/// reasons (e.g. a new reason shipped on the server before the SDK
/// knew about it) fall into [FlagReason.unknown].
enum FlagReason {
  archived,
  halted,
  scheduled,
  noRule,
  rollout,
  variantAssigned,
  variantUnavailable,
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
  dependencyUnmet,
  overrideParseError,
  unknown,
}

FlagReason _reasonFromWire(String? raw) {
  switch (raw) {
    case 'archived':
      return FlagReason.archived;
    case 'halted':
      return FlagReason.halted;
    case 'scheduled':
      return FlagReason.scheduled;
    case 'no_rule':
      return FlagReason.noRule;
    case 'rollout':
      return FlagReason.rollout;
    case 'variant_assigned':
      return FlagReason.variantAssigned;
    case 'variant_unavailable':
      return FlagReason.variantUnavailable;
    case 'not_in_rollout':
      return FlagReason.notInRollout;
    case 'in_excluded_cohort':
      return FlagReason.inExcludedCohort;
    case 'not_in_target_cohort':
      return FlagReason.notInTargetCohort;
    case 'cohort_lookup_failed':
      return FlagReason.cohortLookupFailed;
    case 'country_blocked':
      return FlagReason.countryBlocked;
    case 'country_not_in_allow':
      return FlagReason.countryNotInAllow;
    case 'country_unknown':
      return FlagReason.countryUnknown;
    case 'app_version_below_min':
      return FlagReason.appVersionBelowMin;
    case 'app_version_above_max':
      return FlagReason.appVersionAboveMax;
    case 'os_version_below_min':
      return FlagReason.osVersionBelowMin;
    case 'os_version_above_max':
      return FlagReason.osVersionAboveMax;
    case 'not_in_user_allow_list':
      return FlagReason.notInUserAllowList;
    case 'dependency_unmet':
      return FlagReason.dependencyUnmet;
    case 'override_parse_error':
      return FlagReason.overrideParseError;
    default:
      return FlagReason.unknown;
  }
}

String _reasonToWire(FlagReason r) {
  switch (r) {
    case FlagReason.archived:
      return 'archived';
    case FlagReason.halted:
      return 'halted';
    case FlagReason.scheduled:
      return 'scheduled';
    case FlagReason.noRule:
      return 'no_rule';
    case FlagReason.rollout:
      return 'rollout';
    case FlagReason.variantAssigned:
      return 'variant_assigned';
    case FlagReason.variantUnavailable:
      return 'variant_unavailable';
    case FlagReason.notInRollout:
      return 'not_in_rollout';
    case FlagReason.inExcludedCohort:
      return 'in_excluded_cohort';
    case FlagReason.notInTargetCohort:
      return 'not_in_target_cohort';
    case FlagReason.cohortLookupFailed:
      return 'cohort_lookup_failed';
    case FlagReason.countryBlocked:
      return 'country_blocked';
    case FlagReason.countryNotInAllow:
      return 'country_not_in_allow';
    case FlagReason.countryUnknown:
      return 'country_unknown';
    case FlagReason.appVersionBelowMin:
      return 'app_version_below_min';
    case FlagReason.appVersionAboveMax:
      return 'app_version_above_max';
    case FlagReason.osVersionBelowMin:
      return 'os_version_below_min';
    case FlagReason.osVersionAboveMax:
      return 'os_version_above_max';
    case FlagReason.notInUserAllowList:
      return 'not_in_user_allow_list';
    case FlagReason.dependencyUnmet:
      return 'dependency_unmet';
    case FlagReason.overrideParseError:
      return 'override_parse_error';
    case FlagReason.unknown:
      return 'unknown';
  }
}

/// A single flag evaluation result.
///
/// - [value] is the boolean the SDK returns from `getFlag()`. For
///   variant flags, this is `true` iff the assigned variant is
///   non-default — a convenience so callers who just care about
///   "did this flag fire" don't have to inspect [variant].
/// - [variant] is the assigned variant key ("A", "control", ...) for
///   variant flags; empty for boolean flags.
/// - [reason] is the stable tag the server emitted.
/// - [version] is the flag's current version; rotates on every save.
class FlagDecision {
  final bool value;
  final String variant;
  final FlagReason reason;
  final int version;

  const FlagDecision({
    required this.value,
    this.variant = '',
    required this.reason,
    required this.version,
  });

  factory FlagDecision.fromJson(Map<String, dynamic> json) {
    return FlagDecision(
      value: json['value'] as bool? ?? false,
      variant: json['variant'] as String? ?? '',
      reason: _reasonFromWire(json['reason'] as String?),
      version: json['version'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'value': value,
        'variant': variant,
        'reason': _reasonToWire(reason),
        'version': version,
      };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is FlagDecision &&
        other.value == value &&
        other.variant == variant &&
        other.reason == reason &&
        other.version == version;
  }

  @override
  int get hashCode => Object.hash(value, variant, reason, version);
}

/// Callback fired when a flag's decision changes after a handshake
/// refresh. `decision` is `null` when the flag was removed from the
/// config entirely (archived remotely, key renamed, etc).
typedef FlagChangeListener = void Function(FlagDecision? decision);
