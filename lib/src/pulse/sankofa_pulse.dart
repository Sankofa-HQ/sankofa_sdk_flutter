import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../core/module_registry.dart';
import '../replay/sankofa_replay.dart';
import '../sankofa_client.dart';
import '../switch/sankofa_switch.dart';
import 'branching.dart';
import 'pulse_client.dart';
import 'pulse_models.dart';
import 'pulse_queue.dart';
import 'survey_dialog.dart';
import 'targeting.dart';
import 'translator.dart';

/// Sankofa Pulse — in-app surveys on Flutter.
///
/// ```dart
/// await Sankofa.instance.init(apiKey: 'sk_live_…');
/// await SankofaPulse.instance.register();
///
/// // Programmatic show
/// SankofaPulse.instance.show(context, surveyId: 'psv_abc');
///
/// // Or fetch what's eligible right now and pick one yourself
/// final list = await SankofaPulse.instance.activeMatchingSurveys();
/// ```
///
/// Self-registers with the Traffic Cop on [register] so the
/// handshake's `modules.pulse` payload flows through
/// [applyHandshake]; survey *content* still comes from the dedicated
/// `/api/pulse/handshake` because the unified handshake only carries
/// enable/disable + tier gating, not the survey graph.
class SankofaPulse implements SankofaModule {
  SankofaPulse._();

  static final SankofaPulse instance = SankofaPulse._();

  PulseClient? _client;
  /// Targeting rules keyed by survey id, populated alongside
  /// [_cached] on each `_refreshSurveys()`. Lets
  /// [activeMatchingSurveys] run the eligibility evaluator without
  /// fetching a full bundle for every cached survey.
  Map<String, List<PulseTargetingRule>> _targetingRules = const {};
  PulseQueue? _queue;
  bool _registered = false;
  bool _enabled = true;
  List<PulseSurvey> _cached = const [];
  Future<void>? _refreshFuture;

  /// Lifecycle event listener registry. Per-event buckets so an
  /// `onCompleted` subscriber doesn't run for `dismissed` events.
  final Map<PulseEvent, Set<PulseEventListener>> _listeners = {};

  @override
  SankofaModuleName get name => SankofaModuleName.pulseModule;

  /// True once [register] has been called and we have a working
  /// client.
  bool get isRegistered => _registered;

  /// Wires Pulse to the host's already-initialised Sankofa SDK.
  /// Idempotent — calling twice is a no-op. Returns false if the
  /// host hasn't called `Sankofa.instance.init` yet.
  Future<bool> register() async {
    if (_registered) return true;
    final host = Sankofa.instance;
    final apiKey = host.apiKey;
    final endpoint = host.endpoint;
    if (apiKey == null || apiKey.isEmpty || endpoint == null || endpoint.isEmpty) {
      if (kDebugMode) {
        debugPrint(
          '[Sankofa] SankofaPulse.register() called before '
          'Sankofa.instance.init() — skipping',
        );
      }
      return false;
    }
    _client = PulseClient(endpoint: endpoint, apiKey: apiKey);
    _queue = PulseQueue();
    _registered = true;
    SankofaModuleRegistry.instance.register(this);
    // App version comes from a platform channel — load it once now
    // so submit-time enrichment doesn't have to wait on it.
    unawaited(_loadAppVersion());
    // First refresh fires off-frame so register() doesn't block the
    // host's app boot. Subsequent refreshes are driven by the Traffic
    // Cop every time a fresh handshake lands.
    unawaited(_refreshSurveys());
    return true;
  }

  // ── SankofaModule (Traffic Cop hook) ──────────────────────────────

  @override
  Future<void> applyHandshake(Map<String, dynamic> config) async {
    final on = config['enabled'] as bool? ?? true;
    _enabled = on;
    if (!on) return;

    // The unified handshake may inline a partial survey list (small
    // payload optimisation). Take it if present so the very first
    // show() call doesn't have to wait on a second round-trip; the
    // dedicated /api/pulse/handshake refresh still runs to pick up
    // anything the unified payload elided.
    final inline = config['surveys'];
    if (inline is List) {
      try {
        _cached = inline
            .whereType<Map<String, dynamic>>()
            .map(PulseSurvey.fromJson)
            .toList();
      } catch (_) {
        // Inline list malformed — fall through to the dedicated
        // handshake call below.
      }
    }
    await _refreshSurveys();
  }

