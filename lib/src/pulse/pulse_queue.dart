import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'pulse_models.dart';

/// Persistent queue for offline survey submissions. Backed by
/// SharedPreferences — survey volumes are low (a handful of
/// completions per session), so the simpler key-value store wins
/// over pulling in path_provider just for one JSON file.
///
/// Concurrency: every public method awaits a single `_lock` future,
/// so concurrent enqueue/drain calls serialise cleanly. The store
/// key is rewritten in full on every persist; SharedPreferences
/// guarantees an atomic write per key on every platform we ship.
class PulseQueue {
  static const String _storageKey = 'sankofa:pulse:queue';

  Future<void>? _lock;
  List<PulseSubmitPayload> _pending = [];
  bool _hydrated = false;

  Future<void> _withLock<T>(Future<T> Function() body) async {
    final prev = _lock;
    final completer = Completer<void>();
    _lock = completer.future;
    try {
      if (prev != null) await prev;
      await body();
    } finally {
      completer.complete();
    }
  }

  Future<void> _ensureHydrated() async {
    if (_hydrated) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_storageKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          _pending = decoded
              .whereType<Map<String, dynamic>>()
              .map(PulseSubmitPayload.fromJson)
              .toList();
        }
      }
    } catch (_) {
      // Corrupt JSON — drop and start fresh.
      _pending = [];
    } finally {
      _hydrated = true;
    }
  }

  Future<int> count() async {
    await _ensureHydrated();
    return _pending.length;
  }

  Future<void> enqueue(PulseSubmitPayload payload) async {
    await _withLock(() async {
      await _ensureHydrated();
      _pending.add(payload);
      await _persist();
    });
  }

  /// Drain attempts to flush every pending payload through the
  /// supplied submit function. Successes are removed; failures stay
  /// in the queue for the next drain.
  Future<PulseDrainResult> drain(
    Future<PulseSubmitResponse> Function(PulseSubmitPayload) submit,
  ) async {
    var sent = 0;
    var failed = 0;
    await _withLock(() async {
      await _ensureHydrated();
      if (_pending.isEmpty) return;
      final snapshot = List<PulseSubmitPayload>.from(_pending);
      final remaining = <PulseSubmitPayload>[];
      for (final p in snapshot) {
        try {
          await submit(p);
          sent += 1;
        } catch (_) {
          failed += 1;
          remaining.add(p);
        }
      }
      _pending = remaining;
      await _persist();
    });
    return PulseDrainResult(sent: sent, failed: failed);
  }

  Future<void> clear() async {
    await _withLock(() async {
      _pending = [];
      _hydrated = true;
      await _persist();
    });
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = jsonEncode(_pending.map((p) => p.toJson()).toList());
      await prefs.setString(_storageKey, encoded);
    } catch (_) {
      // Disk-full or sandbox failure — keep the in-memory copy so
      // the next attempt this session has a chance, accept worst-case
      // loss on app death.
    }
  }
}

class PulseDrainResult {
  final int sent;
  final int failed;
  const PulseDrainResult({required this.sent, required this.failed});
}
