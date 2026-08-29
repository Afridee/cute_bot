/// Rule-based NLU in front of the LLM.
///
/// The bot's action space is tiny (`express` / `set_timer` /
/// `cancel_timer` / `pause_timer` / `resume_timer` / `get_battery`)
/// and the persona few-shots are formulaic. High-confidence hits skip
/// Gemma's audio encode + thought block; anything hedged falls through.
/// Precision over recall — a wrong timer is worse than a slow one.
library;

import '../expressions.dart';
import 'bot_brain.dart';
import 'fast_intent_overlay.dart';

/// One conservative match. [calls] is what the body should run, in order.
final class FastIntentHit {
  const FastIntentHit(this.calls, {required this.reason});

  final List<ToolCall> calls;
  final String reason;
}

/// Parse [text] (a cue, or a future ASR transcript). Null = let the LLM go.
///
/// Checks run narrow-to-broad: tool intents first, then specific moods,
/// with the catch-all greeting (`hey`/`hi`) last. Optional [overlay] is
/// additive: defaults run first; enrolled phrases/slots only if they miss.
FastIntentHit? matchText(String text, [FastIntentOverlay? overlay]) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  final lower = trimmed.toLowerCase();
  if (_negated(lower)) return null;

  return _matchTimerFire(lower) ??
      _matchCancelTimer(lower, overlay) ??
      _matchPauseTimer(lower, overlay) ??
      _matchResumeTimer(trimmed, lower, overlay) ??
      _matchSetTimer(trimmed, lower, overlay) ??
      _matchBattery(lower, overlay) ??
      _matchCapabilityNo(lower) ??
      _matchDance(lower) ??
      _matchPlay(lower) ??
      _matchStartle(lower) ??
      _matchThanksPraise(lower) ??
      _matchScold(lower) ??
      _matchComfort(lower) ??
      _matchQuiet(lower) ??
      _matchAffection(lower) ??
      _matchFarewell(lower) ??
      _matchGreeting(lower);
}

/// Canonical lemmas plus inflections. Synonyms and ASR stand-ins belong
/// on the enrolled overlay, not here.
const _pauseVerbs = [
  'pause',
  'paused',
  'pausing',
];
const _cancelVerbs = [
  'cancel',
  'canceled',
  'cancelled',
  'canceling',
  'cancelling',
  'stop',
  'stopped',
  'stopping',
];
const _resumeVerbs = [
  'resume',
  'resumed',
  'resuming',
  'unpause',
  'unpaused',
  'unpausing',
  'continue',
  'continued',
  'continuing',
  'start',
  'started',
  'starting',
];
const _timerNouns = ['timer', 'countdown'];
const _timerControlIds = [
  FastIntentId.pauseTimer,
  FastIntentId.cancelTimer,
  FastIntentId.resumeTimer,
  FastIntentId.setTimer,
];
const _phraseFillers = {'the', 'a', 'an', 'my', 'this', 'that'};

/// Battery percent → the mood the persona asks for after `get_battery`.
BotMood moodFromBatteryPercent(Object? percent) {
  if (percent is! int) return BotMood.confused;
  if (percent < 20) return BotMood.low_battery;
  if (percent < 35) return BotMood.sleepy;
  return BotMood.yes;
}

bool _negated(String lower) {
  return RegExp(
    r"\b(?:don't|do not|didn't|did not|never|not going to)\b",
  ).hasMatch(lower);
}

FastIntentHit? _matchTimerFire(String lower) {
  if (RegExp(r'timer\s+just\s+finished').hasMatch(lower) ||
      RegExp(r'timer\s+fired').hasMatch(lower) ||
      RegExp(r"a timer just finished").hasMatch(lower)) {
    return const FastIntentHit(
      [ToolCall('express', {'mood': 'alarm'})],
      reason: 'timer-fire',
    );
  }
  return null;
}

