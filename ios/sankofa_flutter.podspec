#
# Phase C — Flutter plugin podspec (standalone native crash reporter).
#
# Bridges the Dart-side `SankofaCatch` to a minimal iOS native crash
# reporter living entirely inside this plugin's `Classes/` directory.
# We deliberately do NOT depend on the standalone `SankofaIOS` Pod —
# the iOS SDK is a separate product for native iOS apps; the Flutter
# package owns its own implementation so a Flutter host doesn't pull
# in the iOS SDK's analytics/replay/Pulse code.
#
# What this plugin captures:
#   - NSException (Objective-C throws, KVO crashes, framework asserts)
#     via NSSetUncaughtExceptionHandler.
#   - POSIX signals (SIGSEGV/SIGABRT/SIGBUS/SIGILL/SIGFPE/SIGTRAP/SIGSYS)
#     via sigaction handlers writing an async-signal-safe dump.
#   - Main-queue stalls (configurable threshold, default 2s).
#
# Events are POSTed to the same `/api/catch/events` endpoint the Dart
# side uses. The Dart side keeps catching `FlutterError.onError`,
# `PlatformDispatcher.onError`, and isolate errors — the plugin is
# the missing piece below the Dart layer.
#
Pod::Spec.new do |s|
  s.name             = 'sankofa_flutter'
  s.version          = '0.1.0'
  s.summary          = 'Native crash bridging for the Sankofa Flutter SDK.'
  s.description      = <<-DESC
Forwards NSException + POSIX signal crashes from iOS to the same
Sankofa Catch ingest endpoint the Dart-side SDK uses, giving Flutter
apps a unified error feed without writing native code or depending on
the standalone iOS SDK.
                       DESC
  s.homepage         = 'https://sankofa.dev'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Sankofa' => 'hello@sankofa.dev' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end
