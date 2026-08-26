/// Rolling text window of recent bot expressions.
///
/// Pure: no flutter_gemma. Kept for the transcript UI and for a future
/// path that can replay turns as real user/model messages. GemmaBrain
/// must **not** [addQueryChunk] this tail today: LiteRT-LM concatenates
/// every chunk into one user prompt, so `express(playful)` in the seed
/// becomes the answer. User "(voice, …)" placeholders stay in
/// [TranscriptStore] / UI; they teach the model nothing.
library;

import 'transcript.dart';

/// Cap on seedable transcript lines. Oldest drop first. Audio + template
/// + this must fit in the model's token window.
const int kContextEntryCap = 16;

/// Bot and system lines, chronological, capped at [cap].
///
/// Drops the current user placeholder BrainSession just appended
/// (`(voice, 1.2 s)`) — that turn is the audio clip, not text — and
/// every other user voice stub. User text is never included.
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
