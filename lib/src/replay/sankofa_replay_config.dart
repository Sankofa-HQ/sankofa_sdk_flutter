class SankofaReplayConfig {
  final bool enabled;
  final double sampleRate;
  final List<String> highFidelityTriggers;
  final int highFidelityDurationSeconds;
  final bool maskAllInputs;
  final bool captureNetwork;

  SankofaReplayConfig({
    required this.enabled,
    required this.sampleRate,
    required this.highFidelityTriggers,
    required this.highFidelityDurationSeconds,
    required this.maskAllInputs,
    required this.captureNetwork,
  });

  factory SankofaReplayConfig.fromJson(Map<String, dynamic> json) {
    return SankofaReplayConfig(
      enabled: json['enabled'] ?? true,
      sampleRate: (json['sample_rate'] ?? 1.0).toDouble(),
      highFidelityTriggers: List<String>.from(json['high_fidelity_triggers'] ?? []),
      highFidelityDurationSeconds: json['high_fidelity_duration_seconds'] ?? 30,
      maskAllInputs: json['mask_all_inputs'] ?? true,
      captureNetwork: json['capture_network'] ?? false,
    );
  }

  factory SankofaReplayConfig.defaults() {
    return SankofaReplayConfig(
      enabled: true,
      sampleRate: 1.0,
      highFidelityTriggers: ['app_crash', 'payment_failed'],
      highFidelityDurationSeconds: 30,
      maskAllInputs: true,
      captureNetwork: false,
    );
  }
}
