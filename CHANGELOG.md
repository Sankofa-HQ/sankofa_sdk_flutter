# Changelog

## 0.2.1 — `SankofaUpdater` + customer-blocking fixes

**New: `SankofaUpdater` — the one class.** A clean facade for OTA
updates that lives behind a zero-arg constructor and lazy
`sankofa.yaml` discovery. No engine versions, signing keys, or "KBC"
anywhere in customer code — those live in `sankofa.yaml`, written by
the CLI:

```yaml
# sankofa.yaml (project root; add to flutter.assets in pubspec.yaml)
app_id: proj_xxxxxxxxxxxxx
api_key: sk_live_xxxxxxxxxxxxxxxx
```

```yaml
# pubspec.yaml — two deps
dependencies:
  sankofa_flutter: ^0.2.1
  dynamic_modules:
    git:
      url: https://github.com/Sankofa-HQ/sankofa-dart-sdk.git
      path: standalone/dynamic_modules
      ref: main
flutter:
  assets:
    - sankofa.yaml
```

```dart
// main.dart — full Sankofa Deploy integration:
import 'package:dynamic_modules/dynamic_modules.dart';
import 'package:sankofa_flutter/sankofa_flutter.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SankofaUpdater.registerLoader(loadModuleFromBytes);   // one-time
  await SankofaUpdater.preFlight();
  runApp(const MyApp());
}
```

Don't write any of this by hand — run `sankofa init` (in a Flutter
project) and the CLI writes the pubspec stanzas + sankofa.yaml +
modifies lib/main.dart for you.

> **Why `dynamic_modules` is a separate customer dep:** the underlying
> binding imports `dart:_internal`, which pub.dev refuses to publish.
> The package lives in a separate repo; you reference it via git.
> A future release will move the binding into our bundled Flutter SDK
> as a `sdk: flutter` package so this dep drops out entirely.

```dart
// Anywhere in the app:
final updater = SankofaUpdater();

// Currently-installed patch.
final current = await updater.readCurrentPatch();

// Is a new patch available?
final result = await updater.checkForUpdate();
if (result.hasUpdate) {
  if (result.update!.isMandatory) {
    await updater.downloadUpdate(result.update!);
  } else if (await showUpdateDialog(context)) {
    await updater.downloadUpdate(
      result.update!,
      onProgress: (rx, total) =>
          setState(() => _progress = total > 0 ? rx / total : 0),
    );
  }
}
```

**Customer-facing surface stops there.** Engine versions, KBC
bytecode, Ed25519 signing keys — none appear in customer code. They
live in `sankofa.yaml` (written by `sankofa init` / `sankofa keys
generate`) and the SDK reads them transparently.

The previous Kbc-named methods on `Sankofa.deploy` (`checkForKbcUpdate`,
`downloadKbcUpdate`, `readCurrentKbcPatch`) were renamed to drop the
prefix (`checkForUpdate`, `downloadUpdate`, `readCurrentPatch`). The
all-in-one `fetchAndApplyKbcPatch` still exists for hosts that want
one call.

**Customer-blocking release crash fix:** the heatmap snapshotter and
the replay recorder both called `RenderObject.debugNeedsPaint`, which
is a debug-only getter (its `result` local is assigned inside an
`assert(() { ... }())` that Flutter strips in release / profile
builds). Accessing it then throws
`LateInitializationError: Local 'result' has not been initialized.`
Two call sites in v0.2.0; both now gated behind `kDebugMode` so release
builds skip the wait and snapshot whatever is on screen.

**Customer-blocking iOS bug fix:** v0.2.0 shipped to pub.dev without
`ios/sankofa_flutter.podspec` — a stray `**/*.podspec` rule in
`.pubignore` filtered out the file. Consumers got
`No podspec found for sankofa_flutter` on every `pod install` and had
to remove the dependency to unblock builds. v0.2.1 ships the podspec
correctly. **Every iOS-consuming customer on 0.2.0 must bump to 0.2.1.**

**Replay quality fixes** (informed by customer reports against 0.2.0):

*   **Mask blink** — `SankofaMask` no longer paints solid black in the
    live widget tree during capture. The flag-driven render branch
    caused inconsistent flicker on every screenshot because Flutter's
    pipeline doesn't repaint on global flag flips. Masking still
    happens off-screen on the rasterized bitmap. Result: masked
    regions in the upload are still black; the live UI no longer
    flickers.
*   **External texture invalidation on Android Impeller** — the
    recorder now walks the tree before every frame and skips capture
    if any `Texture`, `AndroidView`, `UiKitView`, or
    `PlatformViewLink` is in the subtree. Fixes `Invalid external
    texture` logcat spam and the scroll-to-top behaviour seen on
    screens running `BetterPlayer`, `video_player`, `flutter_map`,
    `webview_flutter`, etc.
*   **New `SankofaReplaySuppress` widget** — wrap a sensitive subtree
    (video player, map, camera preview) to mark it as off-limits for
    capture. Exported from
    `package:sankofa_flutter/sankofa_flutter.dart`.

## 0.2.0 — Sankofa Deploy: Flutter Code (OTA patches via KBC interpreter)

*   **Sankofa Deploy module** — Path C iOS OTA via the Sankofa-fork
    Flutter engine's `dart::Interpreter::Run`. No App Store
    resubmission, no JIT entitlement. Patches ship as
    `SANKOFA_KBC_ENVELOPE v1` files signed with project-bound
    Ed25519 keypairs.
*   **`Sankofa.deploy.fetchAndApplyKbcPatch`** — single-call
    fetch + verify + apply path for Tier-A and Tier-B patches.
*   **`Sankofa.deploy.tryApplyStagedKbcPatch`** — boot-time
    re-apply for OTA persistence across cold restart.
*   **Rollback safety** — boot-counter auto-disables a patch
    after `kbcRollbackThreshold` (default 3) consecutive crashes;
    host calls `notifyKbcPatchReady` after first frame to reset.
*   **Ed25519 envelope verification** — `SankofaDeployOptions.
    signingPubkeyB64` opt-in; SDK refuses unsigned or non-verifying
    envelopes when set. Handshake-distributed pubkeys merge with
    the host-embedded key for graceful rotation.
