/// Deterministic ASR enrollment: align prompt tokens to Zipformer
/// transcripts and merge substitutions into a [FastIntentOverlay].
///
/// No Gemma. A phrase, verb alias, or noun alias is stored only if it
/// appears in at least [kMinEnrollOccurrences] successful takes
/// (majority vote). Hapax (count == 1) is dropped. The common-word
/// blocklist is separate: words like `was` are never verb/noun aliases
/// but may remain inside a phrase that itself passed the count gate.
/// Precision gates: collision with another intent's defaults/overlay
/// drops the token (run after the count filter).
library;

import 'fast_intent_overlay.dart';

/// Prompt + successful transcripts for one script line.
final class VoiceEnrollSample {
  const VoiceEnrollSample({
    required this.prompt,
    required this.intent,
    required this.transcripts,
  });

  final String prompt;
  final FastIntentId intent;
  final List<String> transcripts;
}

/// One line the user is asked to say. Intent is for the aligner, not the UI.
final class VoiceEnrollLine {
  const VoiceEnrollLine(this.prompt, this.intent);
  final String prompt;
  final FastIntentId intent;
}

/// Setup script. Order is the wizard order. Canonical phrases only;
/// speaker synonyms are learned from how these lines come out of ASR.
const List<VoiceEnrollLine> kVoiceEnrollScript = [
  VoiceEnrollLine('Pause the timer', FastIntentId.pauseTimer),
  VoiceEnrollLine('Pause the tea timer', FastIntentId.pauseTimer),
  VoiceEnrollLine('Cancel the timer', FastIntentId.cancelTimer),
  VoiceEnrollLine('Stop the timer', FastIntentId.cancelTimer),
  VoiceEnrollLine('Resume the timer', FastIntentId.resumeTimer),
  VoiceEnrollLine('Start the timer', FastIntentId.resumeTimer),
  VoiceEnrollLine('Set a timer for 20 seconds', FastIntentId.setTimer),
  VoiceEnrollLine('Set a timer for three minutes, tea', FastIntentId.setTimer),
  VoiceEnrollLine('Remind me in ten minutes', FastIntentId.setTimer),
  VoiceEnrollLine('How much battery do you have', FastIntentId.battery),
  VoiceEnrollLine('How much battery', FastIntentId.battery),
];

const int kVoiceEnrollTakesTarget = 5;
const int kVoiceEnrollSkipLineAfter = 3;
const int kMaxPhrasesPerIntent = 12;
const int kMaxAliasesPerSlot = 8;
const int kMinEnrollOccurrences = 2;

/// Dropped from alignment slots; kept in the stored phrase.
const Set<String> kAlignStopwords = {
  'the',
  'a',
  'an',
  'to',
  'for',
  'me',
  'you',
  'please',
  'uh',
  'um',
};

/// Never a verb/noun alias. `was` is not a verb; a phrase containing
/// `was` may still enroll if that phrase itself passes the count gate.
const Set<String> kCommonWordBlocklist = {
  'was',
  'is',
  'are',
  'am',
  'be',
  'been',
  'being',
  'can',
  'could',
  'would',
  'should',
  'will',
  'shall',
  'may',
  'might',
  'i',
  'you',
  'me',
  'my',
  'your',
  'we',
  'they',
  'it',
  'he',
  'she',
  'the',
  'a',
  'an',
  'to',
  'for',
  'of',
  'on',
  'in',
  'at',
  'by',
  'and',
  'or',
  'please',
  'uh',
  'um',
  'oh',
  'ah',
  'er',
  'like',
  'just',
  'so',
  'do',
  'did',
  'does',
  'have',
  'has',
  'had',
  'this',
  'that',
  'these',
  'those',
  'how',
  'what',
  'when',
  'where',
  'who',
  'why',
  'much',
  'not',
  'no',
  'yes',
  'ok',
  'okay',
};

