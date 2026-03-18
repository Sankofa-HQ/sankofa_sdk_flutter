import 'package:flutter/foundation.dart';

class SankofaLogger {
  final bool debug;

  SankofaLogger({required this.debug});

  void log(String value) {
    if (debug) debugPrint(value);
  }
}
