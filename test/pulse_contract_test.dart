import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sankofa_flutter/sankofa_flutter.dart';

/// Cross-SDK contract test. Reads the canonical golden submit body
/// from `sdks/_contract_tests/goldens/pulse_submit_basic.json` and
/// asserts that the Flutter SDK serialises the same fixture inputs
/// into a structurally identical JSON payload.
///
/// If this test fails, the Flutter wire shape has drifted away from
/// the server contract that Web + RN already speak. Fix the SDK, not
/// the golden — the golden mirrors what the server's `ingestPayload`
/// struct accepts in `server/engine/ee/pulse/handlers_ingest.go`.
void main() {
  group('Pulse contract', () {
    test('pulse_submit_basic matches golden', () {
      final golden = _readGolden('pulse_submit_basic.json');

      const payload = PulseSubmitPayload(
        surveyId: 'psv_test_001',
        respondent: PulseRespondent(
          userId: 'usr_42',
          externalId: 'ext_42',
          email: 'alice@example.com',
        ),
        context: PulseContext(
          sessionId: 'sess_abc',
          anonymousId: 'anon_xyz',
          platform: 'contract-test',
          osVersion: 'test-os',
          appVersion: '1.0.0',
          locale: 'en-US',
        ),
        answers: {
          'q1': 'hello',
          'q2': 9,
          'q3': ['red', 'green'],
        },
      );

      final produced =
          jsonDecode(jsonEncode(payload.toJson())) as Map<String, dynamic>;
      _assertStructurallyEqual(golden, produced, '\$');
    });

    test('pulse_submit_anonymous matches golden', () {
      // Fully anonymous: no respondent ids, minimal context. Catches
      // regressions where the SDK fabricates empty strings for
      // missing identity fields rather than omitting them.
      final golden = _readGolden('pulse_submit_anonymous.json');
      const payload = PulseSubmitPayload(
        surveyId: 'psv_anon_001',
        respondent: PulseRespondent(),
        context: PulseContext(
          sessionId: null,
          anonymousId: null,
          platform: 'contract-test',
          osVersion: null,
          appVersion: null,
          locale: null,
        ),
        answers: {'q1': 'anonymous'},
      );
      final produced =
          jsonDecode(jsonEncode(payload.toJson())) as Map<String, dynamic>;
      _assertStructurallyEqual(golden, produced, '\$');
    });

    test('pulse_submit_all_answer_kinds matches golden', () {
      // Every supported answer value type encoded into a single
      // payload — catches encoder regressions that only affect a
      // specific kind.
      final golden = _readGolden('pulse_submit_all_answer_kinds.json');
      const payload = PulseSubmitPayload(
        surveyId: 'psv_kinds_001',
        respondent: PulseRespondent(externalId: 'ext_42'),
        context: PulseContext(
          sessionId: null,
          anonymousId: null,
          platform: 'contract-test',
          osVersion: null,
          appVersion: null,
          locale: null,
          replaySessionId: 'rep_abc',
        ),
        answers: {
          'short_text': 'hello',
          'long_text': 'the app feels slow when I open the cart screen',
          'number': 42,
          'rating': 4,
          'nps': 9,
          'single': 'key_pro',
          'multi': ['key_a', 'key_c'],
          'boolean': true,
          'slider': 75,
          'date': '2026-05-01',
          'ranking': ['key_b', 'key_a', 'key_c'],
          'matrix': {'row_a': 'col_x', 'row_b': 'col_y'},
          'consent': true,
          'image_choice': 'key_blue',
          'maxdiff': {'best': 'key_a', 'worst': 'key_c'},
          'signature': 'data:image/png;base64,iVBORw0KGgo=',
        },
      );
      final produced =
          jsonDecode(jsonEncode(payload.toJson())) as Map<String, dynamic>;
      _assertStructurallyEqual(golden, produced, '\$');
    });
  });
}

Map<String, dynamic> _readGolden(String name) {
  final file = _resolveGolden(name);
  expect(file, isNotNull, reason: 'golden file $name not found');
  return jsonDecode(file!.readAsStringSync()) as Map<String, dynamic>;
}

/// Walks up from cwd looking for `sdks/_contract_tests/goldens/<name>`.
/// Falls back to the `SANKOFA_CONTRACT_GOLDENS` env var for CI runs
/// that exec outside the workspace.
File? _resolveGolden(String name) {
  final override = Platform.environment['SANKOFA_CONTRACT_GOLDENS'];
  if (override != null && override.isNotEmpty) {
    final f = File('$override${Platform.pathSeparator}$name');
    return f.existsSync() ? f : null;
  }
  Directory? dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    if (dir == null) break;
    final candidate = File(
      '${dir.path}${Platform.pathSeparator}sdks${Platform.pathSeparator}_contract_tests${Platform.pathSeparator}goldens${Platform.pathSeparator}$name',
    );
    if (candidate.existsSync()) return candidate;
    dir = dir.parent;
    if (dir.path == dir.parent.path) break;
  }
  return null;
}

/// Structural equality: same keys, same values, same nesting.
/// Numbers compare by `.toDouble()` so `9` and `9.0` aren't a
/// false positive across language serialisers.
void _assertStructurallyEqual(Object? expected, Object? actual, String path) {
  if (expected is Map) {
    expect(actual, isA<Map>(), reason: '$path: expected map');
    final actualMap = actual as Map;
    expect(
      actualMap.keys.map((k) => k.toString()).toSet(),
      expected.keys.map((k) => k.toString()).toSet(),
      reason: '$path: key set mismatch',
    );
    for (final entry in expected.entries) {
      _assertStructurallyEqual(
        entry.value,
        actualMap[entry.key.toString()],
        '$path.${entry.key}',
      );
    }
    return;
  }
  if (expected is List) {
    expect(actual, isA<List>(), reason: '$path: expected list');
    final actualList = actual as List;
    expect(actualList.length, expected.length, reason: '$path: list length');
    for (var i = 0; i < expected.length; i++) {
      _assertStructurallyEqual(expected[i], actualList[i], '$path[$i]');
    }
    return;
  }
  if (expected is num) {
    expect(actual, isA<num>(), reason: '$path: expected number');
    expect(
      (actual as num).toDouble(),
      closeTo(expected.toDouble(), 1e-9),
      reason: path,
    );
    return;
  }
  expect(actual, expected, reason: path);
}