  // ── Public reads ──────────────────────────────────────────────────

  /// Returns the surveys whose targeting rules pass for the current
  /// respondent. Sourced from `/api/pulse/surveys` (one call per
  /// refresh) plus the local targeting evaluator — same evaluator
  /// the Web/RN/iOS/Android SDKs use, and a byte-for-byte mirror of
  /// the Go server-side implementation.
  Future<List<PulseSurvey>> activeMatchingSurveys() async {
    if (_cached.isEmpty) {
      final pending = _refreshFuture;
      if (pending != null) {
        await pending;
      } else {
        await _refreshSurveys();
      }
    }
    if (_cached.isEmpty) return const [];
    final out = <PulseSurvey>[];
    for (final s in _cached) {
      final rules = _targetingRules[s.id] ?? const <PulseTargetingRule>[];
      if (rules.isEmpty) {
        out.add(s);
        continue;
      }
      final decision = _evaluateLocally(
        surveyId: s.id,
        rules: rules,
        properties: const {},
        flags: const {},
      );
      if (decision.eligible) out.add(s);
    }
    return out;
  }

  /// Forces a refresh of the cached survey list from the server.
  /// Useful right after identify().
  Future<void> refreshSurveys() => _refreshSurveys();

  // ── Lifecycle event subscriptions ───────────────────────────────────

  /// Subscribe to one Pulse lifecycle event. Returns a
  /// [PulseSubscription] handle — call its `cancel()` to remove the
  /// listener. Mirrors the Web SDK's `Sankofa.pulse.on(event, listener)`
  /// shape so a host swapping between platforms doesn't relearn the
  /// API.
  PulseSubscription on(PulseEvent event, PulseEventListener listener) {
    final bucket = _listeners.putIfAbsent(event, () => <PulseEventListener>{});
    bucket.add(listener);
    return PulseSubscription(() {
      final b = _listeners[event];
      if (b == null) return;
      b.remove(listener);
      if (b.isEmpty) _listeners.remove(event);
    });
  }

  void _emit(PulseEventPayload payload) {
    // Auto-emit into the host's analytics queue with a "$pulse."
    // prefix so survey lifecycle shows up in the same dashboard /
    // warehouse as every other event the host tracks. Listeners
    // registered through on(...) still fire as well — that path is
    // for in-process integrations (Slack pings, conditional UI),
    // not for analytics.
    final trackProps = <String, Object>{'survey_id': payload.surveyId};
    if (payload.responseId != null) trackProps['response_id'] = payload.responseId!;
    if (payload.reason != null) trackProps['reason'] = payload.reason!;
    unawaited(Sankofa.instance
        .track('\$pulse.${payload.event.wireName}', trackProps)
        .catchError((_) {}));

    final bucket = _listeners[payload.event];
    if (bucket == null) return;
    for (final l in bucket.toList()) {
      try {
        l(payload);
      } catch (e) {
        if (kDebugMode) debugPrint('[Sankofa] pulse listener threw: $e');
      }
    }
  }

  // ── Programmatic presentation ─────────────────────────────────────

