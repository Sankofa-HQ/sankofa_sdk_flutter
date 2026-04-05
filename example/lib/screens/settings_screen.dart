import 'package:flutter/material.dart';
import 'package:sankofa_flutter/sankofa_flutter.dart';

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
      onTap: () => Sankofa.instance.track('settings_click', {'label': label}),
    );
  }
}
