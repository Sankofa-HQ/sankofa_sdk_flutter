/// Subpath import for Sankofa Deploy only.
///
/// Use this when you don't need the full `sankofa_flutter` surface and
/// want a smaller import footprint:
///
/// ```dart
/// import 'package:sankofa_flutter/deploy.dart';
///
/// // Then via the top-level Sankofa instance:
/// import 'package:sankofa_flutter/sankofa_flutter.dart';
/// await Sankofa.instance.init(apiKey: '...', enableDeploy: true);
/// await Sankofa.instance.deploy!.notifyAppReady();
/// ```
library sankofa_flutter.deploy;

export 'src/deploy/sankofa_deploy.dart' show SankofaDeploy;
export 'src/deploy/deploy_config.dart' show SankofaDeployOptions;
export 'src/deploy/update_status.dart' show UpdateStatus;
