import 'package:flutter/foundation.dart';

/// Status of a `checkForKbcUpdate` call.
///
/// Mirrors Shorebird's `UpdateStatus` enum so customers migrating
/// between the two SDKs see the same value set. `bannedLocally` is
/// Sankofa-specific — it means the device's auto-rollback subsystem
/// has previously flagged this label as crash-loop bad and the SDK
/// refuses to re-download it until the host clears the local ban.
enum SankofaUpdateStatus {
  /// Server returned `has_update: false`. No patch to stage.
  upToDate,

  /// A new patch is available. See [SankofaUpdateCheckResult.update]
  /// for label, size, signed download URL, and mandatory flag.
  outdated,

  /// Could not reach the server (DNS failure, TCP refused, timeout,
  /// 5xx). The host should treat this as transient — try again on
  /// next launch / resume.
  unavailable,

  /// Configuration error from the server (4xx other than auth) —
  /// usually a mismatched `engine_version` or unknown `app_version`.
  /// Reason string is in [SankofaUpdateCheckResult.reason].
  invalidConfig,

  /// The latest available patch has the same label as a previous
  /// patch that auto-rolled-back on this device. The recorder
  /// refuses to re-download until the host calls
  /// `Sankofa.deploy.clearBannedKbcLabels()`.
  bannedLocally,
}

/// Patch metadata returned by `checkForKbcUpdate` when status is
/// [SankofaUpdateStatus.outdated]. Mirrors Shorebird's `Patch` plus
/// the fields the Sankofa server actually exposes.
@immutable
class SankofaUpdate {
  /// Human-readable release label (e.g. `"v1.2.0-patch.3"`). Same
  /// label the dashboard's Releases view displays.
  final String label;

  /// Stable release identifier (e.g. `"rel_*"`). Useful for analytics
  /// + cross-referencing with the dashboard. May be empty if the
  /// server didn't surface it.
  final String releaseId;

  /// Signed CDN URL the SDK fetches the envelope from. Time-limited
  /// (~15 min on B2). Do not persist this URL — re-check if you need
  /// to download later.
  final String downloadUrl;

  /// SHA-256 of the envelope bytes. The SDK verifies this end-to-end
  /// during download; the field is exposed so a host can show "Patch
  /// signed: abc12345…" in a debug UI.
  final String sha256;

  /// Envelope size in bytes. Used to drive a progress bar before the
  /// download starts ("Downloading 240 KB…"). Zero when the server
  /// didn't include it (legacy releases).
  final int sizeBytes;

  /// True iff the release was marked mandatory in the dashboard. The
  /// host should skip any "Update?" prompt and download immediately;
  /// optional updates should be gated behind a user confirmation.
  final bool isMandatory;

  const SankofaUpdate({
    required this.label,
    required this.releaseId,
    required this.downloadUrl,
    required this.sha256,
    required this.sizeBytes,
    required this.isMandatory,
  });

  @override
  String toString() =>
      'SankofaUpdate(label: $label, mandatory: $isMandatory, size: $sizeBytes B)';
}

/// Information about the currently-installed patch on this device.
/// Returned by `readCurrentKbcPatch` — `null` when no patch has ever
/// been applied (the app is running its baseline AOT code).
///
/// Mirrors Shorebird's `Patch`. Sankofa exposes the human label
/// rather than just a number, since releases are label-keyed (e.g.
/// `"v1.2.0-patch.3"`).
@immutable
class SankofaCurrentPatch {
  /// Label of the active patch. Same string the dashboard shows.
  final String label;

  /// Release identifier, when available.
  final String? releaseId;

  /// When the patch was first promoted to the `last_good` slot
  /// (i.e. the boot it survived). Roughly "when this patch became
  /// stable on this device". Null when the metadata file lacks a
  /// timestamp (older patches).
  final DateTime? appliedAt;

  const SankofaCurrentPatch({
    required this.label,
    this.releaseId,
    this.appliedAt,
  });

  @override
  String toString() => 'SankofaCurrentPatch(label: $label)';
}

/// Result of a `checkForKbcUpdate` call.
@immutable
class SankofaUpdateCheckResult {
  /// Status. Drives the host's branching.
  final SankofaUpdateStatus status;

  /// The new patch, when [status] is [SankofaUpdateStatus.outdated].
  /// Null otherwise.
  final SankofaUpdate? update;

  /// Server-supplied reason string. Most useful when [status] is
  /// [SankofaUpdateStatus.unavailable] or
  /// [SankofaUpdateStatus.invalidConfig]. Examples:
  /// `"network_error:check:SocketException..."`, `"engine_unknown"`.
  final String? reason;

  const SankofaUpdateCheckResult({
    required this.status,
    this.update,
    this.reason,
  });

  /// Convenience getter — returns true when [status] is `outdated`.
  bool get hasUpdate => status == SankofaUpdateStatus.outdated;

  @override
  String toString() =>
      'SankofaUpdateCheckResult(status: $status, update: $update, reason: $reason)';
}
