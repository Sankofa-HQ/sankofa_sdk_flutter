import 'dart:math';
import 'package:flutter/material.dart';
import 'package:sankofa_flutter/sankofa_flutter.dart';

class AnimationStressTestScreen extends StatefulWidget {
  const AnimationStressTestScreen({super.key});

  @override
  State<AnimationStressTestScreen> createState() =>
      _AnimationStressTestScreenState();
}

class _AnimationStressTestScreenState extends State<AnimationStressTestScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _rotationController;

  @override
  void initState() {
    super.initState();
    // 📍 MANUAL TAGGING: Explicit Screen View
    Sankofa.instance.screen("AnimationStressTestScreen");
    _rotationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat();
  }

  @override
  void dispose() {
    _rotationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('UI Stress Testing')),
      body: SingleChildScrollView(
        child: Column(
          children: [
            _buildRotatingBox(),
            _buildInteractiveCenter(),
            const Padding(
              padding: EdgeInsets.all(20),
              child: Text(
                'Deep Scroll Physics Recording Demo',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
            ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: 40,
              itemBuilder: (context, index) {
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor:
                        Colors.primaries[index % Colors.primaries.length],
                  ),
                  title: Text('Heatmap Target Item #$index'),
                  subtitle: const Text('Tap to verify Absolute Y coordinate'),
                  onTap: () => Sankofa.instance.track('list_item_tapped', {
                    'index': index,
                  }),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRotatingBox() {
    return Container(
      height: 250,
      width: double.infinity,
      color: const Color(0xFF1A1A2E),
      child: Center(
        child: AnimatedBuilder(
          animation: _rotationController,
          builder: (context, child) => Transform.rotate(
            angle: _rotationController.value * 2 * pi,
            child: child,
          ),
          child: GestureDetector(
            onTap: () => Sankofa.instance.track("tapped_rotating_box"),
            child: Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Colors.purple, Colors.orange],
                ),
                borderRadius: BorderRadius.circular(20),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInteractiveCenter() {
    return Container(
      height: 240,
      width: double.infinity,
      color: Colors.black12,
      child: InteractiveViewer(
        boundaryMargin: const EdgeInsets.all(50),
        minScale: 0.5,
        maxScale: 3.5,
        child: Center(
          child: GestureDetector(
            onTap: () => Sankofa.instance.track("tapped_zoom_target"),
            child: Container(
              width: 180,
              height: 100,
              decoration: BoxDecoration(
                color: const Color(0xFF00B894),
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
