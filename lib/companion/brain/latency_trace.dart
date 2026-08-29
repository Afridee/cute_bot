/// Per-turn latency breakdown (M3).
///
/// The product budget is end-of-speech → first expression on the body.
/// The clip-based `respond(AudioClip)` path is fully sequential, so
/// worst-case latency is the *sum* of stages. [firstTokenMs] is
/// end-of-speech → first tool call (`express(...)`).
library;

/// One inference turn, split into the stages we can actually measure.
final class LatencyTrace {
  const LatencyTrace({
    this.downloadMs,
    this.modelLoadMs,
    this.chatCreateMs,
    required this.submitMs,
    required this.firstTokenMs,
    required this.decodeMs,
    required this.totalMs,
    this.backend,
    this.firstTokenText,
  });

  /// Model-file download (warm-up only; null on later turns).
  final int? downloadMs;

  /// `getActiveModel` (warm-up only).
  final int? modelLoadMs;

  /// `createChat` (warm-up only).
  final int? chatCreateMs;

  /// `addQueryChunk` of the audio clip — encoder + staging.
  final int submitMs;

  /// End of `respond()` start → first tool call. Includes submit + prefill.
  final int firstTokenMs;

  /// First token → [Done].
  final int decodeMs;

  /// Whole `respond()` call.
  final int totalMs;

  /// `gpu` or `cpu`, whichever load succeeded.
  final String? backend;

  /// First tool-call line (`express(happy)`), for the debug panel.
  final String? firstTokenText;

  /// One-line logcat summary.
  String get summary {
    final warm = [
      if (downloadMs != null) 'dl ${downloadMs}ms',
      if (modelLoadMs != null) 'load ${modelLoadMs}ms',
      if (chatCreateMs != null) 'chat ${chatCreateMs}ms',
    ];
    final turn =
        'submit ${submitMs}ms · ttf ${firstTokenMs}ms · decode ${decodeMs}ms · '
        'total ${totalMs}ms';
    final head = warm.isEmpty ? turn : '${warm.join(' · ')} · $turn';
    return backend == null ? head : '$head · $backend';
  }

  Map<String, Object?> toMap() => {
        'dl': downloadMs,
        'load': modelLoadMs,
        'chat': chatCreateMs,
        'submit': submitMs,
        'ttf': firstTokenMs,
        'decode': decodeMs,
        'total': totalMs,
        'backend': backend,
        'tok': firstTokenText,
      };

  static LatencyTrace? fromMap(Object? raw) {
    if (raw is! Map) return null;
    int? asInt(Object? v) => v is int ? v : null;
    return LatencyTrace(
      downloadMs: asInt(raw['dl']),
      modelLoadMs: asInt(raw['load']),
      chatCreateMs: asInt(raw['chat']),
      submitMs: asInt(raw['submit']) ?? 0,
      firstTokenMs: asInt(raw['ttf']) ?? 0,
      decodeMs: asInt(raw['decode']) ?? 0,
      totalMs: asInt(raw['total']) ?? 0,
      backend: raw['backend'] is String ? raw['backend'] as String : null,
      firstTokenText: raw['tok'] is String ? raw['tok'] as String : null,
    );
  }
}
