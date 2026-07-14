package com.sankofa.deploy

import android.content.Context
import android.util.Log

/**
 * Native boot-failure guard for OTA patches (crash → auto-rollback).
 *
 * A bad patch that crashes Dart before the first frame leaves the app in a
 * permanent boot-loop unless something NATIVE notices: the Dart-side SDK (and
 * with it the server handshake — the delivery/rollback channel) never runs, so
 * neither a new patch nor a server-side rollback can rescue the device.
 * Dogfood 2026-07-14 proved this: a patch that throws in `main()` boot-looped
 * forever, and disabling the release server-side changed nothing.
 *
 * The guard is deliberately simple and fully native:
 *
 *  1. [SankofaFlutterActivity.getFlutterShellArgs] asks [shouldUsePatch]
 *     before injecting `--aot-shared-library-name`. A patch that has already
 *     burned [MAX_BOOT_ATTEMPTS] boots without ever reaching a healthy Dart
 *     runtime is tombstoned: the activity falls back to the APK-default
 *     libapp.so and the stale `current_bundle_label` pref is cleared so the
 *     next handshake gets a fresh offer (e.g. the previous good patch).
 *  2. Every boot that DOES hand the patch to the engine is recorded via
 *     [noteBootAttempt] before Dart starts.
 *  3. The first MethodChannel call from Dart ([SankofaDeployPlugin]) proves
 *     the runtime came up — [markBootHealthy] resets the attempt counter.
 *
 * Tombstones are per patch id (the `vdrl-<release>` directory name) and
 * persist until the app is reinstalled or a DIFFERENT patch id is installed —
 * re-offering the same broken bytes will never boot-loop the device again.
 */
object SankofaBootGuard {

    private const val TAG = "SankofaBootGuard"
    private const val PREFS = "sankofa_deploy" // shared with SankofaDeployPlugin
    private const val KEY_PENDING_PATCH = "boot_pending_patch"
    private const val KEY_ATTEMPTS_PREFIX = "boot_attempts_"
    private const val KEY_TOMBSTONE_PREFIX = "boot_tombstoned_"
    private const val PREF_CURRENT_LABEL = "current_bundle_label"

    /** Boots a patch may burn without a healthy signal before it's tombstoned. */
    private const val MAX_BOOT_ATTEMPTS = 2

    private fun prefs(ctx: Context) =
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /**
     * Gate a patch before it is handed to the engine. Returns false when the
     * patch is (or has just become) tombstoned — the caller must fall back to
     * the APK-default libapp.so.
     */
    fun shouldUsePatch(ctx: Context, patchId: String): Boolean {
        val p = prefs(ctx)
        if (p.getBoolean(KEY_TOMBSTONE_PREFIX + patchId, false)) {
            Log.w(TAG, "Patch $patchId is tombstoned (failed boots); using APK default libapp.so")
            return false
        }
        val attempts = p.getInt(KEY_ATTEMPTS_PREFIX + patchId, 0)
        if (attempts >= MAX_BOOT_ATTEMPTS) {
            Log.e(
                TAG,
                "Patch $patchId burned $attempts boots without a healthy Dart runtime — " +
                    "TOMBSTONING and rolling back to the APK baseline.",
            )
            p.edit()
                .putBoolean(KEY_TOMBSTONE_PREFIX + patchId, true)
                .remove(KEY_ATTEMPTS_PREFIX + patchId)
                .remove(KEY_PENDING_PATCH)
                // Clear the handshake label so the server re-offers the best
                // available release instead of "already_on_latest".
                .remove(PREF_CURRENT_LABEL)
                .apply()
            return false
        }
        return true
    }

    /** Record that this boot is about to run [patchId]. Call BEFORE Dart starts. */
    fun noteBootAttempt(ctx: Context, patchId: String) {
        val p = prefs(ctx)
        val attempts = p.getInt(KEY_ATTEMPTS_PREFIX + patchId, 0) + 1
        p.edit()
            .putInt(KEY_ATTEMPTS_PREFIX + patchId, attempts)
            .putString(KEY_PENDING_PATCH, patchId)
            .apply()
        Log.i(TAG, "Boot attempt $attempts/$MAX_BOOT_ATTEMPTS for patch $patchId")
    }

    /**
     * Dart is alive (first MethodChannel call) — the pending patch booted
     * successfully. Clears its attempt counter. Cheap + idempotent.
     */
    fun markBootHealthy(ctx: Context) {
        val p = prefs(ctx)
        val pending = p.getString(KEY_PENDING_PATCH, null) ?: return
        p.edit()
            .remove(KEY_ATTEMPTS_PREFIX + pending)
            .remove(KEY_PENDING_PATCH)
            .apply()
        Log.i(TAG, "Boot healthy — cleared failure counter for patch $pending")
    }
}
