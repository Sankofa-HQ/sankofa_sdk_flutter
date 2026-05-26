# Changelog

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
