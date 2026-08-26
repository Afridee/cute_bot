/// Split streaming [TextDelta]s into speakable chunks (M5).
///
/// flutter_tts `synthesizeToFile` finishes a whole string before the first
/// PCM byte exists, so we cut on sentence boundaries (and a length cap) as
/// tokens arrive instead of waiting for [Done].
library;

/// Force-split if the model rambles without punctuation.
const int kForceSplitChars = 96;

/// Pull completed sentences off [buffer]. Remainder has no terminator yet
/// (unless [flush], which takes the tail as a last sentence).
(List<String> sentences, String rest) takeSentences(
  String buffer, {
  bool flush = false,
}) {
  final sentences = <String>[];
  var rest = buffer;
  while (true) {
    final trimmedStart = rest.trimLeft();
    if (trimmedStart.length != rest.length) rest = trimmedStart;

    final end = _sentenceEnd(rest);
    if (end != null) {
      final sentence = rest.substring(0, end).trim();
      rest = rest.substring(end);
      if (sentence.isNotEmpty) sentences.add(sentence);
      continue;
    }

    if (rest.length >= kForceSplitChars) {
      var cut = rest.lastIndexOf(' ', kForceSplitChars);
      if (cut < 24) cut = kForceSplitChars.clamp(0, rest.length);
      final piece = rest.substring(0, cut).trim();
      rest = rest.substring(cut);
      if (piece.isNotEmpty) sentences.add(piece);
      continue;
    }
    break;
  }

  if (flush) {
    final tail = rest.trim();
    if (tail.isNotEmpty) sentences.add(tail);
    rest = '';
  }
  return (sentences, rest);
}

/// Index just after the terminator and following space/quote, or null.
int? _sentenceEnd(String text) {
    final match = RegExp(r'''[.!?…]["']*(\s+|$)''').firstMatch(text);
  if (match == null) return null;
  // Don't split on a lone "." at the very start.
  if (match.start == 0 && match.end <= 2 && text.trim().length <= 2) {
    return null;
  }
  return match.end;
}
