// Sankofa Catch wire contract — Dart mirror of
// server/engine/ee/catch/wire.go. Field names MUST match the Go struct
// 1:1; the server rejects unknown fields under wire_version 1.

/// The only wire version the server currently accepts.
const int kCatchWireVersion = 1;

enum CatchLevel { fatal, error, warning, info, debug }

extension CatchLevelWire on CatchLevel {
  String get wireName {
    switch (this) {
      case CatchLevel.fatal:
        return 'fatal';
      case CatchLevel.error:
        return 'error';
      case CatchLevel.warning:
        return 'warning';
      case CatchLevel.info:
        return 'info';
      case CatchLevel.debug:
        return 'debug';
    }
  }
}

class CatchStackFrame {
  final String? filename;
  final String? function;
  final String? module;
  final int? lineno;
  final int? colno;
  final String? absPath;
  final bool? inApp;
  final String? platform;
  final String? instructionAddr;
  final String? package;
  final String? symbol;
  final String? symbolAddr;
  final String? addrMode;

  const CatchStackFrame({
    this.filename,
    this.function,
    this.module,
    this.lineno,
    this.colno,
    this.absPath,
    this.inApp,
    this.platform,
    this.instructionAddr,
    this.package,
    this.symbol,
    this.symbolAddr,
    this.addrMode,
  });

  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{};
    if (filename != null) m['filename'] = filename;
    if (function != null) m['function'] = function;
    if (module != null) m['module'] = module;
    if (lineno != null) m['lineno'] = lineno;
    if (colno != null) m['colno'] = colno;
    if (absPath != null) m['abs_path'] = absPath;
    if (inApp != null) m['in_app'] = inApp;
    if (platform != null) m['platform'] = platform;
    if (instructionAddr != null) m['instruction_addr'] = instructionAddr;
    if (package != null) m['package'] = package;
    if (symbol != null) m['symbol'] = symbol;
    if (symbolAddr != null) m['symbol_addr'] = symbolAddr;
    if (addrMode != null) m['addr_mode'] = addrMode;
    return m;
  }
}

class CatchStackTrace {
  final List<CatchStackFrame> frames;
  const CatchStackTrace(this.frames);
  Map<String, dynamic> toJson() =>
      {'frames': frames.map((f) => f.toJson()).toList()};
}

class CatchMechanism {
  final String type;
  final bool handled;
  final String? description;
  const CatchMechanism({required this.type, required this.handled, this.description});
  Map<String, dynamic> toJson() => {
        'type': type,
        'handled': handled,
        if (description != null) 'description': description,
      };
}

class CatchException {
  final String type;
  final String value;
  final String? module;
  final CatchMechanism? mechanism;
  final CatchStackTrace? stacktrace;
  final List<CatchException>? chained;

  const CatchException({
    required this.type,
    required this.value,
    this.module,
    this.mechanism,
    this.stacktrace,
    this.chained,
  });

  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{'type': type, 'value': value};
    if (module != null) m['module'] = module;
    if (mechanism != null) m['mechanism'] = mechanism!.toJson();
    if (stacktrace != null) m['stacktrace'] = stacktrace!.toJson();
    if (chained != null && chained!.isNotEmpty) {
      m['chained'] = chained!.map((e) => e.toJson()).toList();
    }
    return m;
  }
}

class CatchUserContext {
  final String? id;
  final String? email;
  final String? username;
  final String? ipAddress;
  final String? segment;
  final Map<String, String>? data;
  const CatchUserContext({this.id, this.email, this.username, this.ipAddress, this.segment, this.data});
  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{};
    if (id != null) m['id'] = id;
    if (email != null) m['email'] = email;
    if (username != null) m['username'] = username;
    if (ipAddress != null) m['ip_address'] = ipAddress;
    if (segment != null) m['segment'] = segment;
    if (data != null) m['data'] = data;
    return m;
  }
}

class CatchDeviceContext {
  final String? os;
  final String? osVersion;
  final String? model;
  final String? arch;
  final int? memoryMb;
  final String? locale;
  final String? country;
  final String? timezone;
  final String? appVersion;
  final bool? online;
  const CatchDeviceContext({
    this.os,
    this.osVersion,
    this.model,
    this.arch,
    this.memoryMb,
    this.locale,
    this.country,
    this.timezone,
    this.appVersion,
    this.online,
  });
  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{};
    if (os != null) m['os'] = os;
    if (osVersion != null) m['os_version'] = osVersion;
    if (model != null) m['model'] = model;
    if (arch != null) m['arch'] = arch;
    if (memoryMb != null) m['memory_mb'] = memoryMb;
    if (locale != null) m['locale'] = locale;
    if (country != null) m['country'] = country;
    if (timezone != null) m['timezone'] = timezone;
    if (appVersion != null) m['app_version'] = appVersion;
    if (online != null) m['online'] = online;
    return m;
  }
}

class CatchBreadcrumb {
  final int tsMs;
  final String type;
  final String? category;
  final String? message;
  final CatchLevel? level;
  final Map<String, dynamic>? data;

