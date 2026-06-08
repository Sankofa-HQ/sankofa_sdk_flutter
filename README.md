# Sankofa Flutter SDK

[![Pub Version](https://img.shields.io/pub/v/sankofa_flutter?logo=dart&logoColor=white)](https://pub.dev/packages/sankofa_flutter)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Sankofa](https://img.shields.io/badge/Made%20with-Sankofa-blueviolet)](https://sankofa.dev)

The official Flutter SDK for [Sankofa](https://sankofa.dev) — **OTA updates** (the
Shorebird-compatible replacement, App Store compliant), plus Analytics, Catch
(crash + error tracking), Switch (feature flags), Config (remote config), Pulse
(in-app surveys), and Session Replay. One pubspec dependency, one initialization
call, all six products.

```dart
// Full integration — main.dart
import 'package:sankofa_flutter/sankofa_flutter.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SankofaUpdater.preFlight();   // apply staged OTA patch
  runApp(const MyApp());
}
```

---

## Contents

- [Why Sankofa](#why-sankofa)
- [Install](#install)
- [Sankofa Deploy — OTA patches without App Store resubmission](#sankofa-deploy)
- [Full SDK initialization](#full-sdk-initialization)
- [Per-product usage](#per-product-usage)
- [Session Replay](#session-replay)
- [Troubleshooting](#troubleshooting)
- [Architecture in one paragraph](#architecture-in-one-paragraph)
- [License](#license)

---

## Why Sankofa

| | Sankofa | Shorebird | CodePush (RN-only) |
|---|---|---|---|
| Flutter OTA, iOS App Store compliant | ✅ | ✅ | ❌ |
| Self-hostable backend | ✅ | ❌ | ❌ |
| Includes analytics + crash + surveys + flags + replay | ✅ | ❌ | ❌ |
| One package, one init call | ✅ | ✅ | ❌ |

Sankofa Deploy ships under the same App Store guideline that Shorebird and
CodePush use — Apple PLA § 3.3.2 carve-out for **interpreted code in a VM**.
Patches are Dart kernel bytecode (KBC) executed via `dart::Interpreter::Run`
inside the signed app. No JIT entitlement. No `PROT_EXEC` mmap. App Store
approves with the same review notes Shorebird customers ship under (see
[App Review notes template](https://github.com/Sankofa-HQ/sankofa-flutter-deploy/blob/main/docs/app-review-notes-template.md)).

---

## Install

```yaml
dependencies:
  sankofa_flutter: ^0.2.1
flutter:
  uses-material-design: true
  assets:
    - sankofa.yaml   # config file, see Deploy section below
```

`flutter pub get` and you're done. The SDK transitively pulls in everything it
needs to load patches — you do not add `dynamic_modules` or any other helper
package.

---

## Sankofa Deploy

OTA updates for Flutter, App Store compliant, iOS + Android.

### Setup (one time, ~30 seconds)

1. **Get an API key**: sign up at [app.sankofa.dev](https://app.sankofa.dev),
   create a project, copy the `sk_live_…` key from Settings → API Keys.

2. **Create `sankofa.yaml`** in your project root:

   ```yaml
   app_id: proj_xxxxxxxxxxxxx
   api_key: sk_live_xxxxxxxxxxxxxxxx
   ```

   The `sankofa init` CLI command writes this for you; copy by hand if you
   prefer.

3. **Add the YAML to your assets** (already shown in [Install](#install)
   above):

   ```yaml
   flutter:
     assets:
       - sankofa.yaml
   ```

4. **In `main()`**, call `preFlight` before `runApp`:

   ```dart
   import 'package:sankofa_flutter/sankofa_flutter.dart';

   void main() async {
     WidgetsFlutterBinding.ensureInitialized();
     await SankofaUpdater.preFlight();
     runApp(const MyApp());
   }
   ```

That's the entire setup. No engine version, no signing keys, no loaders to
register. The CLI writes those into `sankofa.yaml` when you run
`sankofa keys generate`; the SDK reads them transparently.

> **Why `preFlight()` exists** — Shorebird's customer code is literally
> `void main() => runApp(MyApp())` because their patch mechanism runs in
> native Rust before Dart starts. On iOS the kernel forbids that (no
> `PROT_EXEC` mmap of unsigned files). Sankofa uses the legal alternative:
> Dart kernel bytecode interpreted inside the signed app. Bytecode has to
> be loaded into the Dart VM, which can only happen after Dart starts —
> hence the one-line hook. A future engine release moves this inside the
> Flutter engine fork (the customer's `main()` becomes Shorebird-equivalent
> at that point).

### Customer API

```dart
import 'package:sankofa_flutter/sankofa_flutter.dart';

final updater = SankofaUpdater();

// What patch is the device currently running? Returns null on baseline.
final current = await updater.readCurrentPatch();
print(current?.label ?? 'baseline');

// Is a new patch available? Does NOT download — returns metadata only.
final result = await updater.checkForUpdate();
if (result.hasUpdate) {
  final update = result.update!;

  if (update.isMandatory) {
    // skip the prompt
    await updater.downloadUpdate(update);
  } else {
    // gate behind a user confirmation
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
launch automatically applies it (the `preFlight` call you added in step 4
picks it up). Show a "Restart to apply" prompt if you want — or do nothing
and let the patch take effect on next launch.

### What ships in a patch

Patches are Dart kernel bytecode produced by the Sankofa CLI:

```bash
sankofa patch ios       # builds + signs + uploads
sankofa patch android   # builds + signs + uploads
```

Patches replace code execution, not the app bundle. They cannot:

- Add new native code or libraries (no new symbols beyond what the AOT app
  already has).
- Change the app's primary purpose (App Store rule — every patch should be a
  bug fix, parameter tweak, or copy change).
- Replace launcher icons / splash / `Info.plist` / `AndroidManifest.xml`.

For changes outside those bounds, ship a new App Store / Play Store binary
the normal way.

### Rollback

Sankofa Deploy auto-rolls-back patches that crash the app within 30 seconds
of launch. Two consecutive quick crashes inside that window → the patch is
moved to the `disabled/` slot and the last known-good patch is restored.
The crashed label is added to a local ban list so the same patch isn't
re-downloaded from the server.

No host code required for rollback — the SDK handles it. Hosts can call
`Sankofa.instance.deploy?.clearBannedKbcLabels()` if they ship a fixed
re-issue under the same label (rare; usually a hotfix uses a new label).

---

## Full SDK initialization

`SankofaUpdater.preFlight()` brings up Deploy plus everything else if you've
configured it in `sankofa.yaml`. For projects that want explicit control over
which products run, use `Sankofa.instance.init(...)` instead:

```dart
import 'package:sankofa_flutter/sankofa_flutter.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Sankofa.instance.init(
    apiKey: 'sk_live_…',
    endpoint: 'https://api.sankofa.dev',
    appVersion: '1.0.0',

    // ── Product switches (all default true except Deploy) ──
    enableAnalytics: true,
    enableCatch: true,
    enableFlags: true,
    enableConfig: true,
    enablePulse: true,
    enableDeploy: true,    // Deploy defaults OFF; flip on here

    // ── Optional per-product config ──
    catchEnvironment: 'production',
    release: 'myapp@1.0.0',
    flagDefaults: {'new_checkout': FlagDecision(value: false, reason: 'default')},
    configDefaults: {'max_upload_mb': ItemDecision(value: 25, version: 1, reason: 'default')},
    beforeSend: (event) {
      if (event.message?.contains('setState called after dispose') ?? false) {
        return null;
      }
      return event;
    },
  );

  runApp(const MyApp());
}
```

After `init()`, every product is reachable via the singleton:
`Sankofa.instance.flags`, `.config`, `.pulse`, `.deploy`, `.catch`.

`preFlight()` is a thin wrapper around `init()` that auto-reads `sankofa.yaml`
and defaults Deploy on. Use whichever fits your app — they can be combined
(call `preFlight()` first, then `init()` is a no-op).

---

## Per-product usage

### Analytics

```dart
Sankofa.instance.track('completed_purchase', {
  'item_name': 'Vintage Camera',
  'price': 120.50,
  'currency': 'USD',
});

Sankofa.instance.identify('user_99');
Sankofa.instance.setPerson(
  name: 'Jane Doe',
  email: 'jane@example.com',
  properties: {'membership': 'Gold'},
);
```

### Catch — error capture

Static helpers work from anywhere once `init()` resolves. Dart-level errors
(`FlutterError.onError`, `PlatformDispatcher.onError`, isolate listeners)
plus iOS NSException / POSIX signals and Android JVM-uncaught / ANR all
flow to the same endpoint.

```dart
try {
  await chargeCard(amount);
} catch (err, stack) {
  Sankofa.captureException(err, stack);
}

Sankofa.captureMessage('payment retry attempted');
Sankofa.log('checkout: applying coupon SUMMER25');

Sankofa.setUser(CatchUserContext(id: 'u_42', email: 'ada@example.com'));
Sankofa.setTag('flow', 'checkout');
Sankofa.setExtra('cart_id', cart.id);

Sankofa.withScope((scope) {
  scope.setTag('checkout_step', 'payment');
  scope.setLevel(CatchLevel.warning);
  Sankofa.captureException(err);
});
```

### Switch — feature flags

```dart
final flags = Sankofa.instance.flags!;
if (flags.getFlag('new_checkout')) showNewCheckout();
final variant = flags.getVariant('checkout_redesign', defaultValue: 'control');
```

### Config — remote config

```dart
final config = Sankofa.instance.config!;
final maxUploads = config.get<int>('max_uploads_per_day', 25);
```

### Pulse — surveys

Surveys flagged **auto-show** in the dashboard appear on their own. Targeting
rules are AND-ed and evaluated on-device.

```dart
await Sankofa.instance.pulse.show(context, surveyId: 'nps-2024');

Sankofa.instance.pulse.on(PulseEvent.surveyCompleted, (e) {
  print('Survey ${e.surveyId} completed');
});
```

---

## Session Replay

Wrap your app with `SankofaReplayBoundary` to enable recording. Mask
sensitive widgets with `SankofaMask`, and for screens that host external
textures (video, maps, web views) use `SankofaReplaySuppress`.

```dart
MaterialApp(
  navigatorObservers: [SankofaNavigatorObserver()],
  home: const SankofaReplayBoundary(
    child: MyHomePage(),
  ),
);

// Mask passwords / balances / personal details — replaced with solid black
// in the upload, untouched in the live UI.
SankofaMask(
  child: TextField(controller: _passwordController, obscureText: true),
);

// Suppress capture entirely for a subtree — videos, maps, WebViews.
SankofaReplaySuppress(
  child: BetterPlayer(controller: _videoController),
);
```

---

## Troubleshooting

### `[!] No podspec found for sankofa_flutter` on `pod install`

Symptom: `cd ios && pod install` errors with
`No podspec found for sankofa_flutter in .symlinks/plugins/sankofa_flutter/ios`.

The podspec ships at `ios/sankofa_flutter.podspec`. The error means
CocoaPods can't see it through the symlink. Three quick checks:

```bash
# 1. Where does Flutter think sankofa_flutter is installed?
ls -l ios/.symlinks/plugins/sankofa_flutter

# 2. Does that target dir contain the podspec?
ls "$(readlink ios/.symlinks/plugins/sankofa_flutter)/ios"
# expected: includes `sankofa_flutter.podspec`
```

| If step 2 lists the `.podspec` | Stale CocoaPods state — `flutter clean && rm -rf ios/Pods ios/Podfile.lock ios/.symlinks && flutter pub get && cd ios && pod install` |
| If step 2 does NOT list the `.podspec` | You're on a ref that pre-dates v0.2.1 — bump constraint to `^0.2.1`, then `flutter pub upgrade sankofa_flutter` |

v0.2.0 (now retracted) shipped without the podspec. **Anyone still on
0.2.0 must bump to 0.2.1 or later.**

### Android: `Invalid external texture` logcat spam during video playback

The replay recorder previously called `RepaintBoundary.toImage` over
external-texture surfaces (BetterPlayer, `video_player`, `flutter_map`,
`webview_flutter`). On Android Impeller this could invalidate the texture
handle a media decoder was writing into.

Fixed in v0.2.1. The recorder now walks the tree before each capture and
skips frames when an external texture is present. You can also wrap a
specific subtree in `SankofaReplaySuppress` (shown above) for finer
control.

### Replay masks "blink" during capture

Fixed in v0.2.1. Masking moved off-screen entirely — the live UI no
longer flickers. Bump to v0.2.1 if you saw this on v0.2.0.

### `LateInitializationError: Local 'result' has not been initialized.`

Fixed in v0.2.1. Two SDK call sites used `RenderObject.debugNeedsPaint`,
a debug-only Flutter API whose `result` local is assigned inside an
`assert(() {...}())` that release/profile builds strip. Bump to v0.2.1.

### Updates aren't applying

```bash
# Check that the device sees the patch on disk:
sankofa devices show <device-id>
# or in the dashboard's Releases view
```

If the patch is staged but `readCurrentPatch()` returns `null` after a
restart, verify:

- You called `await SankofaUpdater.preFlight()` BEFORE `runApp()` (otherwise
  the boot-time apply doesn't run).
- The dashboard's "rollout" for the release is set to `100%` (or includes
  your device's distinct_id).
- The device's app version matches the release's `target_binary_version`
  exactly. Passing `1.0.0+12` when the release was published for `1.0.0`
  matches; passing `1.0.0+12` when the release was published for `1.0.0+12`
  also matches — the SDK compares against the dashboard's value verbatim.

---

## Architecture in one paragraph

Sankofa Deploy ships Dart kernel bytecode (`.kbc`) over HTTPS, signed with
Ed25519, verified on-device, and interpreted by `dart::Interpreter::Run`
inside the signed Flutter engine fork. No JIT entitlement. No
`PROT_EXEC` mmap. No native code is downloaded. Apple PLA § 3.3.2 and
Google Play's DNA policy both explicitly permit this pattern; Microsoft
CodePush (React Native) and Shorebird (Flutter) have shipped under the
same carve-out for years. The full architecture (engine fork details,
envelope format, server contract) lives in the
[`flutter-deploy/` private repo](https://github.com/Sankofa-HQ/sankofa-flutter-deploy).

---

## Documentation

- [Pub.dev API docs](https://pub.dev/documentation/sankofa_flutter/latest/) —
  auto-generated dartdoc for every public symbol
- [Sankofa docs](https://docs.sankofa.dev/sdks/flutter/overview) — guides,
  dashboard walkthrough, server self-hosting
- [Integration cookbook](https://github.com/Sankofa-HQ/sankofa-flutter-deploy/blob/main/docs/codepush-integration-cookbook.md) —
  the four gotchas + working `hello_codepush` reference app
- [App Review notes template](https://github.com/Sankofa-HQ/sankofa-flutter-deploy/blob/main/docs/app-review-notes-template.md) —
  copy-paste text for App Store Connect + Play Console submission
- [CHANGELOG](./CHANGELOG.md) — all changes per version

---

## License

Distributed under the MIT License. See `LICENSE` for more information.
