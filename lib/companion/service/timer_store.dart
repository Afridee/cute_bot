/// Pending phone-side timers (M4).
///
/// `set_timer` is a model tool but the clock lives on the phone. Kill →
/// restart must not drop them: same [KeyValueStore] as the transcript.
/// Firing is the caller's job (serialized conversation queue) — this file
/// is persistence + due/remaining math, no Dart [Timer]s.
library;

import 'dart:convert';

import '../../shared/timer_display.dart';
import '../brain/transcript.dart';

/// One countdown the bot promised to announce.
final class PendingTimer {
  const PendingTimer({
    required this.id,
    required this.minutes,
    required this.label,
    required this.firesAt,
  });

  final String id;
  final int minutes;
  final String label;
  final DateTime firesAt;

  Duration remainingAt(DateTime now) {
    final left = firesAt.difference(now);
    return left.isNegative ? Duration.zero : left;
  }

  bool isDueAt(DateTime now) => !firesAt.isAfter(now);

  Map<String, Object?> toMap() => {
        'id': id,
        'minutes': minutes,
        'label': label,
        'firesAt': firesAt.millisecondsSinceEpoch,
      };

  static PendingTimer? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final minutes = raw['minutes'];
    final label = raw['label'];
    final firesAt = raw['firesAt'];
    if (id is! String || id.isEmpty) return null;
    if (minutes is! int || minutes < 1) return null;
    if (label is! String) return null;
    if (firesAt is! int) return null;
    return PendingTimer(
      id: id,
      minutes: minutes,
      label: label,
      firesAt: DateTime.fromMillisecondsSinceEpoch(firesAt),
    );
  }
}

/// Write-through store of pending timers. Load once at service start, then
/// add/remove; every mutation persists so a kill loses at most the write
/// in flight.
final class TimerStore {
  TimerStore(this._store);

  static const String storageKey = 'timers_v1';

  /// Hard cap — a desk robot is not a calendar.
  static const int maxPending = 8;

  final KeyValueStore _store;
  final List<PendingTimer> _timers = [];
  bool _loaded = false;

  List<PendingTimer> get pending => List.unmodifiable(_timers);

  Future<List<PendingTimer>> load() async {
    _timers.clear();
    _loaded = true;
    final raw = await _store.read(storageKey);
    if (raw == null) return pending;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        for (final item in decoded) {
          final timer = PendingTimer.fromMap(item);
          if (timer != null) _timers.add(timer);
        }
      }
    } on FormatException {
      // Corrupt store: start empty rather than wedging recovery.
    }
    return pending;
  }

  /// Inserts [timer]. Returns false if the cap is hit (caller should not
  /// schedule a Dart timer it cannot persist).
  Future<bool> add(PendingTimer timer) async {
    _ensureLoaded();
    if (_timers.length >= maxPending) return false;
    _timers.add(timer);
    await _persist();
    return true;
  }

  Future<PendingTimer?> remove(String id) async {
    _ensureLoaded();
    final index = _timers.indexWhere((t) => t.id == id);
    if (index < 0) return null;
    final gone = _timers.removeAt(index);
    await _persist();
    return gone;
  }

  Future<void> clear() async {
    _timers.clear();
    _loaded = true;
    await _store.remove(storageKey);
  }

  void _ensureLoaded() {
    if (!_loaded) {
      throw StateError('TimerStore used before load()');
    }
  }

  Future<void> _persist() => _store.write(
        storageKey,
        jsonEncode([for (final t in _timers) t.toMap()]),
      );
}

/// Allocates a unique-enough id without a uuid package.
String newTimerId([DateTime? now]) {
  final t = now ?? DateTime.now();
  return 't${t.microsecondsSinceEpoch}';
}

/// Soonest-firing timer, or null if [pending] is empty.
PendingTimer? soonestPendingTimer(Iterable<PendingTimer> pending) {
  PendingTimer? best;
  for (final t in pending) {
    if (best == null || t.firesAt.isBefore(best.firesAt)) best = t;
  }
  return best;
}

/// OLED countdown for the soonest pending timer (`HH:MM:SS` only).
String formatTimerCountdown(PendingTimer timer, DateTime now) =>
    formatRemainingHhMmSs(timer.remainingAt(now));