FastIntentHit? _matchCancelTimer(
  String lower,
  FastIntentOverlay? overlay,
) {
  if (!_controlHit(
    lower,
    overlay,
    FastIntentId.cancelTimer,
    _cancelVerbs,
    extraRegex: r'\bturn\s+off\b.{0,20}\b(?:timer|countdown)\b',
  )) {
    return null;
  }
  return const FastIntentHit(
    [ToolCall('cancel_timer', {})],
    reason: 'cancel-timer',
  );
}

FastIntentHit? _matchPauseTimer(
  String lower,
  FastIntentOverlay? overlay,
) {
  if (!_controlHit(lower, overlay, FastIntentId.pauseTimer, _pauseVerbs)) {
    return null;
  }
  return const FastIntentHit(
    [ToolCall('pause_timer', {})],
    reason: 'pause-timer',
  );
}

FastIntentHit? _matchResumeTimer(
  String original,
  String lower,
  FastIntentOverlay? overlay,
) {
  // A duration means set, not resume ("start the timer for 5 minutes").
  if (_parseDurationAndLabel(original, lower) != null) return null;
  if (!_controlHit(lower, overlay, FastIntentId.resumeTimer, _resumeVerbs)) {
    return null;
  }
  return const FastIntentHit(
    [ToolCall('resume_timer', {})],
    reason: 'resume-timer',
  );
}

FastIntentHit? _matchSetTimer(
  String original,
  String lower,
  FastIntentOverlay? overlay,
) {
  final aliases = overlay?.of(FastIntentId.setTimer);
  final defaultLook = _looksLikeSetTimer(lower);
  final overlayLook =
      aliases != null && _overlayPhraseHits(lower, aliases.phrases);
  if (!defaultLook && !overlayLook) return null;

  final parsed = _parseDurationAndLabel(original, lower);
  if (parsed == null) return null;
  final (totalSeconds, label) = parsed;
  if (totalSeconds < 1 || totalSeconds > 180 * 60) return null;

  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  return FastIntentHit(
    [
      ToolCall('set_timer', {
        if (minutes > 0) 'minutes': minutes,
        if (seconds > 0) 'seconds': seconds,
        'label': label,
      }),
    ],
    reason: 'set-timer',
  );
}

/// Timer-ish utterance, not a bare duration ("in 20 seconds" alone is
/// chatter). Duration is checked separately so "20 second timer" and
/// "timer for 20 seconds" both land. A 4–7 letter near-miss of "timer"
/// (ASR: diamer, dimer, tymer) also counts; still needs a duration.
bool _looksLikeSetTimer(String lower) {
  if (RegExp(
    r'\b(?:set|start|make)\b'
    r'.{0,40}\b(?:a\s+)?(?:timer|countdown|alarm)\b'
    r'|\b(?:timer|countdown|alarm)\s+(?:for|of|in|to)\b'
    r'|\b(?:timer|countdown)\b.{0,24}\b(?:seconds?|secs?|minutes?|mins?|hours?|hrs?)\b'
    r'|\b(?:seconds?|secs?|minutes?|mins?|hours?|hrs?)\b.{0,16}\b(?:timer|countdown)\b'
    r'|\bremind\s+me\b'
    r'|\bcount\s?down\b',
  ).hasMatch(lower)) {
    return true;
  }
  return _hasNearMissTimerNoun(lower);
}

/// Zipformer often drops or swaps a letter in "timer". Distance 0 is
/// already covered above; 1–2 on a short token is the ASR near-miss.
bool _hasNearMissTimerNoun(String lower) {
  for (final token in tokenizeUtterance(lower)) {
    if (_tokenIsNearMissTimer(token)) return true;
  }
  return false;
}

