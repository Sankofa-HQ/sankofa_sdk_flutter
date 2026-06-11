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

  # Apple Privacy Manifest (mandatory since May 2024). Shipped as a resource
  # bundle so it lands in <App>.app/Frameworks/sankofa_flutter_privacy.bundle/
  # exactly like every other Flutter plugin in the ecosystem. Apple's App
  # Store Connect validator will reject the upload with ITMS-91061 without it.
  # The vendored xcframework slices each carry their own PrivacyInfo.xcprivacy
  # for the Rust updater's data flows.
  s.resource_bundles = {
    'sankofa_flutter_privacy' => ['Resources/PrivacyInfo.xcprivacy']
  }

  # Phase 6 (Sankofa Deploy OTA): vendor the Rust updater xcframework
  # built by flutter-deploy/sankofa-flutter-deploy/updater/build-ios.sh.
  # Xcode picks ios-arm64 for devices, ios-arm64_x86_64-simulator for
  # both Apple Silicon and Intel simulators. The framework ships the
  # sankofa_updater.h umbrella header + module.modulemap so
  # SankofaUpdaterBridge.swift can `import SankofaUpdaterFFI` directly.
  s.vendored_frameworks = 'SankofaUpdaterFFI.xcframework'

  # Flutter.framework does not contain a i386 slice. iOS 13+ has been
  # arm64-only on devices since iOS 11, so the Excluded arch on sim is
  # purely belt-and-braces.
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    # Static-lib symbols are namespaced via the umbrella header; tell
    # Xcode where to find the module map so `import SankofaUpdaterFFI`
    # resolves at compile time without bridging-header gymnastics.
    # The modulemap lives per-slice inside the vendored xcframework, so
    # the include path must match the active SDK — a single device-only
    # path breaks simulator builds with "Unable to resolve module
    # dependency: SankofaUpdaterFFI".
    # No SWIFT_INCLUDE_PATHS / module overrides for SankofaUpdaterFFI.
    # The FFI surface (Classes/sankofa_updater.h, kept in sync by
    # build-ios.sh) is a public header of this pod, so Swift sees the C
    # declarations through the pod's own underlying clang module. Every
    # external-module route (xcframework Headers modulemap) proved racy
    # under Xcode 26: the explicit-module scanner runs before CocoaPods'
    # copy phase on clean builds, and a SWIFT_INCLUDE_PATHS copy of the
    # map collides with the copied one ("Redefinition of module").
  }
  s.swift_version = '5.0'
end
