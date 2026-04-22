import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:isolate';
import 'dart:math' show Random;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../core/module_registry.dart';
import '../sankofa_client.dart';
import 'catch_stack_parser.dart';
import 'catch_types.dart';

/// Sankofa Catch — error tracking for Flutter. Construct once after
/// `Sankofa.instance.init()`:
///
/// ```dart
/// await Sankofa.instance.init(apiKey: 'sk_live_...');
/// final catcher = SankofaCatch(
///   environment: 'live',
///   readFlagSnapshot: () => switches.getAllKeys().asMap().map(...),
/// );
///
/// try { doThing(); } catch (e, st) { catcher.captureException(e, st); }
/// ```
///
/// Uncaught Dart exceptions and async errors are captured
/// automatically via `FlutterError.onError` and
/// `PlatformDispatcher.instance.onError`. The instance self-registers
/// with the Traffic Cop; handshake payloads flow in automatically.
class SankofaCatch implements SankofaModule {
  static const String _queueKey = 'sankofa:catch:queue';
  static const int _defaultBatchSize = 20;
  static const Duration _flushInterval = Duration(seconds: 5);
  static const int _maxStorageBytes = 512 * 1024;

  final String environment;
  final String? release;
  final String? appVersion;
  final Map<String, String> Function()? readFlagSnapshot;
  final Map<String, dynamic> Function()? readConfigSnapshot;

  final List<CatchEvent> _buffer = [];
  final _BreadcrumbRing _breadcrumbs = _BreadcrumbRing(100);

  bool _enabled = true;
  double _errorSampleRate = 1.0;
  Timer? _flushTimer;

  CatchUserContext? _user;
  final Map<String, String> _tags = {};
  final Map<String, dynamic> _extra = {};

  FlutterExceptionHandler? _previousFlutterOnError;
  ErrorCallback? _previousPlatformOnError;
  bool _handlersInstalled = false;
  bool _hydrated = false;

  SankofaCatch({
    this.environment = 'live',
    this.release,
    this.appVersion,
    bool captureUnhandled = true,
    bool captureRejections = true,
    this.readFlagSnapshot,
    this.readConfigSnapshot,
  }) {
    SankofaModuleRegistry.instance.register(this);
    unawaited(_hydrate());
    _flushTimer = Timer.periodic(_flushInterval, (_) => unawaited(flush()));
    if (captureUnhandled || captureRejections) {
      _installHandlers(captureUnhandled: captureUnhandled, captureRejections: captureRejections);
    }
  }

  @override
  SankofaModuleName get name => SankofaModuleName.catchModule;

  // ── Traffic Cop hook ──────────────────────────────────────────

  @override
  Future<void> applyHandshake(Map<String, dynamic> config) async {
    final cfg = CatchHandshakeConfig.fromJson(config);
    if (cfg.enabled == false) {
      _enabled = false;
      return;
    }
    _enabled = true;
    if (cfg.errorSampleRate != null) {
      _errorSampleRate = cfg.errorSampleRate!.clamp(0.0, 1.0);
    }
    if (cfg.breadcrumbsMaxBuffer != null) {
      _breadcrumbs.capacity = cfg.breadcrumbsMaxBuffer!;
    }
  }

  // ── Public API ───────────────────────────────────────────────

  String captureException(Object error, [Object? stackTrace, CatchCaptureOptions? options]) {
    return _capture(
      error: error,
      stackTrace: stackTrace,
      message: null,
      type: 'unhandled_exception',
      options: options,
      mechanism: const CatchMechanism(type: 'manual', handled: true),
    );
  }

  String captureMessage(String message, [CatchCaptureOptions? options]) {
    return _capture(
      error: null,
      stackTrace: null,
      message: message,
      type: 'console_error',
      options: options,
      mechanism: null,
    );
  }

  void addBreadcrumb(CatchBreadcrumb crumb) => _breadcrumbs.push(crumb);

  void setUser(CatchUserContext? user) => _user = user;
  void setTags(Map<String, String> tags) => _tags.addAll(tags);
  void setExtra(String key, dynamic value) => _extra[key] = value;

  /// Flush pending events to the server. No-op if empty.
  Future<void> flush() async {
    if (_buffer.isEmpty) return;
    final batch = List<CatchEvent>.from(_buffer);
    _buffer.clear();
    await _persist();

    final endpoint = Sankofa.instance.endpoint;
    final apiKey = Sankofa.instance.apiKey;
    if (endpoint == null || apiKey == null) {
      // Config unavailable — restore buffer so next tick tries again.
      _buffer.insertAll(0, batch);
      await _persist();
      return;
    }

    final url = Uri.parse('${endpoint.replaceAll(RegExp(r'/$'), '')}/api/catch/events');
    try {
      await http.post(
        url,
        headers: {'Content-Type': 'application/json', 'x-api-key': apiKey},
        body: jsonEncode({
          'wire_version': kCatchWireVersion,
          'events': batch.map((e) => e.toJson()).toList(),
        }),
      );
    } catch (e) {
      // Network failure — requeue so the next tick tries again.
      if (kDebugMode) debugPrint('[Sankofa Catch] flush failed: $e');
      _buffer.insertAll(0, batch);
      await _persist();
    }
  }

