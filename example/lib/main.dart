import 'dart:math';

import 'package:flutter/material.dart';
import 'package:sankofa_flutter/sankofa_flutter.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return SankofaReplayBoundary(
      child: MaterialApp(
        title: 'Sankofa Demo',
        navigatorObservers: [SankofaNavigatorObserver()],
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF6C5CE7),
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
          scaffoldBackgroundColor: const Color(0xFF0F0F1A),
          cardTheme: CardThemeData(
            color: const Color(0xFF1A1A2E),
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
            ),
          ),
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: const Color(0xFF16162A),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(
                color: Colors.white.withValues(alpha: 0.1),
              ),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(
                color: Colors.white.withValues(alpha: 0.1),
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(
                color: Color(0xFF6C5CE7),
                width: 1.5,
              ),
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 14,
            ),
            hintStyle: TextStyle(
              color: Colors.white.withValues(alpha: 0.3),
              fontSize: 14,
            ),
            labelStyle: TextStyle(color: Colors.white.withValues(alpha: 0.6)),
          ),
        ),
        home: const SetupScreen(),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SETUP SCREEN — Configure Engine URL & API Key before initializing SDK
// ─────────────────────────────────────────────────────────────────────────────

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
    // if (kIsWeb) return 'http://localhost:8080';
    // if (Platform.isAndroid) return 'http://10.0.2.2:8080';
    // return 'http://127.0.0.1:8080';
    return 'https://api.sankofa.dev';
  }

  late final _engineUrlController = TextEditingController(
    text: _getDefaultEngineUrl(),
  );
  final _apiKeyController = TextEditingController();

  bool _connecting = false;
  bool _debugMode = true;
  bool _trackLifecycleEvents = true;
  bool _enableSessionReplay = true;
  SankofaReplayMode _replayMode = SankofaReplayMode.wireframe;

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
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
      return;
    }

    setState(() => _connecting = true);

    try {
      await Sankofa.instance.init(
        apiKey: key,
        endpoint: url,
        debug: _debugMode,
        trackLifecycleEvents: _trackLifecycleEvents,
        enableSessionReplay: _enableSessionReplay,
        replayMode: _replayMode,
      );

      if (!mounted) return;

      Navigator.of(context).pushReplacement(
        PageRouteBuilder(
          transitionDuration: const Duration(milliseconds: 600),
          pageBuilder: (context, animation, _) => const EventTesterScreen(),
          transitionsBuilder: (context, animation, _, child) {
            return FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position:
                    Tween<Offset>(
                      begin: const Offset(0, 0.05),
                      end: Offset.zero,
                    ).animate(
                      CurvedAnimation(parent: animation, curve: Curves.easeOut),
                    ),
                child: child,
              ),
            );
          },
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _connecting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Connection failed: $e'),
          backgroundColor: Colors.red.shade700,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
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
              // Logo / Title
              AnimatedBuilder(
                animation: _pulseAnimation,
                builder: (context, child) {
                  return Opacity(opacity: _pulseAnimation.value, child: child);
                },
                child: Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const LinearGradient(
                      colors: [Color(0xFF6C5CE7), Color(0xFFA29BFE)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
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
              ),
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
                'Event Tester',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: Colors.white.withValues(alpha: 0.4),
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(height: 48),

              // Config Card
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: const Color(0xFF1A1A2E),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.06),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.settings_rounded,
                          color: Colors.white.withValues(alpha: 0.5),
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'CONNECTION SETTINGS',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.5,
                            color: Colors.white.withValues(alpha: 0.5),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),

                    // Engine URL
                    const _FieldLabel(label: 'Engine URL'),
                    const SizedBox(height: 8),
                    TextField(
                      key: _engineUrlFieldKey,
                      controller: _engineUrlController,
                      style: const TextStyle(color: Colors.white, fontSize: 14),
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

                    // API Key
                    const _FieldLabel(label: 'API Key'),
                    const SizedBox(height: 8),
                    SankofaMask(
                      child: TextField(
                        key: _apiKeyFieldKey,
                        controller: _apiKeyController,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                        ),
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

                    // Debug toggle
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.bug_report_rounded,
                              size: 18,
                              color: Colors.white.withValues(alpha: 0.5),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Debug Mode',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.7),
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                        Switch(
                          value: _debugMode,
                          onChanged: (v) => setState(() => _debugMode = v),
                          activeThumbColor: const Color(0xFF6C5CE7),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    // Track Lifecycle toggle
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.history_toggle_off_rounded,
                              size: 18,
                              color: Colors.white.withValues(alpha: 0.5),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Track Lifecycle',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.7),
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                        Switch(
                          value: _trackLifecycleEvents,
                          onChanged: (v) =>
                              setState(() => _trackLifecycleEvents = v),
                          activeThumbColor: const Color(0xFF6C5CE7),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    // Session Replay toggle
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.videocam_rounded,
                              size: 18,
                              color: Colors.white.withValues(alpha: 0.5),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Session Replay',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.7),
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                        Switch(
                          value: _enableSessionReplay,
                          onChanged: (v) =>
                              setState(() => _enableSessionReplay = v),
                          activeThumbColor: const Color(0xFF6C5CE7),
                        ),
                      ],
                    ),
                    if (_enableSessionReplay) ...[
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.switch_video_rounded,
                                size: 18,
                                color: Colors.white.withValues(alpha: 0.5),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'Replay Mode',
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.7),
                                  fontSize: 14,
                                ),
                              ),
                            ],
                          ),
                          DropdownButton<SankofaReplayMode>(
                            value: _replayMode,
                            dropdownColor: const Color(0xFF16162A),
                            underline: const SizedBox(),
                            icon: const Icon(
                              Icons.arrow_drop_down,
                              color: Color(0xFF6C5CE7),
                            ),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                            ),
                            onChanged: (SankofaReplayMode? newValue) {
                              if (newValue != null) {
                                setState(() {
                                  _replayMode = newValue;
                                });
                              }
                            },
                            items: SankofaReplayMode.values.map((
                              SankofaReplayMode mode,
                            ) {
                              return DropdownMenuItem<SankofaReplayMode>(
                                value: mode,
                                child: Text(mode.name),
                              );
                            }).toList(),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),

              const SizedBox(height: 28),

              // Connect Button
              SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton(
                  key: _connectButtonKey,
                  onPressed: _connecting ? null : _connect,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF6C5CE7),
                    disabledBackgroundColor: const Color(
                      0xFF6C5CE7,
                    ).withValues(alpha: 0.5),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: _connecting
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: Colors.white,
                          ),
                        )
                      : const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.bolt_rounded, size: 20),
                            SizedBox(width: 8),
                            Text(
                              'Initialize & Connect',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                ),
              ),

              const SizedBox(height: 16),
              Text(
                'Tip: Use 10.0.2.2 for Android emulator\nor localhost for iOS simulator',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.white.withValues(alpha: 0.3),
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  final String label;
  const _FieldLabel({required this.label});

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: Colors.white.withValues(alpha: 0.6),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// EVENT TESTER SCREEN — Main event testing dashboard
// ─────────────────────────────────────────────────────────────────────────────

class EventTesterScreen extends StatefulWidget {
  const EventTesterScreen({super.key});

  @override
  State<EventTesterScreen> createState() => _EventTesterScreenState();
}

class _EventTesterScreenState extends State<EventTesterScreen> {
  int _counter = 0;
  bool _autoSending = false;

  // Custom event fields
  final _eventNameController = TextEditingController();
  final List<MapEntry<TextEditingController, TextEditingController>>
  _customProps = [];
  bool _sendingCustom = false;

  @override
  void dispose() {
    _eventNameController.dispose();
    for (final entry in _customProps) {
      entry.key.dispose();
      entry.value.dispose();
    }
    super.dispose();
  }

  void _addProperty() {
    setState(() {
      _customProps.add(
        MapEntry(TextEditingController(), TextEditingController()),
      );
    });
  }

  void _removeProperty(int index) {
    setState(() {
      _customProps[index].key.dispose();
      _customProps[index].value.dispose();
      _customProps.removeAt(index);
    });
  }

  Future<void> _sendCustomEvent() async {
    final eventName = _eventNameController.text.trim();
    if (eventName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Please enter an event name'),
          backgroundColor: Colors.red.shade700,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
      return;
    }

    setState(() => _sendingCustom = true);

    final props = <String, dynamic>{};
    for (final entry in _customProps) {
      final key = entry.key.text.trim();
      final value = entry.value.text.trim();
      if (key.isNotEmpty) {
        // Try to parse as number or bool, otherwise keep as string
        if (double.tryParse(value) != null) {
          props[key] = double.parse(value);
        } else if (value.toLowerCase() == 'true' ||
            value.toLowerCase() == 'false') {
          props[key] = value.toLowerCase() == 'true';
        } else {
          props[key] = value;
        }
      }
    }

    try {
      await Sankofa.instance.track(eventName, props.isNotEmpty ? props : null);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.check_circle, color: Colors.white, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Sent "$eventName"${props.isNotEmpty ? ' with ${props.length} prop(s)' : ''}',
                ),
              ),
            ],
          ),
          backgroundColor: const Color(0xFF00B894),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed: $e'),
          backgroundColor: Colors.red.shade700,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }

    setState(() => _sendingCustom = false);
  }

  void _incrementCounter() {
    setState(() {
      _counter++;
    });
    Sankofa.instance.track('button_click', {
      'button_id': 'increment_fab',
      'current_count': _counter,
    });
  }

  Future<void> _simulateUserJourney() async {
    await Sankofa.instance.track('page_view', {'path': '/home'});
    await Future.delayed(const Duration(milliseconds: 500));
    await Sankofa.instance.track('view_item', {
      'item_id': 'prod_123',
      'price': 29.99,
    });
    await Future.delayed(const Duration(milliseconds: 800));
    await Sankofa.instance.track('add_to_cart', {
      'item_id': 'prod_123',
      'quantity': 1,
    });
    await Future.delayed(const Duration(milliseconds: 1200));
    await Sankofa.instance.track('begin_checkout');

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Row(
          children: [
            Icon(Icons.shopping_cart, color: Colors.white, size: 18),
            SizedBox(width: 8),
            Text('Simulated Journey Sent!'),
          ],
        ),
        backgroundColor: const Color(0xFF6C5CE7),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  void _toggleAutoSpam() async {
    setState(() {
      _autoSending = !_autoSending;
    });

    if (_autoSending) {
      while (_autoSending) {
        final r = Random();
        await Sankofa.instance.track('auto_event', {
          'random_val': r.nextInt(100),
          'spam_mode': true,
        });
        await Future.delayed(
          const Duration(milliseconds: 100),
        ); // 10 events/sec
        if (!mounted) break;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF16162A),
        surfaceTintColor: Colors.transparent,
        title: const Row(
          children: [
            Icon(Icons.analytics_rounded, color: Color(0xFF6C5CE7), size: 22),
            SizedBox(width: 10),
            Text(
              'Sankofa Tester',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18),
            ),
          ],
        ),
        actions: [
          IconButton(
            onPressed: () {
              // Navigate back to setup
              Sankofa.instance.reset();
              Navigator.of(context).pushReplacement(
                MaterialPageRoute(builder: (_) => const SetupScreen()),
              );
            },
            icon: Icon(
              Icons.settings_rounded,
              color: Colors.white.withValues(alpha: 0.5),
            ),
            tooltip: 'Configuration',
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Custom Event Section ──────────────────────────────
            _buildSectionHeader(
              icon: Icons.send_rounded,
              title: 'Custom Event',
              color: const Color(0xFF00B894),
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFF1A1A2E),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Event Name
                  TextField(
                    controller: _eventNameController,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                    decoration: InputDecoration(
                      hintText: 'Event name (e.g. purchase_completed)',
                      prefixIcon: const Icon(
                        Icons.label_rounded,
                        size: 20,
                        color: Color(0xFF00B894),
                      ),
                      suffixIcon: _eventNameController.text.isNotEmpty
                          ? IconButton(
                              icon: Icon(
                                Icons.clear,
                                size: 18,
                                color: Colors.white.withValues(alpha: 0.3),
                              ),
                              onPressed: () {
                                _eventNameController.clear();
                                setState(() {});
                              },
                            )
                          : null,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 16),

                  // Properties Header
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Properties',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Colors.white.withValues(alpha: 0.6),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: _addProperty,
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text('Add'),
                        style: TextButton.styleFrom(
                          foregroundColor: const Color(0xFF00B894),
                          textStyle: const TextStyle(fontSize: 13),
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    ],
                  ),

                  // Properties List
                  if (_customProps.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        'No properties yet. Tap "Add" to include key-value pairs.',
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.white.withValues(alpha: 0.25),
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    )
                  else
                    ..._customProps.asMap().entries.map((entry) {
                      final index = entry.key;
                      final kv = entry.value;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Row(
                          children: [
                            Expanded(
                              flex: 2,
                              child: TextField(
                                controller: kv.key,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                ),
                                decoration: InputDecoration(
                                  hintText: 'Key',
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 10,
                                  ),
                                  hintStyle: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.2),
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              flex: 3,
                              child: TextField(
                                controller: kv.value,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                ),
                                decoration: InputDecoration(
                                  hintText: 'Value',
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 10,
                                  ),
                                  hintStyle: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.2),
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                            InkWell(
                              onTap: () => _removeProperty(index),
                              borderRadius: BorderRadius.circular(8),
                              child: Padding(
                                padding: const EdgeInsets.all(6),
                                child: Icon(
                                  Icons.remove_circle_outline,
                                  size: 20,
                                  color: Colors.red.withValues(alpha: 0.7),
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    }),

                  const SizedBox(height: 12),

                  // Send Button
                  SizedBox(
                    width: double.infinity,
                    height: 46,
                    child: FilledButton.icon(
                      onPressed: _sendingCustom ? null : _sendCustomEvent,
                      icon: _sendingCustom
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.send_rounded, size: 18),
                      label: Text(
                        _sendingCustom ? 'Sending...' : 'Send Event',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF00B894),
                        disabledBackgroundColor: const Color(
                          0xFF00B894,
                        ).withValues(alpha: 0.5),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 32),

            // ── Quick Actions ────────────────────────────────────
            _buildSectionHeader(
              icon: Icons.bolt_rounded,
              title: 'Quick Actions',
              color: const Color(0xFF6C5CE7),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                _QuickActionChip(
                  label: 'Identify User',
                  icon: Icons.person_rounded,
                  color: const Color(0xFF6C5CE7),
                  onTap: () => Sankofa.instance.identify(
                    'user_${Random().nextInt(1000)}',
                  ),
                ),
                _QuickActionChip(
                  label: 'Set Profile',
                  icon: Icons.badge_rounded,
                  color: const Color(0xFF0984E3),
                  onTap: () => Sankofa.instance.peopleSet({
                    'plan': 'premium',
                    'email': 'user@example.com',
                    'ltv': Random().nextInt(500),
                  }),
                ),
                _QuickActionChip(
                  label: 'Reset Identity',
                  icon: Icons.logout_rounded,
                  color: const Color(0xFFE17055),
                  onTap: () => Sankofa.instance.reset(),
                ),
                _QuickActionChip(
                  label: 'Track Tap',
                  icon: Icons.touch_app_rounded,
                  color: const Color(0xFFFDAA5E),
                  onTap: () => Sankofa.instance.track('simple_tap'),
                ),
                _QuickActionChip(
                  label: 'Track Purchase Error',
                  icon: Icons.touch_app_rounded,
                  color: const Color.fromARGB(255, 207, 0, 134),
                  onTap: () => Sankofa.instance.track('purchase_error'),
                ),
                _QuickActionChip(
                  label: 'Purchase Flow',
                  icon: Icons.shopping_cart_rounded,
                  color: const Color(0xFF00CEC9),
                  onTap: _simulateUserJourney,
                ),
              ],
            ),

            const SizedBox(height: 32),

            // ── Stress Test ──────────────────────────────────────
            _buildSectionHeader(
              icon: Icons.speed_rounded,
              title: 'Stress Test',
              color: const Color(0xFFE74C3C),
            ),
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFF1A1A2E),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: _autoSending
                      ? Colors.red.withValues(alpha: 0.3)
                      : Colors.white.withValues(alpha: 0.06),
                ),
              ),
              child: Column(
                children: [
                  Icon(
                    _autoSending
                        ? Icons.sensors_rounded
                        : Icons.sensors_off_rounded,
                    size: 36,
                    color: _autoSending
                        ? Colors.red
                        : Colors.white.withValues(alpha: 0.3),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _autoSending ? 'Sending 10 events/sec' : 'Auto-spam mode',
                    style: TextStyle(
                      color: _autoSending
                          ? Colors.red.shade300
                          : Colors.white.withValues(alpha: 0.5),
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    height: 46,
                    child: FilledButton.icon(
                      onPressed: _toggleAutoSpam,
                      icon: Icon(
                        _autoSending
                            ? Icons.stop_rounded
                            : Icons.play_arrow_rounded,
                        size: 20,
                      ),
                      label: Text(
                        _autoSending ? 'Stop' : 'Start Spam',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      style: FilledButton.styleFrom(
                        backgroundColor: _autoSending
                            ? Colors.red.shade700
                            : const Color(0xFF2D3436),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 40),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _incrementCounter,
        tooltip: 'Track button_click',
        backgroundColor: const Color(0xFF6C5CE7),
        child: const Icon(Icons.add, color: Colors.white),
      ),
    );
  }

  Widget _buildSectionHeader({
    required IconData icon,
    required String title,
    required Color color,
  }) {
    return Row(
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, size: 18, color: color),
        ),
        const SizedBox(width: 10),
        Text(
          title,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: Colors.white,
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Quick Action Chip Widget
// ─────────────────────────────────────────────────────────────────────────────

class _QuickActionChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _QuickActionChip({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        splashColor: color.withValues(alpha: 0.2),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: color.withValues(alpha: 0.2)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
