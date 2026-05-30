import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
class SankofaPulse with WidgetsBindingObserver implements SankofaModule {
  SankofaPulse._();

  static final SankofaPulse instance = SankofaPulse._();

  PulseClient? _client;
  /// Targeting rules keyed by survey id, populated alongside
  /// [_cached] on each `_refreshSurveys()`. Lets
  /// [activeMatchingSurveys] run the eligibility evaluator without
  /// fetching a full bundle for every cached survey.
  Map<String, List<PulseTargetingRule>> _targetingRules = const {};

  /// Per-survey display behaviour (auto_show / cooldown / delay), populated
  /// alongside [_cached]. Drives [maybeAutoShow].
  Map<String, _SurveyDisplay> _display = const {};

  PulseQueue? _queue;
  bool _registered = false;
  bool _enabled = true;
  List<PulseSurvey> _cached = const [];
  Future<void>? _refreshFuture;

  /// Host-registered navigator key, used as the presentation anchor for
  /// auto-show (which has no BuildContext of its own). The host must pass the
  /// SAME key to `MaterialApp(navigatorKey: ...)`.
  GlobalKey<NavigatorState>? _navigatorKey;

  /// Master switch for auto-show — mirrors the web `autoShow:false` opt-out.
  bool autoShowEnabled = true;

  /// Survey ids already auto-shown this process, so a resume/refresh
  /// re-trigger doesn't re-present the same survey on a zero cooldown.
  final Set<String> _shownThisSession = <String>{};

  /// True while a survey dialog is on screen — suppresses auto-show stacking.
  bool _presenting = false;

  /// Lifecycle event listener registry. Per-event buckets so an
  /// `onCompleted` subscriber doesn't run for `dismissed` events.
  final Map<PulseEvent, Set<PulseEventListener>> _listeners = {};

  @override
  SankofaModuleName get name => SankofaModuleName.pulseModule;

  /// True once [register] has been called and we have a working
  /// client.
  bool get isRegistered => _registered;

  /// Register the host's navigator key so auto-show can present a survey
  /// without a host-supplied BuildContext. Pass the SAME
  /// `GlobalKey<NavigatorState>` to your `MaterialApp(navigatorKey: key)`.
  /// Without it, surveys flagged `auto_show` in the dashboard cannot
  /// auto-present (the host must call [show] with a context instead).
  void setNavigatorKey(GlobalKey<NavigatorState> key) {
    _navigatorKey = key;
    // A key registered after the first fetch should still trigger a survey.
    if (_registered) maybeAutoShow();
  }

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
    // Re-evaluate auto-show on app foreground (mirrors iOS/Android).
    WidgetsBinding.instance.addObserver(this);
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

