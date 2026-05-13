import 'package:flutter/material.dart';
import 'package:sankofa_flutter/sankofa_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'setup_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _notifications = true;
  bool _darkMode = true;
  double _volume = 0.5;

  @override
  void initState() {
    super.initState();
    // 📍 MANUAL TAGGING: Explicit Screen View
    Sankofa.instance.screen("SettingsScreen");
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Account Settings')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            _buildSettingToggle('Enable Notifications', _notifications, (v) {
              setState(() => _notifications = v);
              Sankofa.instance.track('toggle_notifications', {'enabled': v});
            }, Icons.notifications),
            _buildSettingToggle('Dark Mode', _darkMode, (v) {
              setState(() => _darkMode = v);
              Sankofa.instance.track('toggle_dark_mode', {'enabled': v});
            }, Icons.dark_mode),
            const SizedBox(height: 24),
            _buildVolumeSlider(),
            const SizedBox(height: 32),
            _buildAccountButton('Change Password', Icons.lock, Colors.blue),
            _buildAccountButton(
              'Privacy Policy',
              Icons.privacy_tip,
              Colors.green,
            ),
            _buildAccountButton('Logout', Icons.logout, Colors.red),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Widget _buildSettingToggle(
    String label,
    bool value,
    ValueChanged<bool> onChanged,
    IconData icon,
  ) {
    return ListTile(
      leading: Icon(icon, color: const Color(0xFF6C5CE7)),
      title: Text(label),
      trailing: Switch(value: value, onChanged: onChanged),
    );
  }

  Widget _buildVolumeSlider() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Media Volume',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        Slider(
          value: _volume,
          onChanged: (v) {
            setState(() => _volume = v);
            Sankofa.instance.track('volume_change', {'value': v});
          },
        ),
      ],
    );
  }

  Widget _buildAccountButton(String label, IconData icon, Color color) {
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(label),
      // The bundled "Logout" account row doubles as the
      // Disconnect-and-forget-key control. Tapping it wipes the
      // persisted Sankofa creds and routes back to SetupScreen so
      // the next session re-enters the API key, matching the iOS /
      // Android / web examples' Disconnect UX.
      onTap: () async {
        Sankofa.instance.track('settings_click', {'label': label});
        if (label == 'Logout') {
          await _disconnect();
        }
      },
    );
  }

  Future<void> _disconnect() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(setupPrefsApiKey);
      await prefs.remove(setupPrefsEngineUrl);
    } catch (_) {
      // Persistence errors here are non-fatal — the navigation below
      // still returns the user to the connect screen, which is the
      // important UX guarantee.
    }
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const SetupScreen()),
      (route) => false,
    );
  }
}