  CatchBreadcrumb({
    int? tsMs,
    required this.type,
    this.category,
    this.message,
    this.level,
    this.data,
  }) : tsMs = tsMs ?? DateTime.now().millisecondsSinceEpoch;

  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{'ts_ms': tsMs, 'type': type};
    if (category != null) m['category'] = category;
    if (message != null) m['message'] = message;
    if (level != null) m['level'] = level!.wireName;
    if (data != null) m['data'] = data;
    return m;
  }
}

/// Debug-meta — loaded binary table for native symbolication under
/// ASLR. Rarely populated on pure-Dart errors; the iOS/Android native
/// bridges fill this in when a native crash is reported up via the
/// platform channel.
class CatchDebugImage {
  final String type;
  final String debugId;
  final String? codeId;
  final String? codeFile;
  final String imageAddr;
  final int? imageSize;
  final String? imageVmaddr;
  final String? arch;

  const CatchDebugImage({
    required this.type,
    required this.debugId,
    required this.imageAddr,
    this.codeId,
    this.codeFile,
    this.imageSize,
    this.imageVmaddr,
    this.arch,
  });

  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{'type': type, 'debug_id': debugId, 'image_addr': imageAddr};
    if (codeId != null) m['code_id'] = codeId;
    if (codeFile != null) m['code_file'] = codeFile;
    if (imageSize != null) m['image_size'] = imageSize;
    if (imageVmaddr != null) m['image_vmaddr'] = imageVmaddr;
    if (arch != null) m['arch'] = arch;
    return m;
  }
}

class CatchDebugMeta {
  final List<CatchDebugImage>? images;
  const CatchDebugMeta({this.images});
  Map<String, dynamic> toJson() => {
        if (images != null && images!.isNotEmpty)
          'images': images!.map((i) => i.toJson()).toList(),
      };
}

/// The full event envelope. `toJson` produces the exact wire shape.
class CatchEvent {
  final String eventId;
  final int tsMs;
  final String environment; // live | test

  final String? distinctId;
  final String? anonId;
  final String? sessionId;

  final CatchLevel level;
  final String type;

  final CatchException? exception;
  final String? message;

  final Map<String, String>? tags;
  final Map<String, dynamic>? extra;
  final CatchUserContext? user;
  final CatchDeviceContext? device;
  final String? release;
  final String platform;
  final Map<String, String> sdk; // {name, version}

  final List<CatchBreadcrumb>? breadcrumbs;
  final List<String>? fingerprint;
  final Map<String, String>? flagSnapshot;
  final Map<String, dynamic>? configSnapshot;
  final String? traceId;
  final String? spanId;
  final int? replayChunkIndex;
  final CatchDebugMeta? debugMeta;

  CatchEvent({
    required this.eventId,
    required this.tsMs,
    required this.environment,
    required this.level,
    required this.type,
    required this.platform,
    required this.sdk,
    this.distinctId,
    this.anonId,
    this.sessionId,
    this.exception,
    this.message,
    this.tags,
    this.extra,
    this.user,
    this.device,
    this.release,
    this.breadcrumbs,
    this.fingerprint,
    this.flagSnapshot,
    this.configSnapshot,
    this.traceId,
    this.spanId,
    this.replayChunkIndex,
    this.debugMeta,
  });

  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{
      'wire_version': kCatchWireVersion,
      'event_id': eventId,
      'ts_ms': tsMs,
      'environment': environment,
      'level': level.wireName,
      'type': type,
      'platform': platform,
      'sdk': sdk,
    };
    if (distinctId != null) m['distinct_id'] = distinctId;
    if (anonId != null) m['anon_id'] = anonId;
    if (sessionId != null) m['session_id'] = sessionId;
    if (exception != null) m['exception'] = exception!.toJson();
    if (message != null) m['message'] = message;
    if (tags != null && tags!.isNotEmpty) m['tags'] = tags;
    if (extra != null && extra!.isNotEmpty) m['extra'] = extra;
    if (user != null) m['user'] = user!.toJson();
    if (device != null) m['device'] = device!.toJson();
    if (release != null) m['release'] = release;
    if (breadcrumbs != null && breadcrumbs!.isNotEmpty) {
      m['breadcrumbs'] = breadcrumbs!.map((b) => b.toJson()).toList();
    }
    if (fingerprint != null && fingerprint!.isNotEmpty) m['fingerprint'] = fingerprint;
    if (flagSnapshot != null && flagSnapshot!.isNotEmpty) m['flag_snapshot'] = flagSnapshot;
    if (configSnapshot != null && configSnapshot!.isNotEmpty) m['config_snapshot'] = configSnapshot;
    if (traceId != null) m['trace_id'] = traceId;
    if (spanId != null) m['span_id'] = spanId;
    if (replayChunkIndex != null) m['replay_chunk_index'] = replayChunkIndex;
    if (debugMeta != null) m['debug_meta'] = debugMeta!.toJson();
    return m;
  }
}

