/// Wire format for the bot OLED timer row (`show_text` when a countdown runs).
/// Shared by companion + simulator; dependency-free for firmware porting.
library;

/// Formats remaining time as `HH:MM:SS` (zero-padded).
String formatRemainingHhMmSs(Duration remaining) {
  final totalSec = remaining.inSeconds < 0 ? 0 : remaining.inSeconds;
  final h = totalSec ~/ 3600;
  final m = (totalSec % 3600) ~/ 60;
  final s = totalSec % 60;
  return '${h.toString().padLeft(2, '0')}:'
      '${m.toString().padLeft(2, '0')}:'
      '${s.toString().padLeft(2, '0')}';
}

/// Parses `HH:MM:SS` into a duration, or null if malformed.
Duration? parseHhMmSs(String text) {
  final parts = text.trim().split(':');
  if (parts.length != 3) return null;
  final h = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  final s = int.tryParse(parts[2]);
  if (h == null || m == null || s == null) return null;
  if (m < 0 || m > 59 || s < 0 || s > 59 || h < 0) return null;
  return Duration(hours: h, minutes: m, seconds: s);
}

/// True when [text] is a timer countdown line from the companion.
bool isTimerDisplayText(String text) =>
    parseHhMmSs(text) != null;
