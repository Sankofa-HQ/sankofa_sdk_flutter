import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:sankofa_flutter/sankofa_flutter.dart';

import '../sankofa_demo.dart';
import '../sankofa_runtime.dart';

// ConfigType.wireName lives on a package-private extension in the
// SDK; redefine the tiny mapper here so the row can label its type
// without reaching into internal API.
String _configTypeLabel(ConfigType? t) {
  switch (t) {
    case ConfigType.string:
      return 'string';
    case ConfigType.int_:
      return 'int';
    case ConfigType.float:
      return 'float';
    case ConfigType.bool_:
      return 'bool';
    case ConfigType.json:
      return 'json';
    case null:
      return '';
  }
}

/// Lab screen — single-scroll view showing the live application of
/// every demo flag + config alongside a decision table for each.
/// Subscriptions re-render the whole view whenever a handshake
/// refresh lands so dashboard edits propagate without a hot reload.
class FlagsLabScreen extends StatefulWidget {
  const FlagsLabScreen({super.key});

  @override
  State<FlagsLabScreen> createState() => _FlagsLabScreenState();
}

class _FlagsLabScreenState extends State<FlagsLabScreen> {
  final _unsub = <VoidCallback>[];
  Map<String, FlagDecision> _flags = {};
  Map<String, ItemDecision> _config = {};

  @override
  void initState() {
    super.initState();
    Sankofa.instance.screen('FlagsLabScreen');
    _refresh();
    final s = sankofaSwitch();
    final c = sankofaConfig();
    for (final k in DemoFlags.all) {
      _unsub.add(s.onChange(k, (_) => _refresh()));
    }
    for (final k in DemoConfig.all) {
      _unsub.add(c.onChange(k, (_) => _refresh()));
    }
  }

  void _refresh() {
    final s = sankofaSwitch();
    final c = sankofaConfig();
    final nextFlags = <String, FlagDecision>{};
    for (final k in DemoFlags.all) {
      nextFlags[k] = s.getDecision(k) ?? demoFlagDefaults()[k]!;
    }
    final nextConfig = <String, ItemDecision>{};
    for (final k in DemoConfig.all) {
      nextConfig[k] = c.getDecision(k) ?? demoConfigDefaults()[k]!;
    }
    if (mounted) {
      setState(() {
        _flags = nextFlags;
        _config = nextConfig;
      });
    }
  }

  @override
  void dispose() {
    for (final u in _unsub) {
      u();
    }
    super.dispose();
  }

  // ── Derived values ────────────────────────────────────────────────

  Color get _themePrimary {
    final v = (_config[DemoConfig.themeColors]?.value as Map?)?['primary'];
    return _parseHex(v as String?) ?? const Color(0xFF6C5CE7);
  }

  Color get _themeAccent {
    final v = (_config[DemoConfig.themeColors]?.value as Map?)?['accent'];
    return _parseHex(v as String?) ?? const Color(0xFFEC4899);
  }

  String get _supportUrl =>
      (_config[DemoConfig.supportUrl]?.value as String?) ??
      'https://support.sankofa.dev';

  int get _maxUploads =>
      (_config[DemoConfig.maxUploadsPerDay]?.value as num?)?.toInt() ?? 25;

  double get _discount =>
      (_config[DemoConfig.trialDiscountPct]?.value as num?)?.toDouble() ?? 0;

  bool get _maintenance =>
      (_config[DemoConfig.maintenanceBannerEnabled]?.value as bool?) ?? false;

  bool get _newHome => _flags[DemoFlags.newHomeLayout]?.value ?? false;
  String get _ctaVariant =>
      _flags[DemoFlags.checkoutCtaVariant]?.variant ?? 'control';
  bool get _onboardingV2 =>
      _flags[DemoFlags.onboardingV2Rollout]?.value ?? false;
  bool get _aiHalted =>
      _flags[DemoFlags.aiSummaryKillSwitch]?.value ?? false;
  String get _pricingArm =>
      _flags[DemoFlags.abPricingPage]?.variant ?? 'A';
  bool get _premiumBadge =>
      _flags[DemoFlags.premiumBadgeVisible]?.value ?? true;

