package com.sankofa.deploy

import android.content.pm.PackageManager
import android.util.Log
import io.flutter.app.FlutterApplication
import java.io.File
import java.io.FileOutputStream
import java.util.zip.ZipFile

/**
 * Drop-in [FlutterApplication] subclass that initializes the Sankofa
 * updater BEFORE any activity is created.
 *
 * The standard Phase 7 flow (init from Dart in main()) fires after the
 * Flutter engine has already started — too late for
 * [SankofaFlutterActivity.getFlutterShellArgs] to query the updater for
 * the active patch path. By initializing here, the on-disk patch state
 * is loaded into the Rust updater while the process is still in its
 * Application phase, so the next activity that starts can see the active
 * patch immediately.
 *
 * Customer integration is one line in their AndroidManifest.xml:
 * ```xml
 * <application
 *     android:name="com.sankofa.deploy.SankofaDeployApplication"
 *     ...>
 *   <meta-data
 *       android:name="com.sankofa.apiKey"
 *       android:value="sk_live_xxxxxxxx" />
 *   <meta-data
 *       android:name="com.sankofa.endpoint"
 *       android:value="https://api.sankofa.dev" />
 *   ...
 * </application>
 * ```
 *
 * Reads two meta-data values from the manifest:
 * - `com.sankofa.apiKey`   — customer's Sankofa API key (required)
 * - `com.sankofa.endpoint` — Sankofa API endpoint (required;
 *                             production = https://api.sankofa.dev)
 *
 * If either is missing, this class logs the error and skips init —
 * SankofaFlutterActivity will then fall back to the APK-default
 * libapp.so, same as if the SDK wasn't integrated at all.
 *
 * The Dart-side [SankofaDeploy.init] is still callable; it's a no-op if
 * the native updater is already initialized (per the Phase 4 manager
 * contract: re-init returns OK without disturbing existing state).
 */
open class SankofaDeployApplication : FlutterApplication() {

    override fun onCreate() {
        super.onCreate()
        initializeUpdaterFromManifest()
    }

    private fun initializeUpdaterFromManifest() {
        try {
            val ai = packageManager.getApplicationInfo(
                packageName,
                PackageManager.GET_META_DATA,
            )
            val md = ai.metaData
            if (md == null) {
                Log.w(TAG, "No <meta-data> entries on <application>; skipping pre-Dart init")
                return
            }
            val apiKey = md.getString("com.sankofa.apiKey")
            val endpoint = md.getString("com.sankofa.endpoint")
            if (apiKey.isNullOrBlank() || endpoint.isNullOrBlank()) {
                Log.w(
                    TAG,
                    "com.sankofa.apiKey or com.sankofa.endpoint missing/blank; skipping pre-Dart init. SDK will fall back to APK default libapp.so."
                )
                return
            }

            val dataDir = File(filesDir, "sankofa").apply { mkdirs() }
            val baselineLibapp = ensureBaselineExtracted(dataDir) ?: run {
                Log.w(TAG, "Could not locate libapp.so in APK; SDK will fall back to APK default")
                return
            }

            // Phase 8 will use `endpoint` for the server check; held in
            // memory by the plugin for now via the same MethodChannel init.
            val rc = SankofaUpdaterJNI.nativeInit(
                apiKey,
                baselineLibapp.absolutePath,
                dataDir.absolutePath,
                BASELINE_ENGINE_VERSION,
            )
            if (rc == 0 || rc == 1) {
                SankofaUpdaterJNI.isInitialized = true
                SankofaUpdaterJNI.apiKey = apiKey
                SankofaUpdaterJNI.endpoint = endpoint.trimEnd('/')
                Log.i(
                    TAG,
                    "Pre-Dart updater init OK (rc=$rc) at ${dataDir.absolutePath}, baseline=${baselineLibapp.absolutePath}, endpoint=$endpoint. SankofaFlutterActivity can now see the active patch."
                )
            } else {
                Log.e(TAG, "Pre-Dart updater init FAILED rc=$rc")
            }
        } catch (e: Throwable) {
            Log.e(TAG, "Pre-Dart updater init threw; falling back to APK default", e)
        }
    }

    private fun ensureBaselineExtracted(dataDir: File): File? {
        val baselineDir = File(dataDir, "baseline").apply { mkdirs() }
        val target = File(baselineDir, "libapp.so")
        if (target.exists() && target.length() > 0) return target

        val abi = android.os.Build.SUPPORTED_ABIS.firstOrNull() ?: return null
        val apkPath = applicationInfo.sourceDir
        val zipEntry = "lib/$abi/libapp.so"

        return try {
            ZipFile(apkPath).use { zip ->
                val entry = zip.getEntry(zipEntry) ?: return null
                zip.getInputStream(entry).use { input ->
                    FileOutputStream(target).use { output ->
                        input.copyTo(output)
                    }
                }
            }
            Log.i(TAG, "Extracted baseline libapp.so (${target.length()} bytes) from $apkPath:$zipEntry")
            target
        } catch (e: Throwable) {
            Log.e(TAG, "Failed to extract baseline libapp.so from APK", e)
            null
        }
    }

    companion object {
        private const val TAG = "SankofaDeployApp"
        // Must match the Phase 3 marker in GetFlutterEngineVersion().
        private const val BASELINE_ENGINE_VERSION = "3.44.1+sankofa-2"
    }
}