/// First content token maps to verb when it is one of these.
const Set<String> kVerbCueTokens = {
  'pause',
  'cancel',
  'stop',
  'resume',
  'unpause',
  'continue',
  'start',
};

const Set<String> kNounCueTokens = {
  'timer',
  'countdown',
  'battery',
};

/// Default keywords per intent — collision gate (another intent's terms).
const Map<FastIntentId, Set<String>> kDefaultIntentKeywords = {
  FastIntentId.pauseTimer: {
    'pause',
    'timer',
    'countdown',
  },
  FastIntentId.cancelTimer: {
    'cancel',
    'stop',
    'turn',
    'off',
    'timer',
    'countdown',
  },
  FastIntentId.resumeTimer: {
    'resume',
    'unpause',
    'continue',
    'start',
    'timer',
    'countdown',
  },
  FastIntentId.setTimer: {
    'set',
    'start',
    'make',
    'timer',
    'countdown',
    'alarm',
    'remind',
  },
  FastIntentId.battery: {
    'battery',
    'charged',
    'charge',
    'power',
  },
};

/// Merge samples into an overlay. Empty / blank transcripts are ignored.
/// Same-intent lines share a counter; hapax keys are dropped before
/// [_unionCapped] and [_applyCollisionGates].
FastIntentOverlay buildFastIntentOverlay(List<VoiceEnrollSample> samples) {
  final phraseCounts = <FastIntentId, Map<String, int>>{
    for (final id in FastIntentId.values) id: {},
  };
  final verbCounts = <FastIntentId, Map<String, int>>{
    for (final id in FastIntentId.values) id: {},
  };
  final nounCounts = <FastIntentId, Map<String, int>>{
    for (final id in FastIntentId.values) id: {},
  };
  final phraseOrder = <FastIntentId, List<String>>{
    for (final id in FastIntentId.values) id: [],
  };
  final verbOrder = <FastIntentId, List<String>>{
    for (final id in FastIntentId.values) id: [],
  };
  final nounOrder = <FastIntentId, List<String>>{
    for (final id in FastIntentId.values) id: [],
  };

  for (final sample in samples) {
    for (final take in _alignSample(sample)) {
      _tally(phraseCounts[sample.intent]!, phraseOrder[sample.intent]!, take.phrase);
      _tally(verbCounts[sample.intent]!, verbOrder[sample.intent]!, take.verb);
      _tally(nounCounts[sample.intent]!, nounOrder[sample.intent]!, take.noun);
    }
  }

  final phrases = <FastIntentId, List<String>>{
    for (final id in FastIntentId.values) id: [],
  };
  final verbs = <FastIntentId, List<String>>{
    for (final id in FastIntentId.values) id: [],
  };
  final nouns = <FastIntentId, List<String>>{
    for (final id in FastIntentId.values) id: [],
  };

  for (final id in FastIntentId.values) {
    _unionCapped(
      phrases[id]!,
      _survivors(phraseCounts[id]!, phraseOrder[id]!),
      kMaxPhrasesPerIntent,
    );
    _unionCapped(
      verbs[id]!,
      _survivors(verbCounts[id]!, verbOrder[id]!),
      kMaxAliasesPerSlot,
    );
    _unionCapped(
      nouns[id]!,
      _survivors(nounCounts[id]!, nounOrder[id]!),
      kMaxAliasesPerSlot,
    );
  }

  _applyCollisionGates(phrases, verbs, nouns);

  return FastIntentOverlay(intents: {
    for (final id in FastIntentId.values)
      id: FastIntentAliases(
        phrases: List.unmodifiable(phrases[id]!),
        verb: List.unmodifiable(verbs[id]!),
        noun: List.unmodifiable(nouns[id]!),
      ),
  });
}

void _tally(Map<String, int> counts, List<String> order, String? key) {
  if (key == null) return;
  counts[key] = (counts[key] ?? 0) + 1;
  if (counts[key] == 1) order.add(key);
}