  List<DemoPricingTier> get _tiers {
    final raw = _config[DemoConfig.pricingTable]?.value;
    final parsed = DemoPricingTier.parse(raw);
    return _pricingArm == 'B' ? parsed.reversed.toList() : parsed;
  }

  // ── Build ─────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Flags & Config Lab'),
        backgroundColor: Colors.transparent,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_maintenance) _maintenanceBanner(),
          _heroCard(),
          const SizedBox(height: 12),
          _miniCardsRow(),
          const SizedBox(height: 12),
          _pricingCard(),
          const SizedBox(height: 12),
          _supportCard(),
          const SizedBox(height: 24),
          _sectionLabel('SANKOFA SWITCH — LIVE DECISIONS'),
          const SizedBox(height: 8),
          ...DemoFlags.all.map(_flagRow),
          const SizedBox(height: 20),
          _sectionLabel('SANKOFA CONFIG — TYPED REMOTE VALUES'),
          const SizedBox(height: 8),
          ...DemoConfig.all.map(_configRow),
        ],
      ),
    );
  }

  Widget _maintenanceBanner() {
    return Container(
      padding: const EdgeInsets.all(12),
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF59E0B).withValues(alpha: 0.15),
        border: Border.all(color: const Color(0xFFF59E0B)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: const Text(
        '⚠️  Maintenance window — some features may be slow.',
        style: TextStyle(color: Color(0xFFFBBF24), fontWeight: FontWeight.w600),
      ),
    );
  }

  Widget _heroCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _newHome
            ? _themePrimary.withValues(alpha: 0.10)
            : const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _themeAccent.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _newHome ? 'HERO LAYOUT: V2' : 'HERO LAYOUT: CLASSIC',
            style: TextStyle(
              fontSize: 10,
              letterSpacing: 1.4,
              color: Colors.white.withValues(alpha: 0.5),
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _newHome
                ? 'Analytics for modern teams'
                : 'Ship analytics in minutes',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Driven by new_home_layout and theme_colors.',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.5),
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.tonal(
            onPressed: () {
              // Reading the variant records an exposure row.
              sankofaSwitch().getVariant(
                DemoFlags.checkoutCtaVariant,
                defaultValue: 'control',
              );
              Sankofa.instance.track('lab_cta_pressed', {
                'variant': _ctaVariant,
              });
            },
            style: FilledButton.styleFrom(
              backgroundColor: _ctaBackground(),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              minimumSize: const Size.fromHeight(44),
            ),
            child: Text(_ctaLabel()),
          ),
          const SizedBox(height: 6),
          Text(
            'CTA variant: $_ctaVariant',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 11),
          ),
        ],
      ),
    );
  }

  String _ctaLabel() {
    switch (_ctaVariant) {
      case 'blue':
        return 'Try it free';
      case 'red':
        return 'Upgrade now';
      default:
        return 'Get started';
    }
  }

  Color _ctaBackground() {
    switch (_ctaVariant) {
      case 'blue':
        return const Color(0xFF2563EB);
      case 'red':
        return const Color(0xFFDC2626);
      default:
        return _themePrimary;
    }
  }

  Widget _miniCardsRow() {
    // IntrinsicHeight lets the two cards match their tallest
    // sibling's height without forcing infinite height (ListView's
    // vertical axis is unbounded, so plain CrossAxisAlignment.stretch
    // crashes with "BoxConstraints forces an infinite height").
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
        Expanded(
          child: _miniCard(
            eyebrow: 'AI SUMMARY',
            child: _aiHalted
                ? const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('🛑 Paused',
                          style: TextStyle(
                              color: Color(0xFFFCA5A5),
                              fontSize: 14,
                              fontWeight: FontWeight.bold)),
                      SizedBox(height: 4),
                      Text(
                        'ai_summary_kill_switch halted. Halt webhooks flip this live.',
                        style: TextStyle(color: Colors.white70, fontSize: 11),
                      ),
                    ],
                  )
                : const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Ready for queries',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.bold)),
                      SizedBox(height: 4),
                      Text('Kill switch clear.',
                          style: TextStyle(color: Colors.white70, fontSize: 11)),
                    ],
                  ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _miniCard(
            eyebrow: 'UPLOADS',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('$_maxUploads / day',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.tonal(
                    onPressed: _onboardingV2
                        ? () {
                            sankofaSwitch().getFlag(
                              DemoFlags.onboardingV2Rollout,
                              defaultValue: false,
                            );
                          }
                        : null,
                    style: FilledButton.styleFrom(
                      backgroundColor: _onboardingV2 ? _themeAccent : Colors.grey,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: Text(
                      _onboardingV2 ? 'Open uploader (v2)' : 'Coming soon',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        ],
      ),
    );
  }

  Widget _pricingCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _themePrimary.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'PRICING — ARM $_pricingArm',
                      style: TextStyle(
                        fontSize: 10,
                        letterSpacing: 1.4,
                        color: Colors.white.withValues(alpha: 0.5),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      _pricingArm == 'B'
                          ? 'Enterprise-first pricing'
                          : 'Simple pricing, scales with you',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              if (_premiumBadge)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: _themePrimary.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: _themePrimary.withValues(alpha: 0.5)),
                  ),
                  child: Text(
                    '✨ Premium',
                    style: TextStyle(
                      color: _themePrimary,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          ..._tiers.map(_pricingTile),
        ],
      ),
    );
  }

  Widget _pricingTile(DemoPricingTier tier) {
    final discounted = (tier.price * (1 - _discount)).clamp(0, double.infinity);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tier.name,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.bold)),
                Text(
                  '\$${discounted.toInt()}/mo',
                  style: TextStyle(
                    color: _themePrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (_discount > 0 && tier.price > 0)
                  Text(
                    '${(_discount * 100).toInt()}% off trial',
                    style: const TextStyle(
                      color: Color(0xFFFBBF24),
                      fontSize: 10,
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: tier.features
                  .map((f) => Text('• $f',
                      style: const TextStyle(color: Colors.white70, fontSize: 11)))
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _supportCard() {
    return _miniCard(
      eyebrow: 'SUPPORT',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _supportUrl,
            style: TextStyle(
              color: _themeAccent,
              fontWeight: FontWeight.bold,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'From support_url.',
            style: TextStyle(color: Colors.white70, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _miniCard({required String eyebrow, required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            eyebrow,
            style: TextStyle(
              fontSize: 10,
              letterSpacing: 1.4,
              color: Colors.white.withValues(alpha: 0.5),
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 6),
          child,
        ],
      ),
    );
  }

  Widget _sectionLabel(String text) => Text(
        text,
        style: TextStyle(
          fontSize: 10,
          letterSpacing: 1.4,
          fontWeight: FontWeight.bold,
          color: Colors.white.withValues(alpha: 0.5),
        ),
      );

  Widget _flagRow(String key) {
    final d = _flags[key];
    final value = (d?.variant.isNotEmpty ?? false)
        ? d!.variant
        : (d?.value.toString() ?? 'null');
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(key,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    )),
                Text(DemoFlags.descriptions[key] ?? '',
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.5), fontSize: 11)),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(value,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    color: Color(0xFFFDA4AF),
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  )),
              Text('${d?.reason.name ?? ''} · v${d?.version ?? 0}',
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.4), fontSize: 10)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _configRow(String key) {
    final d = _config[key];
    String rendered;
    if (d == null) {
      rendered = 'null';
    } else if (d.type == ConfigType.json) {
      rendered = jsonEncode(d.value);
    } else if (d.value is String) {
      rendered = '"${d.value}"';
    } else {
      rendered = '${d.value}';
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(key,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    )),
                Text(DemoConfig.descriptions[key] ?? '',
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.5), fontSize: 11)),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(rendered,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      color: Color(0xFFFDA4AF),
                      fontWeight: FontWeight.bold,
                      fontSize: 11,
                    )),
                Text(
                    '${_configTypeLabel(d?.type)} · ${d?.reason.name ?? ''} · v${d?.version ?? 0}',
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.4), fontSize: 10)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

Color? _parseHex(String? hex) {
  if (hex == null) return null;
  var h = hex.replaceFirst('#', '').trim();
  if (h.length == 6) h = 'FF$h';
  if (h.length != 8) return null;
  final v = int.tryParse(h, radix: 16);
  return v == null ? null : Color(v);
}
