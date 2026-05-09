import 'package:flutter/material.dart';
import 'package:sankofa_flutter/sankofa_flutter.dart';
import '../sankofa_runtime.dart';
import 'event_tester_screen.dart';

class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen>
    with SingleTickerProviderStateMixin {
  static const _engineUrlFieldKey = Key('setup-engine-url-field');
  static const _apiKeyFieldKey = Key('setup-api-key-field');
  static const _connectButtonKey = Key('setup-connect-button');

  String _getDefaultEngineUrl() {
    return 'http://172.20.10.6:8080';
  }

  late final _engineUrlController = TextEditingController(
    text: _getDefaultEngineUrl(),
  );
  final _apiKeyController = TextEditingController(
    // text: 'sk_test_b25f965d194d55bd071fb23921401e7c',
  );

  bool _connecting = false;
  bool _debugMode = true;
  bool _trackLifecycleEvents = true;
  bool _enableSessionReplay = true;
  final SankofaReplayMode _replayMode = SankofaReplayMode.screenshot;

  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 0.6, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _engineUrlController.dispose();
    _apiKeyController.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final url = _engineUrlController.text.trim();
    final key = _apiKeyController.text.trim();

    if (url.isEmpty || key.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Please fill in both fields'),
          backgroundColor: Colors.red.shade700,
        ),
      );
      return;
    }

    setState(() => _connecting = true);
    try {
      // Construct the Switch + Config singletons BEFORE init so they
      // register with the Traffic Cop before the first handshake
      // fires. Constructing after init means the first handshake runs
      // with empty registry and logs "module not installed" warnings —
      // subsequent handshakes would pick them up, but the initial
      // payload is lost and the Lab renders bundled defaults for a
      // few seconds until the next refresh.
      sankofaSwitch();
      sankofaConfig();
      // 🚀 Phase A — Catch is now auto-constructed by `Sankofa.instance.init`
      // when `enableCatch: true` (the default).  No more manual
      // `sankofaCatch()` factory call needed for the 90% case.  The
      // legacy factory in `sankofa_runtime.dart` still works for
      // power users who want a custom transport / sample rate / etc.
      // Switch + Config decisions are auto-discovered from the
      // registry — no `readFlagSnapshot`/`readConfigSnapshot` closures.

      await Sankofa.instance.init(
        apiKey: key,
        endpoint: url,
        debug: _debugMode,
        trackLifecycleEvents: _trackLifecycleEvents,
        enableSessionReplay: _enableSessionReplay,
        replayMode: _replayMode,
        // ── Catch (Crashlytics + Sentry merged) ──
        // Default `enableCatch: true` would auto-construct without
        // these — passing them explicitly for clarity in the demo.
        enableCatch: true,
        catchEnvironment: 'test',
        release: 'sankofa-example-flutter@0.1.0',
      );
      // Pulse registers AFTER init because it reads apiKey + endpoint
      // at register-time (Switch/Config/Catch all pull lazily on
      // first call). A failure here doesn't block the demo — the
      // Pulse Lab screen will surface a "not registered" message.
      await registerSankofaPulse();
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const EventTesterScreen()),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _connecting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Connection failed: $e'),
          backgroundColor: Colors.red.shade700,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildLogo(),
              const SizedBox(height: 24),
              const Text(
                'Sankofa',
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Multi-Screen Showcase',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: Colors.white.withValues(alpha: 0.4),
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(height: 48),
              _buildConfigCard(),
              const SizedBox(height: 28),
              _buildConnectButton(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLogo() {
    return AnimatedBuilder(
      animation: _pulseAnimation,
      builder: (context, child) =>
          Opacity(opacity: _pulseAnimation.value, child: child),
      child: Container(
        width: 80,
        height: 80,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const LinearGradient(
            colors: [Color(0xFF6C5CE7), Color(0xFFA29BFE)],
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF6C5CE7).withValues(alpha: 0.4),
              blurRadius: 24,
              spreadRadius: 2,
            ),
          ],
        ),
        child: const Icon(
          Icons.analytics_rounded,
          color: Colors.white,
          size: 40,
        ),
      ),
    );
  }

  Widget _buildConfigCard() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildFieldLabel('Engine URL'),
          const SizedBox(height: 8),
          TextField(
            key: _engineUrlFieldKey,
            controller: _engineUrlController,
            decoration: const InputDecoration(
              hintText: 'http://localhost:8080',
              prefixIcon: Icon(
                Icons.dns_rounded,
                size: 20,
                color: Color(0xFF6C5CE7),
              ),
            ),
          ),
          const SizedBox(height: 18),
          _buildFieldLabel('API Key'),
          const SizedBox(height: 8),
          SankofaMask(
            child: TextField(
              key: _apiKeyFieldKey,
              controller: _apiKeyController,
              obscureText: true,
              decoration: const InputDecoration(
                hintText: 'sk_test_...',
                prefixIcon: Icon(
                  Icons.key_rounded,
                  size: 20,
                  color: Color(0xFF6C5CE7),
                ),
              ),
            ),
          ),
          const SizedBox(height: 18),
          _buildToggle(
            'Debug Mode',
            _debugMode,
            (v) => setState(() => _debugMode = v),
            Icons.bug_report_rounded,
          ),
          _buildToggle(
            'Track Lifecycle',
            _trackLifecycleEvents,
            (v) => setState(() => _trackLifecycleEvents = v),
            Icons.history_toggle_off_rounded,
          ),
          _buildToggle(
            'Session Replay',
            _enableSessionReplay,
            (v) => setState(() => _enableSessionReplay = v),
            Icons.videocam_rounded,
          ),
        ],
      ),
    );
  }

  Widget _buildToggle(
    String label,
    bool value,
    ValueChanged<bool> onChanged,
    IconData icon,
  ) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          children: [
            Icon(icon, size: 18, color: Colors.white.withValues(alpha: 0.5)),
            const SizedBox(width: 8),
            Text(
              label,
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
          ],
        ),
        Switch(
          value: value,
          onChanged: onChanged,
          activeThumbColor: const Color(0xFF6C5CE7),
        ),
      ],
    );
  }

  Widget _buildFieldLabel(String label) => Text(
    label,
    style: TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w600,
      color: Colors.white.withValues(alpha: 0.6),
    ),
  );

  Widget _buildConnectButton() {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: FilledButton(
        key: _connectButtonKey,
        onPressed: _connecting ? null : _connect,
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xFF6C5CE7),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        child: _connecting
            ? const CircularProgressIndicator(color: Colors.white)
            : const Text(
                'Initialize & Connect',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
      ),
    );
  }
}
