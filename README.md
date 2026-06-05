# Sankofa Flutter SDK 🚀

[![Pub Version](https://img.shields.io/pub/v/sankofa_flutter?logo=dart&logoColor=white)](https://pub.dev/packages/sankofa_flutter)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Sankofa](https://img.shields.io/badge/Made%20with-Sankofa-blueviolet)](https://sankofa.dev)

The official Flutter SDK for [Sankofa](https://sankofa.dev) — six products in one package: Analytics, Catch, Switch, Config, Pulse, Replay. Plus a **standalone** native crash bridge that captures iOS NSException + POSIX signals and Android JVM-uncaught + ANR with zero dependency on the iOS / Android SDKs.

---

## ✨ Features

- **Analytics**: events, identify, peopleSet, deep-link attribution, offline-first queueing.
- **Catch (Crashlytics + Sentry merged)**: Dart-level errors via `FlutterError.onError` / `PlatformDispatcher.onError` / isolate listeners — plus iOS NSException + POSIX signals + main-queue stalls and Android JVM-uncaught + ANR via the bundled Flutter plugin.
- **Switch**: feature flags with bundled defaults + onChange listeners.
- **Config**: remote-config with typed `get<T>` accessors.
- **Pulse**: in-app surveys (NPS, CSAT, custom).
- **Session Replay**: wireframe + screenshot modes, automatic input masking, `SankofaMask` widget.

---

## 🚀 Quick start

### 1. Install
Add the dependency to your `pubspec.yaml`:

```yaml
dependencies:
  sankofa_flutter: ^0.1.0
```

### 2. Initialize
**One call wires every product.** Analytics, Catch, Switch, Config and Pulse all come up from a single `init()` — no per-product `new SankofaX()` boilerplate, no `register()` step. Each product is gated server-side via the handshake, so a flag you don't subscribe to is simply a no-op. Both Dart errors AND iOS/Android native crashes flow through `Sankofa.captureException`.

```dart
import 'package:sankofa_flutter/sankofa_flutter.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Sankofa.instance.init(
    apiKey: 'YOUR_PROJECT_API_KEY',
    endpoint: 'https://api.sankofa.dev',
    debug: true,

    // ── Product switches (all default true except Deploy) ──
    enableAnalytics: true, // events, screens, lifecycle, presence
    enableCatch: true,     // errors + native crashes
    enableFlags: true,     // Switch — feature flags
    enableConfig: true,    // remote config
    enablePulse: true,     // in-app surveys (auto-shows, no extra wiring)

    // ── Optional per-product config ──
    catchEnvironment: 'production',
    release: 'myapp@1.4.0',
    flagDefaults: {'new_checkout': FlagDecision(value: false, reason: 'default')},
    configDefaults: {'max_upload_mb': ItemDecision(value: 25, version: 1, reason: 'default')},
    // Sentry-style hook to scrub PII / drop noise.
    beforeSend: (event) {
      if (event.message?.contains('setState called after dispose') ?? false) return null;
      return event;
    },
  );

  runApp(const MyApp());
}
```

After `init()`, reach any product through the client: `Sankofa.instance.flags`, `.config`, `.pulse`, `.errors`. The legacy `SankofaSwitch()` / `SankofaConfig()` / `SankofaPulse.instance.register()` constructors still work (and win if you call them before `init`), but they're no longer required.

> **Turning a product off:** pass `enableFlags: false` (etc.) to skip constructing it entirely. `enableAnalytics: false` ships a build that sends **zero** analytics events while keeping Catch/Switch/Config/Pulse live.

---

## 🛠 Usage

### Analytics

```dart
// Events
Sankofa.instance.track('completed_purchase', {
  'item_name': 'Vintage Camera',
  'price': 120.50,
  'currency': 'USD',
});

// Identity
Sankofa.instance.identify('user_99');
Sankofa.instance.setPerson(
  name: 'Jane Doe',
  email: 'jane@example.com',
  properties: {'membership': 'Gold'},
);
```

### Catch — error capture

Once `init()` resolves, every helper below works from anywhere. No `SankofaCatch.instance` to thread through your widget tree.

```dart
// Capture a handled exception
try {
  await chargeCard(amount);
} catch (err, stack) {
  Sankofa.captureException(err, stack);
}

// Non-error event
Sankofa.captureMessage('payment retry attempted');

// Crashlytics-style breadcrumb log — rides on next capture, doesn't bill.
Sankofa.log('checkout: applying coupon SUMMER25');

// Ambient context
Sankofa.setUser(CatchUserContext(id: 'u_42', email: 'ada@example.com'));
Sankofa.setTag('flow', 'checkout');
Sankofa.setExtra('cart_id', cart.id);

// Sentry-style temporary scope — tags only on this capture.
Sankofa.withScope((scope) {
  scope.setTag('checkout_step', 'payment');
  scope.setLevel(CatchLevel.warning);
  Sankofa.captureException(err);
});
```

### Session replay

```dart
MaterialApp(
  navigatorObservers: [SankofaNavigatorObserver()],
  home: const SankofaReplayBoundary(
    child: MyHomePage(),
  ),
);

// Hide sensitive UI from replays
SankofaMask(
  child: TextField(controller: _passwordController, obscureText: true),
);
```

### Switch — feature flags

Auto-constructed by `init(enableFlags: true)`. Read from anywhere via `Sankofa.instance.flags`:

```dart
final flags = Sankofa.instance.flags!; // pass flagDefaults to init() for offline-first values

if (flags.getFlag('new_checkout')) showNewCheckout();
final variant = flags.getVariant('checkout_redesign', defaultValue: 'control');
```

### Config — remote config

Auto-constructed by `init(enableConfig: true)`. Read via `Sankofa.instance.config`:

```dart
final config = Sankofa.instance.config!; // pass configDefaults to init() for offline-first values

final maxUploads = config.get<int>('max_uploads_per_day', 25);
```

### Pulse — surveys

Auto-registered by `init(enablePulse: true)` — no `register()` call needed. Surveys flagged **auto-show** in the dashboard appear on their own; Pulse discovers your app's navigator automatically, so there's **no navigator key to wire up**. Present one manually with:

```dart
await Sankofa.instance.pulse.show(context, surveyId: 'nps-2024');

// React to lifecycle events
Sankofa.instance.pulse.on(PulseEvent.surveyCompleted, (e) {
  print('Survey ${e.surveyId} completed');
});
```

---

## 🪤 Native crash bridge (Phase C)

The Flutter SDK is a **federated plugin** with a standalone native crash reporter in `ios/Classes/` and `android/src/main/kotlin/`. **Zero dependency** on the standalone `SankofaIOS` Pod or `dev.sankofa:sankofa` Maven artifact.

| Layer | Captured |
|---|---|
| Dart | `FlutterError.onError`, `PlatformDispatcher.onError`, isolate listeners |
| iOS plugin | `NSSetUncaughtExceptionHandler`, POSIX signals (SIGSEGV/SIGABRT/SIGBUS/SIGILL/SIGFPE/SIGTRAP/SIGSYS), main-queue stalls |
| Android plugin | Chained `Thread.UncaughtExceptionHandler`, ANR watcher (main thread > 5s) |

All three POST to the same `/api/catch/events` endpoint. `Sankofa.setUser` / `setTag(s)` / `flushCatch` mirror to the native side automatically.

---

## 📑 Documentation

For full API references and integration guides, visit the [Sankofa docs](https://docs.sankofa.dev/sdks/flutter/overview).

---

## 🛡 License

Distributed under the MIT License. See `LICENSE` for more information.
