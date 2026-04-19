import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/module_registry.dart';
import 'flag_decision.dart';

/// Sankofa Switch — feature flags on Flutter. Construct once after
/// `Sankofa.instance.init()`:
///
/// ```dart
/// await Sankofa.instance.init(apiKey: 'sk_live_...');
/// final switches = SankofaSwitch();
/// // later, from anywhere:
/// if (switches.getFlag('new_checkout')) { ... }
/// ```
///
/// The instance self-registers with the Traffic Cop so the handshake
/// response's `modules.switch` payload flows here automatically.
/// Calls made before the handshake completes return the bundled
/// default or the last persisted decision from SharedPreferences
/// (7-day stale-while-revalidate window).
class SankofaSwitch implements SankofaModule {
  static const String _storageKey = 'sankofa:switch:state';
  static const Duration _staleMax = Duration(days: 7);

  Map<String, FlagDecision> _flags = {};
  String _etag = '';
  int _savedAtMs = 0;
  final Map<String, FlagDecision> _defaults;
  final Map<String, Set<FlagChangeListener>> _listeners = {};
  bool _hydrated = false;

  /// [defaults] are returned synchronously when the handshake hasn't
  /// completed yet AND no persisted cache exists. The wire shape is
  /// the full [FlagDecision] envelope, not just a bool, so callers
  /// can precompute a reason tag for debugging.
  SankofaSwitch({Map<String, FlagDecision>? defaults})
      : _defaults = defaults ?? const {} {
    SankofaModuleRegistry.instance.register(this);
    // Fire-and-forget hydrate from SharedPreferences. `getFlag()` calls
    // made before hydrate completes return the bundled default — the
    // first handful of frames at app launch are the rare window where
    // the cache isn't available yet.
    unawaited(_hydrate());
  }

  @override
  SankofaModuleName get name => SankofaModuleName.switchModule;

  // ── SankofaModule (Traffic Cop hook) ──────────────────────────────

  @override
  Future<void> applyHandshake(Map<String, dynamic> config) async {
    if (config['enabled'] == false) return;
    final incoming = <String, FlagDecision>{};
    final rawFlags = config['flags'] as Map<String, dynamic>?;
    if (rawFlags != null) {
      rawFlags.forEach((key, value) {
        if (value is Map<String, dynamic>) {
          incoming[key] = FlagDecision.fromJson(value);
        }
      });
    }
    final diff = _diff(incoming);
    _flags = incoming;
    _etag = (config['etag'] as String?) ?? '';
    _savedAtMs = DateTime.now().millisecondsSinceEpoch;
    await _persist();
    _fire(diff.changed, diff.removed);
  }

  // ── Public API ────────────────────────────────────────────────────

  /// Returns the boolean value for a flag. Boolean flags return their
  /// evaluated value; variant flags return `true` iff the assigned
  /// variant is not the flag's default variant.
  ///
  /// [defaultValue] is returned when the flag is missing from the
  /// remote config AND from the supplied defaults map.
  bool getFlag(String key, {bool defaultValue = false}) {
    final decision = _resolve(key);
    if (decision == null) return defaultValue;
    return decision.value;
  }

  /// Returns the assigned variant key for a variant flag, or the
  /// supplied default when the flag is missing / not a variant flag.
  String getVariant(String key, {String defaultValue = ''}) {
    final decision = _resolve(key);
    if (decision == null) return defaultValue;
    return decision.variant.isEmpty ? defaultValue : decision.variant;
  }

  /// Full decision envelope — value + variant + reason + version.
  /// Useful for debugging ("why does this user see FALSE?") or for
  /// instrumentation that needs the reason tag.
  FlagDecision? getDecision(String key) => _resolve(key);

  /// Every currently known flag key (union of cached + defaults).
  List<String> getAllKeys() {
    final merged = <String>{..._flags.keys, ..._defaults.keys};
    return merged.toList();
  }