  /// Teardown — uninstalls error handlers, cancels the flush timer.
  /// Useful for hot-reload dev loops; not required in production.
  void shutdown() {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_handlersInstalled) {
      FlutterError.onError = _previousFlutterOnError;
      PlatformDispatcher.instance.onError = _previousPlatformOnError;
      _handlersInstalled = false;
    }
  }

  // ── Global handler wiring ────────────────────────────────────

  void _installHandlers({required bool captureUnhandled, required bool captureRejections}) {
    if (_handlersInstalled) return;
    _handlersInstalled = true;

    if (captureUnhandled) {
      _previousFlutterOnError = FlutterError.onError;
      FlutterError.onError = (FlutterErrorDetails details) {
        try {
          _capture(
            error: details.exception,
            stackTrace: details.stack,
            message: null,
            type: 'unhandled_exception',
            options: null,
            mechanism: CatchMechanism(
              type: 'flutter_error',
              handled: false,
              description: details.context?.toString(),
            ),
          );
        } catch (_) {
          /* never throw from our own handler */
        }
        // Chain to whatever the host app (or Flutter's default) had.
        _previousFlutterOnError?.call(details);
      };
    }

    if (captureRejections) {
      _previousPlatformOnError = PlatformDispatcher.instance.onError;
      PlatformDispatcher.instance.onError = (error, stackTrace) {
        try {
          _capture(
            error: error,
            stackTrace: stackTrace,
            message: null,
            type: 'unhandled_rejection',
            options: null,
            mechanism: const CatchMechanism(type: 'platform_dispatcher', handled: false),
          );
        } catch (_) {
          /* never throw from our own handler */
        }
        // Chain; return true so async errors continue to propagate
        // according to the host's own policy.
        return _previousPlatformOnError?.call(error, stackTrace) ?? true;
      };

      // ── Isolate error listener ─────────────────────────────────
      //
      // FlutterError.onError + PlatformDispatcher only capture
      // errors inside the root isolate's zone. Errors raised inside
      // compute() / spawn()'d isolates escape both handlers and
      // silently crash that isolate while the app keeps running.
      //
      // Isolate.current.addErrorListener fixes this — it receives
      // every (error, stackTrace) pair from the isolate it's
      // registered on. Chaining isn't needed here because
      // addErrorListener appends rather than replacing.
      try {
        final receivePort = ReceivePort();
        receivePort.listen((dynamic message) {
          // Isolate sends error messages as a 2-element list:
          // [errorString, stackTraceString].
          if (message is List && message.length == 2) {
            final errorText = message[0]?.toString() ?? 'isolate error';
            final stackText = message[1]?.toString();
            final stack = stackText == null ? null : StackTrace.fromString(stackText);
            try {
              _capture(
                error: errorText,
                stackTrace: stack,
                message: null,
                type: 'unhandled_rejection',
                options: null,
                mechanism: const CatchMechanism(
                  type: 'isolate_error',
                  handled: false,
                  description: 'error escaped an isolate zone',
                ),
              );
            } catch (_) { /* never throw from handler */ }
          }
        });
        Isolate.current.addErrorListener(receivePort.sendPort);
      } catch (_) {
        // Some Flutter Web builds don't support Isolate APIs; swallow
        // so the plugin still initialises on every platform.
      }
    }
  }

  // ── Event composition ────────────────────────────────────────

  String _capture({
    required Object? error,
    required Object? stackTrace,
    required String? message,
    required String type,
    required CatchCaptureOptions? options,
    required CatchMechanism? mechanism,
  }) {
    if (!_enabled) return '';
    if (!_shouldSample()) return '';

    final level = options?.level ?? (type == 'console_error' ? CatchLevel.warning : CatchLevel.error);

    CatchException? exc;
    String? msg;
    if (message != null) {
      msg = message;
    } else if (error != null) {
      exc = errorToException(error, stackTrace, mechanism: mechanism);
    }

    final eventId = _randomId();
    final ev = CatchEvent(
      eventId: eventId,
      tsMs: DateTime.now().millisecondsSinceEpoch,
      environment: environment,
      distinctId: Sankofa.instance.identity?.distinctId,
      anonId: _maybeAnonId(),
      sessionId: Sankofa.instance.sessionManager?.sessionId,
      level: level,
      type: type,
      exception: exc,
      message: msg,
      tags: {..._tags, ...?options?.tags},
      extra: {..._extra, ...?options?.extra},
      user: options?.user ?? _user,
      device: _buildDeviceContext(),
      release: release,
      platform: 'flutter',
      sdk: {'name': 'sankofa.flutter', 'version': 'flutter-0.1.0'},
      breadcrumbs: _breadcrumbs.snapshot(),
      fingerprint: options?.fingerprint,
      flagSnapshot: readFlagSnapshot?.call(),
      configSnapshot: readConfigSnapshot?.call(),
      traceId: options?.traceId,
      spanId: options?.spanId,
    );

    _buffer.add(ev);
    unawaited(_persist());
    if (_buffer.length >= _defaultBatchSize) {
      unawaited(flush());
    }
    return eventId;
  }

  String? _maybeAnonId() {
    final id = Sankofa.instance.identity;
    if (id == null) return null;
    final distinct = id.distinctId;
    final anon = id.anonymousId;
    if (anon == null || anon.isEmpty) return null;
    if (anon == distinct) return null;
    return anon;
  }

  CatchDeviceContext _buildDeviceContext() {
    try {
      return CatchDeviceContext(
        os: Platform.operatingSystem,
        osVersion: Platform.operatingSystemVersion,
        locale: Platform.localeName,
        appVersion: appVersion,
      );
    } catch (_) {
      return const CatchDeviceContext();
    }
  }

  bool _shouldSample() {
    if (_errorSampleRate >= 1) return true;
    if (_errorSampleRate <= 0) return false;
    return Random().nextDouble() < _errorSampleRate;
  }

  // ── Persistence — shared_preferences-backed ──────────────────

  Future<void> _hydrate() async {
    if (_hydrated) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_queueKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final entry in decoded) {
            if (entry is Map) {
              _buffer.add(_eventFromJson(Map<String, dynamic>.from(entry)));
            }
          }
          if (kDebugMode) debugPrint('[Sankofa Catch] recovered ${_buffer.length} persisted events');
        }
      }
    } catch (_) {
      try {
        (await SharedPreferences.getInstance()).remove(_queueKey);
      } catch (_) {}
    } finally {
      _hydrated = true;
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      var serialised = jsonEncode(_buffer.map((e) => e.toJson()).toList());
      while (serialised.length > _maxStorageBytes && _buffer.length > 1) {
        _buffer.removeAt(0);
        serialised = jsonEncode(_buffer.map((e) => e.toJson()).toList());
      }
      await prefs.setString(_queueKey, serialised);
    } catch (_) {
      /* storage unavailable — continue */
    }
  }

  /// Minimal decoder — covers the fields the persistence layer
  /// round-trips. Good enough for recovery since we just need to
  /// re-POST the batch; full fidelity is not required.
  CatchEvent _eventFromJson(Map<String, dynamic> j) {
    return CatchEvent(
      eventId: j['event_id'] as String? ?? _randomId(),
      tsMs: (j['ts_ms'] as int?) ?? DateTime.now().millisecondsSinceEpoch,
      environment: j['environment'] as String? ?? environment,
      level: _parseLevel(j['level'] as String?) ?? CatchLevel.error,
      type: j['type'] as String? ?? 'unhandled_exception',
      platform: j['platform'] as String? ?? 'flutter',
      sdk: Map<String, String>.from(
        (j['sdk'] as Map?)?.cast<String, String>() ??
            {'name': 'sankofa.flutter', 'version': 'flutter-0.1.0'},
      ),
      message: j['message'] as String?,
      tags: (j['tags'] as Map?)?.cast<String, String>(),
      extra: (j['extra'] as Map?)?.cast<String, dynamic>(),
    );
  }
}

// ── Helpers ─────────────────────────────────────────────────────

CatchLevel? _parseLevel(String? raw) {
  switch (raw) {
    case 'fatal':
      return CatchLevel.fatal;
    case 'error':
      return CatchLevel.error;
    case 'warning':
      return CatchLevel.warning;
    case 'info':
      return CatchLevel.info;
    case 'debug':
      return CatchLevel.debug;
  }
  return null;
}

String _randomId() {
  final r = Random();
  String hex() => r.nextInt(0xFFFFFFFF).toRadixString(16).padLeft(8, '0');
  return '${hex()}-${hex()}';
}

class _BreadcrumbRing {
  int capacity;
  final List<CatchBreadcrumb> _items = [];
  _BreadcrumbRing(this.capacity);
  void push(CatchBreadcrumb b) {
    _items.add(b);
    while (_items.length > capacity) {
      _items.removeAt(0);
    }
  }

  List<CatchBreadcrumb> snapshot() => List<CatchBreadcrumb>.from(_items);
}