Iterable<String> _survivors(Map<String, int> counts, List<String> order) {
  return [
    for (final key in order)
      if (counts[key]! >= kMinEnrollOccurrences) key,
  ];
}

void _unionCapped(List<String> dest, Iterable<String> extra, int cap) {
  for (final item in extra) {
    if (dest.length >= cap) return;
    if (!dest.contains(item)) dest.add(item);
  }
}

List<_TakeResult> _alignSample(VoiceEnrollSample sample) {
  final takes = <_TakeResult>[];
  for (final raw in sample.transcripts) {
    final take = _alignTake(sample.prompt, raw);
    if (take == null) continue;
    takes.add(take);
  }
  return takes;
}

class _TakeResult {
  const _TakeResult({this.phrase, this.verb, this.noun});
  final String? phrase;
  final String? verb;
  final String? noun;
}

_TakeResult? _alignTake(String prompt, String transcript) {
  final heardFull = tokenizeUtterance(transcript);
  if (heardFull.isEmpty) return null;
  final promptFull = tokenizeUtterance(prompt);
  final promptContent = [
    for (final t in promptFull)
      if (!kAlignStopwords.contains(t)) t,
  ];
  final heardContent = <String>[];
  final heardContentAt = <int>[];
  for (var i = 0; i < heardFull.length; i++) {
    if (kAlignStopwords.contains(heardFull[i])) continue;
    heardContent.add(heardFull[i]);
    heardContentAt.add(i);
  }

  final ops = _alignTokens(promptContent, heardContent);
  String? verbSub;
  String? nounSub;
  int? firstAligned;
  int? lastAligned;
  final firstPromptContent = promptContent.isEmpty ? null : promptContent.first;

  for (final op in ops) {
    if (op.promptIndex == null || op.heardIndex == null) continue;
    final pTok = promptContent[op.promptIndex!];
    final hTok = heardContent[op.heardIndex!];
    final fullIdx = heardContentAt[op.heardIndex!];
    firstAligned ??= fullIdx;
    lastAligned = fullIdx;
    if (pTok == hTok) continue;
    if (kNounCueTokens.contains(pTok)) {
      nounSub ??= hTok;
    } else if (pTok == firstPromptContent && kVerbCueTokens.contains(pTok)) {
      verbSub ??= hTok;
    }
  }

  String? phrase;
  if (firstAligned != null && lastAligned != null) {
    final span = heardFull.sublist(firstAligned, lastAligned + 1);
    if (span.length >= 2 && span.length <= 8) {
      phrase = span.join(' ');
    }
  }
  phrase ??= () {
    if (heardFull.length >= 2 && heardFull.length <= 8) {
      return heardFull.join(' ');
    }
    return null;
  }();
  phrase = _distinctivePhrase(phrase, nounSub);

  return _TakeResult(
    phrase: phrase,
    verb: _slotAlias(verbSub),
    noun: _slotAlias(nounSub),
  );
}

/// Drop phrases that are only a determiner plus the timer-noun stand-in
/// (`the diamond`). Slot product already covers verb × noun; a noun-only
/// span would match cancel/pause utterances that share that noun.
String? _distinctivePhrase(String? phrase, String? nounSub) {
  if (phrase == null) return null;
  final toks = tokenizeUtterance(phrase);
  final distinctive = [
    for (final t in toks)
      if (!kAlignStopwords.contains(t) &&
          !kNounCueTokens.contains(t) &&
          t != nounSub)
        t,
  ];
  if (distinctive.isEmpty) return null;
  return phrase;
}

String? _slotAlias(String? token) {
  if (token == null || token.isEmpty) return null;
  if (kCommonWordBlocklist.contains(token)) return null;
  if (kAlignStopwords.contains(token)) return null;
  return token;
}

final class _AlignOp {
  const _AlignOp({this.promptIndex, this.heardIndex});
  final int? promptIndex;
  final int? heardIndex;
}