  /// Subscribe to changes for one flag. The callback fires when a
  /// handshake refresh delivers a new decision, OR when the flag is
  /// removed from the config entirely (callback receives `null`).
  ///
  /// Returns an unsubscribe function.
  VoidCallback onChange(String key, FlagChangeListener listener) {
    final bucket = _listeners.putIfAbsent(key, () => <FlagChangeListener>{});
    bucket.add(listener);
    return () {
      final b = _listeners[key];
      if (b == null) return;
      b.remove(listener);
      if (b.isEmpty) _listeners.remove(key);
    };
  }

  /// Composite etag from the last successful handshake. The core
  /// reads this and sends `If-None-Match` on the next refresh so
  /// the server can respond with 304 when nothing has changed.
  String get etag => _etag;

  // ── Internals ─────────────────────────────────────────────────────

  FlagDecision? _resolve(String key) => _flags[key] ?? _defaults[key];

  Future<void> _hydrate() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_storageKey);
      if (raw == null) return;
      final parsed = jsonDecode(raw) as Map<String, dynamic>;
      final savedAt = parsed['savedAt'] as int? ?? 0;
      if (savedAt > 0 &&
          DateTime.now().millisecondsSinceEpoch - savedAt >
              _staleMax.inMilliseconds) {
        // Cache older than 7 days — discard rather than serve stale
        // values for too long. Handshake will repopulate.
        return;
      }
      final flagsRaw = parsed['flags'] as Map<String, dynamic>?;
      if (flagsRaw == null) return;
      final rebuilt = <String, FlagDecision>{};
      flagsRaw.forEach((k, v) {
        if (v is Map<String, dynamic>) {
          rebuilt[k] = FlagDecision.fromJson(v);
        }
      });
      _flags = rebuilt;
      _etag = parsed['etag'] as String? ?? '';
      _savedAtMs = savedAt;
      // Fire listeners attached before hydrate completed — they
      // registered with an empty set, so every cached key looks "new"
      // to them.
      _fire(_flags.keys.toSet(), <String>{});
    } catch (_) {
      // Corrupt JSON — ignore, next apply() overwrites.
    } finally {
      _hydrated = true;
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final payload = <String, dynamic>{
        'flags': _flags.map((k, v) => MapEntry(k, v.toJson())),
        'etag': _etag,
        'savedAt': _savedAtMs,
      };
      await prefs.setString(_storageKey, jsonEncode(payload));
    } catch (_) {
      // Best-effort; in-memory state stays correct.
    }
  }

  _Diff _diff(Map<String, FlagDecision> incoming) {
    final changed = <String>{};
    final removed = <String>{};
    for (final key in _flags.keys) {
      if (!incoming.containsKey(key)) removed.add(key);
    }
    incoming.forEach((key, decision) {
      if (_flags[key] != decision) changed.add(key);
    });
    return _Diff(changed: changed, removed: removed);
  }

  void _fire(Set<String> changed, Set<String> removed) {
    for (final key in changed) {
      final bucket = _listeners[key];
      if (bucket == null) continue;
      final decision = _flags[key];
      for (final listener in bucket) {
        try {
          listener(decision);
        } catch (err, stack) {
          if (kDebugMode) {
            debugPrint(
              '[Sankofa] switch onChange for "$key" threw: $err\n$stack',
            );
          }
        }
      }
    }
    for (final key in removed) {
      final bucket = _listeners[key];
      if (bucket == null) continue;
      for (final listener in bucket) {
        try {
          listener(null);
        } catch (err, stack) {
          if (kDebugMode) {
            debugPrint(
              '[Sankofa] switch onChange (remove) for "$key" threw: $err\n$stack',
            );
          }
        }
      }
    }
  }

  /// Test-only hook — re-runs hydration. Public-API callers should
  /// not need this; the constructor kicks hydration off automatically.
  @visibleForTesting
  Future<void> awaitHydrated() async {
    // Poll rather than expose the private future — keeps the API
    // narrow and survives refactors.
    while (!_hydrated) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }
}

class _Diff {
  final Set<String> changed;
  final Set<String> removed;
  _Diff({required this.changed, required this.removed});
}