  /// Show a survey by id. Fetches the full bundle, runs targeting
  /// locally; if the respondent isn't eligible we silently skip
  /// (the host can call [isEligible] up-front to decide on its own
  /// what to do with a 'no').
  ///
  /// [properties] populates `userProperties` for `user_property`
  /// rules; [flags] populates `flagValues` for `feature_flag` rules.
  /// Other context fields auto-fill from Sankofa core (identity,
  /// session) or are left empty.
  Future<void> show(
    BuildContext context, {
    required String surveyId,
    Map<String, Object?> properties = const {},
    Map<String, Object?> flags = const {},
  }) async {
    if (!_registered) {
      if (kDebugMode) {
        debugPrint(
          '[Sankofa] SankofaPulse.show() called before register() — skipping',
        );
      }
      return;
    }
    if (!_enabled) return;
    final c = _client;
    if (c == null) return;
    PulseSurveyBundle bundle;
    try {
      bundle = await c.loadSurveyBundle(surveyId);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[Sankofa] SankofaPulse.show($surveyId) — bundle fetch failed: $e');
      }
      return;
    }
    if (bundle.survey.id.isEmpty) {
      if (kDebugMode) {
        debugPrint('[Sankofa] SankofaPulse.show($surveyId) — survey not found');
      }
      return;
    }
    final decision = _evaluateLocally(
      surveyId: surveyId,
      rules: bundle.targetingRules,
      properties: properties,
      flags: flags,
    );
    if (!decision.eligible) {
      if (kDebugMode) {
        debugPrint(
          '[Sankofa] SankofaPulse.show($surveyId) — ineligible: ${decision.reason}',
        );
      }
      return;
    }
    // Hydrate from any in-progress partial. Load failures (offline,
    // expired, server error) are swallowed — the survey simply
    // starts fresh, which is strictly better than refusing to show.
    final externalId = Sankofa.instance.identity?.distinctId ?? '';
    PulsePartial? partial;
    if (externalId.isNotEmpty) {
      try {
        partial = await c.loadPartial(
          surveyId: surveyId,
          externalId: externalId,
        );
      } catch (_) {
        partial = null;
      }
    }

