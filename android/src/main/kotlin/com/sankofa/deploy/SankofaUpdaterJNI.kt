package com.sankofa.deploy

object SankofaUpdaterJNI {

    init {
        System.loadLibrary("sankofa_updater_ffi")
    }

    /**
     * True once any caller has successfully invoked [nativeInit]. Read by
     * the [SankofaDeployPlugin] to short-circuit the Dart-side init when
     * [SankofaDeployApplication] has already run pre-engine. Volatile so
     * the activity thread sees the Application thread's write.
     */
    @Volatile
    var isInitialized: Boolean = false

    /**
     * Sankofa API key (`sk_live_*` / `sk_test_*`). Set by whichever code
     * path initializes the updater first ([SankofaDeployApplication] from
     * manifest meta-data, or [SankofaDeployPlugin] from the Dart-side
     * config). Read by [SankofaDeployPlugin.checkForUpdate] to populate
     * the `x-api-key` header.
     */
    @Volatile
    var apiKey: String? = null

    /**
     * Sankofa API endpoint base URL (e.g. `https://api.sankofa.dev`).
     * Same lifecycle as [apiKey]. Trailing slashes are stripped at write
     * time so URL construction is unambiguous.
     */
    @Volatile
    var endpoint: String? = null

    external fun nativeInit(
        appId: String,
        baselineLibappPath: String,
        dataDir: String,
        baselineEngineVersion: String,
    ): Int

    external fun nativeShutdown()
    external fun nativeVersion(): String
    external fun nativeGetLibappPath(): String?
    external fun nativeGetActiveVersion(): String?
    external fun nativeNotifyAppReady()
    external fun nativeReportCrash()
    external fun nativeDisableCurrentPatch(): Int

    /**
     * Install a downloaded patch (Phase 8).
     *
     * The Kotlin Plugin calls this after streaming a libapp.so download
     * to a path inside the app's data dir AND attesting its SHA matches
     * what the server returned. The Rust updater re-verifies the SHA
     * (defense in depth), atomically moves the file into
     * `patches/<version>/libapp.so`, writes a manifest.json, and flips
     * state.json to point at this new active patch.
     *
     * @param version e.g. "v1.2.3-hotfix" — matches PatchVersion grammar
     * @param sourceLibappPath absolute path to the staged libapp.so on
     *   the same filesystem as the data dir
     * @param expectedSha256 64 lowercase hex chars, attested by server
     * @return one of [SankofaUpdaterReturnCode]:
     *   - 0 = OK, patch installed, restart to apply
     *   - 1 = invalid input (bad version/path/SHA, OR SHA mismatch)
     *   - 3 = fatal I/O error
     *   - -1 = caller hasn't run nativeInit yet
     */
    external fun nativeInstallPatch(
        version: String,
        sourceLibappPath: String,
        expectedSha256: String,
    ): Int
}

/** Mirrors the C-side SANKOFA_* constants for readability. */
object SankofaUpdaterReturnCode {
    const val OK: Int = 0
    const val INVALID_INPUT: Int = 1
    const val RECOVERED: Int = 2
    const val FATAL: Int = 3
    const val NOT_INITIALIZED: Int = -1
}
