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

// Sankofa Deploy — OTA updates (Flutter Code)
export 'src/deploy/sankofa_deploy.dart' show SankofaDeploy;
export 'src/deploy/deploy_config.dart' show SankofaDeployOptions;
export 'src/deploy/update_status.dart' show UpdateStatus;

// Module integration status — let hosts read the audit result
// (e.g. to show their own UI when integration is incomplete).
export 'src/core/module_registry.dart'
    show ModuleIntegrationStatus, ModuleIntegrationLevel, SankofaModuleName;

// Sankofa Catch — error tracking + crash reporting
export 'src/catch/sankofa_catch.dart' show SankofaCatch;
export 'src/catch/catch_types.dart'
    show
        CatchEvent,
        CatchBreadcrumb,
        CatchCaptureOptions,
        CatchDebugImage,
        CatchDebugMeta,
        CatchDeviceContext,
        CatchException,
        CatchLevel,
        CatchMechanism,
        CatchStackFrame,
        CatchStackTrace,
        CatchUserContext;

// Sankofa Pulse — in-app surveys
export 'src/pulse/sankofa_pulse.dart' show SankofaPulse;
export 'src/pulse/pulse_models.dart'
    show
        PulseSurvey,
        PulseSurveyBundle,
        PulseQuestion,
        PulseQuestionOption,
        PulseTheme,
        PulseRespondent,
        PulseSubmitPayload,
        PulseSubmitResponse,
        PulseContext,
        PulseHandshakeResponse,
        PulseEvent,
        PulseEventPayload,
        PulseEventListener,
        PulseSubscription;
export 'src/pulse/targeting.dart'
    show
        PulseTargetingRule,
        PulseEligibilityContext,
        PulseDecision,
        PulseRuleKind,
        PulseMatchOp,
        evaluatePulseTargeting,
        pulseStableHash;
export 'src/pulse/branching.dart'
    show
        PulseBranchingRule,
        PulseBranchingCondition,
        PulseOutcome,
        PulseBranchingActionKind,
        PulseBranchingCondKind,
        PulseBranchingCondOp,
        pulseBranchingEndOfSurvey,
        resolvePulseBranching,
        evaluatePulseBranchingCondition;
export 'src/pulse/translator.dart' show PulseTranslator;
export 'src/pulse/survey_dialog.dart' show SankofaSurveyDialog;
