import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/module_registry.dart';
import 'item_decision.dart';

/// Sankofa Config — remote config on Flutter. Typed variables
/// (string/int/float/bool/json) with cohort-targeted payloads and
/// version history on the server side. The SDK owns:
///
/// - Synchronous reads that prefer the freshest persisted value.
/// - Per-item change subscriptions via [onChange].
/// - A 7-day stale-while-revalidate window on the local cache so
///   users who launch the app offline still see sensible values.
///
/// Construct once after `Sankofa.instance.init()`:
///
/// ```dart
/// await Sankofa.instance.init(apiKey: 'sk_live_...');
/// final cfg = SankofaConfig();
/// final max = cfg.get<int>('max_upload_mb', 25);
/// ```
class SankofaConfig implements SankofaModule {
  static const String _storageKey = 'sankofa:config:state';
  static const Duration _staleMax = Duration(days: 7);

  Map<String, ItemDecision> _values = {};
  String _etag = '';
  int _savedAtMs = 0;
  final Map<String, ItemDecision> _defaults;
  final Map<String, Set<ConfigChangeListener>> _listeners = {};
  bool _hydrated = false;

  /// [defaults] are the fallbacks used when the handshake hasn't
  /// landed and no persisted cache exists. They must be the full
  /// [ItemDecision] envelope so each one carries its type — a
  /// `string` default supplied for a `json` item will still resolve
  /// correctly because the typed `get<T>` path respects the default's
  /// declared type.
  SankofaConfig({Map<String, ItemDecision>? defaults})
      : _defaults = defaults ?? const {} {
    SankofaModuleRegistry.instance.register(this);
    unawaited(_hydrate());
  }

  @override
  SankofaModuleName get name => SankofaModuleName.configModule;

  // ── SankofaModule (Traffic Cop hook) ──────────────────────────────

  @override
  Future<void> applyHandshake(Map<String, dynamic> config) async {
    if (config['enabled'] == false) return;
    final incoming = <String, ItemDecision>{};
    final rawValues = config['values'] as Map<String, dynamic>?;
    if (rawValues != null) {
      rawValues.forEach((key, value) {
        if (value is Map<String, dynamic>) {
          incoming[key] = ItemDecision.fromJson(value);
        }
      });
    }
    final diff = _diff(incoming);
    _values = incoming;
    _etag = (config['etag'] as String?) ?? '';
    _savedAtMs = DateTime.now().millisecondsSinceEpoch;
    await _persist();
    _fire(diff.changed, diff.removed);
  }

  // ── Public API ────────────────────────────────────────────────────

  /// Typed lookup. The generic [T] carries the expected type so the
  /// caller gets the right type back without casting. If the stored
  /// value doesn't match [T] (e.g. the server shipped a `string`
  /// where the caller asked for `int`), [defaultValue] is returned —
  /// a mismatch is the same as a missing key.
  ///
  /// Supported Ts: `String`, `int`, `double`, `bool`, `Map`, `List`,
  /// and `num` (accepts both int and float).
  T get<T>(String key, T defaultValue) {
    final decision = _resolve(key);
    if (decision == null || decision.value == null) return defaultValue;
    final v = decision.value;
    if (v is T) return v;
    // Allow int → double and double → int narrowing because the server
    // emits both as `num` over JSON; Dart clients may ask for either.
    if (T == double && v is num) return v.toDouble() as T;
    if (T == int && v is num) return v.toInt() as T;
    return defaultValue;
  }

  /// Full decision envelope including reason + version + type.
  ItemDecision? getDecision(String key) => _resolve(key);

  /// Every known key (union of remote + local defaults).
  List<String> getAllKeys() {
    return <String>{..._values.keys, ..._defaults.keys}.toList();
  }

  /// Plain `{ key: value }` snapshot of the whole config surface.
  /// Handy for "replace my global settings object on refresh" flows.
  Map<String, Object?> getAll() {
    final out = <String, Object?>{};
    _defaults.forEach((k, d) => out[k] = d.value);
    _values.forEach((k, d) => out[k] = d.value);
    return out;
  }

  /// Subscribe to changes for one key. Returns an unsubscribe fn.
  VoidCallback onChange(String key, ConfigChangeListener listener) {
    final bucket = _listeners.putIfAbsent(key, () => <ConfigChangeListener>{});
    bucket.add(listener);
    return () {
      final b = _listeners[key];
      if (b == null) return;
      b.remove(listener);
      if (b.isEmpty) _listeners.remove(key);
    };
  }

  /// Composite etag from the last successful handshake. The core
  /// sends this as `If-None-Match` on refresh.
  String get etag => _etag;

  // ── Internals ─────────────────────────────────────────────────────

  ItemDecision? _resolve(String key) => _values[key] ?? _defaults[key];

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
        return;
      }
      final valuesRaw = parsed['values'] as Map<String, dynamic>?;
      if (valuesRaw == null) return;
      final rebuilt = <String, ItemDecision>{};
      valuesRaw.forEach((k, v) {
        if (v is Map<String, dynamic>) {
          rebuilt[k] = ItemDecision.fromJson(v);
        }
      });
      _values = rebuilt;
      _etag = parsed['etag'] as String? ?? '';
      _savedAtMs = savedAt;
      _fire(_values.keys.toSet(), <String>{});
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
        'values': _values.map((k, v) => MapEntry(k, v.toJson())),
        'etag': _etag,
        'savedAt': _savedAtMs,
      };
      await prefs.setString(_storageKey, jsonEncode(payload));
    } catch (_) {
      /* best-effort */
    }
  }

  _Diff _diff(Map<String, ItemDecision> incoming) {
    final changed = <String>{};
    final removed = <String>{};
    for (final key in _values.keys) {
      if (!incoming.containsKey(key)) removed.add(key);
    }
    incoming.forEach((key, decision) {
      if (_values[key] != decision) changed.add(key);
    });
    return _Diff(changed: changed, removed: removed);
  }

  void _fire(Set<String> changed, Set<String> removed) {
    for (final key in changed) {
      final bucket = _listeners[key];
      if (bucket == null) continue;
      final decision = _values[key];
      for (final listener in bucket) {
        try {
          listener(decision);
        } catch (err, stack) {
          if (kDebugMode) {
            debugPrint(
              '[Sankofa] config onChange for "$key" threw: $err\n$stack',
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
              '[Sankofa] config onChange (remove) for "$key" threw: $err\n$stack',
            );
          }
        }
      }
    }
  }

  @visibleForTesting
  Future<void> awaitHydrated() async {
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