class CatchHandshakeConfig {
  final bool? enabled;
  final double? errorSampleRate;
  final double? transactionSampleRate;
  final double? profilesSampleRate;
  final bool? replayOnErrorEnabled;
  final int? replayBurstSeconds;
  final int? breadcrumbsMaxBuffer;
  final String? reason;

  const CatchHandshakeConfig({
    this.enabled,
    this.errorSampleRate,
    this.transactionSampleRate,
    this.profilesSampleRate,
    this.replayOnErrorEnabled,
    this.replayBurstSeconds,
    this.breadcrumbsMaxBuffer,
    this.reason,
  });

  factory CatchHandshakeConfig.fromJson(Map<String, dynamic> j) {
    final sampling = j['sampling'] as Map<String, dynamic>?;
    final replay = j['replay'] as Map<String, dynamic>?;
    final bc = j['breadcrumbs'] as Map<String, dynamic>?;
    return CatchHandshakeConfig(
      enabled: j['enabled'] as bool?,
      errorSampleRate: (sampling?['error_sample_rate'] as num?)?.toDouble(),
      transactionSampleRate: (sampling?['transaction_sample_rate'] as num?)?.toDouble(),
      profilesSampleRate: (sampling?['profiles_sample_rate'] as num?)?.toDouble(),
      replayOnErrorEnabled: replay?['on_error_enabled'] as bool?,
      replayBurstSeconds: replay?['burst_seconds'] as int?,
      breadcrumbsMaxBuffer: bc?['max_buffer'] as int?,
      reason: j['reason'] as String?,
    );
  }
}

/// Optional parameters passed to captureException / captureMessage.
class CatchCaptureOptions {
  final CatchLevel? level;
  final Map<String, String>? tags;
  final Map<String, dynamic>? extra;
  final CatchUserContext? user;
  final List<String>? fingerprint;
  final String? traceId;
  final String? spanId;

  const CatchCaptureOptions({
    this.level,
    this.tags,
    this.extra,
    this.user,
    this.fingerprint,
    this.traceId,
    this.spanId,
  });
}

/// Synchronous hook called after an event has been composed but BEFORE
/// the SDK enqueues it for transport. Return the (possibly modified)
/// event to ship it; return `null` to drop it entirely.
///
/// Use cases:
///   - PII scrubbing (e.g. strip `event.user?.email`)
///   - Noise filtering (e.g. drop framework-level setState warnings)
///   - Tag enrichment from state unavailable at SDK init time
///
/// Throwing inside the hook is treated like returning the event
/// unchanged — a host bug must never break the capture pipeline.
typedef BeforeSendFn = CatchEvent? Function(CatchEvent event);

/// Sentry-style temporary scope. Mutations made via the callback in
/// `SankofaCatch.instance!.withScope(fn)` overlay onto the next
/// captured event without polluting the global scope set via
/// `setUser` / `setTags` / `setExtra`.
///
/// ```dart
/// SankofaCatch.instance!.withScope((scope) {
///   scope.setTag('checkout_step', 'payment');
///   scope.setExtra('cart_id', cart.id);
///   Sankofa.captureException(err);
/// });
/// // Outside the closure, those tags / extras are gone.
/// ```
class SankofaCatchScope {
  final Map<String, String> _tags = {};
  final Map<String, dynamic> _extra = {};
  CatchUserContext? _user;
  bool _userTouched = false;
  CatchLevel? _level;
  List<String>? _fingerprint;

  SankofaCatchScope setTag(String key, String value) {
    _tags[key] = value;
    return this;
  }

  SankofaCatchScope setTags(Map<String, String> tags) {
    _tags.addAll(tags);
    return this;
  }

  SankofaCatchScope setExtra(String key, dynamic value) {
    _extra[key] = value;
    return this;
  }

  SankofaCatchScope setUser(CatchUserContext? user) {
    _user = user;
    _userTouched = true;
    return this;
  }

  SankofaCatchScope setLevel(CatchLevel level) {
    _level = level;
    return this;
  }

  SankofaCatchScope setFingerprint(List<String> fingerprint) {
    _fingerprint = List.unmodifiable(fingerprint);
    return this;
  }

  /// Layer this scope on top of the caller's `options`. Caller options
  /// take precedence (most specific wins); the global scope set on the
  /// client is applied separately in [SankofaCatch._capture] so this
  /// merge only covers the scope ↔ options layer.
  CatchCaptureOptions applyTo(CatchCaptureOptions? options) {
    return CatchCaptureOptions(
      level: options?.level ?? _level,
      tags: {..._tags, ...?options?.tags},
      extra: {..._extra, ...?options?.extra},
      // User: caller wins, then scope. `_userTouched` distinguishes
      // "scope explicitly cleared user with setUser(null)" from "scope
      // never set user" — only the former should override the client's
      // global user.
      user: options?.user ?? (_userTouched ? _user : null),
      fingerprint: options?.fingerprint ?? _fingerprint,
      traceId: options?.traceId,
      spanId: options?.spanId,
    );
  }
}
