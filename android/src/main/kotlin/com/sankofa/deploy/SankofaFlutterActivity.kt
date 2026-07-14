package com.sankofa.deploy

import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterShellArgs

/**
 * Drop-in replacement for [FlutterActivity] that injects the
 * `--aot-shared-library-name=<path>` engine flag when the Sankofa
 * updater has an active patched libapp.so available.
 *
 * Customer integration:
 * ```
 * class MainActivity : SankofaFlutterActivity()
 * ```
 *
 * The updater must be initialized BEFORE this activity is created.
 * Initialize from Dart in `main()`:
 * ```
 * await SankofaDeploy.init(SankofaDeployConfig(appKey: '...', serverUrl: '...'));
 * runApp(MyApp());
 * ```
 *
 * If the updater hasn't been initialized yet (e.g. first cold boot before
 * Dart has run), `nativeGetLibappPath()` returns null and we fall through
 * to vanilla Flutter behavior — the engine loads libapp.so from the APK.
 */
open class SankofaFlutterActivity : FlutterActivity() {

    override fun getFlutterShellArgs(): FlutterShellArgs {
        val base = super.getFlutterShellArgs()
        val overridePath = try {
            SankofaUpdaterJNI.nativeGetLibappPath()
        } catch (e: Throwable) {
            Log.w(TAG, "Could not query updater for libapp path; using APK default", e)
            null
        }

        if (overridePath.isNullOrEmpty()) {
            Log.d(TAG, "No active Sankofa patch; using APK default libapp.so")
            return base
        }

        // Boot-guard (crash → auto-rollback): a patch that repeatedly boots
        // without Dart ever coming up healthy gets tombstoned and we fall back
        // to the APK baseline — otherwise a bad patch boot-loops forever and
        // even a server-side rollback can't rescue the device (the rescue
        // channel — the handshake — runs from Dart). See SankofaBootGuard.
        val patchId = java.io.File(overridePath).parentFile?.name ?: overridePath
        if (!SankofaBootGuard.shouldUsePatch(this, patchId)) {
            Log.w(TAG, "Boot-guard refused patch $patchId; using APK default libapp.so")
            return base
        }
        SankofaBootGuard.noteBootAttempt(this, patchId)

        Log.i(TAG, "Sankofa patch active → $overridePath")
        val extended = base.toArray().toMutableList().apply {
            add("--aot-shared-library-name=$overridePath")
        }
        return FlutterShellArgs(extended.toTypedArray())
    }

    companion object {
        private const val TAG = "SankofaFlutterActivity"
    }
}
