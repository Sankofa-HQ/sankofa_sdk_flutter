/// Flutter client SDK for Sankofa Analytics, Deploy, Switch, and Config —
/// offline queueing, session replay, feature flags, and remote config.
///
/// Construct [Sankofa.instance.init] once at app startup, then (optionally)
/// construct [SankofaSwitch] and [SankofaConfig] to light up those modules.
library sankofa_flutter;

export 'src/sankofa_client.dart';
export 'src/replay/sankofa_replay.dart'
    show
        SankofaReplay,
        SankofaReplayMode,
        SankofaReplayBoundary,
        SankofaMask,
        SankofaNavigatorObserver;

// Sankofa Switch — feature flags + A/B variants
export 'src/switch/sankofa_switch.dart' show SankofaSwitch;
export 'src/switch/flag_decision.dart'
    show FlagDecision, FlagReason, FlagChangeListener;

// Sankofa Config — typed remote config with version history
export 'src/config/sankofa_config.dart' show SankofaConfig;
export 'src/config/item_decision.dart'
    show ItemDecision, ItemReason, ConfigType, ConfigChangeListener;
