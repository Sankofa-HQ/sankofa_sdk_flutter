import 'package:flutter/widgets.dart';

import 'branching.dart';
import 'pulse_models.dart';
import 'translator.dart';

/// Everything a custom Pulse renderer needs to present a survey and
/// report back its lifecycle — the "survey state + controller" pair.
///
/// Pulse hands one of these to a renderer registered via
/// `SankofaPulse.instance.registerRenderer(...)`. The renderer owns its
/// own UI (and is responsible for dismissing it when done); it drives
/// the survey by invoking the callbacks below. Pulse takes care of the
/// surrounding lifecycle — targeting, cooldown/version/completion
/// suppression, partial-save scheduling, analytics emission — so a
/// renderer only deals with presentation.
@immutable
class PulseRenderRequest {
  /// The survey graph (questions sorted by `orderIndex`), theme, and
  /// published [PulseSurvey.versionNumber].
  final PulseSurvey survey;

  /// Skip-logic / branching rules for the survey, if any.
  final List<PulseBranchingRule> branchingRules;

  /// Locale-resolved string lookup. Null when the survey has no
  /// translations — render the survey's own strings directly.
  final PulseTranslator? translator;

  /// Answers to seed the renderer with — non-empty when resuming an
  /// in-progress partial. Keyed by question id.
  final Map<String, Object?> initialAnswers;

  /// Question id to open on, when resuming a partial. Null → start at
  /// the first question.
  final String? initialQuestionId;

  /// Call as the respondent edits answers so Pulse can debounce-save
  /// the partial for cross-session resume. Null when partial save is
  /// unavailable (anonymous respondent with no external id).
  final void Function(
    Map<String, Object?> answers,
    String currentQuestionId,
  )? onProgress;

  /// Call once with the assembled payload when the respondent submits.
  /// Pulse handles the network submit, queueing, analytics, and
  /// permanent-completion suppression. The renderer should close its UI
  /// after invoking this.
  final void Function(PulseSubmitPayload payload) onSubmit;

  /// Call when the respondent closes the survey without submitting, so
  /// Pulse emits the dismissed event. The in-progress partial is kept
  /// for resume.
  final VoidCallback onDismiss;

  const PulseRenderRequest({
    required this.survey,
    this.branchingRules = const [],
    this.translator,
    this.initialAnswers = const {},
    this.initialQuestionId,
    this.onProgress,
    required this.onSubmit,
    required this.onDismiss,
  });
}

/// A host-supplied renderer. Present whatever UI you like from
/// [context] and return a Future that completes when the survey UI is
/// gone (submitted or dismissed) — Pulse uses completion to clear its
/// "a survey is on screen" guard. Register with
/// `SankofaPulse.instance.registerRenderer(...)`; pass `null` to fall
/// back to the built-in renderer.
typedef PulseSurveyRenderer = Future<void> Function(
  BuildContext context,
  PulseRenderRequest request,
);
