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
/// with the catch-all greeting (`hey`/`hi`/...) last. Optional [overlay] is
/// additive: defaults run first; enrolled phrases/slots only if they miss.
FastIntentHit? matchText(String text, [FastIntentOverlay? overlay]) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  final lower = trimmed.toLowerCase();
  if (_negated(lower)) return null;

  return _matchTimerFire(lower) ??
      _matchCancelTimer(trimmed, lower, overlay) ??
      _matchPauseTimer(trimmed, lower, overlay) ??
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

const _pauseVerbs = ['pause', 'hold', 'freeze'];
const _cancelVerbs = [
  'cancel',
  'stop',
  'clear',
  'delete',
  'kill',
  'dismiss',
  'drop',
  'forget',
];
const _resumeVerbs = ['resume', 'unpause', 'continue', 'start'];
const _timerNouns = ['timer', 'countdown'];

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
  String original,
  String lower,
  FastIntentOverlay? overlay,
) {
  final aliases = overlay?.of(FastIntentId.cancelTimer);
  if (!RegExp(
    r'\b(?:cancel|stop|clear|delete|kill|dismiss|drop|forget)\b.{0,40}\b(?:timer|countdown)\b'
    r'|\bturn\s+off\b.{0,20}\b(?:timer|countdown)\b',
  ).hasMatch(lower)) {
    if (!_overlayControlHits(lower, aliases, _cancelVerbs)) return null;
  }
  final label = _timerControlLabel(original, aliases);
  return FastIntentHit(
    [
      ToolCall('cancel_timer', {
        'label': ?label,
      }),
    ],
    reason: 'cancel-timer',
  );
}

FastIntentHit? _matchPauseTimer(
  String original,
  String lower,
  FastIntentOverlay? overlay,
) {
  final aliases = overlay?.of(FastIntentId.pauseTimer);
  if (!RegExp(
    r'\b(?:pause|hold|freeze)\b.{0,40}\b(?:timer|countdown)\b',
  ).hasMatch(lower)) {
    if (!_overlayControlHits(lower, aliases, _pauseVerbs)) return null;
  }
  final label = _timerControlLabel(original, aliases);
  return FastIntentHit(
    [
      ToolCall('pause_timer', {
        'label': ?label,
      }),
    ],
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
  final aliases = overlay?.of(FastIntentId.resumeTimer);
  if (!RegExp(
    r'\b(?:resume|unpause|continue)\b.{0,40}\b(?:timer|countdown)\b'
    r'|\bstart\s+(?:the\s+)?(?:timer|countdown)\b',
  ).hasMatch(lower)) {
    if (!_overlayControlHits(lower, aliases, _resumeVerbs)) return null;
  }
  final label = _timerControlLabel(original, aliases);
  return FastIntentHit(
    [
      ToolCall('resume_timer', {
        'label': ?label,
      }),
    ],
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
    r'\b(?:set|start|make|create|put|give\s+me|need|want)\b'
    r'.{0,40}\b(?:a\s+)?(?:timer|countdown|alarm)\b'
    r'|\b(?:timer|countdown|alarm)\s+(?:for|of|in|to)\b'
    r'|\b(?:timer|countdown)\b.{0,24}\b(?:seconds?|secs?|minutes?|mins?|hours?|hrs?)\b'
    r'|\b(?:seconds?|secs?|minutes?|mins?|hours?|hrs?)\b.{0,16}\b(?:timer|countdown)\b'
    r'|\bremind\s+me\b'
    r'|\bcount\s?down\b'
    r'|\bwake\s+me\b'
    r'|\btime\s+me\b',
  ).hasMatch(lower)) {
    return true;
  }
  return _hasNearMissTimerNoun(lower);
}

/// Zipformer often drops or swaps a letter in "timer". Distance 0 is
/// already covered above; 1–2 on a short token is the ASR near-miss.
bool _hasNearMissTimerNoun(String lower) {
  const target = 'timer';
  for (final token in lower.split(RegExp(r'[^a-z]+'))) {
    if (token.length < 4 || token.length > 7) continue;
    if (token == target) continue;
    final d = _editDistance(token, target);
    if (d >= 1 && d <= 2) return true;
  }
  return false;
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
    r'\b(?:battery|charged?|how much power|power left'
    r'|juice left|running low)\b',
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

/// Enrolled phrase as a token span, or overlay-verb × overlay-noun /
/// overlay-verb × default noun / default-verb × overlay-noun.
bool _overlayControlHits(
  String lower,
  FastIntentAliases? aliases,
  List<String> defaultVerbs,
) {
  if (aliases == null || aliases.isEmpty) return false;
  if (_overlayPhraseHits(lower, aliases.phrases)) return true;
  if (_slotPairHits(lower, aliases.verb, aliases.noun)) return true;
  if (_slotPairHits(lower, aliases.verb, _timerNouns)) return true;
  if (_slotPairHits(lower, defaultVerbs, aliases.noun)) return true;
  return false;
}

bool _overlayPhraseHits(String lower, List<String> phrases) {
  if (phrases.isEmpty) return false;
  final hay = tokenizeUtterance(lower);
  for (final phrase in phrases) {
    final ned = tokenizeUtterance(phrase);
    if (ned.isEmpty || hay.length < ned.length) continue;
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
    r'\b(?:dance|wiggle|spin|shake|boogie|bust a move|show me a move'
    r'|do a (?:little )?trick|do a (?:little )?dance)\b',
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
  if (RegExp(
    r'\bboo\b|\bsurprise\b|\bwake up\b|\blook out\b',
  ).hasMatch(lower)) {
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
    r"\b(?:love you|i love you|love ya|you're cute|you are cute"
    r'|cutie|adorable|sweetheart)\b'
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
    r"\b(?:hey|hi|hello|yo|sup|howdy)\b"
    r"|\byou awake\b"
    r"|\bwhat'?s up\b"
    r"|\bgood (?:morning|evening|afternoon)\b"
    r"|\bmorning\b",
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

/// Leftover words after stripping cancel/pause/resume phrasing. Null when
/// the utterance did not name a specific timer.
String? _timerControlLabel(String original, [FastIntentAliases? aliases]) {
  final extra = <String>[
    ...?aliases?.verb,
    ...?aliases?.noun,
    for (final phrase in aliases?.phrases ?? const <String>[])
      ...tokenizeUtterance(phrase),
  ];
  final extraPat = extra.isEmpty
      ? ''
      : '${extra.map(RegExp.escape).join('|')}|';
  var rest = original.replaceAll(
    RegExp(
      '\\b(?:$extraPat'
      r'please|cancel|stop|clear|delete|kill|dismiss|drop|forget|pause|hold|freeze|resume|unpause|'
      r'continue|start|turn|off|again|the|my|this|a|an|timer|countdown|'
      r'for|called|labelled|labeled|named|on)\b',
      caseSensitive: false,
    ),
    ' ',
  );
  rest = rest.replaceAll(RegExp(r'[^\w\s]+'), ' ');
  rest = rest.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (rest.isEmpty) return null;
  return rest;
}
