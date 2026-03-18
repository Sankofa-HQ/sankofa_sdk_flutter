import 'dart:async';
import 'package:app_links/app_links.dart';
import 'utils/logger.dart';

class SankofaDeepLinks {
  final SankofaLogger logger;
  final Function(String eventName, Map<String, dynamic> properties) onUtmCaught;
  final Map<String, String> defaultProperties;

  AppLinks? _appLinks;
  StreamSubscription<Uri>? _linkSubscription;

  SankofaDeepLinks({
    required this.logger,
    required this.onUtmCaught,
    required this.defaultProperties,
  });

  void init() {
    try {
      _appLinks = AppLinks();
      _linkSubscription = _appLinks!.uriLinkStream.listen((uri) {
        logger.log('🔗 Deep Link Caught: $uri');

        final queryParams = uri.queryParameters;
        bool hasUtms = false;

        final utmKeys = [
          'utm_source',
          'utm_medium',
          'utm_campaign',
          'utm_term',
          'utm_content',
        ];

        for (final key in utmKeys) {
          if (queryParams.containsKey(key)) {
            defaultProperties[key] = queryParams[key]!;
            hasUtms = true;
          }
        }

        if (hasUtms) {
          onUtmCaught('\$campaign_details', queryParams);
        }
      });
    } catch (e) {
      logger.log('⚠️ Sankofa: Deep links are unavailable: $e');
    }
  }

  void dispose() {
    _linkSubscription?.cancel();
  }
}
