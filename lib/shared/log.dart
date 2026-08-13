// Single logging channel for the whole app (brief rule 7). Everything goes
// through debugPrint, which lands in logcat, so a device is debuggable with
// `adb logcat | grep CuteBot` and no debugger attached.
//
// App-side only — the ESP32 does not port this file.

import 'package:flutter/foundation.dart';

enum LogLevel { debug, info, warn, error }

/// Minimum level actually emitted. Raise to quiet a noisy subsystem.
LogLevel logThreshold = LogLevel.debug;

final class Log {
  Log._();

  static void d(String tag, String message) => _log(LogLevel.debug, tag, message);
  static void i(String tag, String message) => _log(LogLevel.info, tag, message);
  static void w(String tag, String message) => _log(LogLevel.warn, tag, message);
  static void e(String tag, String message, [Object? error, StackTrace? stack]) {
    _log(LogLevel.error, tag, error == null ? message : '$message: $error');
    if (stack != null) _log(LogLevel.error, tag, '$stack');
  }

  static void _log(LogLevel level, String tag, String message) {
    if (level.index < logThreshold.index) return;
    final label = switch (level) {
      LogLevel.debug => 'D',
      LogLevel.info => 'I',
      LogLevel.warn => 'W',
      LogLevel.error => 'E',
    };
    debugPrint('CuteBot/$label/$tag: $message');
  }
}
