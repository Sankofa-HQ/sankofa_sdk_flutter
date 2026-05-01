/// Translation helpers — wire-shape lookups + locale resolution.
/// Mirrors `i18n.ts` in the Web SDK so a survey rendered in Flutter
/// picks the same locale + same per-string fallback chain as the
/// same survey rendered in a browser.
///
/// Lookup keys are dot-paths:
///   - survey.name
///   - survey.description
///   - question.<question_id>.prompt
///   - question.<question_id>.helptext
///   - question.<question_id>.option.<option_key>.label
///
/// Missing keys fall back to the source string on the survey /
/// question / option object — never throws, never blanks the UI.
library;

import 'pulse_models.dart';

/// BCP-47 language tags whose script renders right-to-left.
/// Matches the Unicode CLDR list; SDKs use it to flip dialog layout
/// when a survey's resolved locale is RTL even though the host's
/// system locale is LTR.
const Set<String> _pulseRtlLanguageTags = {
  'ar', 'fa', 'he', 'iw', 'ji', 'ku', 'ps', 'sd', 'ug', 'ur', 'yi',
};

bool pulseLocaleIsRTL(String? locale) {
  if (locale == null || locale.isEmpty) return false;
  final language = locale.split('-').first.toLowerCase();
  return _pulseRtlLanguageTags.contains(language);
}

class PulseTranslator {
  final Map<String, String> _strings;

  /// BCP-47 tag this translator was built for; null when no
  /// translation was applied (source strings render unchanged).
  final String? locale;

  const PulseTranslator(this._strings, {this.locale});

  String surveyName(PulseSurvey survey) =>
      _strings['survey.name'] ?? survey.name;

  String? surveyDescription(PulseSurvey survey) =>
      _strings['survey.description'] ?? survey.description;

  String questionPrompt(PulseQuestion question) =>
      _strings['question.${question.id}.prompt'] ?? question.prompt;

  String? questionHelptext(PulseQuestion question) =>
      _strings['question.${question.id}.helptext'] ?? question.helptext;

  String optionLabel(PulseQuestion question, PulseQuestionOption option) =>
      _strings['question.${question.id}.option.${option.key}.label'] ??
      option.label;

  /// Resolution order:
  ///   1. Exact match against translations keys
  ///   2. Language-only fallback (en-US → en)
  ///   3. Device default — exact, then language-only
  ///   4. null → render source strings unchanged
  static String? resolveLocale(
    Map<String, Map<String, String>>? translations, {
    String? preferred,
    String? deviceLocale,
  }) {
    if (translations == null || translations.isEmpty) return null;
    final candidates = <String>[];
    if (preferred != null && preferred.isNotEmpty) candidates.add(preferred);
    if (deviceLocale != null && deviceLocale.isNotEmpty) {
      candidates.add(deviceLocale);
    }
    for (final candidate in candidates) {
      if (translations.containsKey(candidate)) return candidate;
      final language = candidate.split('-').first;
      if (language != candidate && translations.containsKey(language)) {
        return language;
      }
    }
    return null;
  }

  static PulseTranslator? build(
    Map<String, Map<String, String>>? translations, {
    String? preferred,
    String? deviceLocale,
  }) {
    final locale = resolveLocale(
      translations,
      preferred: preferred,
      deviceLocale: deviceLocale,
    );
    if (locale == null) return null;
    final strings = translations?[locale];
    if (strings == null) return null;
    return PulseTranslator(strings, locale: locale);
  }
}
