/*
 * sankofa_updater.h — C ABI surface of sankofa-updater-ffi.
 *
 * This header is the contract between the Rust updater core and any
 * native consumer that links the static library. Two consumers today:
 *
 *   1. The Sankofa Deploy CLI's own test/dev harnesses (host macOS +
 *      Linux), which dlopen the cdylib variant for integration tests.
 *
 *   2. The Sankofa Flutter SDK's iOS Pod (sankofa_flutter), which
 *      links the staticlib via the SankofaUpdaterFFI.xcframework
 *      bundle and calls these functions from
 *      SankofaUpdaterBridge.swift to bridge into the Dart layer.
 *
 * Stability: every symbol in this header is part of the public C ABI.
 * Breaking changes (renames, signature edits, ordering) require a
 * major-version bump of the crate AND coordinated updates on the
 * Flutter SDK + CLI consumers. Additive changes (new symbols, new
 * return-code values) are fine without coordination.
 *
 * The Java JNI bridge (Java_com_sankofa_deploy_SankofaUpdaterJNI_*)
 * lives in jni_bridge.rs and is NOT exposed here — Android does not
 * need this header. iOS consumers stay on the C ABI; the JNI exports
 * are platform-gated to target_os = "android".
 *
 * Thread-safety: all functions are safe to call from any thread. The
 * Rust core wraps its Manager in a Mutex; concurrent callers serialize
 * inside the FFI rather than at the call site.
 *
 * Pointer lifetimes: returned `const char *` strings live for the
 * lifetime of the program OR until the next call to
 * sankofa_updater_init, sankofa_updater_shutdown, or
 * sankofa_updater_disable_current_patch. Callers MUST NOT free them.
 */

#ifndef SANKOFA_UPDATER_H
#define SANKOFA_UPDATER_H

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Return codes from sankofa_updater_init and
 * sankofa_updater_disable_current_patch.
 *
 * SANKOFA_OK / SANKOFA_RECOVERED indicate success — the caller should
 * proceed. SANKOFA_RECOVERED additionally signals that the updater
 * detected an orphan boot (previous process didn't reach
 * notify_app_ready) and rolled back to the baseline; the active
 * version is now "baseline" again.
 *
 * SANKOFA_INVALID_INPUT and SANKOFA_FATAL are caller-facing errors.
 * Treat both as "do not use the updater this run" — the host app
 * should fall back to loading Flutter's APK-default snapshot.
 */
typedef enum {
    SANKOFA_OK             =  0,
    SANKOFA_INVALID_INPUT  =  1,
    SANKOFA_RECOVERED      =  2,
    SANKOFA_FATAL          =  3
} SankofaUpdaterReturnCode;

/*
 * Returns the crate's CARGO_PKG_VERSION as a static NUL-terminated
 * UTF-8 string. Useful for smoke-testing that the static lib was
 * linked correctly + version reporting from Swift/Dart.
 *
 * Never NULL. Caller MUST NOT free.
 */
const char *sankofa_updater_version(void);

/*
 * Initialize the updater. Call once from the host app's pre-engine
 * hook (Android: Application.onCreate; iOS:
 * SankofaFlutterAppDelegate.application:didFinishLaunchingWithOptions).
 *
 * All four pointers must be NUL-terminated UTF-8 strings:
 *   app_id                   — opaque identifier (typically the
 *                              package/bundle id of the host app).
 *   baseline_libapp_path     — absolute path to the AOT snapshot
 *                              shipped inside the app bundle. On
 *                              iOS, this is `<bundle>/Frameworks/
 *                              App.framework/App`.
 *   updater_data_dir         — writable per-app directory the updater
 *                              owns. On iOS, NSCachesDirectory.
 *   baseline_engine_version  — string from
 *                              flutter::GetFlutterEngineVersion(),
 *                              used to reject cross-engine patches.
 *
 * Returns one of SankofaUpdaterReturnCode. After success, the
 * sankofa_updater_get_* getters return non-NULL paths/versions.
 */
int sankofa_updater_init(const char *app_id,
                         const char *baseline_libapp_path,
                         const char *updater_data_dir,
                         const char *baseline_engine_version);

/*
 * Drop the updater singleton. Rarely called in production — mobile
 * platforms typically kill processes without graceful shutdown. Safe
 * to call before init (no-op).
 */
void sankofa_updater_shutdown(void);

/*
 * Returns the absolute filesystem path to the AOT snapshot the
 * Flutter engine should load. Either:
 *
 *   - the baseline_libapp_path passed to init (no patch installed),
 *   - a patch path inside updater_data_dir (active patch),
 *   - NULL (sankofa_updater_init has not been called, or returned
 *     SANKOFA_FATAL).
 *
 * Pointer is valid until the next call to sankofa_updater_init,
 * sankofa_updater_shutdown, or
 * sankofa_updater_disable_current_patch. MUST NOT be freed.
 *
 * Consumers pass this verbatim to the engine as
 * `--aot-shared-library-name=<path>`.
 */
const char *sankofa_updater_get_libapp_path(void);

/*
 * Returns `"baseline"` or a patch version string like `"v1.2.3-hotfix"`.
 * NULL when init has not been called. Same lifetime contract as
 * sankofa_updater_get_libapp_path.
 *
 * Surfaced to Dart through the SDK as
 * `Sankofa.instance.deploy?.activeVersion`.
 */
const char *sankofa_updater_get_active_version(void);

/*
 * Notify the updater that the first frame rendered without crashing.
 * Called from the Dart SDK after `runApp(...)` resolves. Promotes the
 * active patch — future cold boots continue serving it instead of
 * treating the active boot as a recovery candidate.
 *
 * No-op if init has not been called.
 */
void sankofa_updater_notify_app_ready(void);

/*
 * Record a crash event. Called from the platform's uncaught-exception
 * handler (NSException on iOS; uncaughtExceptionHandler on Android).
 * Does NOT by itself revert the patch — the next boot's init decides
 * based on the orphan-boot algorithm. No-op if init has not been
 * called.
 */
void sankofa_updater_report_crash(void);

/*
 * Manual revert: mark the currently active patch dead and switch
 * state to baseline for the next boot. Useful when the Dart layer or
 * dashboard wants to force a rollback without waiting for an orphan
 * boot.
 *
 * Returns:
 *   0  — no patch was active (no-op)
 *   1  — a patch was marked dead; caller should restart the app
 *  <0  — I/O failure persisting state
 */
int sankofa_updater_disable_current_patch(void);

#ifdef __cplusplus
}
#endif

#endif /* SANKOFA_UPDATER_H */
