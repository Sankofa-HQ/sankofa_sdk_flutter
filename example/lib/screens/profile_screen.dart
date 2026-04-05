import 'package:flutter/material.dart';
import 'package:sankofa_flutter/sankofa_flutter.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _bioController = TextEditingController(
    text: 'Sankofa Analytics Enthusiast & Flutter Developer',
  );

  @override
  void initState() {
    super.initState();
    // 📍 MANUAL TAGGING: Explicit Screen View
    Sankofa.instance.screen("ProfileScreen");
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My Profile')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            const CircleAvatar(
              radius: 60,
              backgroundImage: NetworkImage('https://i.pravatar.cc/300'),
            ),
            const SizedBox(height: 16),
            const Text(
              'Samuel Adinkra',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const Text(
              'Premium Member',
              style: TextStyle(color: Colors.white38),
            ),
            const SizedBox(height: 32),
            TextField(
              controller: _bioController,
              onChanged: (v) =>
                  Sankofa.instance.track('update_bio', {'length': v.length}),
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'Bio',
                hintText: 'Write something...',
              ),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: _ProfileTile(
                    label: 'Followers',
                    value: '1.2K',
                    color: Colors.blue,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _ProfileTile(
                    label: 'Events',
                    value: '458',
                    color: Colors.purple,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 32),
            FilledButton.icon(
              onPressed: () => Sankofa.instance.track('save_profile'),
              icon: const Icon(Icons.check),
              label: const Text('Save Changes'),
            ),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }
}

class _ProfileTile extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _ProfileTile({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Text(
            value,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          Text(
            label,
            style: const TextStyle(color: Colors.white54, fontSize: 13),
          ),
        ],
      ),
    );
  }
}
