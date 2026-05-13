import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

/// Live-presence heartbeat — every ~15s while the app is foregrounded
/// the SDK pings `/api/v1/screens/heartbeat` so the dashboard's
/// "X live now" badge reflects who's actually on each screen.
///
/// Mirrors the web / RN / iOS / Android implementations:
/// `WidgetsBindingObserver` gates the timer (resumed → start, paused
/// → stop). Backgrounded apps stop ticking immediately so we don't
/// paint stale "still live" badges.
///
/// Server-side TTL handles the rest — a missed heartbeat trims the
/// user from the live set after the window. Presence is decorative;
/// failures are silent.
class PresenceHeartbeat with WidgetsBindingObserver {
  PresenceHeartbeat({
    required String endpoint,
    required this.apiKey,
    required this.payloadProvider,
  }) : url = Uri.parse(
          '${endpoint.endsWith('/') ? endpoint.substring(0, endpoint.length - 1) : endpoint}/api/v1/screens/heartbeat',
        );

  final Uri url;
  final String apiKey;
  final ({String? screen, String? distinctId, String? sessionId}) Function()
      payloadProvider;

  static const Duration _interval = Duration(seconds: 15);
  Timer? _timer;
  bool _running = false;

  void start() {
    WidgetsBinding.instance.addObserver(this);
    // Prime once so the badge updates the moment the app launches,
    // not 15s later.
    _beat();
    _scheduleTimer();
  }

  void stop() {
    WidgetsBinding.instance.removeObserver(this);
    _cancelTimer();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Resumed foreground — fire immediately, then resume the
      // timer.
      if (!_running) {
        _beat();
        _scheduleTimer();
      }
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _cancelTimer();
    }
  }

  void _scheduleTimer() {
    _cancelTimer();
    _running = true;
    _timer = Timer.periodic(_interval, (_) => _beat());
  }

  void _cancelTimer() {
    _running = false;
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _beat() async {
    final payload = payloadProvider();
    final screen = payload.screen;
    final distinctId = payload.distinctId;
    if (screen == null || screen.isEmpty) return;
    if (distinctId == null || distinctId.isEmpty) return;

    final body = <String, dynamic>{
      'screen': screen,
      'distinct_id': distinctId,
    };
    final sid = payload.sessionId;
    if (sid != null && sid.isNotEmpty) body['session_id'] = sid;

    try {
      await http.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'x-api-key': apiKey,
        },
        body: jsonEncode(body),
      );
    } catch (_) {
      // Presence is decorative — never throw, never retry.
    }
  }
}
