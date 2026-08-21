/// Rolling text window seeded into Gemma's chat before each utterance.
///
/// Pure: no flutter_gemma. Live turns and kill → re-warm use the same
/// seeder so every respond() looks like a restart — one current WAV plus
/// a short tail of recent bot (and system) text. User "(voice, …)"
/// placeholders stay in [TranscriptStore] / UI; they teach the model
/// nothing.
library;

import 'transcript.dart';

/// Cap on seedable transcript lines. Oldest drop first. Audio + template
/// + this must fit in the model's token window.
const int kContextEntryCap = 16;

/// Bot and system lines to seed, chronological, capped at [cap].
///
/// Drops the current user placeholder BrainSession just appended
/// (`(voice, 1.2 s)`) — that turn is the audio clip, not text — and
/// every other user voice stub. User text is never seeded.
List<TranscriptEntry> rollingTextWindow(
  List<TranscriptEntry> transcript, {
  int cap = kContextEntryCap,
}) {
  var entries = transcript;
  if (entries.isEmpty) return const [];
  final last = entries.last;
  if (_isUserVoicePlaceholder(last)) {
    entries = entries.sublist(0, entries.length - 1);
  }
  final seedable = [
    for (final entry in entries)
      if (_isSeedable(entry)) entry,
  ];
  if (seedable.length > cap) {
    return seedable.sublist(seedable.length - cap);
  }
  return seedable;
}

bool _isUserVoicePlaceholder(TranscriptEntry entry) =>
    entry.role == TranscriptRole.user && entry.text.startsWith('(voice,');

bool _isSeedable(TranscriptEntry entry) {
  if (_isUserVoicePlaceholder(entry)) return false;
  return entry.role == TranscriptRole.bot ||
      entry.role == TranscriptRole.system;
}
