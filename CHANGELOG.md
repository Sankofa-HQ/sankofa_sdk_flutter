# Changelog

## 0.2.1 — Replay fixes + restore missing iOS podspec

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
    happens off-screen on the rasterized bitmap (the recorder's
    `_applyMasks` path is the authoritative one). Result: masked
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
*   **Telemetry** — `kbc_apply_success` / `_failed`,
    `kbc_boot_apply_success` / `_failed` / `_skipped_rollback`
    fire on every apply path with error-message + cause-class
    context for dashboard rollups.
*   **`Sankofa.deploy.getStagedKbcPatchInfo`** — read-only view
    of the active patch (label, dartVersion, engineCommit, signed
    flag, size, modifiedAt) for debug screens.

### Hardening (data integrity, privacy, crash durability, robustness)

*   **Pulse auto-show** — surveys flagged `auto_show` in the dashboard
    now present automatically (parity with iOS/Android). New
    `SankofaPulse.setNavigatorKey(GlobalKey<NavigatorState>)` gives the
    pump a presentation anchor; honours per-survey cooldown + delay and
    re-evaluates on app foreground / after each fetch. Screen/URL
    targeting now works (the eligibility context populates the current
    screen). `refreshSurveys()` forces a fresh fetch after `identify()`.
*   **Analytics queue** — per-status delivery disposition (transient
    failures retry, client errors drop) instead of all-or-nothing,
    plus a hard size cap + 48h TTL and single-flight flush. Custom
    property numbers/booleans keep their native JSON type.
*   **Session replay privacy** — automatic masking of text inputs
    (always for obscured fields), `SankofaMask` regions, and optional
    text/images; the server `mask_all_inputs` flag is now enforced.
    Bounded frame/event buffers, no data loss on failed uploads,
    serialized uploads.
*   **Crash durability** — fatal crashes are spooled synchronously and
    recovered (with full payload) + flushed on the next launch; fatals
    are never sampled out; `PlatformDispatcher.onError` preserves the
    host's default error propagation.
*   **Lifecycle** — correct cold-start session rotation, `paused`/
    `hidden`-only backgrounding, race-free init, and `reset()` re-points
    replay to the new anonymous id.
*   **Config/Switch** — `config.get<bool>` coerces 1/0 and
    "true"/"false"; change listeners deliver a consistent snapshot.

## 0.1.0

*   Added high-fidelity session replay mode.
*   Implemented remote configuration fetching for dynamic sampling.
*   Added event-based high-fidelity recording triggers.
*   Updated dependency management for cleaner integration.

## 0.0.1

* Initial release of Sankofa Flutter SDK.
* Modular architecture for easier maintenance.
* Support for event tracking, identity management, and session replay (wireframe & screenshot modes).
* Automatic UTM parameter capturing from deep links.
* App lifecycle observation for automatic event tracking and queue flushing.
