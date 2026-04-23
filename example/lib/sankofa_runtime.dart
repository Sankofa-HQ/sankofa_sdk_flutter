import 'package:sankofa_flutter/sankofa_flutter.dart';

import 'sankofa_demo.dart';

/// Process-wide handles to the Switch + Config + Catch modules.
/// Constructed once in `SetupScreen._connect()` right after
/// `Sankofa.instance.init` so the Traffic Cop wires them before the
/// handshake fires. The Catch module reads live Switch/Config state at
/// capture time via the *Snapshot closures, so every Catch event
/// carries the flag + config values that were live when it fired.
SankofaSwitch? _switch;
SankofaConfig? _config;
SankofaCatch? _catch;

SankofaSwitch sankofaSwitch() {
  return _switch ??= SankofaSwitch(defaults: demoFlagDefaults());
}

SankofaConfig sankofaConfig() {
  return _config ??= SankofaConfig(defaults: demoConfigDefaults());
}

SankofaCatch sankofaCatch() {
  return _catch ??= SankofaCatch(
    environment: 'test',
    release: 'sankofa-example-flutter@0.1.0',
    readFlagSnapshot: () {
      // Serialise the current flag decisions so every Catch event
      // records what the user was seeing at crash time.
      final out = <String, String>{};
      final sw = _switch;
      if (sw == null) return out;
      for (final key in demoFlagDefaults().keys) {
        final dec = sw.getDecision(key);
        if (dec == null) continue;
        out[key] = dec.variant.isNotEmpty ? dec.variant : dec.value.toString();
      }
      return out;
    },
    readConfigSnapshot: () {
      final out = <String, dynamic>{};
      final cfg = _config;
      if (cfg == null) return out;
      for (final key in demoConfigDefaults().keys) {
        final dec = cfg.getDecision(key);
        if (dec == null) continue;
        out[key] = dec.value;
      }
      return out;
    },
  );
}

/// Forces all three singletons to re-instantiate. Useful in dev flows
/// where the user tears down + re-initialises the SDK via the setup
/// screen.
void resetSankofaModules() {
  _switch = null;
  _config = null;
  _catch?.shutdown();
  _catch = null;
}
