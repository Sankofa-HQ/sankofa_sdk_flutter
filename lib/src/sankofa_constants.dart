const String kQueueKey = 'sankofa_queue';
const String kAnonIdKey = 'sankofa_anon_id';
const String kUserIdKey = 'sankofa_user_id';
const String kSessionIdKey = 'sankofa_session_id';

/// Monotonic count of distinct sessions started on this device.
/// Incremented once per genuine new session (cold start or post-timeout
/// rotation). Feeds Pulse `session` targeting ("show on every Nth
/// session"); also useful for first-run / Nth-launch analytics.
const String kSessionCountKey = 'sankofa_session_count';
const String kLastEventTimeKey = 'sankofa_last_event_time';
const String kDefaultPropertiesKey = 'sankofa_default_props';

/// Single source of truth for the SDK version. Keep [kSdkVersion] in sync
/// with `version:` in pubspec.yaml (asserted in test). Previously three
/// different hardcoded strings disagreed (track/catch said `flutter-0.1.0`,
/// the integration reporter said `0.1.0`, pubspec said `0.2.0`).
const String kSdkVersion = '0.2.0';
const String kLibVersion = 'flutter-$kSdkVersion';

const int kSessionTimeoutMinutes = 30;
const int kFlushIntervalSeconds = 30;

/// Number of queued events that triggers an eager flush.
const int kMaxQueueSize = 10;

/// Hard cap on persisted analytics events. Beyond this the oldest are dropped
/// so a long offline period (or a server outage) can't grow the queue without
/// bound and turn every enqueue into an O(n) SharedPreferences rewrite.
const int kMaxStoredEvents = 500;

/// Events older than this are dropped rather than shipped — stale events
/// pollute time-series data and a multi-day-old event has no analytics value.
const Duration kEventTtl = Duration(hours: 48);

/// Internal-only key stamped on each queued event for TTL/age tracking.
/// Stripped from the payload before transport.
const String kEnqueuedAtField = r'$sankofa_enqueued_ms';
