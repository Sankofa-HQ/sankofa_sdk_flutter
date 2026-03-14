import 'package:flutter_test/flutter_test.dart';
import 'package:sankofa_flutter/sankofa_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SankofaReplay.instance.resetForTesting();
  });

  tearDown(() async {
    await SankofaReplay.instance.resetForTesting();
  });

  test('normalizes track endpoints from supported input formats', () {
    expect(
      Sankofa.resolveTrackUri('http://localhost:8080').toString(),
      'http://localhost:8080/api/v1/track',
    );
    expect(
      Sankofa.resolveTrackUri('http://localhost:8080/api/v1').toString(),
      'http://localhost:8080/api/v1/track',
    );
    expect(
      Sankofa.resolveTrackUri('http://localhost:8080/api/v1/track').toString(),
      'http://localhost:8080/api/v1/track',
    );
    expect(
      Sankofa.resolveTrackUri('http://localhost:8080/v1/track').toString(),
      'http://localhost:8080/api/v1/track',
    );
  });

  test('serializes nested transport values into stable strings', () {
    final serialized = Sankofa.serializeTransportProperties({
      'count': 42,
      'enabled': true,
      'metadata': {
        'step': 3,
        'tags': ['signup', 'checkout'],
      },
      'sent_at': DateTime.utc(2026, 3, 13, 12, 30),
    });

    expect(serialized['count'], '42');
    expect(serialized['enabled'], 'true');
    expect(serialized['metadata'], '{"step":3,"tags":["signup","checkout"]}');
    expect(serialized['sent_at'], '2026-03-13T12:30:00.000Z');
  });

  test('replay reconfigures when the session changes', () async {
    SharedPreferences.setMockInitialValues({
      'sankofa_replay_chunk_session-a': 4,
    });

    await SankofaReplay.instance.configure(
      apiKey: 'sk_test_123',
      endpoint: 'http://localhost:8080',
      sessionId: 'session-a',
      debug: false,
    );

    expect(SankofaReplay.instance.currentSessionId, 'session-a');
    expect(SankofaReplay.instance.currentChunkIndex, 4);
    expect(SankofaReplay.instance.isRecordingForTesting, isTrue);

    await SankofaReplay.instance.configure(
      apiKey: 'sk_test_123',
      endpoint: 'http://localhost:8080',
      sessionId: 'session-b',
      debug: false,
    );

    expect(SankofaReplay.instance.currentSessionId, 'session-b');
    expect(SankofaReplay.instance.currentChunkIndex, 0);
    expect(SankofaReplay.instance.isRecordingForTesting, isTrue);
  });
}
