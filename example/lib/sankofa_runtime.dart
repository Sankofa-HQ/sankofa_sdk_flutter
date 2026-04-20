import 'package:sankofa_flutter/sankofa_flutter.dart';

import 'sankofa_demo.dart';

/// Process-wide handles to the Switch + Config modules. Constructed
/// once in `SetupScreen._connect()` right after `Sankofa.instance.init`
/// so the Traffic Cop wires them before the handshake fires.
SankofaSwitch? _switch;
SankofaConfig? _config;

SankofaSwitch sankofaSwitch() {
  return _switch ??= SankofaSwitch(defaults: demoFlagDefaults());
}

SankofaConfig sankofaConfig() {
  return _config ??= SankofaConfig(defaults: demoConfigDefaults());
}

/// Forces both singletons to re-instantiate. Useful in dev flows where
/// the user tears down + re-initialises the SDK via the setup screen.
void resetSankofaModules() {
  _switch = null;
  _config = null;
}