    if (!context.mounted) return;
    final translator = PulseTranslator.build(
      bundle.translations,
      deviceLocale: WidgetsBinding.instance.platformDispatcher.locale.toLanguageTag(),
    );
    await _present(
      context,
      surveyId: surveyId,
      survey: bundle.survey,
      branchingRules: bundle.branchingRules,
      translator: translator,
      externalId: externalId,
      initialAnswers: partial?.answers ?? const {},
      initialQuestionId: partial?.currentQuestionId,
    );
  }

  /// Returns the targeting Decision for [surveyId] without showing.
  /// Useful for hosts that want to render their own UI affordance
  /// ("answer a quick survey?") only if eligible.
  Future<PulseDecision> isEligible(
    String surveyId, {
    Map<String, Object?> properties = const {},
    Map<String, Object?> flags = const {},
  }) async {
    if (!_registered) {
      return const PulseDecision(eligible: false, reason: 'pulse not registered');
    }
    if (!_enabled) {
      return const PulseDecision(
          eligible: false, reason: 'pulse disabled by handshake');
    }
    final c = _client;
    if (c == null) return const PulseDecision(eligible: false, reason: 'no client');
    PulseSurveyBundle bundle;
    try {
      bundle = await c.loadSurveyBundle(surveyId);
    } catch (_) {
      return const PulseDecision(eligible: false, reason: 'bundle fetch failed');
    }
    if (bundle.survey.id.isEmpty) {
      return const PulseDecision(eligible: false, reason: 'survey not found');
    }
    return _evaluateLocally(
      surveyId: surveyId,
      rules: bundle.targetingRules,
      properties: properties,
      flags: flags,
    );
  }

  PulseDecision _evaluateLocally({
    required String surveyId,
    required List<PulseTargetingRule> rules,
    required Map<String, Object?> properties,
    required Map<String, Object?> flags,
  }) {
    if (rules.isEmpty) return const PulseDecision(eligible: true);
    final identity = Sankofa.instance.identity;
    final ctx = PulseEligibilityContext(
      surveyId: surveyId,
      respondentExternalId: identity?.distinctId ?? '',
      userProperties: properties,
      flagValues: _mergeWithSwitchFlags(flags),
    );
    return evaluatePulseTargeting(rules, ctx);
  }

  /// Merge SankofaSwitch flag values into the eligibility context
  /// so feature_flag rules can target without the host re-passing
  /// every flag. Host-supplied [overrides] win over Switch values
  /// by key — that lets a host force a flag for testing without
  /// the runtime Switch decision overriding them.
  Map<String, Object?> _mergeWithSwitchFlags(Map<String, Object?> overrides) {
    final switches = SankofaSwitch.instance;
    if (switches == null) return overrides;
    final merged = <String, Object?>{};
    try {
      for (final key in switches.getAllKeys()) {
        final decision = switches.getDecision(key);
        if (decision == null) continue;
        // For variant flags we expose the variant string; for
        // boolean flags we expose the bool value. The targeting
        // evaluator's _jsonEqual handles either.
        merged[key] =
            decision.variant.isNotEmpty ? decision.variant : decision.value;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[Sankofa] switch flag merge failed: $e');
    }
    merged.addAll(overrides);
    return merged;
  }

  Future<void> _present(
    BuildContext context, {
    required String surveyId,
    required PulseSurvey survey,
    required List<PulseBranchingRule> branchingRules,
    required String externalId,
    PulseTranslator? translator,
    Map<String, Object?> initialAnswers = const {},
    String? initialQuestionId,
  }) {
    final fut = showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => SankofaSurveyDialog(
        survey: survey,
        branchingRules: branchingRules,
        translator: translator,
        initialAnswers: initialAnswers,
        initialQuestionId: initialQuestionId,
        onProgress: externalId.isEmpty
            ? null
            : (answers, currentQuestionId) {
                _schedulePartialSave(
                  surveyId: surveyId,
                  externalId: externalId,
                  answers: answers,
                  currentQuestionId: currentQuestionId,
                );
              },
        onSubmit: (payload) {
          // Server auto-deletes the partial on a successful insert.
          // Best-effort client-side delete too so a dismissed-then-
          // resumed-in-a-different-session doesn't surface a stale
          // partial during the brief window.
          _handleSubmit(_enrichContext(payload), surveyId: surveyId);
          if (externalId.isNotEmpty) {
            unawaited(_deletePartial(surveyId, externalId));
          }
          Navigator.of(ctx).maybePop();
        },
        onDismiss: () {
          _emit(PulseEventPayload(
            event: PulseEvent.surveyDismissed,
            surveyId: surveyId,
          ));
          // Keep partial intact for resume — that's the whole point.
        },
      ),
    );
    _emit(PulseEventPayload(
      event: PulseEvent.surveyShown,
      surveyId: surveyId,
    ));
    return fut;
  }

  // ── Partial save scheduler ──────────────────────────────────────────
  //
  // Coalesce saves on a 750ms debounce: a fast-clicking respondent
  // who skips through 5 questions in a second only burns one save call,
  // and the latest pending state always wins.

  static const Duration _partialDebounce = Duration(milliseconds: 750);
  Timer? _partialSaveTimer;

  void _schedulePartialSave({
    required String surveyId,
    required String externalId,
    required Map<String, Object?> answers,
    required String currentQuestionId,
  }) {
    _partialSaveTimer?.cancel();
    _partialSaveTimer = Timer(_partialDebounce, () {
      unawaited(_savePartial(
        surveyId: surveyId,
        externalId: externalId,
        answers: answers,
        currentQuestionId: currentQuestionId,
      ));
    });
  }

  Future<void> _savePartial({
    required String surveyId,
    required String externalId,
    required Map<String, Object?> answers,
    required String currentQuestionId,
  }) async {
    final c = _client;
    if (c == null) return;
    try {
      await c.savePartial(PulsePartialUpsert(
        surveyId: surveyId,
        respondent: PulseRespondent(externalId: externalId),
        context: _buildPulseContext(),
        answers: answers,
        currentQuestionId: currentQuestionId,
      ));
      _emit(PulseEventPayload(
        event: PulseEvent.surveyPartialSaved,
        surveyId: surveyId,
      ));
    } catch (e) {
      if (kDebugMode) debugPrint('[Sankofa] partial save failed: $e');
    }
  }

  Future<void> _deletePartial(String surveyId, String externalId) async {
    final c = _client;
    if (c == null) return;
    try {
      await c.deletePartial(surveyId: surveyId, externalId: externalId);
    } catch (_) {
      // Server auto-cleans on submit anyway; ignore.
    }
  }

  // ── Submission ────────────────────────────────────────────────────

  void _handleSubmit(PulseSubmitPayload payload, {required String surveyId}) {
    final c = _client;
    final q = _queue;
    if (c == null) return;
    unawaited(() async {
      try {
        final resp = await c.submit(payload);
        // Fire SURVEY_COMPLETED with the server-issued response id
        // so hosts can correlate against dashboard rows.
        _emit(PulseEventPayload(
          event: PulseEvent.surveyCompleted,
          surveyId: surveyId,
          responseId: resp.id,
        ));
        if (q != null) await q.drain((p) => c.submit(p));
      } catch (_) {
        // Network down — persist for next drain. We deliberately
        // do NOT fire SURVEY_COMPLETED yet; the host's analytics
        // should treat "submitted to local queue" differently from
        // "server confirmed".
        if (q != null) await q.enqueue(payload);
      }
    }());
  }

  PulseSubmitPayload _enrichContext(PulseSubmitPayload payload) {
    final host = Sankofa.instance;
    final ctx = _buildPulseContext();
    final distinct = host.identity?.distinctId;
    final respondent = payload.respondent.copyWith(
      externalId: payload.respondent.externalId ??
          (distinct == null || distinct.isEmpty ? null : distinct),
    );
    return payload.copyWith(
      respondent: respondent,
      context: ctx,
    );
  }

  // ── Internals ─────────────────────────────────────────────────────

  Future<void> _refreshSurveys() {
    final c = _client;
    if (c == null) return Future.value();
    final pending = _refreshFuture;
    if (pending != null) return pending;
    final fut = () async {
      try {
        // SDK-readable list endpoint — returns the lightweight
        // summary + targeting rules per survey so the local
        // eligibility evaluator has everything it needs without a
        // per-survey bundle round-trip. Falls through to the legacy
        // `/api/pulse/handshake` endpoint on older engines that
        // 404 the new path; either response shape produces a
        // populated _cached.
        final summaries = await c.listSurveys();
        if (summaries.isNotEmpty) {
          _cached = summaries
              .map((s) => PulseSurvey(
                    id: s.id,
                    kind: s.kind,
                    name: s.name,
                    description: s.description,
                  ))
              .toList(growable: false);
          _targetingRules = {
            for (final s in summaries) s.id: s.targetingRules,
          };
        } else {
          final resp = await c.handshake();
          _cached = resp.surveys;
          _targetingRules = const {};
        }
        final q = _queue;
        if (q != null) await q.drain((p) => c.submit(p));
      } catch (e) {
        if (kDebugMode) {
          debugPrint('[Sankofa] pulse refresh failed: $e');
        }
      } finally {
        _refreshFuture = null;
      }
    }();
    _refreshFuture = fut;
    return fut;
  }

  /// Build the per-call [PulseContext] used by both the final
  /// submit payload and any partial-save calls. Centralising here
  /// keeps "what we tell the server about this device" in one
  /// place — drift between submit + partial would surface as
  /// inconsistent dashboard rows for the same respondent.
  PulseContext _buildPulseContext() {
    final host = Sankofa.instance;
    // SankofaReplay.instance.currentSessionId is "" before
    // configure() runs (replay sampled out, recordSessions=false,
    // or pre-handshake). We map empty → null so the wire field
    // distinguishes "no recording" from "replay session unknown".
    final replaySid = SankofaReplay.instance.activeSessionId;
    return PulseContext(
      sessionId: host.sessionManager?.sessionId,
      anonymousId: host.identity?.anonymousId,
      platform: 'flutter',
      osVersion: _osVersion(),
      appVersion: _appVersion,
      locale: WidgetsBinding.instance.platformDispatcher.locale.toLanguageTag(),
      replaySessionId: replaySid.isEmpty ? null : replaySid,
    );
  }

  // App + OS version cached lazily so we don't hit the platform
  // channel on every survey submit.
  String? _appVersion;
  bool _appVersionLoaded = false;
  Future<void> _loadAppVersion() async {
    if (_appVersionLoaded) return;
    try {
      final info = await PackageInfo.fromPlatform();
      final short = info.version;
      final build = info.buildNumber;
      _appVersion = build.isEmpty ? short : '$short ($build)';
    } catch (_) {
      _appVersion = null;
    } finally {
      _appVersionLoaded = true;
    }
  }

  String? _osVersion() {
    try {
      if (Platform.isAndroid) return 'Android ${Platform.operatingSystemVersion}';
      if (Platform.isIOS) return 'iOS ${Platform.operatingSystemVersion}';
      return Platform.operatingSystemVersion;
    } catch (_) {
      return null;
    }
  }
}