bool _tokenIsNearMissTimer(String token) {
  const target = 'timer';
  if (token.length < 4 || token.length > 7) return false;
  if (token == target) return false;
  final d = _editDistance(token, target);
  return d >= 1 && d <= 2;
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

FastIntentHit? _matchBattery(String lower, FastIntentOverlay? overlay) {
  if (RegExp(
    r'\b(?:battery|charged?|how much power|power left)\b',
  ).hasMatch(lower)) {
    return const FastIntentHit(
      [ToolCall('get_battery', {})],
      reason: 'battery',
    );
  }
  final aliases = overlay?.of(FastIntentId.battery);
  if (aliases != null && _overlayPhraseHits(lower, aliases.phrases)) {
    return const FastIntentHit(
      [ToolCall('get_battery', {})],
      reason: 'battery',
    );
  }
  return null;
}

bool _controlHit(
  String lower,
  FastIntentOverlay? overlay,
  FastIntentId id,
  List<String> defaultVerbs, {
  String? extraRegex,
}) {
  final verbAlt = defaultVerbs.map(RegExp.escape).join('|');
  final nounAlt = _timerNouns.map(RegExp.escape).join('|');
  if (RegExp('\\b(?:$verbAlt)\\b.{0,40}\\b(?:$nounAlt)\\b').hasMatch(lower)) {
    return true;
  }
  if (extraRegex != null && RegExp(extraRegex).hasMatch(lower)) return true;
  final extraNouns = _timerOverlayNouns(overlay);
  if (_overlayControlHits(
    lower,
    overlay?.of(id),
    defaultVerbs,
    extraNouns: extraNouns,
  )) {
    return true;
  }
  return _fuzzyControlHit(lower, defaultVerbs, extraNouns);
}

List<String> _timerOverlayNouns(FastIntentOverlay? overlay) {
  if (overlay == null) return const [];
  return [
    for (final id in _timerControlIds) ...overlay.of(id).noun,
  ];
}

/// Enrolled phrase as a token span, or overlay-verb × overlay-noun /
/// overlay-verb × default noun / default-verb × overlay-noun.
///
/// Timer nouns enrolled on any control intent count for all of them
/// ("diamond" from resume still pairs with cancel). Phrases that are
/// only a determiner plus a timer noun ("the diamond") do not fire —
/// they would steal cancel/pause utterances that share the noun.
bool _overlayControlHits(
  String lower,
  FastIntentAliases? aliases,
  List<String> defaultVerbs, {
  List<String> extraNouns = const [],
}) {
  final overlayVerbs = aliases?.verb ?? const [];
  final overlayNouns = aliases?.noun ?? const [];
  final nouns = [...overlayNouns, ...extraNouns];
  final phrases = aliases?.phrases ?? const [];
  if (_overlayPhraseHits(lower, phrases, weakNouns: nouns)) return true;
  // Distinctive phrase tokens (`was` in `was the temper`) × overlay nouns,
  // including nouns enrolled on a sibling intent. Never × default
  // timer/countdown — `I was the one who set the timer` must not pause.
  if (_slotPairHits(lower, _phraseCueTokens(phrases, nouns), nouns)) {
    return true;
  }
  if (_slotPairHits(lower, overlayVerbs, nouns)) return true;
  if (_slotPairHits(lower, overlayVerbs, _timerNouns)) return true;
  if (_slotPairHits(lower, defaultVerbs, nouns)) return true;
  return false;
}

List<String> _phraseCueTokens(List<String> phrases, List<String> nouns) {
  final weak = {
    ..._phraseFillers,
    ..._timerNouns,
    for (final n in nouns) n.toLowerCase(),
  };
  final cues = <String>[];
  for (final phrase in phrases) {
    for (final t in tokenizeUtterance(phrase)) {
      if (weak.contains(t) || cues.contains(t)) continue;
      cues.add(t);
    }
  }
  return cues;
}

bool _overlayPhraseHits(
  String lower,
  List<String> phrases, {
  Iterable<String> weakNouns = const [],
}) {
  if (phrases.isEmpty) return false;
  final hay = tokenizeUtterance(lower);
  final weak = {
    ..._phraseFillers,
    ..._timerNouns,
    for (final n in weakNouns) n.toLowerCase(),
  };
  for (final phrase in phrases) {
    final ned = tokenizeUtterance(phrase);
    if (ned.isEmpty || hay.length < ned.length) continue;
    if (ned.every(weak.contains)) continue;
    for (var i = 0; i <= hay.length - ned.length; i++) {
      var ok = true;
      for (var k = 0; k < ned.length; k++) {
        if (hay[i + k] != ned[k]) {
          ok = false;
          break;
        }
      }
      if (ok) return true;
    }
  }
  return false;
}

/// Exact control verb, or edit-distance 1–2 on verbs of length ≥ 6
/// (`cancel`/`canceled` → `canseled`). Short verbs stay exact-only so
/// `stop` does not become `start`.
bool _fuzzyControlHit(
  String lower,
  List<String> verbs,
  List<String> extraNouns,
) {
  return _hasFuzzyControlVerb(lower, verbs) &&
      _hasTimerNounToken(lower, extraNouns);
}

bool _hasFuzzyControlVerb(String lower, List<String> verbs) {
  for (final token in tokenizeUtterance(lower)) {
    if (_fuzzyVerbToken(token, verbs)) return true;
  }
  return false;
}

bool _fuzzyVerbToken(String token, List<String> verbs) {
  for (final verb in verbs) {
    if (token == verb) return true;
    if (verb.length < 6 || token.length < 4) continue;
    if ((token.length - verb.length).abs() > 2) continue;
    final d = _editDistance(token, verb);
    if (d >= 1 && d <= 2) return true;
  }
  return false;
}

bool _hasTimerNounToken(String lower, List<String> extraNouns) {
  final extra = {for (final n in extraNouns) n.toLowerCase()};
  for (final token in tokenizeUtterance(lower)) {
    if (_timerNouns.contains(token) || extra.contains(token)) return true;
  }
  return false;
}

bool _slotPairHits(String lower, List<String> verbs, List<String> nouns) {
  if (verbs.isEmpty || nouns.isEmpty) return false;
  final v = verbs.map(RegExp.escape).join('|');
  final n = nouns.map(RegExp.escape).join('|');
  return RegExp('\\b($v)\\b.{0,40}\\b($n)\\b').hasMatch(lower);
}

/// The persona says the bot must `express(no)` when asked to do something
/// it cannot do. Only the literal impossibles — anything vaguer goes to
/// the LLM (the timer check already ran, so "can you set a timer for 5
/// minutes" never reaches this).
FastIntentHit? _matchCapabilityNo(String lower) {
  if (RegExp(
    r'\bcan you (?:talk|speak|sing|walk)\b'
    r'|\bsay something\b',
  ).hasMatch(lower)) {
    return const FastIntentHit(
      [ToolCall('express', {'mood': 'no'})],
      reason: 'cannot-do',
    );
  }
  return null;
}

FastIntentHit? _matchDance(String lower) {
  if (RegExp(
    r'\b(?:dance|wiggle|do a (?:little )?dance)\b',
  ).hasMatch(lower)) {
    return const FastIntentHit(
      [ToolCall('express', {'mood': 'delighted'})],
      reason: 'dance',
    );
  }
  return null;
}

FastIntentHit? _matchPlay(String lower) {
  if (RegExp(
    r"\bwanna play\b|\blet'?s play\b|\bplay with me\b"
    r'|\bpeek-?a-?boo\b|\btickle\b',
  ).hasMatch(lower)) {
    return const FastIntentHit(
      [ToolCall('express', {'mood': 'playful'})],
      reason: 'play',
    );
  }
  return null;
}

FastIntentHit? _matchStartle(String lower) {
  if (RegExp(r'\bboo\b|\bsurprise\b').hasMatch(lower)) {
    return const FastIntentHit(
      [ToolCall('express', {'mood': 'startled'})],
      reason: 'startle',
    );
  }
  return null;
}

FastIntentHit? _matchThanksPraise(String lower) {
  if (RegExp(r'\bthank you\b|\bthanks\b').hasMatch(lower)) {
    return const FastIntentHit(
      [ToolCall('express', {'mood': 'happy'})],
      reason: 'thanks',
    );
  }
  if (RegExp(
    r'\bwell done\b|\bgood job\b|\byou did it\b'
    r'|\bproud of you\b|\bnice work\b',
  ).hasMatch(lower)) {
    return const FastIntentHit(
      [ToolCall('express', {'mood': 'proud'})],
      reason: 'well-done',
    );
  }
  return null;
}

/// Conservative: only with `bot`/`robot` attached, so "bad day" stays
/// with the comfort matcher.
FastIntentHit? _matchScold(String lower) {
  if (RegExp(
    r'\b(?:bad|stupid)\s+(?:little\s+)?(?:bot|robot)\b',
  ).hasMatch(lower)) {
    return const FastIntentHit(
      [ToolCall('express', {'mood': 'sad'})],
      reason: 'scold',
    );
  }
  return null;
}

FastIntentHit? _matchComfort(String lower) {
  if (RegExp(
    r"\bi'?m sad\b|\bi am sad\b|\bfeeling down\b"
    r'|\b(?:bad|rough) day\b',
  ).hasMatch(lower)) {
    return const FastIntentHit(
      [ToolCall('express', {'mood': 'sad'})],
      reason: 'comfort',
    );
  }
  return null;
}

/// Acknowledge the request. `stop it` / `stop beeping` stay with the LLM
/// (no timer word, and they are not hush/quiet).
FastIntentHit? _matchQuiet(String lower) {
  if (RegExp(
    r'\bbe quiet\b|\bquiet down\b|\bhush\b|\btoo loud\b|\bsh{2,}\b',
  ).hasMatch(lower)) {
    return const FastIntentHit(
      [ToolCall('express', {'mood': 'yes'})],
      reason: 'quiet',
    );
  }
  return null;
}

FastIntentHit? _matchAffection(String lower) {
  if (RegExp(
    r"\b(?:love you|i love you|you're cute|you are cute)\b"
    r'|\bmiss(?:ed)? you\b',
  ).hasMatch(lower)) {
    return const FastIntentHit(
      [ToolCall('express', {'mood': 'love'})],
      reason: 'affection',
    );
  }
  if (RegExp(r'\bgood (?:little )?(?:bot|robot|guy)\b').hasMatch(lower)) {
    return const FastIntentHit(
      [ToolCall('express', {'mood': 'happy'})],
      reason: 'praise',
    );
  }
  return null;
}

FastIntentHit? _matchFarewell(String lower) {
  // Winding down for the night → sleepy.
  if (RegExp(
    r'\bgo to sleep\b|\bnap time\b|\btime for bed\b|\bbedtime\b'
    r'|\bsweet dreams\b|\bsee you tomorrow\b',
  ).hasMatch(lower)) {
    return const FastIntentHit(
      [ToolCall('express', {'mood': 'sleepy'})],
      reason: 'wind-down',
    );
  }
  // Leaving → the bot is sad to see you go.
  if (RegExp(
    r'\bgood-?bye\b|\bbye\b|\bsee you later\b|\bgotta go\b'
    r"|\bi'?m leaving\b|\bi'?m heading out\b",
  ).hasMatch(lower)) {
    return const FastIntentHit(
      [ToolCall('express', {'mood': 'sad'})],
      reason: 'goodbye',
    );
  }
  return null;
}

FastIntentHit? _matchGreeting(String lower) {
  if (RegExp(r'\bgood night\b').hasMatch(lower)) {
    return const FastIntentHit(
      [ToolCall('express', {'mood': 'sleepy'})],
      reason: 'good-night',
    );
  }
  if (RegExp(
    r"\b(?:hey|hi|hello)\b"
    r"|\byou awake\b"
    r"|\bwhat'?s up\b"
    r"|\bgood (?:morning|evening|afternoon)\b",
  ).hasMatch(lower)) {
    return const FastIntentHit(
      [ToolCall('express', {'mood': 'curious'})],
      reason: 'greeting',
    );
  }
  return null;
}

/// Total seconds plus leftover label. Hours / minutes / seconds (and
/// mixes like "1 minute 20 seconds") all land here.
(int, String)? _parseDurationAndLabel(String original, String lower) {
  // "two and a half hours" — must run before the chunk scan so the
  // "and a half" is not dropped as a label.
  final halfHours = RegExp(
    '\\b(${_numberToken.pattern})\\s+and\\s+a\\s+half\\s+${_hourUnit.pattern}',
  ).firstMatch(lower);
  if (halfHours != null) {
    final n = _parseNumberToken(halfHours.group(1)!);
    if (n != null) {
      return (n * 3600 + 1800, _labelAfter(original, halfHours.end));
    }
  }

  // "an hour and a half"
  final hourAndHalf =
      RegExp(r'\b(?:an?|one|1)\s+hour\s+and\s+a\s+half\b').firstMatch(lower);
  if (hourAndHalf != null) {
    return (5400, _labelAfter(original, hourAndHalf.end));
  }

  // "half an hour" / "half hour"
  final halfHour = RegExp(r'\bhalf\s+(?:an\s+)?hour\b').firstMatch(lower);
  if (halfHour != null) {
    return (1800, _labelAfter(original, halfHour.end));
  }

  var total = 0;
  var lastEnd = -1;
  for (final match in _durationChunk.allMatches(lower)) {
    final n = _parseNumberToken(match.group(1)!);
    if (n == null) continue;
    final secs = match.group(2) != null
        ? n * 3600
        : match.group(3) != null
            ? n * 60
            : n;
    total += secs;
    lastEnd = match.end;
  }
  if (lastEnd >= 0) return (total, _labelAfter(original, lastEnd));

  // "set a timer for 3, tea" — bare number is minutes.
  final bare = RegExp(r'\bfor\s+(\d+)\b').firstMatch(lower);
  if (bare != null) {
    final n = int.tryParse(bare.group(1)!);
    if (n == null) return null;
    return (n * 60, _labelAfter(original, bare.end));
  }
  return null;
}

final _hourUnit = RegExp(r'(?:hours?|hrs?)');
final _minuteUnit = RegExp(r'(?:minutes?|mins?|min)');
final _secondUnit = RegExp(r'(?:seconds?|secs?|s)');

/// `<number>[-]hours|minutes|seconds` — hyphenated "20-second" counts.
final _durationChunk = RegExp(
  '\\b(${_numberToken.pattern})(?:\\s+of)?\\s*-?\\s*'
  '(?:(${_hourUnit.pattern})|(${_minuteUnit.pattern})|(${_secondUnit.pattern}))'
  r'\b',
);

final _numberToken = RegExp(
  r'\d+|forty-five|a couple|a few|'
  r'one|two|three|four|five|six|seven|eight|nine|ten|'
  r'eleven|twelve|thirteen|fourteen|fifteen|sixteen|'
  r'seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|'
  r'seventy|eighty|ninety|a|an',
);

int? _parseNumberToken(String raw) {
  final digits = int.tryParse(raw);
  if (digits != null) return digits;
  return switch (raw.toLowerCase()) {
    'a' || 'an' || 'one' => 1,
    'two' || 'a couple' => 2,
    'three' || 'a few' => 3,
    'four' => 4,
    'five' => 5,
    'six' => 6,
    'seven' => 7,
    'eight' => 8,
    'nine' => 9,
    'ten' => 10,
    'eleven' => 11,
    'twelve' => 12,
    'thirteen' => 13,
    'fourteen' => 14,
    'fifteen' => 15,
    'sixteen' => 16,
    'seventeen' => 17,
    'eighteen' => 18,
    'nineteen' => 19,
    'twenty' => 20,
    'thirty' => 30,
    'forty' => 40,
    'forty-five' => 45,
    'fifty' => 50,
    'sixty' => 60,
    'seventy' => 70,
    'eighty' => 80,
    'ninety' => 90,
    _ => null,
  };
}

String _labelAfter(String original, int endInLower) {
  if (endInLower >= original.length) return 'timer';
  var rest = original.substring(endInLower).trim();
  rest = rest.replaceFirst(RegExp(r'^[\s,.:;!\-]+'), '');
  rest = rest.replaceFirst(
    RegExp(r'^(?:for|called|labelled|labeled|named|please)\s+',
        caseSensitive: false),
    '',
  );
  rest = rest.replaceFirst(RegExp(r'[.!?]+$'), '').trim();
  rest = rest.replaceFirst(
    RegExp(r'\s+please$', caseSensitive: false),
    '',
  );
  if (rest.isEmpty) return 'timer';
  return rest;
}
