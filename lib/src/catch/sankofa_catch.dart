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
import '../switch/sankofa_switch.dart';
import '../config/sankofa_config.dart';
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

  /// Singleton accessor for the active Catch instance.  Set the first
  /// time [SankofaCatch] is constructed (typically during
  /// `Sankofa.instance.init(catch: true)`).  The static helpers on the
  /// public [Sankofa] class — `Sankofa.captureException`, `Sankofa.log`,
  /// etc. — read this so host code never needs to thread an instance
  /// reference through every screen.  Returns null when Catch was
  /// disabled at init or `init()` hasn't run yet — the helpers all
  /// degrade to no-ops in that case.
  static SankofaCatch? _instance;
  static SankofaCatch? get instance => _instance;

  final String environment;
  final String? release;
  final String? appVersion;
  /// When non-null, called at every capture to read the active feature-
  /// flag decisions.  When null (the default after Phase A), Catch
  /// auto-discovers the registered [SankofaSwitch] from the module
  /// registry and reads its decisions directly — no boilerplate.
  final Map<String, String> Function()? readFlagSnapshot;
  /// Same as [readFlagSnapshot] but for [SankofaConfig] remote values.
  final Map<String, dynamic> Function()? readConfigSnapshot;
  /// Synchronous hook fired AFTER event composition but BEFORE the
  /// transport enqueues. Return `null` to drop, return the (possibly
  /// modified) event to ship. Throws are swallowed — a host hook can
  /// never block the capture pipeline.
  final BeforeSendFn? beforeSend;

  /// Stack of active [SankofaCatchScope] instances pushed by
  /// [withScope]. The top scope overlays onto every capture inside
  /// the closure; async captures deferred past the closure's return
  /// will NOT see the scope (it was popped in `finally`).
  final List<SankofaCatchScope> _scopeStack = [];

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
    this.beforeSend,
  }) {
    // Static singleton lock-in.  First instance wins so multiple
    // accidental constructions (hot reload, nested test setup) don't
    // shadow each other.  Hosts that genuinely need a fresh instance
    // call [shutdown] first to clear it.
    _instance ??= this;
    SankofaModuleRegistry.instance.register(this);
    unawaited(_hydrate());
    _flushTimer = Timer.periodic(_flushInterval, (_) => unawaited(flush()));
    if (captureUnhandled || captureRejections) {
      _installHandlers(captureUnhandled: captureUnhandled, captureRejections: captureRejections);
    }
  }

  /// Crashlytics-style structured log.
  ///
  /// Adds an entry to the in-memory breadcrumb ring buffer that rides
  /// on the next captured event — perfect for narrating user activity
  /// ("entered checkout", "tapped pay") so when a crash fires the
  /// dashboard shows the lead-up.  Does NOT emit a billable event on
  /// its own; pair with [captureException] / [captureMessage] when you
  /// want a standalone event.  Mirrors `FirebaseCrashlytics.log(msg)`.
  void log(String message, {String? category}) {
    _breadcrumbs.push(CatchBreadcrumb(
      type: 'log',
      category: category ?? 'log',
      message: message,
      level: CatchLevel.info,
    ));
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

  /// Self-audit the host's Catch integration. Mirrors Deploy's audit
  /// shape so the reverse-handshake reporter can batch every module
  /// into one POST.
  ///
  /// Checks the wiring that fails silently in real apps:
  ///   - hydrate finished (storage worked)
  ///   - native error handlers installed when host opted in
  ///   - server has enabled Catch via the handshake
  ///   - sample rate is sensible
  Future<ModuleIntegrationStatus> checkIntegration() async {
    final missing = <String>[];
    final warnings = <String>[];

    if (!_hydrated) {
      warnings.add(
        'Catch cache has not finished hydrating from local storage. Early breadcrumbs may be missing on the first event.',
      );
    }
    if (!_handlersInstalled) {
      warnings.add(
        'Native error handlers are not installed — uncaught exceptions and platform errors will not be auto-captured. Construct SankofaCatch with captureUnhandled: true.',
      );
    }
    if (!_enabled) {
      missing.add(
        'Catch is disabled by the server-side handshake response. Open Project Settings → Catch in the dashboard or check the org plan tier.',
      );
    }
    if (_errorSampleRate <= 0) {
      warnings.add(
        'errorSampleRate is $_errorSampleRate — every captured event will be sampled out. Useful in dev; misleading in prod.',
      );
    }

    return ModuleIntegrationStatus(
      module: SankofaModuleName.catchModule,
      level: deriveModuleIntegrationLevel(missing),
      missing: missing,
      warnings: warnings,
    );
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
  void setTag(String key, String value) => _tags[key] = value;
  void setTags(Map<String, String> tags) => _tags.addAll(tags);
  void setExtra(String key, dynamic value) => _extra[key] = value;

  /// Run [fn] with a fresh scope. Mutations made via the scope
  /// (tags, extras, user, level, fingerprint) overlay onto any
  /// [captureException] / [captureMessage] calls inside [fn]. The
  /// scope is popped when [fn] returns — async captures deferred past
  /// the closure's return will NOT see the scope.
  T withScope<T>(T Function(SankofaCatchScope scope) fn) {
    final scope = SankofaCatchScope();
    _scopeStack.add(scope);
    try {
      return fn(scope);
    } finally {
      _scopeStack.removeLast();
    }
  }

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
    // Clear the singleton only if THIS instance was the one registered
    // — guards against the "two-instance hot-reload" case where
    // shutting down a stale instance would otherwise null out the
    // active one.
    if (identical(_instance, this)) _instance = null;
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

    // Apply active withScope() overlay (if any). Layering order:
    //   global setUser/setTags/setExtra (read below)
    //   → top-of-stack scope (applyTo here)
    //   → caller-supplied options (already merged in by applyTo)
    final scope = _scopeStack.isNotEmpty ? _scopeStack.last : null;
    final mergedOptions = scope != null ? scope.applyTo(options) : options;

    final level = mergedOptions?.level ?? (type == 'console_error' ? CatchLevel.warning : CatchLevel.error);

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
      tags: {..._tags, ...?mergedOptions?.tags},
      extra: {..._extra, ...?mergedOptions?.extra},
      user: mergedOptions?.user ?? _user,
      device: _buildDeviceContext(),
      release: release,
      platform: 'flutter',
      sdk: {'name': 'sankofa.flutter', 'version': 'flutter-0.1.0'},
      breadcrumbs: _breadcrumbs.snapshot(),
      fingerprint: mergedOptions?.fingerprint,
      flagSnapshot: readFlagSnapshot?.call() ?? _autoFlagSnapshot(),
      configSnapshot: readConfigSnapshot?.call() ?? _autoConfigSnapshot(),
      traceId: mergedOptions?.traceId,
      spanId: mergedOptions?.spanId,
      screen: Sankofa.instance.hasTaggedScreen ? Sankofa.instance.currentScreen : null,
    );

    // beforeSend hook — host gets final say. A null return drops the
    // event; an exception is treated as "pass through unchanged"
    // because losing telemetry from a buggy hook is worse than the
    // hook misbehaving.
    CatchEvent? outgoing = ev;
    if (beforeSend != null) {
      try {
        outgoing = beforeSend!(ev);
      } catch (e) {
        if (kDebugMode) debugPrint('[Sankofa Catch] beforeSend threw — sending original event: $e');
        outgoing = ev;
      }
    }
    if (outgoing == null) {
      if (kDebugMode) debugPrint('[Sankofa Catch] event $eventId dropped by beforeSend');
      return '';
    }

    _buffer.add(outgoing);
    unawaited(_persist());
    if (_buffer.length >= _defaultBatchSize) {
      unawaited(flush());
    }
    return outgoing.eventId;
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

  /// Auto-discover the active feature-flag decisions by introspecting
  /// the registered [SankofaSwitch].  Lets every captured event carry
  /// the live flag state without the host wiring a closure by hand.
  /// Returns null when no Switch module is registered or when the
  /// snapshot would be empty.
  Map<String, String>? _autoFlagSnapshot() {
    final mod = SankofaModuleRegistry.instance.get(SankofaModuleName.switchModule);
    if (mod is! SankofaSwitch) return null;
    final out = <String, String>{};
    for (final key in mod.getAllKeys()) {
      final dec = mod.getDecision(key);
      if (dec == null) continue;
      out[key] = dec.variant.isNotEmpty ? dec.variant : dec.value.toString();
    }
    return out.isEmpty ? null : out;
  }

  /// Same as [_autoFlagSnapshot] but for the registered [SankofaConfig]
  /// remote-config module.  Reads the active value for every key the
  /// host passed into the Config defaults map.
  Map<String, dynamic>? _autoConfigSnapshot() {
    final mod = SankofaModuleRegistry.instance.get(SankofaModuleName.configModule);
    if (mod is! SankofaConfig) return null;
    final out = <String, dynamic>{};
    for (final key in mod.getAllKeys()) {
      final dec = mod.getDecision(key);
      if (dec == null) continue;
      out[key] = dec.value;
    }
    return out.isEmpty ? null : out;
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
