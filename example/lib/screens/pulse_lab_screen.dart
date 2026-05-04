import 'package:flutter/material.dart';
import 'package:sankofa_flutter/sankofa_flutter.dart';

import '../sankofa_demo.dart';

/// Pulse Lab — exercises every public surface of `SankofaPulse`:
///
///   - `register()` (handled in setup_screen.dart, status surfaced here)
///   - `show(surveyId, properties, flags)` — programmatic presentation
///   - `isEligible(surveyId)` — eligibility probe without rendering
///   - `on(event, listener)` — lifecycle hooks (each event logged)
///
/// The `Pro user` toggle below sets `properties: { plan: 'pro' }`, which
/// the `productResearch` survey's targeting rule requires. Toggle it
/// off to demo a survey that's intentionally ineligible.
class PulseLabScreen extends StatefulWidget {
  const PulseLabScreen({super.key});

  @override
  State<PulseLabScreen> createState() => _PulseLabScreenState();
}

class _PulseLabScreenState extends State<PulseLabScreen> {
  bool _proUser = true;
  final List<String> _eventLog = [];
  final List<PulseSubscription> _subscriptions = [];

  @override
  void initState() {
    super.initState();
    Sankofa.instance.screen('PulseLabScreen');
    // Subscribe to every Pulse lifecycle event so the lab can show
    // exactly what the SDK fires + when. Each subscription stays
    // until dispose() unwinds them — leaving them dangling would
    // leak across hot-reload cycles.
    for (final ev in PulseEvent.values) {
      _subscriptions.add(SankofaPulse.instance.on(ev, (payload) {
        if (!mounted) return;
        final ts = TimeOfDay.fromDateTime(DateTime.now());
        final prefix = '${ts.format(context)}  ${ev.wireName}';
        final suffix = [
          if (payload.responseId != null) 'response=${payload.responseId}',
          if (payload.reason != null) 'reason=${payload.reason}',
        ].join(' · ');
        setState(() {
          _eventLog.insert(
            0,
            suffix.isEmpty ? prefix : '$prefix — $suffix',
          );
          if (_eventLog.length > 40) _eventLog.removeLast();
        });
      }));
    }
  }

  @override
  void dispose() {
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    super.dispose();
  }

  Map<String, Object?> get _hostProperties => {
        if (_proUser) 'plan': 'pro',
      };

  Future<void> _show(String surveyId) async {
    if (!SankofaPulse.instance.isRegistered) {
      _toast('SankofaPulse not registered — check setup screen logs');
      return;
    }
    await SankofaPulse.instance.show(
      context,
      surveyId: surveyId,
      properties: _hostProperties,
    );
  }

  Future<void> _probeEligibility(String surveyId) async {
    if (!SankofaPulse.instance.isRegistered) {
      _toast('SankofaPulse not registered');
      return;
    }
    final decision = await SankofaPulse.instance.isEligible(
      surveyId,
      properties: _hostProperties,
    );
    if (!mounted) return;
    final summary = decision.eligible
        ? 'eligible ✓'
        : 'ineligible — ${decision.reason ?? "(no reason)"}';
    _toast('${DemoSurveys.titles[surveyId]}: $summary');
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final registered = SankofaPulse.instance.isRegistered;
    return Scaffold(
      appBar: AppBar(title: const Text('Pulse Lab')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _registrationCard(registered),
          const SizedBox(height: 16),
          _hostContextCard(),
          const SizedBox(height: 16),
          const Text(
            'Surveys',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          for (final id in DemoSurveys.all) _surveyCard(id),
          const SizedBox(height: 24),
          _eventLogCard(),
        ],
      ),
    );
  }

  Widget _registrationCard(bool registered) {
    final color = registered ? Colors.green : Colors.orange;
    return Card(
      color: color.withValues(alpha: 0.08),
      child: ListTile(
        leading: Icon(
          registered ? Icons.check_circle : Icons.warning_amber_rounded,
          color: color,
        ),
        title: Text(registered
            ? 'SankofaPulse registered'
            : 'SankofaPulse not registered'),
        subtitle: Text(
          registered
              ? 'Surveys will fetch their bundle and present locally.'
              : 'register() returned false — make sure Sankofa.instance.init ran first.',
          style: const TextStyle(fontSize: 12),
        ),
      ),
    );
  }

  Widget _hostContextCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Host-supplied eligibility context',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            const Text(
              'Forwarded into both `show()` and `isEligible()` so '
              'targeting rules can filter on user_property.',
              style: TextStyle(fontSize: 12, color: Colors.white70),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              title: const Text('Pro user (plan = pro)'),
              subtitle: const Text(
                'Required by the "Product research" survey\'s targeting.',
                style: TextStyle(fontSize: 12),
              ),
              value: _proUser,
              onChanged: (v) => setState(() => _proUser = v),
              contentPadding: EdgeInsets.zero,
            ),
          ],
        ),
      ),
    );
  }

  Widget _surveyCard(String id) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        DemoSurveys.titles[id] ?? id,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        id,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.white54,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              DemoSurveys.descriptions[id] ?? '',
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                FilledButton.icon(
                  icon: const Icon(Icons.play_arrow_rounded, size: 18),
                  label: const Text('Show'),
                  onPressed: () => _show(id),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.fact_check_outlined, size: 18),
                  label: const Text('Check eligibility'),
                  onPressed: () => _probeEligibility(id),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _eventLogCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Lifecycle event log',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                if (_eventLog.isNotEmpty)
                  TextButton(
                    onPressed: () => setState(_eventLog.clear),
                    child: const Text('Clear'),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              'Subscribed via SankofaPulse.instance.on(event, listener) — '
              'each entry shows what the SDK fires.',
              style: TextStyle(fontSize: 11, color: Colors.white70),
            ),
            const SizedBox(height: 8),
            if (_eventLog.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  'No events yet. Press Show on a survey above.',
                  style: TextStyle(color: Colors.white38),
                ),
              )
            else
              for (final entry in _eventLog)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    entry,
                    style: const TextStyle(
                      fontSize: 12,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}
