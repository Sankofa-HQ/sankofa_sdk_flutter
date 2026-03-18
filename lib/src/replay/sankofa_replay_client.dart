import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'sankofa_replay_recorder.dart';
import 'sankofa_replay_uploader.dart';

enum SankofaReplayMode { wireframe, screenshot }

class SankofaReplay {
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
  bool get isCapturingFrame => _recorder.isCapturingFrame;
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

  void setDistinctId(String distinctId) {
    _uploader.updateDistinctId(distinctId);
  }

  void triggerHighFidelityMode(Duration duration) {
    _recorder.triggerHighFidelityMode(duration);
  }

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
