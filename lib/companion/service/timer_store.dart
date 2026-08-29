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
    this.pausedRemaining,
    this.durationSeconds,
  });

  final String id;

  /// Whole minutes of the original duration (0 for a sub-minute timer).
  final int minutes;
  final String label;
  final DateTime firesAt;

  /// Original duration in seconds. Null on timers persisted before
  /// sub-minute support; then [totalSeconds] falls back to [minutes] * 60.
  final int? durationSeconds;

  int get totalSeconds => durationSeconds ?? minutes * 60;

  /// Frozen remaining when paused. Null means the clock is running toward
  /// [firesAt].
  final Duration? pausedRemaining;

  bool get isPaused => pausedRemaining != null;

  Duration remainingAt(DateTime now) {
    if (pausedRemaining != null) {
      return pausedRemaining!.isNegative ? Duration.zero : pausedRemaining!;
    }
    final left = firesAt.difference(now);
    return left.isNegative ? Duration.zero : left;
  }

  bool isDueAt(DateTime now) => !isPaused && !firesAt.isAfter(now);

  /// Freeze remaining at [now]. Already-paused timers are unchanged.
  PendingTimer pauseAt(DateTime now) {
    if (isPaused) return this;
    return PendingTimer(
      id: id,
      minutes: minutes,
      label: label,
      firesAt: firesAt,
      pausedRemaining: remainingAt(now),
      durationSeconds: durationSeconds,
    );
  }

  /// Continue from the frozen remaining. Running timers are unchanged.
  PendingTimer resumeAt(DateTime now) {
    final held = pausedRemaining;
    if (held == null) return this;
    return PendingTimer(
      id: id,
      minutes: minutes,
      label: label,
      firesAt: now.add(held),
      durationSeconds: durationSeconds,
    );
  }

  Map<String, Object?> toMap() => {
        'id': id,
        'minutes': minutes,
        'label': label,
        'firesAt': firesAt.millisecondsSinceEpoch,
        if (durationSeconds != null) 'durationSeconds': durationSeconds,
        if (pausedRemaining != null)
          'pausedRemainingMs': pausedRemaining!.inMilliseconds,
      };

  static PendingTimer? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final minutes = raw['minutes'];
    final label = raw['label'];
    final firesAt = raw['firesAt'];
    if (id is! String || id.isEmpty) return null;
    if (label is! String) return null;
    if (firesAt is! int) return null;
    final storedSeconds = raw['durationSeconds'];
    final int totalSeconds;
    final int wholeMinutes;
    if (storedSeconds is int && storedSeconds >= 1) {
      totalSeconds = storedSeconds;
      wholeMinutes = minutes is int && minutes >= 0 ? minutes : totalSeconds ~/ 60;
    } else if (minutes is int && minutes >= 1) {
      totalSeconds = minutes * 60;
      wholeMinutes = minutes;
    } else {
      return null;
    }
    Duration? pausedRemaining;
    final pausedMs = raw['pausedRemainingMs'];
    if (pausedMs is int && pausedMs >= 0) {
      pausedRemaining = Duration(milliseconds: pausedMs);
    }
    return PendingTimer(
      id: id,
      minutes: wholeMinutes,
      label: label,
      firesAt: DateTime.fromMillisecondsSinceEpoch(firesAt),
      pausedRemaining: pausedRemaining,
      durationSeconds: totalSeconds,
    );
  }
}

/// Write-through store of pending timers. Load once at service start, then
/// add/remove; every mutation persists so a kill loses at most the write
/// in flight.
final class TimerStore {
  TimerStore(this._store);

  static const String storageKey = 'timers_v1';

  /// Hard cap — one pending clock. A desk robot is not a calendar.
  static const int maxPending = 1;

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
    if (_timers.length > maxPending) {
      final keep = timerForDisplay(_timers);
      _timers.clear();
      if (keep != null) _timers.add(keep);
      await _persist();
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

  /// Replaces the timer with the same [PendingTimer.id]. Returns null if
  /// that id is not pending.
  Future<PendingTimer?> update(PendingTimer timer) async {
    _ensureLoaded();
    final index = _timers.indexWhere((t) => t.id == timer.id);
    if (index < 0) return null;
    _timers[index] = timer;
    await _persist();
    return timer;
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
int _timerIdSeq = 0;

String newTimerId([DateTime? now]) {
  final t = now ?? DateTime.now();
  _timerIdSeq += 1;
  return 't${t.microsecondsSinceEpoch}_$_timerIdSeq';
}

/// Soonest-firing *running* timer, or null if none are running.
PendingTimer? soonestPendingTimer(Iterable<PendingTimer> pending) {
  PendingTimer? best;
  for (final t in pending) {
    if (t.isPaused) continue;
    if (best == null || t.firesAt.isBefore(best.firesAt)) best = t;
  }
  return best;
}

/// OLED / control target: soonest running timer, else the paused one
/// with the least remaining.
PendingTimer? timerForDisplay(Iterable<PendingTimer> pending, [DateTime? now]) {
  final running = soonestPendingTimer(pending);
  if (running != null) return running;
  final t = now ?? DateTime.fromMillisecondsSinceEpoch(0);
  PendingTimer? best;
  for (final timer in pending) {
    if (!timer.isPaused) continue;
    if (best == null ||
        timer.remainingAt(t) < best.remainingAt(t)) {
      best = timer;
    }
  }
  return best;
}

/// Picks the pending timer for cancel / pause / resume. Labels are
/// metadata only and never used to select. [preferPaused] is for resume;
/// otherwise running timers win, then paused.
PendingTimer? pickTimer(
  Iterable<PendingTimer> pending, {
  bool preferPaused = false,
}) {
  final pool = pending.toList();
  if (pool.isEmpty) return null;
  final preferred = preferPaused
      ? pool.where((t) => t.isPaused).toList()
      : pool.where((t) => !t.isPaused).toList();
  final use = preferred.isNotEmpty ? preferred : pool;
  return timerForDisplay(use) ?? use.first;
}

/// OLED countdown for the soonest pending timer (`HH:MM:SS` only).
String formatTimerCountdown(PendingTimer timer, DateTime now) =>
    formatRemainingHhMmSs(timer.remainingAt(now));
