import 'dart:io';
import 'dart:ui' as ui;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'utils/logger.dart';

class SankofaDeviceInfo {
  static Future<Map<String, String>> getProperties(SankofaLogger logger) async {
    final Map<String, String> props = {};
    final plugin = DeviceInfoPlugin();
    final packageInfo = await PackageInfo.fromPlatform();
    final connectivity = await Connectivity().checkConnectivity();

    // 1. App Info
    props['\$app_version'] = packageInfo.version;
    props['\$app_version_string'] = packageInfo.version;
    props['\$build_number'] = packageInfo.buildNumber;

    // 2. OS Info
    props['\$os'] = Platform.operatingSystem;
    
    // 3. Hardware & Network Info
    if (Platform.isAndroid) {
      final android = await plugin.androidInfo;
      props['\$os_version'] = android.version.release; 
      props['\$device_model'] = android.model;
      props['\$device_manufacturer'] = android.manufacturer;
      props['\$brand'] = android.brand;
      props['\$is_simulator'] = (!android.isPhysicalDevice).toString();
    } else if (Platform.isIOS) {
      final ios = await plugin.iosInfo;
      props['\$os_version'] = ios.systemVersion;
      props['\$device_model'] = ios.model;
      props['\$device_manufacturer'] = 'Apple';
      props['\$brand'] = 'Apple';
      props['\$is_simulator'] = (!ios.isPhysicalDevice).toString();
    }

    // Network status
    final isWifi = connectivity.contains(ConnectivityResult.wifi);
    props['\$wifi'] = isWifi.toString();
    props['\$network_type'] = connectivity.isNotEmpty ? connectivity.first.name : 'none';

    // 4. Display Info
    try {
      final view = ui.PlatformDispatcher.instance.views.first;
      props['\$screen_width'] = view.physicalSize.width.toInt().toString();
      props['\$screen_height'] = view.physicalSize.height.toInt().toString();
      
      // Calculate DPI (approximate)
      final dpi = (view.devicePixelRatio * 160).toInt();
      props['\$screen_dpi'] = dpi.toString();
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
