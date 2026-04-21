import 'catch_types.dart';

/// Dart stack-trace parser. Dart's `StackTrace.toString()` uses a
/// native format that varies between Flutter SDK versions:
///
///   "#0 MyClass.method (package:app/file.dart:42:17)"
///
/// This parser handles that shape plus a handful of edge cases
/// (asynchronous gaps: "<asynchronous suspension>", anonymous
/// closures: "new Foo.<anonymous closure>", AOT-compiled frames
/// without filenames). Unrecognised lines are skipped.
///
/// Output is in **oldest-first** order to match the wire contract.

final _dartFrame = RegExp(
  r'^#\d+\s+(?:(.+?)\s+)?\((package:|dart:|file:|https?:)?([^)\s]+?)(?::(\d+)(?::(\d+))?)?\)$',
);

CatchStackTrace? parseDartStack(Object? stack) {
  if (stack == null) return null;
  final raw = stack.toString();
  if (raw.isEmpty) return null;

  final frames = <CatchStackFrame>[];
  for (final line in raw.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed == '<asynchronous suspension>') continue;
    final m = _dartFrame.firstMatch(trimmed);
    if (m == null) continue;

    final func = m.group(1);
    final scheme = m.group(2) ?? '';
    final pathOrAddr = m.group(3);
    final lineStr = m.group(4);
    final colStr = m.group(5);
    if (pathOrAddr == null) continue;

    final file = scheme.isEmpty ? pathOrAddr : '$scheme$pathOrAddr';
    final lineno = lineStr != null ? int.tryParse(lineStr) : null;
    final colno = colStr != null ? int.tryParse(colStr) : null;

    frames.add(CatchStackFrame(
      function: (func != null && func.isNotEmpty && func != '<anonymous closure>')
          ? func
          : null,
      filename: file,
      absPath: file,
      lineno: lineno,
      colno: colno,
      platform: 'flutter',
      inApp: _isInApp(file),
    ));
  }

  if (frames.isEmpty) return null;
  return CatchStackTrace(List<CatchStackFrame>.from(frames.reversed));
}

bool _isInApp(String file) {
  if (file.startsWith('package:flutter/')) return false;
  if (file.startsWith('dart:')) return false;
  if (file.contains('/pub-cache/')) return false;
  if (file.contains('/flutter/packages/')) return false;
  return true;
}

/// Normalise any thrown value into the wire's Exception shape.
CatchException errorToException(
  Object error,
  Object? stack, {
  CatchMechanism? mechanism,
}) {
  final type = error.runtimeType.toString();
  final value = error.toString();
  return CatchException(
    type: type,
    value: value,
    mechanism: mechanism,
    stacktrace: parseDartStack(stack),
  );
}
