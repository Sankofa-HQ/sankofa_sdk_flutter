import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../core/module_registry.dart';
import '../sankofa_client.dart';
import 'branching.dart';
import 'pulse_client.dart';
import 'pulse_models.dart';
import 'pulse_queue.dart';
import 'survey_dialog.dart';
import 'targeting.dart';

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
  PulseQueue? _queue;
  bool _registered = false;
  bool _enabled = true;
  List<PulseSurvey> _cached = const [];
  Future<void>? _refreshFuture;

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

  /// Returns the surveys eligible for the current user/session.
  /// v1 is "every published survey from the handshake"; targeting
  /// evaluation lands in a future release.
  Future<List<PulseSurvey>> activeMatchingSurveys() async {
    if (_cached.isNotEmpty) return _cached;
    final pending = _refreshFuture;
    if (pending != null) {
      await pending;
    } else {
      await _refreshSurveys();
    }
    return _cached;
  }

  /// Forces a refresh of the cached survey list from the server.
  /// Useful right after identify().
  Future<void> refreshSurveys() => _refreshSurveys();

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
    if (!context.mounted) return;
    await _present(context, bundle.survey, bundle.branchingRules);
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
      flagValues: flags,
    );
    return evaluatePulseTargeting(rules, ctx);
  }

  Future<void> _present(
    BuildContext context,
    PulseSurvey survey,
    List<PulseBranchingRule> branchingRules,
  ) {
    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => SankofaSurveyDialog(
        survey: survey,
        branchingRules: branchingRules,
        onSubmit: (payload) {
          _handleSubmit(_enrichContext(payload));
          Navigator.of(ctx).maybePop();
        },
        onDismiss: () {},
      ),
    );
  }

  // ── Submission ────────────────────────────────────────────────────

  void _handleSubmit(PulseSubmitPayload payload) {
    final c = _client;
    final q = _queue;
    if (c == null) return;
    unawaited(() async {
      try {
        await c.submit(payload);
        if (q != null) await q.drain((p) => c.submit(p));
      } catch (_) {
        // Network down — persist for next drain.
        if (q != null) await q.enqueue(payload);
      }
    }());
  }

  PulseSubmitPayload _enrichContext(PulseSubmitPayload payload) {
    final host = Sankofa.instance;
    final ctx = PulseContext(
      sessionId: host.sessionManager?.sessionId,
      anonymousId: host.identity?.anonymousId,
      platform: 'flutter',
      osVersion: _osVersion(),
      appVersion: _appVersion,
      locale: WidgetsBinding.instance.platformDispatcher.locale.toLanguageTag(),
    );
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
        final resp = await c.handshake();
        _cached = resp.surveys;
        final q = _queue;
        if (q != null) await q.drain((p) => c.submit(p));
      } catch (e) {
        if (kDebugMode) {
          debugPrint('[Sankofa] pulse handshake failed: $e');
        }
      } finally {
        _refreshFuture = null;
      }
    }();
    _refreshFuture = fut;
    return fut;
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
