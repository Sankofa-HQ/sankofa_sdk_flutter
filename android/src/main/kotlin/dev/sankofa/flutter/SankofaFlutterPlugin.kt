package dev.sankofa.flutter

import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.UUID
import java.util.concurrent.ConcurrentLinkedDeque
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Phase C — Android half of the Flutter native-crash bridge.
 *
 * **Standalone**: this file ships entirely inside the Flutter plugin —
 * no dependency on the public `dev.sankofa:sankofa` Maven artifact.
 * The Android SDK is a separate product for native Android apps;
 * Flutter apps already own their analytics + replay surface in Dart
 * and only need the crash-reporting piece below the Dart layer.
 *
 * Coverage on top of Dart-side `FlutterError.onError` /
 * `PlatformDispatcher.onError` / isolate listeners:
 *   - **JVM uncaught exceptions** via chained
 *     `Thread.setDefaultUncaughtExceptionHandler` (NPEs from Java
 *     callbacks invoked by Flutter platform channels, OOM from native
 *     bitmap allocations, etc.).
 *   - **ANRs** (main thread wedged) via background-thread sentinel
 *     pings against the main looper (configurable threshold; 5s
 *     default matches Android's own ANR dialog timing).
 *
 * Events POST to `<endpoint>/api/catch/events` with the same wire
 * shape the Dart side uses.
 */
class SankofaFlutterPlugin : FlutterPlugin, MethodCallHandler {

    private lateinit var channel: MethodChannel
    private var appContext: Context? = null

    /**
     * Sankofa Deploy plugin — packaged inside this SDK so the host's
     * MainActivity can extend `com.sankofa.deploy.SankofaFlutterActivity`
     * without having to pull a separate plugin dependency. Lifecycle is
     * delegated from our own `onAttachedToEngine` / `onDetachedFromEngine`
     * so a single `pluginClass: SankofaFlutterPlugin` registration in
     * pubspec.yaml wires up both the native crash bridge and the Deploy
     * method channel.
     */
    private val deployPlugin = com.sankofa.deploy.SankofaDeployPlugin()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "sankofa_flutter/native_catch")
        channel.setMethodCallHandler(this)
        deployPlugin.onAttachedToEngine(binding)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        appContext = null
        deployPlugin.onDetachedFromEngine(binding)
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "initializeNativeCatch" -> handleInitialize(call, result)
            "setUser" -> handleSetUser(call, result)
            "setTags" -> handleSetTags(call, result)
            "flush" -> {
                SankofaCatchCore.flush()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun handleInitialize(call: MethodCall, result: Result) {
        val ctx = appContext ?: run {
            result.error("ERR_NO_CONTEXT", "Plugin context not attached", null)
            return
        }
        val apiKey = call.argument<String>("apiKey")
        val endpoint = call.argument<String>("endpoint")
        if (apiKey.isNullOrEmpty() || endpoint.isNullOrEmpty()) {
            result.error(
                "ERR_INVALID_ARGS",
                "initializeNativeCatch requires non-empty apiKey + endpoint",
                null
            )
            return
        }
        val environment = call.argument<String>("environment") ?: "live"
        val release = call.argument<String>("release")
        val appVersion = call.argument<String>("appVersion")
        val stallThreshold = (call.argument<Double>("stallThresholdSeconds") ?: 2.0)
        // Android's own ANR dialog fires at ~5s — match it by default
        // when the Dart side passes 2.0 (the iOS-friendly default)
        // because a 2-second flag would be too noisy on Android.
        val anrThresholdMs = if (stallThreshold < 5.0) 5000L else (stallThreshold * 1000).toLong()

        SankofaCatchCore.start(
            context = ctx,
            apiKey = apiKey,
            endpoint = endpoint,
            environment = environment,
            release = release,
            appVersion = appVersion,
            anrThresholdMs = anrThresholdMs,
        )
        result.success(null)
    }

    @Suppress("UNCHECKED_CAST")
    private fun handleSetUser(call: MethodCall, result: Result) {
        val args = call.arguments as? Map<String, Any?>
        if (args == null) {
            SankofaCatchCore.setUser(null)
            result.success(null)
            return
        }
        val id = args["id"] as? String
        val email = args["email"] as? String
        val username = args["username"] as? String
        if (id == null && email == null && username == null) {
            SankofaCatchCore.setUser(null)
        } else {
            SankofaCatchCore.setUser(SankofaCatchUser(id = id, email = email, username = username))
        }
        result.success(null)
    }

    @Suppress("UNCHECKED_CAST")
    private fun handleSetTags(call: MethodCall, result: Result) {
        val tags = call.argument<Map<String, String>>("tags")
        if (tags == null) {
            result.error("ERR_INVALID_ARGS", "setTags requires a tags map", null)
            return
        }
        SankofaCatchCore.setTags(tags)
        result.success(null)
    }
}

// ── Core types ─────────────────────────────────────────────────────

data class SankofaCatchUser(
    val id: String? = null,
    val email: String? = null,
    val username: String? = null,
)

// ── SankofaCatchCore — standalone native crash reporter ────────────

internal object SankofaCatchCore {
    private const val TAG = "SankofaFlutterCatch"
    private const val PREFS_NAME = "sankofa.flutter.catch"
    private const val KEY_QUEUE = "queue"
    private const val FLUSH_INTERVAL_MS = 5_000L
    private const val BATCH_SIZE = 20

    private val lock = Any()
    private var apiKey: String = ""
    private var endpoint: String = ""
    private var environment: String = "live"
    private var release: String? = null
    private var appVersion: String? = null
    private var user: SankofaCatchUser? = null
    private val tags: MutableMap<String, String> = mutableMapOf()

    private val buffer: ConcurrentLinkedDeque<JSONObject> = ConcurrentLinkedDeque()
    private var prefs: SharedPreferences? = null
    private var previousHandler: Thread.UncaughtExceptionHandler? = null
    private val handlerInstalled = AtomicBoolean(false)
    private val started = AtomicBoolean(false)
    private val flusher = Executors.newSingleThreadScheduledExecutor { r ->
        Thread(r, "sankofa-flutter-catch-flusher").apply { isDaemon = true }
    }
    private var anrWatcher: AnrWatcher? = null

    fun start(
        context: Context,
        apiKey: String,
        endpoint: String,
        environment: String,
        release: String?,
        appVersion: String?,
        anrThresholdMs: Long,
    ) {
        synchronized(lock) {
            this.apiKey = apiKey
            this.endpoint = endpoint
            this.environment = environment
            this.release = release
            this.appVersion = appVersion
            if (prefs == null) {
                prefs = context.applicationContext
                    .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                hydrateFromStorage()
            }
        }
        if (!started.compareAndSet(false, true)) return

        installGlobalHandler()
        flusher.scheduleAtFixedRate(
            { runCatching { flushInternal() } },
            FLUSH_INTERVAL_MS,
            FLUSH_INTERVAL_MS,
            TimeUnit.MILLISECONDS
        )
        if (anrThresholdMs > 0) {
            val watcher = AnrWatcher(thresholdMs = anrThresholdMs) { duration ->
                captureAnr(duration)
            }
            watcher.start()
            anrWatcher = watcher
        }
    }

    fun setUser(u: SankofaCatchUser?) {
        synchronized(lock) { user = u }
    }

    fun setTags(t: Map<String, String>) {
        synchronized(lock) { tags.putAll(t) }
    }

    fun flush() {
        flusher.execute { runCatching { flushInternal() } }
    }

    // ── Capture path ──────────────────────────────────────────────

    private fun installGlobalHandler() {
        if (!handlerInstalled.compareAndSet(false, true)) return
        previousHandler = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            try {
                val event = composeException(
                    type = "unhandled_exception",
                    level = "fatal",
                    mechanism = "uncaught_exception_handler",
                    handled = false,
                    throwable = throwable,
                    threadName = thread.name,
                )
                buffer.addFirst(event)
                persistToStorage()
                // Best-effort synchronous flush so the event lands
                // before the process dies.
                runCatching { flushInternalSync() }
            } catch (err: Throwable) {
                Log.e(TAG, "uncaught handler itself threw: ${err.message}")
            }
            previousHandler?.uncaughtException(thread, throwable)
        }
    }

    private fun captureAnr(durationMs: Long) {
        val event = composeBase("anr", "warning")
            .put(
                "exception",
                JSONObject()
                    .put("type", "ApplicationNotResponding")
                    .put("value", "Main thread blocked for ${durationMs} ms")
                    .put(
                        "mechanism",
                        JSONObject()
                            .put("type", "main_queue_stall")
                            .put("handled", false)
                    )
            )
        buffer.add(event)
        persistToStorage()
    }

    private fun composeException(
        type: String,
        level: String,
        mechanism: String,
        handled: Boolean,
        throwable: Throwable,
        threadName: String?,
    ): JSONObject {
        val frames = JSONArray()
        for (frame in throwable.stackTrace) {
            frames.put(
                JSONObject()
                    .put("function", frame.methodName)
                    .put("module", frame.className)
                    .put("filename", frame.fileName ?: "")
                    .put("lineno", frame.lineNumber)
                    .put("in_app", !frame.className.startsWith("java.") &&
                            !frame.className.startsWith("android.") &&
                            !frame.className.startsWith("dalvik.") &&
                            !frame.className.startsWith("kotlin."))
            )
        }
        val mech = JSONObject()
            .put("type", mechanism)
            .put("handled", handled)
        if (threadName != null) mech.put("description", "thread=$threadName")
        val exc = JSONObject()
            .put("type", throwable.javaClass.simpleName)
            .put("value", throwable.message ?: "")
            .put("module", throwable.javaClass.`package`?.name ?: "")
            .put("mechanism", mech)
            .put("stacktrace", JSONObject().put("frames", frames))
        return composeBase(type, level).put("exception", exc)
    }

    private fun composeBase(type: String, level: String): JSONObject {
        val sdk = JSONObject()
            .put("name", "sankofa.flutter.android")
            .put("version", "flutter-android-0.1.0")
        val event = JSONObject()
            .put("wire_version", 1)
            .put("event_id", UUID.randomUUID().toString())
            .put("ts_ms", System.currentTimeMillis())
            .put("environment", environment)
            .put("level", level)
            .put("type", type)
            .put("platform", "android")
            .put("sdk", sdk)
        release?.let { event.put("release", it) }
        synchronized(lock) {
            if (tags.isNotEmpty()) {
                val t = JSONObject()
                for ((k, v) in tags) t.put(k, v)
                event.put("tags", t)
            }
            user?.let { u ->
                val obj = JSONObject()
                u.id?.let { obj.put("id", it) }
                u.email?.let { obj.put("email", it) }
                u.username?.let { obj.put("username", it) }
                event.put("user", obj)
            }
        }
        event.put("device", buildDeviceContext())
        return event
    }

    private fun buildDeviceContext(): JSONObject {
        val device = JSONObject()
            .put("os", "Android")
            .put("os_version", Build.VERSION.RELEASE ?: "")
            .put("model", Build.MODEL ?: "")
            .put("arch", Build.SUPPORTED_ABIS.firstOrNull() ?: "")
            .put("locale", java.util.Locale.getDefault().toString())
        appVersion?.let { device.put("app_version", it) }
        return device
    }

    // ── Persistence ───────────────────────────────────────────────

    private fun hydrateFromStorage() {
        val raw = prefs?.getString(KEY_QUEUE, null) ?: return
        try {
            val arr = JSONArray(raw)
            for (i in 0 until arr.length()) {
                buffer.add(arr.getJSONObject(i))
            }
        } catch (_: Throwable) {
            prefs?.edit()?.remove(KEY_QUEUE)?.apply()
        }
    }

    private fun persistToStorage() {
        val snapshot = buffer.toList()
        if (snapshot.isEmpty()) {
            prefs?.edit()?.remove(KEY_QUEUE)?.apply()
            return
        }
        val arr = JSONArray()
        for (e in snapshot) arr.put(e)
        prefs?.edit()?.putString(KEY_QUEUE, arr.toString())?.apply()
    }

    // ── Transport ─────────────────────────────────────────────────

    private fun flushInternal() {
        if (buffer.isEmpty() || endpoint.isEmpty() || apiKey.isEmpty()) return
        val drained = mutableListOf<JSONObject>()
        while (drained.size < BATCH_SIZE) {
            val e = buffer.pollFirst() ?: break
            drained.add(e)
        }
        if (drained.isEmpty()) return

        val url = URL("${endpoint.trimEnd('/')}/api/catch/events")
        val body = JSONObject().put("wire_version", 1).put(
            "events",
            JSONArray().also { for (e in drained) it.put(e) }
        ).toString()
        try {
            val conn = url.openConnection() as HttpURLConnection
            conn.requestMethod = "POST"
            conn.doOutput = true
            conn.setRequestProperty("Content-Type", "application/json")
            conn.setRequestProperty("x-api-key", apiKey)
            conn.connectTimeout = 5_000
            conn.readTimeout = 10_000
            conn.outputStream.use { it.write(body.toByteArray()) }
            val code = conn.responseCode
            conn.disconnect()
            if (code < 500) return
        } catch (err: Throwable) {
            Log.w(TAG, "flush failed, requeueing batch: ${err.message}")
        }
        for (e in drained.reversed()) buffer.addFirst(e)
        persistToStorage()
    }

    /**
     * Synchronous flush used by the uncaught-exception handler. The
     * JVM is about to terminate; we can't queue through the executor
     * because the executor's thread will be killed.
     */
    private fun flushInternalSync() {
        if (buffer.isEmpty() || endpoint.isEmpty() || apiKey.isEmpty()) return
        val drained = mutableListOf<JSONObject>()
        while (drained.size < BATCH_SIZE) {
            val e = buffer.pollFirst() ?: break
            drained.add(e)
        }
        if (drained.isEmpty()) return
        val url = URL("${endpoint.trimEnd('/')}/api/catch/events")
        val body = JSONObject().put("wire_version", 1).put(
            "events",
            JSONArray().also { for (e in drained) it.put(e) }
        ).toString()
        try {
            val conn = url.openConnection() as HttpURLConnection
            conn.requestMethod = "POST"
            conn.doOutput = true
            conn.setRequestProperty("Content-Type", "application/json")
            conn.setRequestProperty("x-api-key", apiKey)
            conn.connectTimeout = 2_000
            conn.readTimeout = 2_000
            conn.outputStream.use { it.write(body.toByteArray()) }
            conn.responseCode
            conn.disconnect()
        } catch (_: Throwable) {
            // Best-effort — the process is dying anyway.
            for (e in drained.reversed()) buffer.addFirst(e)
            persistToStorage()
        }
    }
}

