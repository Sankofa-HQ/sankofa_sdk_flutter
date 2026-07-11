package com.sankofa.deploy

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.security.MessageDigest
import java.util.Locale
import java.util.UUID
import java.util.zip.ZipFile

class SankofaDeployPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private lateinit var channel: MethodChannel
    private lateinit var applicationContext: Context

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "com.sankofa.deploy/main")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "initialize" -> {
                    // Skip re-init if SankofaDeployApplication already brought up
                    // the Rust updater during Application.onCreate. BUT the pre-init
                    // only had the manifest's fallback apiKey/endpoint and the
                    // compile-time BASELINE_ENGINE_VERSION — all of which mis-gate
                    // the server handshake. The Dart config (SankofaDeployOptions)
                    // is AUTHORITATIVE, so adopt its engineVersion / apiKey / endpoint
                    // here before the first checkForUpdate runs. Without this, the
                    // native handshake sends a stale engine_version (→ no_matching_
                    // release) and the manifest placeholder key (→ 401).
                    if (SankofaUpdaterJNI.isInitialized) {
                        call.argument<String>("engineVersion")?.let { engineVersion = it }
                        call.argument<String>("apiKey")?.let { SankofaUpdaterJNI.apiKey = it }
                        call.argument<String>("endpoint")?.let {
                            SankofaUpdaterJNI.endpoint = it.trimEnd('/')
                        }
                        Log.i(TAG, "Updater already initialized (SankofaDeployApplication); adopted Dart config engineVersion=$engineVersion apiKey=${SankofaUpdaterJNI.apiKey?.take(12)}…")
                        return result.success(null)
                    }

                    val apiKey = call.argument<String>("apiKey")
                        ?: return result.error("BAD_ARG", "apiKey missing", null)
                    val endpoint = call.argument<String>("endpoint")
                        ?: return result.error("BAD_ARG", "endpoint missing", null)
                    // Engine version of the RUNNING engine, supplied by the
                    // Dart layer (SankofaDeployOptions.engineVersion). The
                    // compile-time BASELINE_ENGINE_VERSION constant is only a
                    // last-resort fallback — a stale constant mis-gates the
                    // server's engine_version release filter.
                    engineVersion = call.argument<String>("engineVersion") ?: BASELINE_ENGINE_VERSION

                    val dataDir = File(applicationContext.filesDir, "sankofa").apply { mkdirs() }
                    val baselineLibapp = ensureBaselineExtracted(dataDir)
                    if (baselineLibapp == null) {
                        return result.error(
                            "BASELINE_MISSING",
                            "Could not locate libapp.so inside the APK. This SDK requires a release-mode Flutter build with libapp.so present in lib/<abi>/.",
                            null,
                        )
                    }

                    // apiKey is passed to the Rust updater as the app_id (the
                    // Rust layer doesn't care about Sankofa's key format; it
                    // just uses the value as an opaque tenant identifier for
                    // its state files). endpoint is held by the plugin until
                    // Phase 8 wires the server-side patch check via
                    // GET /api/v1/handshake (x-api-key: $apiKey).
                    val rc = SankofaUpdaterJNI.nativeInit(
                        apiKey,
                        baselineLibapp.absolutePath,
                        dataDir.absolutePath,
                        engineVersion,
                    )
                    if (rc == 0 || rc == 1) {
                        SankofaUpdaterJNI.isInitialized = true
                        SankofaUpdaterJNI.apiKey = apiKey
                        SankofaUpdaterJNI.endpoint = endpoint.trimEnd('/')
                        Log.i(TAG, "Updater initialized (rc=$rc) at ${dataDir.absolutePath}, baseline=${baselineLibapp.absolutePath}, endpoint=$endpoint")
                        result.success(null)
                    } else {
                        result.error("INIT_FAILED", "nativeInit returned $rc", null)
                    }
                }

                "checkForUpdate" -> {
                    Log.i(TAG, "checkForUpdate entry (apiKey=${SankofaUpdaterJNI.apiKey?.take(12)}…, endpoint=${SankofaUpdaterJNI.endpoint}, initialized=${SankofaUpdaterJNI.isInitialized})")
                    // Run off the main thread — network IO is blocking, must
                    // not freeze the UI thread. Result.success/error must
                    // still fire on the main thread (MethodChannel rule).
                    val deferred = result
                    Thread(
                        {
                            try {
                                val status = handshakeAndMaybeInstall()
                                runOnMain { deferred.success(status) }
                            } catch (e: Throwable) {
                                Log.e(TAG, "checkForUpdate failed", e)
                                runOnMain { deferred.success("failed") }
                            }
                        },
                        "sankofa-deploy-check",
                    ).start()
                }

                "notifyAppReady" -> {
                    SankofaUpdaterJNI.nativeNotifyAppReady()
                    result.success(null)
                }

                "reportCrash" -> {
                    SankofaUpdaterJNI.nativeReportCrash()
                    result.success(null)
                }

                "getActiveVersion" -> {
                    result.success(SankofaUpdaterJNI.nativeGetActiveVersion())
                }

                "getCurrentLibappPath" -> {
                    result.success(SankofaUpdaterJNI.nativeGetLibappPath())
                }

                "disableCurrentPatch" -> {
                    val rc = SankofaUpdaterJNI.nativeDisableCurrentPatch()
                    if (rc == 0) {
                        // Clear the persisted label so the next handshake
                        // doesn't claim we're still running the patch we
                        // just disabled — would otherwise produce a stuck
                        // `already_on_latest` reply for a label we no
                        // longer actually have active.
                        prefs().edit().remove(PREF_CURRENT_LABEL).apply()
                        result.success(null)
                    } else {
                        result.error("DISABLE_FAILED", "nativeDisableCurrentPatch returned $rc", null)
                    }
                }

                "shutdown" -> {
                    SankofaUpdaterJNI.nativeShutdown()
                    result.success(null)
                }

                "checkIntegration" -> {
                    // Inspect the host's runtime wiring so the Dart side
                    // can tell the developer (and eventually the
                    // dashboard) which pieces of the Deploy integration
                    // are missing. Pure reflection — no side effects.
                    result.success(checkIntegration())
                }

                else -> result.notImplemented()
            }
        } catch (e: Throwable) {
            Log.e(TAG, "Method ${call.method} threw", e)
            result.error("NATIVE_EXCEPTION", e.message, null)
        }
    }

    /**
     * Phase 8 entry point invoked from a background thread by the
     * `checkForUpdate` MethodChannel handler. Returns one of the
     * [com.sankofa.deploy.UpdateStatus]-stringified values:
     *
     * - `"up_to_date"`     — server says no patch applies
     * - `"installed"`      — patch downloaded + verified + staged for next boot
     * - `"failed"`         — network / server / SHA error; nothing changed
     *
     * Never throws — all errors translate to `"failed"` so the Dart side
     * just sees a status code.
     */
    private fun handshakeAndMaybeInstall(): String {
        val apiKey = SankofaUpdaterJNI.apiKey
        val endpoint = SankofaUpdaterJNI.endpoint
        if (apiKey.isNullOrBlank() || endpoint.isNullOrBlank()) {
            Log.w(TAG, "checkForUpdate called before init — no apiKey/endpoint known")
            return "failed"
        }
        if (!SankofaUpdaterJNI.isInitialized) {
            Log.w(TAG, "checkForUpdate called before nativeInit")
            return "failed"
        }

        val url = buildHandshakeUrl(endpoint)
        Log.i(TAG, "checkForUpdate → $url")

        val responseBody = httpGet(url, apiKey) ?: return "failed"
        val deploy = parseDeployBlock(responseBody) ?: return "up_to_date"

        if (!deploy.optBoolean("has_update", false)) {
            Log.i(TAG, "checkForUpdate: server says up_to_date (reason=${deploy.optString("reason", "")})")
            return "up_to_date"
        }

        val runtime = deploy.optString("runtime", "")
        if (runtime != "flutter-code") {
            Log.w(TAG, "checkForUpdate: server returned a non-flutter-code release (runtime='$runtime'), ignoring")
            return "up_to_date"
        }

        val downloadUrl = deploy.optString("download_url", "")
        val sha256 = deploy.optString("sha256", "").lowercase(Locale.US)
        val label = deploy.optString("label", "")
        val releaseId = deploy.optString("release_id", UUID.randomUUID().toString())
        if (downloadUrl.isEmpty() || sha256.isEmpty() || label.isEmpty()) {
            Log.e(TAG, "checkForUpdate: server response missing download_url/sha256/label; got $deploy")
            return "failed"
        }

        // Use the release_id as the local PatchVersion. Rust grammar:
        // 'v' + alnum + dots/dashes/underscores. Server release_ids are
        // already `drl_<hex>` shaped — prepend 'v' + drop the underscore.
        val patchVersion = "v" + releaseId.replace("_", "-").take(60)

        val dataDir = File(applicationContext.filesDir, "sankofa")
        val downloadsDir = File(dataDir, "downloads").apply { mkdirs() }
        val staged = File(downloadsDir, "$patchVersion.libapp.so")

        Log.i(TAG, "checkForUpdate: downloading $label ($sha256) → ${staged.absolutePath}")
        if (!httpDownload(downloadUrl, staged)) {
            return "failed"
        }

        val downloadedSha = sha256OfFile(staged)
        if (downloadedSha != sha256) {
            Log.e(TAG, "checkForUpdate: SHA256 mismatch: server=$sha256 got=$downloadedSha. Discarding download.")
            staged.delete()
            return "failed"
        }

        val rc = SankofaUpdaterJNI.nativeInstallPatch(patchVersion, staged.absolutePath, sha256)
        return when (rc) {
            SankofaUpdaterReturnCode.OK -> {
                Log.i(TAG, "checkForUpdate: installed $label as $patchVersion. Restart app to apply.")
                // Persist the human label so the next handshake sends it as
                // current_bundle_label, letting the server short-circuit with
                // "already_on_latest" instead of re-handing us the same patch
                // on every check. The Rust state.json only tracks PatchVersion;
                // the customer-visible label lives here in SharedPreferences.
                prefs().edit().putString(PREF_CURRENT_LABEL, label).apply()
                "installed"
            }
            SankofaUpdaterReturnCode.INVALID_INPUT -> {
                Log.e(TAG, "checkForUpdate: nativeInstallPatch rejected input (rc=$rc). Discarding.")
                staged.delete()
                "failed"
            }
            else -> {
                Log.e(TAG, "checkForUpdate: nativeInstallPatch fatal (rc=$rc).")
                "failed"
            }
        }
    }

    private fun prefs() =
        applicationContext.getSharedPreferences("sankofa_deploy", Context.MODE_PRIVATE)

    private fun buildHandshakeUrl(endpoint: String): String {
        val ai = applicationContext.applicationInfo
        val pkgInfo = applicationContext.packageManager.getPackageInfo(applicationContext.packageName, 0)
        val appVersion = pkgInfo.versionName ?: "unknown"
        val locale = Locale.getDefault().toLanguageTag()
        val deviceModel = "${Build.MANUFACTURER} ${Build.MODEL}"
        val osVersion = Build.VERSION.RELEASE
        val abi = Build.SUPPORTED_ABIS.firstOrNull() ?: "unknown"
        val anonId = stableAnonId()
        val params = mutableListOf(
            "platform" to "android",
            "runtime" to "flutter-code",
            "sdk" to "flutter",
            "app_version" to appVersion,
            "device_model" to deviceModel,
            "os_version" to osVersion,
            "locale" to locale,
            "abi" to abi,
            "engine_version" to engineVersion,
            // Phase 8 / pre-Phase 9: synthesize bucketing identifiers
            // from Settings.Secure.ANDROID_ID. The server's gating layer
            // requires BOTH distinct_id (the primary bucketing key,
            // normally an authenticated user ID) and anon_id (the pre-
            // identify shadow). Without distinct_id, every handshake
            // resolves to "missing_update_context" and the cohort engine
            // never runs. Until Phase 9 ships a real SankofaIdentity with
            // a true distinct/anon split, both keys reflect the device's
            // stable per-install ID — gives the server something
            // deterministic to bucket on.
            "distinct_id" to anonId,
            "anon_id" to anonId,
        )
        // current_bundle_label lets the server return `already_on_latest`
        // (gating.go:283) instead of re-handing us the patch we already
        // installed. Only sent when we've installed at least one patch —
        // a fresh device with only the baseline omits the param, which the
        // server treats as "no current label, evaluate normally."
        val currentLabel = prefs().getString(PREF_CURRENT_LABEL, null)
        if (!currentLabel.isNullOrBlank()) {
            params += ("current_bundle_label" to currentLabel)
        }
        val query = params.joinToString("&") { (k, v) ->
            "${URLEncoder.encode(k, "UTF-8")}=${URLEncoder.encode(v, "UTF-8")}"
        }
        return "$endpoint/api/v1/handshake?$query"
    }

    /**
     * GET [urlString] with `x-api-key`. Returns the response body as a
     * String, or null on any non-2xx / IOException. Uses HttpURLConnection
     * to avoid a transitive OkHttp dependency.
     */
    private fun httpGet(urlString: String, apiKey: String): String? {
        val conn = (URL(urlString).openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = 5_000
            readTimeout = 5_000
            setRequestProperty("x-api-key", apiKey)
            setRequestProperty("Accept", "application/json")
            setRequestProperty("User-Agent", "sankofa_deploy/0.1.0 (android; $RUNTIME_SDK)")
        }
        return try {
            val code = conn.responseCode
            if (code in 200..299) {
                conn.inputStream.bufferedReader().use { it.readText() }
            } else {
                val err = conn.errorStream?.bufferedReader()?.use { it.readText() } ?: ""
                Log.w(TAG, "handshake HTTP $code: $err")
                null
            }
        } catch (e: Throwable) {
            // Log the message + class to disambiguate connection refused
            // (server reachable but route gone), timeout, TLS error, etc.
            Log.w(TAG, "handshake IO failed (${e.javaClass.simpleName}): ${e.message}")
            null
        } finally {
            conn.disconnect()
        }
    }

    private fun parseDeployBlock(body: String): JSONObject? {
        return try {
            val modules = JSONObject(body).optJSONObject("modules") ?: return null
            modules.optJSONObject("deploy")
        } catch (e: Throwable) {
            Log.w(TAG, "handshake JSON parse failed: $e")
            null
        }
    }

    /**
     * Stream [urlString] to [target] (8 KiB chunks). Returns true on
     * success, false on IO failure or non-2xx response. Caller is
     * responsible for deleting [target] on false.
     */
    private fun httpDownload(urlString: String, target: File): Boolean {
        val conn = (URL(urlString).openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = 10_000
            readTimeout = 30_000
            instanceFollowRedirects = true
        }
        return try {
            val code = conn.responseCode
            if (code !in 200..299) {
                Log.w(TAG, "download HTTP $code")
                return false
            }
            BufferedInputStream(conn.inputStream).use { input ->
                FileOutputStream(target).use { output ->
                    input.copyTo(output, bufferSize = 8 * 1024)
                }
            }
            true
        } catch (e: Throwable) {
            Log.w(TAG, "download IO failed", e)
            false
        } finally {
            conn.disconnect()
        }
    }

    /**
     * Stable per-install anonymous identifier for handshake bucketing.
     *
     * Phase 8 / pre-Phase 9 stopgap. Returns `Settings.Secure.ANDROID_ID`
     * when available — that's already a Google-blessed per-install
     * identifier on Android 8.0+, stable across reboots, unique per
     * (app-signing-key, device, user). Falls back to a randomly-generated
     * UUID stashed in SharedPreferences if ANDROID_ID is unavailable
     * (very old Android, custom ROMs).
     *
     * Once Phase 9's [SankofaIdentity] ships, this method goes away and
     * the handshake reads from the unified identity store instead.
     */
    private fun stableAnonId(): String {
        val androidId = try {
            android.provider.Settings.Secure.getString(
                applicationContext.contentResolver,
                android.provider.Settings.Secure.ANDROID_ID,
            )
        } catch (_: Throwable) {
            null
        }
        if (!androidId.isNullOrBlank() && androidId != "9774d56d682e549c") {
            // 9774d56d682e549c is a known buggy default on some old devices.
            return androidId
        }
        // Fallback: persist a random UUID in our own prefs.
        val prefs = applicationContext.getSharedPreferences("sankofa_deploy", Context.MODE_PRIVATE)
        val existing = prefs.getString("anon_id", null)
        if (existing != null) return existing
        val fresh = UUID.randomUUID().toString()
        prefs.edit().putString("anon_id", fresh).apply()
        return fresh
    }

    private fun sha256OfFile(file: File): String {
        val md = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buf = ByteArray(8 * 1024)
            while (true) {
                val n = input.read(buf)
                if (n <= 0) break
                md.update(buf, 0, n)
            }
        }
        return md.digest().joinToString("") { "%02x".format(it) }
    }

    private fun runOnMain(block: () -> Unit) {
        Handler(Looper.getMainLooper()).post(block)
    }

    /**
     * Locate the customer's libapp.so inside the installed APK and copy it
     * to a writable location the Rust updater can hold a baseline reference
     * to. Modern Android keeps native libs unextracted inside base.apk (mmap
     * from the zip), so the updater can't reference them directly.
     *
     * Returns the on-disk path to libapp.so, or null if not found (debug
     * build, library missing, etc.).
     */
    private fun ensureBaselineExtracted(dataDir: File): File? {
        val baselineDir = File(dataDir, "baseline").apply { mkdirs() }
        val target = File(baselineDir, "libapp.so")
        if (target.exists() && target.length() > 0) return target

        val abi = android.os.Build.SUPPORTED_ABIS.firstOrNull() ?: return null
        val apkPath = applicationContext.applicationInfo.sourceDir
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
        private const val TAG = "SankofaDeploy"
        // Matches the version string emitted by GetFlutterEngineVersion() in
        // our Sankofa engine fork (Phase 3 marker). When the engine fork is
        // rebased to a new Flutter stable, update this constant in lockstep.
        private const val BASELINE_ENGINE_VERSION = "3.41.9+sankofa-1"

        /** Running engine version from Dart init; falls back to the baseline constant. */
        @Volatile private var engineVersion: String = BASELINE_ENGINE_VERSION

        // Reported in the User-Agent so server-side analytics can correlate
        // SDK versions with handshake outcomes. Bump when shipping a release.
        private const val RUNTIME_SDK = "0.1.0-dev"

        // SharedPreferences key for the human-readable label of the patch
        // most recently installed by this SDK (e.g. "v1.0.3-green"). The
        // Rust updater's state.json tracks only the synthesized PatchVersion
        // (e.g. "vdrl-d8e0a48f"); the original server-side label lives only
        // here and is what the server gates `already_on_latest` against.
        // Cleared automatically when the underlying patch is disabled.
        private const val PREF_CURRENT_LABEL = "current_bundle_label"
    }

    /**
     * Self-audit the host's Deploy wiring. Pure reflection — no
     * side effects. The Dart side reads this map and reports any
     * missing piece to the developer (and eventually the server via
     * the reverse handshake).
     *
     * Each field reports whether ONE host-side wiring requirement is
     * satisfied:
     *
     *  - applicationClass / sankofaDeployApplication: did the host set
     *    `android:name="com.sankofa.deploy.SankofaDeployApplication"`
     *    (or a subclass) on their `<application>`? Required for the
     *    Updater to initialize pre-Dart.
     *  - activityClass / sankofaFlutterActivity: does the current
     *    Activity extend `SankofaFlutterActivity`? Required so the
     *    Flutter engine launches with `--aot-shared-library-name`
     *    pointed at any staged patch.
     *  - internetPermission: is `android.permission.INTERNET` declared
     *    AND granted? Required for the updater to reach the server.
     *  - apiKeyMetaData / endpointMetaData: are the manifest meta-data
     *    keys set so the Updater can run pre-Dart?
     *  - updaterInitialized: did the JNI bridge load + init OK?
     */
    private fun checkIntegration(): Map<String, Any?> {
        val ctx = applicationContext
        val appInfo = ctx.applicationInfo
        val applicationClassName = appInfo.className ?: ""
        val sankofaDeployApp = isSubclassOf(applicationClassName, "com.sankofa.deploy.SankofaDeployApplication")

        // Best-effort current-Activity probe via ActivityThread reflection.
        // Returns null if Flutter hasn't attached an activity yet (very
        // early init); the Dart side treats null as "unknown, retry later".
        val activityClassName = currentActivityClassName()
        val sankofaActivity = activityClassName != null &&
            isSubclassOf(activityClassName, "com.sankofa.deploy.SankofaFlutterActivity")

        val internet = ctx.checkSelfPermission(android.Manifest.permission.INTERNET) ==
            android.content.pm.PackageManager.PERMISSION_GRANTED

        val metaData = try {
            val ai = ctx.packageManager.getApplicationInfo(
                ctx.packageName,
                android.content.pm.PackageManager.GET_META_DATA,
            )
            ai.metaData ?: android.os.Bundle()
        } catch (_: Throwable) {
            android.os.Bundle()
        }
        val hasApiKey = metaData.containsKey("com.sankofa.apiKey")
        val hasEndpoint = metaData.containsKey("com.sankofa.endpoint")

        return mapOf(
            "applicationClass" to applicationClassName,
            "activityClass" to activityClassName,
            "sankofaDeployApplication" to sankofaDeployApp,
            "sankofaFlutterActivity" to sankofaActivity,
            "internetPermission" to internet,
            "apiKeyMetaData" to hasApiKey,
            "endpointMetaData" to hasEndpoint,
            "updaterInitialized" to SankofaUpdaterJNI.isInitialized,
        )
    }

    /**
     * Returns true if [candidateClassName] resolves to a Class that
     * extends [ancestorClassName] (or is the ancestor itself). Returns
     * false for any reflection failure — we never throw on the audit
     * path because a missing class IS the answer we want.
     */
    private fun isSubclassOf(candidateClassName: String, ancestorClassName: String): Boolean {
        if (candidateClassName.isEmpty()) return false
        return try {
            val candidate = Class.forName(candidateClassName)
            val ancestor = Class.forName(ancestorClassName)
            ancestor.isAssignableFrom(candidate)
        } catch (_: Throwable) {
            false
        }
    }

    /**
     * Probe for the currently-foregrounded Activity via ActivityThread
     * reflection. Returns null if Flutter hasn't attached one yet (very
     * early in launch). Not foolproof — multi-activity apps will report
     * whichever Activity is currently resumed — but good enough for the
     * SankofaFlutterActivity audit because the MainActivity is the
     * canonical Flutter host.
     */
    private fun currentActivityClassName(): String? {
        return try {
            val activityThreadClass = Class.forName("android.app.ActivityThread")
            val currentActivityThread = activityThreadClass
                .getMethod("currentActivityThread")
                .invoke(null) ?: return null
            val activitiesField = activityThreadClass.getDeclaredField("mActivities")
            activitiesField.isAccessible = true
            val activities = activitiesField.get(currentActivityThread) as? Map<*, *> ?: return null
            for (record in activities.values) {
                if (record == null) continue
                val pausedField = record.javaClass.getDeclaredField("paused")
                pausedField.isAccessible = true
                val paused = pausedField.getBoolean(record)
                if (paused) continue
                val activityField = record.javaClass.getDeclaredField("activity")
                activityField.isAccessible = true
                val activity = activityField.get(record) as? android.app.Activity ?: continue
                return activity.javaClass.name
            }
            null
        } catch (_: Throwable) {
            null
        }
    }
}
