/// Wire-shape types for the Pulse Flutter SDK. Mirrors the server's
/// JSON envelopes from `server/engine/ee/pulse/`.
///
/// Kept in one file so the network layer + the renderer share a
/// single source of truth — drift here would silently break ingest.
library sankofa_flutter.pulse.models;

import 'branching.dart';
import 'targeting.dart';

class PulseQuestionOption {
  final String key;
  final String label;
  final String? imageUrl;

  const PulseQuestionOption({
    required this.key,
    required this.label,
    this.imageUrl,
  });

  factory PulseQuestionOption.fromJson(Map<String, dynamic> json) =>
      PulseQuestionOption(
        key: json['key'] as String? ?? '',
        label: json['label'] as String? ?? '',
        imageUrl: json['image_url'] as String?,
      );
}

class PulseQuestion {
  final String id;
  final String kind;
  final String prompt;
  final String? helptext;
  final bool required;
  final int orderIndex;
  final List<PulseQuestionOption>? options;

  /// Per-kind validation block; opaque map decoded lazily by the
  /// renderer (e.g. `min`/`max` for `slider`, `min_length` for text).
  final Map<String, dynamic>? validation;

  const PulseQuestion({
    required this.id,
    required this.kind,
    required this.prompt,
    this.helptext,
    this.required = false,
    this.orderIndex = 0,
    this.options,
    this.validation,
  });

  factory PulseQuestion.fromJson(Map<String, dynamic> json) {
    final rawOptions = json['options'] as List<dynamic>?;
    return PulseQuestion(
      id: json['id'] as String? ?? '',
      kind: json['kind'] as String? ?? '',
      prompt: json['prompt'] as String? ?? '',
      helptext: json['helptext'] as String?,
      required: json['required'] as bool? ?? false,
      orderIndex: (json['order_index'] as num?)?.toInt() ?? 0,
      options: rawOptions
          ?.whereType<Map<String, dynamic>>()
          .map(PulseQuestionOption.fromJson)
          .toList(),
      validation: (json['validation'] as Map?)?.cast<String, dynamic>(),
    );
  }
}

class PulseTheme {
  final String? primaryColor;
  final String? backgroundColor;
  final String? foregroundColor;
  final String? mutedColor;
  final String? borderColor;
  final String? fontFamily;
  final String? darkMode;
  final String? logoUrl;

  const PulseTheme({
    this.primaryColor,
    this.backgroundColor,
    this.foregroundColor,
    this.mutedColor,
    this.borderColor,
    this.fontFamily,
    this.darkMode,
    this.logoUrl,
  });

  factory PulseTheme.fromJson(Map<String, dynamic> json) => PulseTheme(
        primaryColor: json['primary_color'] as String?,
        backgroundColor: json['background_color'] as String?,
        foregroundColor: json['foreground_color'] as String?,
        mutedColor: json['muted_color'] as String?,
        borderColor: json['border_color'] as String?,
        fontFamily: json['font_family'] as String?,
        darkMode: json['dark_mode'] as String?,
        logoUrl: json['logo_url'] as String?,
      );
}

class PulseSurvey {
  final String id;
  final String kind;
  final String name;
  final String? description;
  final List<PulseQuestion> questions;
  final PulseTheme? theme;

  /// Published version of this survey. Drives version-aware
  /// suppression: completing/dismissing version N suppresses the
  /// survey only until a version > N is published, at which point all
  /// per-respondent suppression for it resets. 0 means the server
  /// didn't supply a version (older engine) — suppression then behaves
  /// as it did before versions were plumbed through.
  final int versionNumber;

  const PulseSurvey({
    required this.id,
    required this.kind,
    required this.name,
    this.description,
    this.questions = const [],
    this.theme,
    this.versionNumber = 0,
  });

