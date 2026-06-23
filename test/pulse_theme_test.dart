import 'package:flutter_test/flutter_test.dart';
import 'package:sankofa_flutter/sankofa_flutter.dart';

/// Regression: the survey bundle ships `theme` (and `questions`) on sibling
/// keys, NOT nested inside `survey`. PulseSurveyBundle.fromJson used to read
/// only `survey`/`questions`, dropping the sibling theme — so a survey with
/// custom colors set in the dashboard always rendered with the default
/// palette in the Flutter app. These tests pin that the sibling theme is
/// folded onto `bundle.survey.theme`.
void main() {
  group('PulseSurveyBundle theme folding', () {
    test('sibling theme is attached to survey.theme with all colors', () {
      final bundle = PulseSurveyBundle.fromJson({
        'survey': {'id': 'psv_1', 'kind': 'nps', 'name': 'My Survey', 'version_number': 3},
        'questions': [
          {'id': 'psq_1', 'kind': 'text', 'prompt': 'How are you?'},
        ],
        'theme': {
          'primary_color': '#FF0000',
          'background_color': '#000000',
          'foreground_color': '#FFFFFF',
          'muted_color': '#888888',
          'border_color': '#222222',
          'font_family': 'Inter',
          'dark_mode': 'dark',
          'logo_url': 'https://cdn.example.com/logo.png',
        },
        'targeting_rules': [],
        'branching_rules': [],
      });

      final theme = bundle.survey.theme;
      expect(theme, isNotNull, reason: 'sibling theme must be folded onto the survey');
      expect(theme!.primaryColor, '#FF0000');
      expect(theme.backgroundColor, '#000000');
      expect(theme.foregroundColor, '#FFFFFF');
      expect(theme.mutedColor, '#888888');
      expect(theme.borderColor, '#222222');
      expect(theme.fontFamily, 'Inter');
      expect(theme.darkMode, 'dark');
      expect(theme.logoUrl, 'https://cdn.example.com/logo.png');

      // The survey identity + sibling questions must still come through.
      expect(bundle.survey.id, 'psv_1');
      expect(bundle.survey.versionNumber, 3);
      expect(bundle.survey.questions.length, 1);
      expect(bundle.survey.questions.first.prompt, 'How are you?');
    });

    test('no theme → survey.theme is null (renderer uses default palette)', () {
      final bundle = PulseSurveyBundle.fromJson({
        'survey': {'id': 'psv_2', 'kind': 'csat', 'name': 'No Theme'},
        'questions': [],
        'targeting_rules': [],
      });
      expect(bundle.survey.theme, isNull);
    });
  });
}