/// Needleman–Wunsch on token sequences. Substitution cost is character
/// edit distance so `bzz` is an insertion, not a stand-in for `timer`.
List<_AlignOp> _alignTokens(List<String> prompt, List<String> heard) {
  const indel = 3;
  final m = prompt.length;
  final n = heard.length;
  if (m == 0 && n == 0) return const [];
  final dp = List.generate(m + 1, (_) => List<int>.filled(n + 1, 0));
  for (var i = 1; i <= m; i++) {
    dp[i][0] = i * indel;
  }
  for (var j = 1; j <= n; j++) {
    dp[0][j] = j * indel;
  }
  for (var i = 1; i <= m; i++) {
    for (var j = 1; j <= n; j++) {
      final subCost =
          prompt[i - 1] == heard[j - 1] ? 0 : _editDistance(prompt[i - 1], heard[j - 1]);
      final sub = dp[i - 1][j - 1] + subCost;
      final del = dp[i - 1][j] + indel;
      final ins = dp[i][j - 1] + indel;
      var best = sub;
      if (del < best) best = del;
      if (ins < best) best = ins;
      dp[i][j] = best;
    }
  }

  final ops = <_AlignOp>[];
  var i = m;
  var j = n;
  while (i > 0 || j > 0) {
    if (i > 0 && j > 0) {
      final subCost =
          prompt[i - 1] == heard[j - 1] ? 0 : _editDistance(prompt[i - 1], heard[j - 1]);
      if (dp[i][j] == dp[i - 1][j - 1] + subCost) {
        ops.add(_AlignOp(promptIndex: i - 1, heardIndex: j - 1));
        i--;
        j--;
        continue;
      }
    }
    if (j > 0 && (i == 0 || dp[i][j] == dp[i][j - 1] + indel)) {
      ops.add(_AlignOp(heardIndex: j - 1));
      j--;
      continue;
    }
    ops.add(_AlignOp(promptIndex: i - 1));
    i--;
  }
  return ops.reversed.toList();
}

int _editDistance(String a, String b) {
  if (a == b) return 0;
  final m = a.length;
  final n = b.length;
  var prev = List<int>.generate(n + 1, (j) => j);
  var curr = List<int>.filled(n + 1, 0);
  for (var i = 1; i <= m; i++) {
    curr[0] = i;
    for (var j = 1; j <= n; j++) {
      final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      final del = prev[j] + 1;
      final ins = curr[j - 1] + 1;
      final sub = prev[j - 1] + cost;
      curr[j] = del < ins
          ? (del < sub ? del : sub)
          : (ins < sub ? ins : sub);
    }
    final tmp = prev;
    prev = curr;
    curr = tmp;
  }
  return prev[n];
}

void _applyCollisionGates(
  Map<FastIntentId, List<String>> phrases,
  Map<FastIntentId, List<String>> verbs,
  Map<FastIntentId, List<String>> nouns,
) {
  for (final id in FastIntentId.values) {
    verbs[id]!.removeWhere(
      (tok) => _collides(tok, id, phrases, verbs, nouns, slot: true),
    );
    nouns[id]!.removeWhere(
      (tok) => _collides(tok, id, phrases, verbs, nouns, slot: true),
    );
  }
}

bool _collides(
  String token,
  FastIntentId self,
  Map<FastIntentId, List<String>> phrases,
  Map<FastIntentId, List<String>> verbs,
  Map<FastIntentId, List<String>> nouns, {
  required bool slot,
}) {
  for (final other in FastIntentId.values) {
    if (other == self) continue;
    if (kDefaultIntentKeywords[other]!.contains(token)) return true;
    if (verbs[other]!.contains(token) || nouns[other]!.contains(token)) {
      return true;
    }
    for (final phrase in phrases[other]!) {
      if (phrase == token) return true;
      if (slot && tokenizeUtterance(phrase).contains(token)) return true;
    }
  }
  return false;
}
