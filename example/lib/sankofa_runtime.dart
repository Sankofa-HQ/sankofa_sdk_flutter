import 'package:sankofa_flutter/sankofa_flutter.dart';

import 'sankofa_demo.dart';

/// Process-wide handles to the Switch + Config + Catch + Pulse
/// modules. Constructed once in `SetupScreen._connect()` right after
/// `Sankofa.instance.init` so the Traffic Cop wires them before the
/// handshake fires. The Catch module reads live Switch/Config state
/// at capture time via the *Snapshot closures, so every Catch event
/// carries the flag + config values that were live when it fired.
SankofaSwitch? _switch;
SankofaConfig? _config;
SankofaCatch? _catch;
bool _pulseRegistered = false;

SankofaSwitch sankofaSwitch() {
  return _switch ??= SankofaSwitch(defaults: demoFlagDefaults());
}

SankofaConfig sankofaConfig() {
  return _config ??= SankofaConfig(defaults: demoConfigDefaults());
}

/// Legacy factory kept for the Crash Gallery's "advanced API" demo path.
///
/// 🚀 In Phase A, host apps no longer need this — `Sankofa.instance.init`
/// auto-constructs SankofaCatch and the static helpers
/// (`Sankofa.captureException`, `Sankofa.log`, etc.) reach the same
/// singleton from anywhere in the app.  Switch + Config snapshots are
/// auto-discovered from the registry, so the read-snapshot closures
/// that used to live here are gone (dead code).
///
/// The factory still works for power users who want a custom transport
/// or non-default sample rate — it returns the same singleton the
/// statics route to (idempotent constructor).
SankofaCatch sankofaCatch() {
  return _catch ??= SankofaCatch.instance ??
      SankofaCatch(
        environment: 'test',
        release: 'sankofa-example-flutter@0.1.0',
      );
}

/// Register Sankofa Pulse with the host SDK. Unlike Switch/Config/Catch,
/// Pulse needs `Sankofa.instance.init` to have completed first because
/// it reads the API key + endpoint at registration time (the others
/// register pre-init and pull credentials lazily on first call).
///
/// Call this from setup AFTER `Sankofa.instance.init` resolves.
/// Idempotent — no-ops on subsequent calls.
Future<bool> registerSankofaPulse() async {
  if (_pulseRegistered) return true;
  final ok = await SankofaPulse.instance.register();
  if (ok) _pulseRegistered = true;
  return ok;
}

/// Forces all four singletons to re-instantiate. Useful in dev flows
/// where the user tears down + re-initialises the SDK via the setup
/// screen.
void resetSankofaModules() {
  _switch = null;
  _config = null;
  _catch?.shutdown();
  _catch = null;
  _pulseRegistered = false;
}
