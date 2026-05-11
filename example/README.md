# Sankofa Flutter example

A comprehensive sandbox + crash gallery for the **Sankofa Flutter SDK**. Exercises every product the package ships — Analytics, Catch (Crashlytics + Sentry merged), Switch, Config, Pulse, Replay — plus the **standalone native crash bridge** (Phase C) that captures iOS NSException + signals and Android JVM-uncaught + ANR without any Pod/Maven dep on the standalone iOS / Android SDKs.

---

## ✨ Features

- **Dynamic init** — Setup screen lets you point at any Sankofa engine without rebuilding.
- **Catch crash gallery** — every Catch scenario, including `Sankofa.log()`, `withScope` (single + nested), and `beforeSend` demos.
- **Event tester** — fire custom events and inspect them in the dashboard live.
- **Flags + Config lab** — live decision tables.
- **Pulse lab** — surveys + targeting preview.
- **Session replay** — wireframe + screenshot modes with `SankofaMask` privacy.
- **Navigation auto-tagging** — `SankofaNavigatorObserver` tags every screen change.
- **User-journey simulator** — one tap fires a complete e-commerce funnel.

---

## 🚀 Getting Started

### 1. Prerequisites

- **Flutter SDK** (Stable channel, 3.38+)
- **Sankofa Engine** running locally or in the cloud

### 2. Setup

```bash
flutter pub get
```

### 3. Run

```bash
flutter run
```

---

## 🔌 Connection Guide

The Setup screen prompts for:

- **Engine URL**
  - `http://10.0.2.2:8080` for Android emulators
  - `http://localhost:8080` for iOS simulators / web
  - your production URL for live testing
- **API Key** — Project API key from Sankofa Settings
- **Environment** — `sk_test_*` keys land in the Test dataset

---

## 🔍 What it demonstrates

### Phase A — auto-init Catch

`Sankofa.instance.init(enableCatch: true, catchEnvironment: 'production', release: '...')` auto-installs Catch + Dart-side error handlers + iOS native handlers + Android native handlers in one call. See `lib/screens/setup_screen.dart`.

### Phase B — `withScope` + `beforeSend` (`lib/screens/crash_gallery_screen.dart`)

Crash gallery scenarios cover:

- "withScope — temporary scope overlay" — tags + level + extras on ONE capture only.
- "withScope — nested scopes" — inner scope inherits + extends outer.
- "beforeSend — see SankofaProvider.dart" — fires events the hook drops or scrubs.

The `beforeSend` hook is wired at init in `setup_screen.dart` — drops `"[noise]"` messages.

### Phase C — native crash bridge

The bundled Flutter plugin captures:

- **iOS** — `NSSetUncaughtExceptionHandler`, POSIX signals (SIGSEGV/SIGABRT/SIGBUS/SIGILL/SIGFPE/SIGTRAP/SIGSYS), main-queue stalls.
- **Android** — chained `Thread.UncaughtExceptionHandler`, ANR watcher.

Both POST to the same `/api/catch/events` endpoint the Dart side uses. `Sankofa.setUser` / `setTag(s)` / `flushCatch` mirror to the native side automatically. Zero dep on the standalone iOS / Android SDKs — the plugin owns its own crash reporter inside `ios/Classes/` and `android/src/main/kotlin/`.

### Static helpers used throughout the gallery

```dart
Sankofa.captureException(err, stack);
Sankofa.captureMessage('payment retry attempted');
Sankofa.log('checkout: applying coupon SUMMER25');  // doesn't bill
Sankofa.setUser(CatchUserContext(id: 'u_42', email: 'ada@example.com'));
Sankofa.setTag('flow', 'checkout');
Sankofa.setExtra('cart_id', cart.id);
Sankofa.withScope((scope) {
  scope.setTag('checkout_step', 'payment');
  Sankofa.captureException(err);
});
```

---

## 📂 Key code references

| File | What |
|---|---|
| `lib/screens/setup_screen.dart` | `Sankofa.instance.init` with `beforeSend` hook. |
| `lib/screens/crash_gallery_screen.dart` | All Catch scenarios including Phase A/B. |
| `lib/screens/flags_lab_screen.dart` | Live Switch + Config decision tables. |
| `lib/screens/pulse_lab_screen.dart` | Pulse survey runtime. |
| `lib/screens/event_tester_screen.dart` | Custom event tester. |
| `lib/screens/animation_stress_test_screen.dart` | Stresses the replay capture pipeline. |
| `lib/screens/compose_stress_screen.dart` *(if present)* | Compose-style scroll-offset tagging for heatmap accuracy. |

---

## Documentation

Full Flutter SDK reference: [docs.sankofa.dev/sdks/flutter](https://docs.sankofa.dev/sdks/flutter/overview).

---

## 🛡 License

MIT.