  /// Self-audit the host's Pulse integration. Most Pulse breakage
  /// happens at register-time (no API key, host not initialised) — we
  /// surface those as broken so the dashboard flags them clearly.
  Future<ModuleIntegrationStatus> checkIntegration() async {
    final missing = <String>[];
    final warnings = <String>[];

    if (!_registered) {
      missing.add(
        'SankofaPulse.register() has not been called (or returned false). Call register() AFTER Sankofa.instance.init() resolves.',
      );
    }
    if (_client == null) {
      missing.add(
        'PulseClient was not constructed — usually means register() ran before the host had an apiKey / endpoint.',
      );
    }
    if (_registered && _cached.isEmpty) {
      warnings.add(
        'No surveys cached yet — first refresh may still be in flight, or no surveys are published in the project.',
      );
    }
    if (!_enabled) {
      warnings.add(
        'Pulse is disabled by the server handshake. Open Project Settings → Pulse in the dashboard to enable it.',
      );
    }

    return ModuleIntegrationStatus(
      module: SankofaModuleName.pulseModule,
      level: deriveModuleIntegrationLevel(missing),
      missing: missing,
      warnings: warnings,
    );
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

  /// Forces a refresh of the cached survey list from the server. Useful right
  /// after identify() — bypasses the in-flight-coalescing AND the list cache
  /// so the new identity's targeting is re-evaluated rather than returning the
  /// previous user's cached result.
  Future<void> refreshSurveys() => _refreshSurveys(force: true);

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
    final host = Sankofa.instance;
    final identity = host.identity;
    // Populate the current screen so `screen`/`url` targeting rules can match.
    // Without this every screen-targeted survey was permanently ineligible on
    // Flutter (the evaluator saw an empty screenName).
    final screen = host.hasTaggedScreen ? host.currentScreen : null;
    final ctx = PulseEligibilityContext(
      surveyId: surveyId,
      respondentExternalId: identity?.distinctId ?? '',
      userProperties: properties,
      flagValues: _mergeWithSwitchFlags(flags),
      screenName: screen,
      pageUrl: screen,
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
    _presenting = true;
    _shownThisSession.add(surveyId);
    unawaited(_stampShown(surveyId));
    _emit(PulseEventPayload(
      event: PulseEvent.surveyShown,
      surveyId: surveyId,
    ));
    // Clear the presenting guard once the dialog closes (submit or dismiss).
    fut.whenComplete(() => _presenting = false);
    return fut;
  }

  // ── Auto-show pump ────────────────────────────────────────────────
  //
  // Presents the first eligible survey flagged `auto_show` that isn't inside
  // its dismiss cooldown and hasn't shown this session, from the host's
  // navigator. Mirrors iOS/Android. Triggered after each fetch, on app
  // foreground, and when a navigator key is registered. Without this,
  // dashboard surveys with auto_show=true never appear on Flutter.

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) maybeAutoShow();
  }

  /// Re-evaluate auto-show. Safe to call repeatedly — a no-op while a survey
  /// is already on screen, auto-show is disabled, or nothing is eligible.
  Future<void> maybeAutoShow() async {
    if (!_registered || !_enabled || !autoShowEnabled || _presenting) return;
    final ctx = _navigatorKey?.currentContext;
    if (ctx == null) return; // host hasn't wired a navigator key yet
    if (_cached.isEmpty) return;

    final respondent = Sankofa.instance.identity?.distinctId ?? '';
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now().millisecondsSinceEpoch;

    PulseSurvey? candidate;
    for (final s in _cached) {
      if (_shownThisSession.contains(s.id)) continue;
      final d = _display[s.id];
      if (d != null && !d.autoShow) continue;
      // Targeting.
      final rules = _targetingRules[s.id] ?? const <PulseTargetingRule>[];
      if (rules.isNotEmpty &&
          !_evaluateLocally(
            surveyId: s.id,
            rules: rules,
            properties: const {},
            flags: const {},
          ).eligible) {
        continue;
      }
      // Dismiss cooldown.
      final cooldownMs =
          (d?.cooldownSeconds ?? _kDefaultCooldownSeconds) * 1000;
      if (cooldownMs > 0) {
        final last = prefs.getInt(_cooldownKey(respondent, s.id)) ?? 0;
        if (last > 0 && now - last < cooldownMs) continue;
      }
      candidate = s;
      break;
    }
    if (candidate == null) return;

    final delayMs = _display[candidate.id]?.delayMs ?? 0;
    final id = candidate.id;
    Future<void> present() async {
      if (_presenting) return;
      final c2 = _navigatorKey?.currentContext;
      if (c2 == null) return;
      await show(c2, surveyId: id);
    }

    if (delayMs > 0) {
      Future.delayed(Duration(milliseconds: delayMs), present);
    } else {
      await present();
    }
  }

  static const int _kDefaultCooldownSeconds = 7 * 24 * 60 * 60;
  String _cooldownKey(String respondent, String surveyId) =>
      'sankofa.pulse.cooldown.$respondent.$surveyId';

  Future<void> _stampShown(String surveyId) async {
    try {
      final respondent = Sankofa.instance.identity?.distinctId ?? '';
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
        _cooldownKey(respondent, surveyId),
        DateTime.now().millisecondsSinceEpoch,
      );
    } catch (_) {/* best-effort */}
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

  Future<void> _refreshSurveys({bool force = false}) {
    final c = _client;
    if (c == null) return Future.value();
    final pending = _refreshFuture;
    // Coalesce concurrent refreshes — UNLESS forced (post-identify), where a
    // stale in-flight request issued under the previous identity must not be
    // returned in place of a fresh fetch.
    if (pending != null && !force) return pending;
    final fut = () async {
      try {
        // SDK-readable list endpoint (GET /api/pulse/surveys) — returns the
        // lightweight summary + targeting rules + display behaviour per
        // survey, so the local eligibility evaluator + auto-show pump have
        // everything they need without a per-survey bundle round-trip. An
        // empty result simply means "no published surveys" (the dead
        // /api/pulse/handshake fallback was removed — it 404s on the server).
        final summaries = await c.listSurveys(forceRefresh: force);
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
        _display = {
          for (final s in summaries)
            s.id: _SurveyDisplay(
              autoShow: s.autoShow,
              cooldownSeconds: s.displayCooldownSeconds,
              delayMs: s.displayDelayMs,
            ),
        };
        final q = _queue;
        if (q != null) await q.drain((p) => c.submit(p));
        // A fresh list on a live screen should present an eligible auto_show
        // survey immediately, not wait for the next resume.
        maybeAutoShow();
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

/// Per-survey display behaviour resolved from the SDK survey summary.
class _SurveyDisplay {
  final bool autoShow;
  final int cooldownSeconds;
  final int delayMs;
  const _SurveyDisplay({
    required this.autoShow,
    required this.cooldownSeconds,
    required this.delayMs,
  });
}