// ── ANR watcher (background ping → main looper sentinel) ───────────

internal class AnrWatcher(
    private val thresholdMs: Long,
    private val onAnr: (Long) -> Unit,
) {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val watcher = Executors.newSingleThreadScheduledExecutor { r ->
        Thread(r, "sankofa-flutter-anr").apply { isDaemon = true }
    }
    @Volatile private var lastObservedMs: Long = 0L
    @Volatile private var reported = false

    fun start() {
        lastObservedMs = System.currentTimeMillis()
        // Sample at threshold/4 — coarse enough to be cheap, fine
        // enough that we report within ~1.25s of the threshold for
        // a 5s default.
        val interval = (thresholdMs / 4L).coerceAtLeast(250L)
        watcher.scheduleAtFixedRate(
            { runCatching { tick() } },
            interval, interval, TimeUnit.MILLISECONDS
        )
    }

    private fun tick() {
        val now = System.currentTimeMillis()
        val gap = now - lastObservedMs
        if (gap >= thresholdMs && !reported) {
            reported = true
            onAnr(gap)
        }
        // Schedule a sentinel on the main looper — when it runs we
        // know main is responsive again.
        mainHandler.post {
            lastObservedMs = System.currentTimeMillis()
            if (reported) reported = false
        }
    }
}
