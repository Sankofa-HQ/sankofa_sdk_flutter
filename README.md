# Sankofa Flutter SDK 🚀

[![Pub Version](https://img.shields.io/pub/v/sankofa_flutter?logo=dart&logoColor=white)](https://pub.dev/packages/sankofa_flutter)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Sankofa](https://img.shields.io/badge/Made%20with-Sankofa-blueviolet)](https://sankofa.dev)

The official Flutter SDK for [Sankofa](https://sankofa.dev) — seven products
in one package: **Analytics, Catch, Switch, Config, Pulse, Replay, and
Deploy** (App-Store-compliant Flutter OTA updates). Plus a standalone native
crash bridge that captures iOS NSException + POSIX signals and Android
JVM-uncaught + ANR with zero dependency on the iOS / Android SDKs.

---

## ✨ Features

- **Analytics**: events, identify, peopleSet, deep-link attribution,
  offline-first queueing.
- **Catch (Crashlytics + Sentry merged)**: Dart-level errors via
  `FlutterError.onError` / `PlatformDispatcher.onError` / isolate listeners —
  plus iOS NSException + POSIX signals + main-queue stalls and Android
  JVM-uncaught + ANR via the bundled Flutter plugin.
- **Switch**: feature flags with bundled defaults + onChange listeners.
- **Config**: remote-config with typed `get<T>` accessors.
- **Pulse**: in-app surveys (NPS, CSAT, custom).
- **Session Replay**: wireframe + screenshot modes, automatic input masking,
  `SankofaMask` widget.
- **Deploy**: Flutter OTA updates — fix bugs and tweak UI without a new App
  Store / Play Store release. App Store compliant under Apple PLA § 3.3.2 and
  Google Play DNA's interpreted-code carve-out.

---

## 🚀 Quick start

### 1. Install
Add the dependency to your `pubspec.yaml`:

```yaml
dependencies:
  sankofa_flutter: ^0.2.1
```

### 2. Initialize
**One call wires every product.** Analytics, Catch, Switch, Config, Pulse,
Replay and Deploy all come up from a single `init()` — no per-product
`new SankofaX()` boilerplate, no `register()` step. Each product is gated
server-side via the handshake, so a flag you don't subscribe to is simply
a no-op. Both Dart errors AND iOS/Android native crashes flow through
`Sankofa.captureException`.

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
    enableDeploy: true,    // OTA updates

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

After `init()`, reach any product through the client:
`Sankofa.instance.flags`, `.config`, `.pulse`, `.errors`, `.deploy`. The
legacy `SankofaSwitch()` / `SankofaConfig()` / `SankofaPulse.instance.register()`
constructors still work (and win if you call them before `init`), but
they're no longer required.

> **Turning a product off:** pass `enableFlags: false` (etc.) to skip
> constructing it entirely. `enableAnalytics: false` ships a build that
> sends **zero** analytics events while keeping Catch/Switch/Config/Pulse
> live.

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

Once `init()` resolves, every helper below works from anywhere. No
`SankofaCatch.instance` to thread through your widget tree.

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

// Hide sensitive UI from replays — replaced with solid black in the
// upload, untouched in the live UI.
SankofaMask(
  child: TextField(controller: _passwordController, obscureText: true),
);

// Suppress capture for screens that host external textures (video,
// maps, web views) — protects the surrounding scroll position + avoids
// "Invalid external texture" log spam on Android.
SankofaReplaySuppress(
  child: BetterPlayer(controller: _videoController),
);
```

### Switch — feature flags

Auto-constructed by `init(enableFlags: true)`. Read from anywhere via
`Sankofa.instance.flags`:

```dart
final flags = Sankofa.instance.flags!; // pass flagDefaults to init() for offline-first values

if (flags.getFlag('new_checkout')) showNewCheckout();
final variant = flags.getVariant('checkout_redesign', defaultValue: 'control');
```

### Config — remote config

Auto-constructed by `init(enableConfig: true)`. Read via
`Sankofa.instance.config`:

```dart
final config = Sankofa.instance.config!; // pass configDefaults to init() for offline-first values

final maxUploads = config.get<int>('max_uploads_per_day', 25);
```

### Pulse — surveys

Auto-registered by `init(enablePulse: true)` — no `register()` call needed.
Surveys flagged **auto-show** in the dashboard appear on their own; Pulse
discovers your app's navigator automatically, so there's **no navigator key
to wire up**. Present one manually with:

```dart
await Sankofa.instance.pulse.show(context, surveyId: 'nps-2024');

// React to lifecycle events
Sankofa.instance.pulse.on(PulseEvent.surveyCompleted, (e) {
  print('Survey ${e.surveyId} completed');
});
```

**Targeting:** rules are AND-ed and evaluated on-device. For **Screen**
rules, tag screens with `Sankofa.instance.screen('…')` (or
`SankofaNavigatorObserver`). **User-property** rules read traits from
`setPerson`, **Event** rules read on-device `track()` counts, **Cohort**
rules are resolved server-side via the handshake, and **Feature-flag**
rules read `SankofaSwitch`. **URL rules are web-only and ignored on Flutter
— use a Screen rule.** Supply data the SDK can't see itself via
`Sankofa.instance.pulse.setDefaultTargetingContext(userProperties: …,
cohorts: …, flagValues: …)` or per-call `show(..., properties: …,
cohorts: …)`.

### Deploy — Flutter OTA updates

Ship bug fixes and UI tweaks without an App Store / Play Store release.
Apple PLA § 3.3.2 + Google Play DNA both permit interpreted code
downloaded at runtime running in a VM — Sankofa Deploy ships under that
carve-out via the Sankofa-forked Flutter engine's bytecode interpreter.

**Setup (one time, ~30 seconds):**

1. Create `sankofa.yaml` at your project root with your API key:
   ```yaml
   app_id: proj_xxxxxxxxxxxxx
   api_key: sk_live_xxxxxxxxxxxxxxxx
   ```
2. Add it to `pubspec.yaml`'s assets:
   ```yaml
   flutter:
     assets:
       - sankofa.yaml
   ```
3. Apply any patch the previous run staged, right before `runApp()`:
   ```dart
   void main() async {
     WidgetsFlutterBinding.ensureInitialized();
     await SankofaUpdater.preFlight();
     runApp(const MyApp());
   }
   ```

That's the entire setup. The SDK reads `sankofa.yaml` on first call.
You do not import any helper packages or register signing keys —
those live inside `sankofa.yaml` (written by the CLI when you run
`sankofa keys generate`) and the SDK reads them transparently.

**Check + download from anywhere in your app:**

```dart
final updater = SankofaUpdater();

// Currently-installed patch — null on baseline.
final current = await updater.readCurrentPatch();
print(current?.label ?? 'baseline');

// Is a new patch available?
final result = await updater.checkForUpdate();
if (result.hasUpdate) {
  final update = result.update!;
  if (update.isMandatory) {
    // Skip the prompt — download immediately.
    await updater.downloadUpdate(update);
  } else {
    // Gate behind a user confirmation.
    final yes = await showUpdateDialog(context, update);
    if (yes) {
      await updater.downloadUpdate(
        update,
        onProgress: (received, total) {
          setState(() => _progress = total > 0 ? received / total : 0);
        },
      );
    }
  }
}
```

After `downloadUpdate` returns, the patch is staged on disk. The next cold
launch applies it automatically (the `preFlight()` call in step 3 picks it
up). Optionally prompt for restart so the patch takes effect immediately.

**Auto-rollback:** the SDK auto-disables any patch that crashes the app
twice within 30 seconds of launch. The last known-good patch is
restored automatically, and the bad label is added to a local ban list so
the same patch isn't re-downloaded. No host code required.

---

## 🪤 Native crash bridge (Phase C)

The Flutter SDK is a **federated plugin** with a standalone native crash
reporter in `ios/Classes/` and `android/src/main/kotlin/`. **Zero
dependency** on the standalone `SankofaIOS` Pod or `dev.sankofa:sankofa`
Maven artifact.

| Layer | Captured |
|---|---|
| Dart | `FlutterError.onError`, `PlatformDispatcher.onError`, isolate listeners |
| iOS plugin | `NSSetUncaughtExceptionHandler`, POSIX signals (SIGSEGV/SIGABRT/SIGBUS/SIGILL/SIGFPE/SIGTRAP/SIGSYS), main-queue stalls |
| Android plugin | Chained `Thread.UncaughtExceptionHandler`, ANR watcher (main thread > 5s) |

All three POST to the same `/api/catch/events` endpoint.
`Sankofa.setUser` / `setTag(s)` / `flushCatch` mirror to the native side
automatically.

---

## 🩺 Troubleshooting

### `[!] No podspec found for sankofa_flutter` on `pod install`

Symptom: `cd ios && pod install` errors with
`No podspec found for sankofa_flutter in .symlinks/plugins/sankofa_flutter/ios`.

v0.2.1+ ships the podspec correctly. If you're on **0.2.0**, bump to
**0.2.1 or later** — the older release was missing the podspec from its
published archive. Then:

```bash
flutter clean
rm -rf ios/Pods ios/Podfile.lock ios/.symlinks
flutter pub get
cd ios && pod install
```

### Android: `Invalid external texture` during video playback

Symptom: logcat repeats `Invalid external texture` while a
`BetterPlayer` / `video_player` / `flutter_map` / `webview_flutter` screen
is recorded by Session Replay.

Fixed in v0.2.1. The replay recorder walks the tree before each capture
and skips frames if a `Texture` / `AndroidView` / `UiKitView` /
`PlatformViewLink` widget is present. For finer control, wrap the
sensitive subtree in `SankofaReplaySuppress` (shown above).

### Replay masks "blink" during screenshots

Fixed in v0.2.1. `SankofaMask` no longer paints solid black in the live
widget tree; masking happens off-screen on the captured bitmap. Bump to
v0.2.1+.

### `LateInitializationError: Local 'result' has not been initialized.`

Fixed in v0.2.1. Two SDK call sites used `RenderObject.debugNeedsPaint`,
a debug-only Flutter API that throws in release/profile builds. Bump to
v0.2.1+.

### OTA updates aren't applying after restart

Verify in this order:

1. **`SankofaUpdater.preFlight()` is called before `runApp()`.** Without
   it, the staged patch isn't read off disk on cold launch.
2. **`sankofa.yaml` is listed in `pubspec.yaml`'s `flutter.assets:`.**
   Otherwise the SDK can't find your `api_key` at runtime.
3. **The dashboard's rollout for the release is 100%** (or explicitly
   includes your device's `distinct_id`).
4. **`app_version` matches.** The server matches the release's
   `target_binary_version` to the device's app version verbatim — no
   fuzzy semver matching.

---

## 📑 Documentation

For full API references and integration guides, visit the
[Sankofa docs](https://docs.sankofa.dev/sdks/flutter/overview).

---

## 🛡 License

Distributed under the MIT License. See `LICENSE` for more information.
