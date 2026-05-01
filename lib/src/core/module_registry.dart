import 'package:flutter/foundation.dart';

/// # Traffic Cop — Module Registry
///
/// The Core SDK needs to know what modules the developer actually
/// installed, not what the server *thinks* is available. Without this,
/// a dashboard toggle could try to activate a module whose code isn't
/// loaded, crashing the app.
///
/// Every module (Deploy, Catch, future additions) registers itself
/// with the Core at construction time. When the handshake response
/// arrives, the Core routes each enabled module flag to the
/// corresponding registered handler. Flags for modules that aren't
/// registered are:
///
///  - **Debug mode:** logged as a warning so engineers know they
///    forgot to install or import the module.
///  - **Release mode:** silently ignored. The app never crashes from
///    a dashboard toggle.
///
/// Also owns the `installed_modules` list reported back to the server
/// in the Reverse Handshake so the dashboard can show
/// "SDK Not Detected" states for modules the app binary lacks.

/// Canonical module names Sankofa ships.
///
/// The `-Module` suffix on `catchModule`, `switchModule`, `configModule`
/// avoids clashes with Dart keywords (`catch`, `switch`) and common
/// stdlib names. The wire name (what the server speaks) stays clean.
enum SankofaModuleName {
  analytics,
  deploy,
  catchModule,
  switchModule,
  configModule,
  pulseModule,
}

extension SankofaModuleNameExt on SankofaModuleName {
  String get wireName {
    switch (this) {
      case SankofaModuleName.analytics:
        return 'analytics';
      case SankofaModuleName.deploy:
        return 'deploy';
      case SankofaModuleName.catchModule:
        return 'catch';
      case SankofaModuleName.switchModule:
        return 'switch';
      case SankofaModuleName.configModule:
        return 'config';
      case SankofaModuleName.pulseModule:
        return 'pulse';
    }
  }
}

/// Interface every pluggable module implements. The Core never imports
/// concrete module classes — it only talks to them through this shape.
abstract class SankofaModule {
  SankofaModuleName get name;

  /// Called by the Core when the handshake response says this module is
  /// enabled. The module starts its work (e.g. Deploy kicks off an
  /// update check). If `enabled: false`, this is NOT called — the
  /// module stays dormant.
  Future<void> applyHandshake(Map<String, dynamic> config);
}

class SankofaModuleRegistry {
  static final SankofaModuleRegistry instance = SankofaModuleRegistry._();
  SankofaModuleRegistry._();

  final Map<SankofaModuleName, SankofaModule> _registered = {};
  bool _coreInitialized = false;

  /// Called once by `Sankofa.instance.init()` to flip the core-ready flag.
  void markCoreInitialized() {
    _coreInitialized = true;
  }

  bool get isCoreInitialized => _coreInitialized;

  /// Register a module with the Core. Called from each module's init path.
  void register(SankofaModule module) {
    _registered[module.name] = module;

    if (kDebugMode && !_coreInitialized) {
      debugPrint(
        '[Sankofa] ${module.name.wireName} module was registered before '
        'Sankofa.instance.init(). Call init() first so the module can '
        'read your API key and endpoint.',
      );
    }
  }

  void unregister(SankofaModuleName name) {
    _registered.remove(name);
  }

  bool has(SankofaModuleName name) => _registered.containsKey(name);

  /// Returns the list of module names the app binary actually ships with.
  /// Analytics is always present (it IS the core).
  List<String> getInstalledModules() {
    final modules = <String>['analytics'];
    for (final name in _registered.keys) {
      if (name != SankofaModuleName.analytics) {
        modules.add(name.wireName);
      }
    }
    return modules;
  }

  /// The Traffic Cop. Called by the handshake handler when the server
  /// response arrives. Routes each enabled module flag to its registered
  /// handler; warns (debug) or silently no-ops (release) for flags that
  /// reference modules the developer didn't install.
  Future<void> routeHandshake(Map<String, dynamic>? modules) async {
    if (modules == null) return;

    // Deploy
    final deploy = modules['deploy'] as Map<String, dynamic>?;
    if (deploy != null && deploy['enabled'] == true) {
      final mod = _registered[SankofaModuleName.deploy];
      if (mod != null) {
        await mod.applyHandshake(deploy);
      } else if (kDebugMode) {
        debugPrint(
          '[Sankofa] Server enabled "deploy" but Deploy module is not '
          'installed. Add the Deploy SDK to enable OTA updates.',
        );
      }
    }

    // Catch (ships later)
    final catchConfig = modules['catch'] as Map<String, dynamic>?;
    if (catchConfig != null && catchConfig['enabled'] == true) {
      final mod = _registered[SankofaModuleName.catchModule];
      if (mod != null) {
        await mod.applyHandshake(catchConfig);
      } else if (kDebugMode) {
        debugPrint(
          '[Sankofa] Server enabled "catch" but SankofaCatch is not '
          'installed. Add the Catch SDK to enable crash reporting.',
        );
      }
    }

    // Switch — feature flags
    final switchCfg = modules['switch'] as Map<String, dynamic>?;
    if (switchCfg != null && switchCfg['enabled'] == true) {
      final mod = _registered[SankofaModuleName.switchModule];
      if (mod != null) {
        await mod.applyHandshake(switchCfg);
      } else if (kDebugMode) {
        debugPrint(
          '[Sankofa] Server enabled "switch" but SankofaSwitch is not '
          'installed. Import sankofa_flutter and instantiate '
          'SankofaSwitch() after Sankofa.instance.init().',
        );
      }
    }

    // Config — remote config
    final configCfg = modules['config'] as Map<String, dynamic>?;
    if (configCfg != null && configCfg['enabled'] == true) {
      final mod = _registered[SankofaModuleName.configModule];
      if (mod != null) {
        await mod.applyHandshake(configCfg);
      } else if (kDebugMode) {
        debugPrint(
          '[Sankofa] Server enabled "config" but SankofaConfig is not '
          'installed. Import sankofa_flutter and instantiate '
          'SankofaConfig() after Sankofa.instance.init().',
        );
      }
    }

    // Pulse — in-app surveys
    final pulseCfg = modules['pulse'] as Map<String, dynamic>?;
    if (pulseCfg != null && pulseCfg['enabled'] == true) {
      final mod = _registered[SankofaModuleName.pulseModule];
      if (mod != null) {
        await mod.applyHandshake(pulseCfg);
      } else if (kDebugMode) {
        debugPrint(
          '[Sankofa] Server enabled "pulse" but SankofaPulse is not '
          'installed. Call SankofaPulse.instance.register() after '
          'Sankofa.instance.init().',
        );
      }
    }
  }
}
