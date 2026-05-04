import 'package:sankofa_flutter/sankofa_flutter.dart';

// Canonical demo keys — identical to every Sankofa example
// (web, react-native, html, ios, android, flutter). One dashboard
// config drives every client. Keep these strings in lockstep with the
// other examples so a single dashboard edit repaints every surface.

class DemoFlags {
  static const newHomeLayout       = 'new_home_layout';
  static const checkoutCtaVariant  = 'checkout_cta_variant';
  static const onboardingV2Rollout = 'onboarding_v2_rollout';
  static const aiSummaryKillSwitch = 'ai_summary_kill_switch';
  static const abPricingPage       = 'ab_pricing_page';
  static const premiumBadgeVisible = 'premium_badge_visible';

  static const all = [
    newHomeLayout,
    checkoutCtaVariant,
    onboardingV2Rollout,
    aiSummaryKillSwitch,
    abPricingPage,
    premiumBadgeVisible,
  ];

  static const descriptions = <String, String>{
    newHomeLayout:       'Swap hero between classic and v2.',
    checkoutCtaVariant:  'A/B/C variant — CTA copy + colour.',
    onboardingV2Rollout: 'Progressive rollout gate.',
    aiSummaryKillSwitch: 'Halt webhook pauses AI summary.',
    abPricingPage:       'Variant A/B on pricing copy.',
    premiumBadgeVisible: 'Show/hide the premium badge.',
  };
}

class DemoConfig {
  static const supportUrl                = 'support_url';
  static const maxUploadsPerDay          = 'max_uploads_per_day';
  static const trialDiscountPct          = 'trial_discount_pct';
  static const maintenanceBannerEnabled  = 'maintenance_banner_enabled';
  static const pricingTable              = 'pricing_table';
  static const themeColors               = 'theme_colors';

  static const all = [
    supportUrl,
    maxUploadsPerDay,
    trialDiscountPct,
    maintenanceBannerEnabled,
    pricingTable,
    themeColors,
  ];

  static const descriptions = <String, String>{
    supportUrl:               'String — support link target.',
    maxUploadsPerDay:         'Int — daily upload ceiling.',
    trialDiscountPct:         'Float 0–1 — trial discount.',
    maintenanceBannerEnabled: 'Bool — amber maintenance banner.',
    pricingTable:             'JSON — array of pricing tiers.',
    themeColors:              'JSON {primary, accent} — theme tokens.',
  };
}

/// Bundled flag defaults — returned from `getFlag` before the first
/// handshake lands so the Lab screen renders on cold start without
/// flashing blank values.
Map<String, FlagDecision> demoFlagDefaults() => {
      DemoFlags.newHomeLayout:
          const FlagDecision(value: false, reason: FlagReason.unknown, version: 0),
      DemoFlags.checkoutCtaVariant:
          const FlagDecision(value: true, variant: 'control', reason: FlagReason.unknown, version: 0),
      DemoFlags.onboardingV2Rollout:
          const FlagDecision(value: false, reason: FlagReason.unknown, version: 0),
      DemoFlags.aiSummaryKillSwitch:
          const FlagDecision(value: false, reason: FlagReason.unknown, version: 0),
      DemoFlags.abPricingPage:
          const FlagDecision(value: true, variant: 'A', reason: FlagReason.unknown, version: 0),
      DemoFlags.premiumBadgeVisible:
          const FlagDecision(value: true, reason: FlagReason.unknown, version: 0),
    };

Map<String, ItemDecision> demoConfigDefaults() => {
      DemoConfig.supportUrl: const ItemDecision(
        value: 'https://support.sankofa.dev',
        type: ConfigType.string,
        reason: ItemReason.unknown,
        version: 0,
      ),
      DemoConfig.maxUploadsPerDay: const ItemDecision(
        value: 25,
        type: ConfigType.int_,
        reason: ItemReason.unknown,
        version: 0,
      ),
      DemoConfig.trialDiscountPct: const ItemDecision(
        value: 0.2,
        type: ConfigType.float,
        reason: ItemReason.unknown,
        version: 0,
      ),
      DemoConfig.maintenanceBannerEnabled: const ItemDecision(
        value: false,
        type: ConfigType.bool_,
        reason: ItemReason.unknown,
        version: 0,
      ),
      DemoConfig.pricingTable: const ItemDecision(
        value: [
          {'name': 'Starter',    'price': 0,   'features': ['1 project',       '1k events/mo']},
          {'name': 'Pro',        'price': 49,  'features': ['Unlimited projects', '1M events/mo', 'Replay']},
          {'name': 'Enterprise', 'price': 199, 'features': ['SSO',               'Priority support', 'Audit log']},
        ],
        type: ConfigType.json,
        reason: ItemReason.unknown,
        version: 0,
      ),
      DemoConfig.themeColors: const ItemDecision(
        value: {'primary': '#6C5CE7', 'accent': '#EC4899'},
        type: ConfigType.json,
        reason: ItemReason.unknown,
        version: 0,
      ),
    };

/// Demo survey identifiers used by the Pulse Lab screen.
///
/// These IDs match what `seed_pulse` (server/engine/cmd/seed_pulse)
/// publishes against the demo project. If the server hasn't been
/// seeded yet the lab surfaces a "survey not found" message and the
/// host can re-run the seeder. The IDs are intentionally short +
/// human-readable so you can spot them in dashboard URLs.
class DemoSurveys {
  /// Classic 0–10 NPS prompt with a follow-up "why" question. The
  /// follow-up is shown for detractors (NPS < 7) via a branching
  /// rule so this demo also exercises skip-logic.
  static const npsAfterCheckout = 'psv_demo_nps_checkout';

  /// 1–5 CSAT rating against the support experience. Single
  /// question, no branching — the simplest possible flow for first
  /// runs / smoke tests.
  static const csatSupport = 'psv_demo_csat_support';

  /// Multi-question custom survey (single + multi + long-text)
  /// gated by a `user_property` rule so eligibility evaluation has
  /// something non-trivial to demo.
  static const productResearch = 'psv_demo_product_research';

  static const all = [npsAfterCheckout, csatSupport, productResearch];

  static const titles = <String, String>{
    npsAfterCheckout: 'Post-checkout NPS',
    csatSupport: 'Support CSAT',
    productResearch: 'Product research (gated)',
  };

  static const descriptions = <String, String>{
    npsAfterCheckout:
        'Score 0–10. Detractors get a "what went wrong" follow-up via branching.',
    csatSupport:
        'Single 1–5 star rating. Smallest possible survey — good for smoke tests.',
    productResearch:
        'Multi-question. Targeting rule requires user_property "plan" = "pro".',
  };
}

/// Typed accessor wrappers — centralized here so every screen that
/// reads the demo keys stays in sync if the shapes ever change.
class DemoPricingTier {
  final String name;
  final double price;
  final List<String> features;
  const DemoPricingTier({required this.name, required this.price, required this.features});

  static List<DemoPricingTier> parse(Object? raw) {
    if (raw is! List) return const [];
    return raw.whereType<Map>().map((m) {
      final name = m['name']?.toString() ?? '';
      final p = m['price'];
      final price = p is num ? p.toDouble() : 0.0;
      final feats = (m['features'] is List)
          ? (m['features'] as List).map((e) => e.toString()).toList()
          : <String>[];
      return DemoPricingTier(name: name, price: price, features: feats);
    }).toList(growable: false);
  }
}
