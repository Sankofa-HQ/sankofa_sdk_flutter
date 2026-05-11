import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Phase C — bridges the Dart-side `SankofaCatch` to the underlying
/// native iOS / Android Sankofa Catch modules so NSException + POSIX
/// signal crashes (iOS) and JVM-uncaught exceptions + ANRs (Android)
/// are reported alongside Dart-level errors.
///
/// The Dart side captures via `FlutterError.onError`,
/// `PlatformDispatcher.onError`, and isolate error listeners. The
/// native side captures via `NSSetUncaughtExceptionHandler` (iOS) and
/// `Thread.setDefaultUncaughtExceptionHandler` (Android). Both POST
/// to `/api/catch/events` independently — sessions correlate by the
/// host app's distinct_id, and event types differ (`unhandled_exception`
/// vs `anr` vs `console_error`) so there's no dedup needed.
///
/// On platforms other than iOS / Android (tests, web, desktop) every
/// method here is a no-op — the channel isn't registered so calls
/// throw `MissingPluginException`, which we swallow.
class SankofaNativeCatchBridge {
  static const _channel = MethodChannel('sankofa_flutter/native_catch');

  /// True on platforms where the native plugin can run. Web and tests
  /// always return false; the Dart-side handlers still catch Dart
  /// errors on those platforms.
  static bool get isSupported {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
  }

  /// Bootstrap the native SankofaCatch with the credentials the Dart
  /// SDK is using. Called from `Sankofa.instance.init(...)` AFTER the
  /// Dart-side Catch singleton is constructed, so by the time a
  /// native crash fires both layers are listening.
  ///
  /// Best-effort: failures are logged in debug builds but never
  /// thrown — losing native crash reporting must NEVER prevent the
  /// Dart-side SDK from booting.
  static Future<void> initialize({
    required String apiKey,
    required String endpoint,
    String environment = 'live',
    String? release,
    String? appVersion,
    double stallThresholdSeconds = 2.0,
  }) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('initializeNativeCatch', {
        'apiKey': apiKey,
        'endpoint': endpoint,
        'environment': environment,
        'release': release,
        'appVersion': appVersion,
        'stallThresholdSeconds': stallThresholdSeconds,
      });
    } on MissingPluginException {
      // Plugin not registered (tests, web, headless engines). Dart
      // side still functions; native crashes go uncaught.
      if (kDebugMode) {
        debugPrint(
          '[Sankofa Catch] native bridge unavailable on this platform — '
          'Dart-side Catch will still report Dart errors',
        );
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[Sankofa Catch] native bridge initialize failed: $e');
      }
    }
  }

  /// Forward ambient user identity to the native side so a crash that
  /// fires after `Sankofa.instance.setUser(...)` carries the same id.
  /// Pass `null` to clear (e.g. on logout).
  static Future<void> setUser({
    String? id,
    String? email,
    String? username,
  }) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('setUser', {
        'id': id,
        'email': email,
        'username': username,
      });
    } on MissingPluginException {
      // Same fallback as initialize().
    } catch (_) {
      // Best-effort.
    }
  }

  /// Forward ambient tags to the native side.
  static Future<void> setTags(Map<String, String> tags) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('setTags', {'tags': tags});
    } on MissingPluginException {
      // Best-effort.
    } catch (_) {
      // Best-effort.
    }
  }

  /// Force-flush any queued native crash events. The native side has
  /// its own periodic flush timer; call this only when you need an
  /// immediate evacuation (e.g. before a known process exit).
  static Future<void> flush() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('flush');
    } on MissingPluginException {
      // Best-effort.
    } catch (_) {
      // Best-effort.
    }
  }
}
