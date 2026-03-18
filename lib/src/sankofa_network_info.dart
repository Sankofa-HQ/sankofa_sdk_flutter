import 'dart:io';
import 'package:carrier_info/carrier_info.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'utils/logger.dart';

class SankofaNetworkInfo {
  static Future<Map<String, String>> getProperties(SankofaLogger logger) async {
    final Map<String, String> props = {};
    try {
      // Check Wi-Fi vs Cellular
      final connectivityResult = await Connectivity().checkConnectivity();
      props['\$wifi'] = connectivityResult.contains(ConnectivityResult.wifi)
          .toString();

      // Check Telecom Carrier
      if (Platform.isAndroid) {
        final carrierData = await CarrierInfo.getAndroidInfo();
        if (carrierData != null && carrierData.telephonyInfo.isNotEmpty) {
          final name = carrierData.telephonyInfo.first.carrierName;
          if (name.isNotEmpty) {
            props['\$carrier'] = name;
          }
        }
      } else if (Platform.isIOS) {
        final carrierData = await CarrierInfo.getIosInfo();
        if (carrierData.carrierData.isNotEmpty) {
          final name = carrierData.carrierData.first.carrierName;
          if (name != null && name.isNotEmpty) {
            props['\$carrier'] = name;
          }
        }
      }
    } catch (e) {
      logger.log('⚠️ Could not load network info: $e');
    }
    return props;
  }
}
