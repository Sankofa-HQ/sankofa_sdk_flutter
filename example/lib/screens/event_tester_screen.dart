import 'package:flutter/material.dart';
import 'package:sankofa_flutter/sankofa_flutter.dart';
import '../sankofa_demo.dart';
import '../sankofa_runtime.dart';
import 'animation_stress_test_screen.dart';
import 'crash_gallery_screen.dart';
import 'dashboard_screen.dart';
import 'flags_lab_screen.dart';
import 'pulse_lab_screen.dart';
import 'settings_screen.dart';
import 'profile_screen.dart';

class EventTesterScreen extends StatefulWidget {
  const EventTesterScreen({super.key});

  @override
  State<EventTesterScreen> createState() => _EventTesterScreenState();
}

class _EventTesterScreenState extends State<EventTesterScreen> {
  int _counter = 0;
  final _eventNameController = TextEditingController();
  final List<MapEntry<TextEditingController, TextEditingController>>
  _customProps = [];

  @override
  void initState() {
    super.initState();
    // 📍 MANUAL TAGGING: Track this screen view explicitly
    Sankofa.instance.screen("EventTesterScreen");
  }

  @override
  void dispose() {
    _eventNameController.dispose();
    for (final entry in _customProps) {
      entry.key.dispose();
      entry.value.dispose();
    }
    super.dispose();
  }

  Future<void> _sendCustomEvent() async {
    final eventName = _eventNameController.text.trim();
    if (eventName.isEmpty) return;
    final props = <String, dynamic>{};
    for (final entry in _customProps) {
      final key = entry.key.text.trim();
      final value = entry.value.text.trim();
      if (key.isNotEmpty) props[key] = value;
    }
    await Sankofa.instance.track(eventName, props.isNotEmpty ? props : null);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Sankofa Event Tester',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.dashboard_rounded),
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const DashboardScreen())),
          ),
          IconButton(
            icon: const Icon(Icons.science_rounded),
            tooltip: 'Flags & Config Lab',
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const FlagsLabScreen())),
          ),
          IconButton(
            icon: const Icon(Icons.feedback_outlined),
            tooltip: 'Pulse Lab',
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const PulseLabScreen())),
          ),
          IconButton(
            icon: const Icon(Icons.settings_rounded),
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            _buildMaintenanceBanner(),
            _buildFlagDrivenCta(),
            _buildSectionHeader(
              Icons.send_rounded,
              'Custom Event',
              const Color(0xFF00B894),
            ),
            const SizedBox(height: 12),
            _buildCustomEventCard(),
            const SizedBox(height: 32),
            _buildSectionHeader(
              Icons.bolt_rounded,
              'Quick Navigation',
              const Color(0xFF6C5CE7),
            ),
            const SizedBox(height: 12),
            _buildNavigationGrid(),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          setState(() => _counter++);
          Sankofa.instance.track('increment_counter', {'count': _counter});
        },
        child: const Icon(Icons.add),
      ),
    );
  }

  // Maintenance banner — visibility driven by the
  // `maintenance_banner_enabled` remote config. Offline cache or
  // bundled default keeps this hidden until an operator flips it.
  Widget _buildMaintenanceBanner() {
    final on = sankofaConfig().get<bool>(
      DemoConfig.maintenanceBannerEnabled,
      false,
    );
    if (!on) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF59E0B).withValues(alpha: 0.15),
        border: Border.all(color: const Color(0xFFF59E0B)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: const Text(
        '⚠️  Maintenance window — see the Flags Lab for details.',
        style: TextStyle(color: Color(0xFFFBBF24), fontWeight: FontWeight.w600),
      ),
    );
  }

  // Variant-driven CTA — label and colour flip with
  // `checkout_cta_variant` (control / blue / red). Pressing it reads
  // the variant, which records a flag exposure on the server.
  Widget _buildFlagDrivenCta() {
    final variant = sankofaSwitch().getVariant(
      DemoFlags.checkoutCtaVariant,
      defaultValue: 'control',
    );
    final label = variant == 'blue'
        ? 'Try it free'
        : variant == 'red'
            ? 'Upgrade now'
            : 'Fire showcase event';
    final bg = variant == 'blue'
        ? const Color(0xFF2563EB)
        : variant == 'red'
            ? const Color(0xFFDC2626)
            : const Color(0xFF6C5CE7);
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: SizedBox(
        width: double.infinity,
        child: FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: bg,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          onPressed: () {
            Sankofa.instance.track('cta_showcase_pressed', {'variant': variant});
          },
          child: Column(
            children: [
              Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 2),
              Text(
                'variant · $variant',
                style: TextStyle(
                  fontSize: 10,
                  letterSpacing: 1,
                  color: Colors.white.withValues(alpha: 0.8),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionHeader(IconData icon, String title, Color color) {
    return Row(
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 8),
        Text(
          title,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
      ],
    );
  }

  Widget _buildCustomEventCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          TextField(
            controller: _eventNameController,
            decoration: const InputDecoration(hintText: 'Event Name'),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _sendCustomEvent,
              child: const Text('Send Event'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNavigationGrid() {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        _NavCard(
          label: 'Dashboard',
          icon: Icons.insights_rounded,
          color: Colors.blue,
          screen: const DashboardScreen(),
        ),
        _NavCard(
          label: 'Profile',
          icon: Icons.person_rounded,
          color: Colors.orange,
          screen: const ProfileScreen(),
        ),
        _NavCard(
          label: 'Settings',
          icon: Icons.settings_rounded,
          color: Colors.grey,
          screen: const SettingsScreen(),
        ),
        _NavCard(
          label: 'UI Stress',
          icon: Icons.speed_rounded,
          color: Colors.red,
          screen: const AnimationStressTestScreen(),
        ),
        _NavCard(
          label: 'Catch gallery',
          icon: Icons.bug_report_rounded,
          color: Colors.pink,
          screen: const CrashGalleryScreen(),
        ),
        _NavCard(
          label: 'Pulse Lab',
          icon: Icons.feedback_outlined,
          color: Colors.cyan,
          screen: const PulseLabScreen(),
        ),
      ],
    );
  }
}

class _NavCard extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final Widget screen;
  const _NavCard({
    required this.label,
    required this.icon,
    required this.color,
    required this.screen,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () =>
          Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen)),
      child: Container(
        width: 140,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          border: Border.all(color: color.withValues(alpha: 0.3)),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            Icon(icon, color: color),
            const SizedBox(height: 8),
            Text(
              label,
              style: TextStyle(color: color, fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
    );
  }
}
