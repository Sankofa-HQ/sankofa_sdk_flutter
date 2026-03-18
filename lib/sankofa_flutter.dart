/// Flutter client SDK for Sankofa Analytics with offline queueing and session replay.
///
/// This library provides the main [Sankofa] client and session replay tools.
library sankofa_flutter;

export 'src/sankofa_client.dart';
export 'src/replay/sankofa_replay.dart'
    show
        SankofaReplay,
        SankofaReplayMode,
        SankofaReplayBoundary,
        SankofaMask,
        SankofaNavigatorObserver;
