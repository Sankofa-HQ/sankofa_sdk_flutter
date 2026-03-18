import 'dart:io';
import 'dart:ui' as ui;
import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'utils/logger.dart';

class SankofaDeviceInfo {
  static Future<Map<String, String>> getProperties(SankofaLogger logger) async {
    final Map<String, String> props = {};
    final plugin = DeviceInfoPlugin();
    final packageInfo = await PackageInfo.fromPlatform();

    // 1. App Info
    props['\$app_version'] = packageInfo.version;
    props['\$build_number'] = packageInfo.buildNumber;

    // 2. OS Info
    props['\$os'] = Platform.operatingSystem;
    props['\$os_version'] = Platform.operatingSystemVersion;

    // 3. Hardware Info
    if (Platform.isAndroid) {
      final android = await plugin.androidInfo;
      props['\$device_model'] = android.model;
      props['\$device_manufacturer'] = android.manufacturer;
      props['\$is_simulator'] = (!android.isPhysicalDevice).toString();
    } else if (Platform.isIOS) {
      final ios = await plugin.iosInfo;
      props['\$device_model'] = ios.model;
      props['\$device_manufacturer'] = 'Apple';
      props['\$is_simulator'] = (!ios.isPhysicalDevice).toString();
    }

    // 4. Display Info
    try {
      final view = ui.PlatformDispatcher.instance.views.first;
      props['\$screen_width'] = view.physicalSize.width.toString();
      props['\$screen_height'] = view.physicalSize.height.toString();
    } catch (e) {
      logger.log('⚠️ Could not load screen dimensions');
    }

    // 5. Locale & Timezone Info
    props['\$timezone'] = DateTime.now().timeZoneName;
    try {
      final locale = ui.PlatformDispatcher.instance.locale;
      props['\$locale'] = locale.toLanguageTag();
    } catch (e) {
      logger.log('⚠️ Could not load locale');
    }

    return props;
  }
}
