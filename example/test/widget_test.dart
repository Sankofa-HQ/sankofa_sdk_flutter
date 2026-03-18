import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sankofa_example/main.dart';

void main() {
  testWidgets('renders the setup screen controls', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pump();

    expect(find.text('CONNECTION SETTINGS'), findsOneWidget);
    expect(find.text('Engine URL'), findsOneWidget);
    expect(find.text('API Key'), findsOneWidget);
    expect(find.byKey(const Key('setup-engine-url-field')), findsOneWidget);
    expect(find.byKey(const Key('setup-api-key-field')), findsOneWidget);
    expect(find.byKey(const Key('setup-connect-button')), findsOneWidget);
    expect(find.text('Initialize & Connect'), findsOneWidget);
  });
}