  factory PulseSurvey.fromJson(Map<String, dynamic> json) {
    final rawQuestions = json['questions'] as List<dynamic>?;
    final rawTheme = json['theme'];
    return PulseSurvey(
      id: json['id'] as String? ?? '',
      kind: json['kind'] as String? ?? '',
      name: json['name'] as String? ?? '',
      description: json['description'] as String?,
      questions: rawQuestions == null
          ? const []
          : rawQuestions
              .whereType<Map<String, dynamic>>()
              .map(PulseQuestion.fromJson)
              .toList(),
      theme: rawTheme is Map<String, dynamic>
          ? PulseTheme.fromJson(rawTheme)
          : null,
      versionNumber: (json['version_number'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Lightweight projection returned by GET /api/pulse/surveys.
/// Used for survey discovery from the SDK side — pairs with each
/// survey's targeting rules so callers can run local eligibility
/// evaluation without a per-survey bundle fetch.
class PulseSurveySummary {
  final String id;
  final String name;
  final String? description;
  final String kind;
  final String status;
  final String? slug;
  final List<PulseTargetingRule> targetingRules;
  /// Display behaviour fields — published from the dashboard,
  /// evaluated by the SDK. autoShow defaults to true,
  /// displayCooldownSeconds defaults to 7 days, displayDelayMs to 0.
  final bool autoShow;
  final int displayCooldownSeconds;
  final int displayDelayMs;

  /// Published version of the survey. See [PulseSurvey.versionNumber].
  /// 0 when the server's list endpoint doesn't emit `version_number`.
  final int versionNumber;

  const PulseSurveySummary({
    required this.id,
    required this.name,
    this.description,
    required this.kind,
    required this.status,
    this.slug,
    this.targetingRules = const [],
    this.autoShow = true,
    this.displayCooldownSeconds = 7 * 24 * 60 * 60,
    this.displayDelayMs = 0,
    this.versionNumber = 0,
  });

  factory PulseSurveySummary.fromJson(Map<String, dynamic> json) {
    final rawRules = json['targeting_rules'] as List<dynamic>?;
    return PulseSurveySummary(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      description: json['description'] as String?,
      kind: json['kind'] as String? ?? '',
      status: json['status'] as String? ?? '',
      slug: json['slug'] as String?,
      targetingRules: rawRules == null
          ? const []
          : rawRules
              .whereType<Map<String, dynamic>>()
              .map(PulseTargetingRule.fromJson)
              .toList(),
      autoShow: json['auto_show'] as bool? ?? true,
      displayCooldownSeconds:
          (json['display_cooldown_seconds'] as num?)?.toInt() ??
              7 * 24 * 60 * 60,
      displayDelayMs: (json['display_delay_ms'] as num?)?.toInt() ?? 0,
      versionNumber: (json['version_number'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (description != null) 'description': description,
        'kind': kind,
        'status': status,
        if (slug != null) 'slug': slug,
        'targeting_rules': targetingRules.map((r) {
          // Round-trip via fromJson's accepted shape — same wire keys.
          final m = <String, dynamic>{'kind': r.kind};
          if (r.urlMatch != null) m['url_match'] = r.urlMatch;
          if (r.urlValue != null) m['url_value'] = r.urlValue;
          if (r.screenMatch != null) m['screen_match'] = r.screenMatch;
          if (r.screenNames != null) m['screen_names'] = r.screenNames;
          if (r.eventName != null) m['event_name'] = r.eventName;
          if (r.eventMinCount != null) m['event_min_count'] = r.eventMinCount;
          if (r.eventWindowDays != null) {
            m['event_window_days'] = r.eventWindowDays;
          }
          if (r.propertyKey != null) m['property_key'] = r.propertyKey;
          if (r.propertyOp != null) m['property_op'] = r.propertyOp;
          if (r.propertyValue != null) m['property_value'] = r.propertyValue;
          if (r.cohortId != null) m['cohort_id'] = r.cohortId;
          if (r.samplingRate != null) m['sampling_rate'] = r.samplingRate;
          if (r.frequencyScope != null) m['frequency_scope'] = r.frequencyScope;
          if (r.frequencyMax != null) m['frequency_max'] = r.frequencyMax;
          if (r.frequencyWindowDays != null) {
            m['frequency_window_days'] = r.frequencyWindowDays;
          }
          if (r.flagKey != null) m['flag_key'] = r.flagKey;
          if (r.flagValue != null) m['flag_value'] = r.flagValue;
          if (r.sessionEvery != null) m['session_every'] = r.sessionEvery;
          if (r.sessionMin != null) m['session_min'] = r.sessionMin;
          return m;
        }).toList(),
        'auto_show': autoShow,
        'display_cooldown_seconds': displayCooldownSeconds,
        'display_delay_ms': displayDelayMs,
        'version_number': versionNumber,
      };
}

class PulseHandshakeResponse {
  final List<PulseSurvey> surveys;

  const PulseHandshakeResponse({this.surveys = const []});

  factory PulseHandshakeResponse.fromJson(Map<String, dynamic> json) {
    final raw = json['surveys'] as List<dynamic>?;
    return PulseHandshakeResponse(
      surveys: raw == null
          ? const []
          : raw
              .whereType<Map<String, dynamic>>()
              .map(PulseSurvey.fromJson)
              .toList(),
    );
  }
}

/// Full survey bundle — survey row + targeting rules + branching
/// rules + translations. Themes and partial state will land here
/// as those features graduate; the Go-side wire shape includes
/// them all already.
class PulseSurveyBundle {
  final PulseSurvey survey;
  final List<PulseTargetingRule> targetingRules;
  final List<PulseBranchingRule> branchingRules;

  /// Per-locale string overrides keyed first by BCP-47 locale tag
  /// (e.g. "en-US"), then by the dot-path key (e.g.
  /// "question.psq_q1.prompt"). Empty when the survey hasn't been
  /// translated.
  final Map<String, Map<String, String>> translations;

  const PulseSurveyBundle({
    this.survey = const PulseSurvey(id: '', kind: '', name: ''),
    this.targetingRules = const [],
    this.branchingRules = const [],
    this.translations = const {},
  });

  factory PulseSurveyBundle.fromJson(Map<String, dynamic> json) {
    final rawSurvey = json['survey'];
    final rawQuestions = json['questions'];
    final rawTheme = json['theme'];
    final rawTargeting = json['targeting_rules'];
    final rawBranching = json['branching_rules'];
    final rawTranslations = json['translations'];

    PulseSurvey survey = const PulseSurvey(id: '', kind: '', name: '');
    if (rawSurvey is Map<String, dynamic>) {
      survey = PulseSurvey.fromJson(rawSurvey);
    }
    // The bundle ships questions AND theme on sibling keys, not nested
    // inside `survey` — fold them onto the survey so callers see one
    // self-contained PulseSurvey. In particular the renderer reads
    // `survey.theme` for colors; before this the sibling theme was
    // dropped and surveys always rendered with the default palette.
    // Fall back to any nested value if a sibling key is absent.
    final questions = rawQuestions is List
        ? rawQuestions
            .whereType<Map<String, dynamic>>()
            .map(PulseQuestion.fromJson)
            .toList()
        : survey.questions;
    final theme = rawTheme is Map<String, dynamic>
        ? PulseTheme.fromJson(rawTheme)
        : survey.theme;
    survey = PulseSurvey(
      id: survey.id,
      kind: survey.kind,
      name: survey.name,
      description: survey.description,
      questions: questions,
      theme: theme,
      versionNumber: survey.versionNumber,
    );
    final targeting = rawTargeting is List
        ? rawTargeting
            .whereType<Map<String, dynamic>>()
            .map(PulseTargetingRule.fromJson)
            .toList()
        : <PulseTargetingRule>[];
    final branching = rawBranching is List
        ? rawBranching
            .whereType<Map<String, dynamic>>()
            .map(PulseBranchingRule.fromJson)
            .toList()
        : <PulseBranchingRule>[];
    final translations = <String, Map<String, String>>{};
    if (rawTranslations is Map) {
      rawTranslations.forEach((locale, strings) {
        if (strings is Map) {
          final stringMap = <String, String>{};
          strings.forEach((k, v) {
            if (k != null && v != null) {
              stringMap[k.toString()] = v.toString();
            }
          });
          if (stringMap.isNotEmpty) {
            translations[locale.toString()] = stringMap;
          }
        }
      });
    }
    return PulseSurveyBundle(
      survey: survey,
      targetingRules: targeting,
      branchingRules: branching,
      translations: translations,
    );
  }
}

/// Respondent identity envelope. Mirrors the server's
/// `ingestRespondent` shape (server/engine/ee/pulse/handlers_ingest.go).
/// At least one of the three fields should be set; the server tolerates
/// all-empty for fully anonymous submissions but the dashboard groups
/// responses by the most-specific id present.
class PulseRespondent {
  final String? userId;
  final String? externalId;
  final String? email;

  const PulseRespondent({this.userId, this.externalId, this.email});

  PulseRespondent copyWith({
    String? userId,
    String? externalId,
    String? email,
  }) =>
      PulseRespondent(
        userId: userId ?? this.userId,
        externalId: externalId ?? this.externalId,
        email: email ?? this.email,
      );

  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{};
    if (userId != null) m['user_id'] = userId;
    if (externalId != null) m['external_id'] = externalId;
    if (email != null) m['email'] = email;
    return m;
  }

  factory PulseRespondent.fromJson(Map<String, dynamic> json) =>
      PulseRespondent(
        userId: json['user_id'] as String?,
        externalId: json['external_id'] as String?,
        email: json['email'] as String?,
      );
}

class PulseContext {
  final String? sessionId;
  final String? anonymousId;
  final String? platform;
  final String? osVersion;
  final String? appVersion;
  final String? locale;

  /// Session id of the active replay recording, when replay is on.
  /// Lets the dashboard deep-link from a Pulse response straight to
  /// the recorded session. Null when replay is disabled, sampled
  /// out, or not yet started.
  final String? replaySessionId;

  const PulseContext({
    this.sessionId,
    this.anonymousId,
    this.platform = 'flutter',
    this.osVersion,
    this.appVersion,
    this.locale,
    this.replaySessionId,
  });

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{};
    if (sessionId != null) map['session_id'] = sessionId;
    if (anonymousId != null) map['anonymous_id'] = anonymousId;
    if (platform != null) map['platform'] = platform;
    if (osVersion != null) map['os_version'] = osVersion;
    if (appVersion != null) map['app_version'] = appVersion;
    if (locale != null) map['locale'] = locale;
    if (replaySessionId != null) map['replay_session_id'] = replaySessionId;
    return map;
  }

  factory PulseContext.fromJson(Map<String, dynamic> json) => PulseContext(
        sessionId: json['session_id'] as String?,
        anonymousId: json['anonymous_id'] as String?,
        platform: json['platform'] as String? ?? 'flutter',
        osVersion: json['os_version'] as String?,
        appVersion: json['app_version'] as String?,
        locale: json['locale'] as String?,
        replaySessionId: json['replay_session_id'] as String?,
      );
}

/// Final-submit payload. The wire shape matches the server's
/// `ingestPayload`: `answers` is a map keyed by question_id (NOT a
/// list of `{question_id, value}` pairs — that earlier shape was
/// silently 400'd in production because the Go decoder treats arrays
/// + maps as different types). Web + RN already speak this shape;
/// iOS, Android, and Flutter follow.
class PulseSubmitPayload {
  final String surveyId;
  final PulseRespondent respondent;
  final PulseContext? context;
  /// Active screen / route at submission time. First-class
  /// cross-product correlation key — same value Heatmap, Catch, and
  /// Replay use, so a deep link from
  /// `/dashboard/heatmaps/Identify` to
  /// `/dashboard/pulse/responses?screen=Identify` lands in the same
  /// context. Sourced from `Sankofa.instance.currentScreen`.
  final String? screen;
  final String? submittedAt;
  final Map<String, Object?> answers;

  const PulseSubmitPayload({
    required this.surveyId,
    this.respondent = const PulseRespondent(),
    this.context,
    this.screen,
    this.submittedAt,
    this.answers = const {},
  });

  PulseSubmitPayload copyWith({
    String? surveyId,
    PulseRespondent? respondent,
    PulseContext? context,
    String? screen,
    String? submittedAt,
    Map<String, Object?>? answers,
  }) =>
      PulseSubmitPayload(
        surveyId: surveyId ?? this.surveyId,
        respondent: respondent ?? this.respondent,
        context: context ?? this.context,
        screen: screen ?? this.screen,
        submittedAt: submittedAt ?? this.submittedAt,
        answers: answers ?? this.answers,
      );

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{
      'survey_id': surveyId,
      'respondent': respondent.toJson(),
      'answers': answers,
    };
    if (context != null) map['context'] = context!.toJson();
    if (screen != null && screen!.isNotEmpty) map['screen'] = screen;
    if (submittedAt != null) map['submitted_at'] = submittedAt;
    return map;
  }

  factory PulseSubmitPayload.fromJson(Map<String, dynamic> json) {
    final rawAnswers = json['answers'];
    final answers = rawAnswers is Map
        ? Map<String, Object?>.from(rawAnswers.cast<String, Object?>())
        : <String, Object?>{};
    return PulseSubmitPayload(
      surveyId: json['survey_id'] as String? ?? '',
      respondent: json['respondent'] is Map<String, dynamic>
          ? PulseRespondent.fromJson(json['respondent'] as Map<String, dynamic>)
          : const PulseRespondent(),
      context: json['context'] is Map<String, dynamic>
          ? PulseContext.fromJson(json['context'] as Map<String, dynamic>)
          : null,
      submittedAt: json['submitted_at'] as String?,
      answers: answers,
    );
  }
}

/// Wire payload for `POST /api/pulse/partial`. Same answers shape
/// (map keyed by question_id) as the final-submit body so the SDK
/// doesn't have to reformat between save + submit.
class PulsePartialUpsert {
  final String surveyId;
  final PulseRespondent respondent;
  final PulseContext? context;
  final Map<String, Object?> answers;
  final String? currentQuestionId;

  const PulsePartialUpsert({
    required this.surveyId,
    required this.respondent,
    this.context,
    this.answers = const {},
    this.currentQuestionId,
  });

  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{
      'survey_id': surveyId,
      'respondent': respondent.toJson(),
      'answers': answers,
    };
    if (context != null) m['context'] = context!.toJson();
    if (currentQuestionId != null) m['current_question_id'] = currentQuestionId;
    return m;
  }
}

/// Shape returned by `POST /api/pulse/partial`.
class PulsePartialAck {
  final String? id;
  final String? surveyId;
  final String? currentQuestionId;
  final int? versionNumber;
  final String? expiresAt;
  final String? updatedAt;

  const PulsePartialAck({
    this.id,
    this.surveyId,
    this.currentQuestionId,
    this.versionNumber,
    this.expiresAt,
    this.updatedAt,
  });

  factory PulsePartialAck.fromJson(Map<String, dynamic> json) =>
      PulsePartialAck(
        id: json['id'] as String?,
        surveyId: json['survey_id'] as String?,
        currentQuestionId: json['current_question_id'] as String?,
        versionNumber: (json['version_number'] as num?)?.toInt(),
        expiresAt: json['expires_at'] as String?,
        updatedAt: json['updated_at'] as String?,
      );
}

/// Shape returned by `GET /api/pulse/partial`. Mirrors the server's
/// `ResponsePartial` row.
class PulsePartial {
  final String? id;
  final String? surveyId;
  final String? respondentExternalId;
  final String? respondentUserId;
  final String? respondentEmail;
  final Map<String, Object?>? answers;
  final String? currentQuestionId;
  final int? versionNumber;
  final String? expiresAt;
  final String? updatedAt;

  const PulsePartial({
    this.id,
    this.surveyId,
    this.respondentExternalId,
    this.respondentUserId,
    this.respondentEmail,
    this.answers,
    this.currentQuestionId,
    this.versionNumber,
    this.expiresAt,
    this.updatedAt,
  });

  factory PulsePartial.fromJson(Map<String, dynamic> json) {
    final raw = json['answers'];
    return PulsePartial(
      id: json['id'] as String?,
      surveyId: json['survey_id'] as String?,
      respondentExternalId: json['respondent_external_id'] as String?,
      respondentUserId: json['respondent_user_id'] as String?,
      respondentEmail: json['respondent_email'] as String?,
      answers: raw is Map
          ? Map<String, Object?>.from(raw.cast<String, Object?>())
          : null,
      currentQuestionId: json['current_question_id'] as String?,
      versionNumber: (json['version_number'] as num?)?.toInt(),
      expiresAt: json['expires_at'] as String?,
      updatedAt: json['updated_at'] as String?,
    );
  }
}

/// Lifecycle events the SDK fires while a survey is on screen.
/// Hosts subscribe via `SankofaPulse.instance.on(...)` to wire
/// Pulse into their own analytics / CRM / replay tooling.
enum PulseEvent {
  /// Fired right after the survey dialog opens.
  surveyShown,

  /// Fired when the respondent closes without submitting.
  surveyDismissed,

  /// Fired after a successful submission.
  surveyCompleted,

  /// Fired after a successful partial-state save.
  surveyPartialSaved;

  String get wireName {
    switch (this) {
      case PulseEvent.surveyShown:
        return 'survey_shown';
      case PulseEvent.surveyDismissed:
        return 'survey_dismissed';
      case PulseEvent.surveyCompleted:
        return 'survey_completed';
      case PulseEvent.surveyPartialSaved:
        return 'survey_partial_saved';
    }
  }
}

/// Payload delivered to every [PulseEventListener]. `responseId`
/// is only populated on [PulseEvent.surveyCompleted]; `reason` is
/// populated on dismissal when we have one (e.g. eligibility miss).
class PulseEventPayload {
  final PulseEvent event;
  final String surveyId;
  final String? responseId;
  final String? reason;

  const PulseEventPayload({
    required this.event,
    required this.surveyId,
    this.responseId,
    this.reason,
  });
}

typedef PulseEventListener = void Function(PulseEventPayload payload);

/// Token returned by `SankofaPulse.instance.on(...)`. Hold it to
/// keep the listener alive; call [cancel] to remove it. The
/// constructor is public for SDK-internal use; hosts should only
/// ever obtain instances by calling `on(...)`.
class PulseSubscription {
  PulseSubscription(this._cancel);
  void Function()? _cancel;
  void cancel() {
    _cancel?.call();
    _cancel = null;
  }
}

class PulseSubmitResponse {
  final String? id;
  final String? surveyId;

  const PulseSubmitResponse({this.id, this.surveyId});

  factory PulseSubmitResponse.fromJson(Map<String, dynamic> json) =>
      PulseSubmitResponse(
        id: json['id'] as String?,
        surveyId: json['survey_id'] as String?,
      );
}
