import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'sankofa_replay_recorder.dart';
import 'sankofa_replay_uploader.dart';

/// The recording mode for session replay.
enum SankofaReplayMode {
  /// Renders a lightweight, privacy-focused wireframe of the UI.
  wireframe,

  /// Captures actual screenshots of the app (higher fidelity, higher bandwidth).
  screenshot,
}

/// The controller for managing session replay and visual recording.
///
/// This is used internally by [Sankofa] but can also be accessed directly
/// via [SankofaReplay.instance] for fine-grained control.
class SankofaReplay {
  /// The singleton instance of the Sankofa replay controller.
  static final SankofaReplay instance = SankofaReplay._internal();
  SankofaReplay._internal() {
    _uploader = SankofaReplayUploader(logger: _log);
    _recorder = SankofaReplayRecorder(
      logger: _log,
      uploader: _uploader,
    );
  }

  late SankofaReplayRecorder _recorder;
  late SankofaReplayUploader _uploader;
  bool _debug = false;

  bool get isRecordingForTesting => _recorder.isRecording;
  /// Returns true if a frame is currently being captured.
  bool get isCapturingFrame => _recorder.isCapturingFrame;

  /// The current recording mode (wireframe or screenshot).
  SankofaReplayMode get mode => _recorder.mode;
  GlobalKey get rootBoundaryKey => _recorder.rootBoundaryKey;

  @visibleForTesting
  String get currentSessionId => _uploader.sessionId;
  @visibleForTesting
  int get currentChunkIndex => _uploader.chunkIndex;

  @visibleForTesting
  Future<void> resetForTesting() async {
    _recorder.stopRecording();
    // Reset state if needed
  }

  /// Configures the replay engine.
  ///
  /// This is typically called automatically by [Sankofa.init].
  Future<void> configure({
    required String apiKey,
    required String endpoint,
    required String sessionId,
    String distinctId = 'anonymous',
    SankofaReplayMode mode = SankofaReplayMode.wireframe,
    int fps = 1,
    bool debug = false,
  }) async {
    _debug = debug;
    _uploader.updateConfig(
      apiKey: apiKey,
      endpoint: endpoint,
      sessionId: sessionId,
      distinctId: distinctId,
    );
    await _recorder.configure(
      mode: mode,
      fps: fps,
      sessionId: sessionId,
    );
  }

  /// Updates the distinct ID for the current replay session.
  void setDistinctId(String distinctId) {
    _uploader.updateDistinctId(distinctId);
  }

  /// Temporarily switches to high-fidelity [SankofaReplayMode.screenshot] mode
  /// for the specified [duration]. This is useful for capturing critical errors
  /// or specific user journeys in high detail.
  void triggerHighFidelityMode(Duration duration) {
    _recorder.triggerHighFidelityMode(duration);
  }

  /// Stops the current recording session.
  void stopRecording() {
    _recorder.stopRecording();
  }

  void onAppLifecycleStateChanged(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _recorder.flush(force: true);
    }
  }

  // Internal hooks for the Boundary and Observer
  void recordPointerEvent(String type, PointerEvent event) => _recorder.recordPointerEvent(type, event);
  void recordRouteEvent(String routeName) => _recorder.recordRouteEvent(routeName);
  void recordScrollEvent(double scrollY) => _recorder.recordScrollEvent(scrollY);
  void updateDeviceContext(double w, double h, double pr) => _recorder.updateDeviceContext(w, h, pr);

  void _log(String value) {
    if (_debug || kDebugMode) debugPrint(value);
  }
}
