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

/// One conservative match. [calls] is what the body should run, in order.
final class FastIntentHit {
  const FastIntentHit(this.calls, {required this.reason});

  final List<ToolCall> calls;
  final String reason;
}

/// Parse [text] (a cue, or a future ASR transcript). Null = let the LLM go.
///
/// Checks run narrow-to-broad: tool intents first, then specific moods,
/// with the catch-all greeting (`hey`/`hi`/...) last.
FastIntentHit? matchText(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  final lower = trimmed.toLowerCase();
  if (_negated(lower)) return null;

  return _matchTimerFire(lower) ??
      _matchCancelTimer(trimmed, lower) ??
      _matchPauseTimer(trimmed, lower) ??
      _matchResumeTimer(trimmed, lower) ??
      _matchSetTimer(trimmed, lower) ??
      _matchBattery(lower) ??
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

FastIntentHit? _matchCancelTimer(String original, String lower) {
  if (!RegExp(
    r'\b(?:cancel|stop|clear|delete)\b.{0,40}\b(?:timer|countdown)\b'
    r'|\bturn\s+off\b.{0,20}\b(?:timer|countdown)\b',
  ).hasMatch(lower)) {
    return null;
  }
  final label = _timerControlLabel(original);
  return FastIntentHit(
    [
      ToolCall('cancel_timer', {
        if (label != null) 'label': label,
      }),
    ],
    reason: 'cancel-timer',
  );
}

FastIntentHit? _matchPauseTimer(String original, String lower) {
  if (!RegExp(
    r'\b(?:pause|hold)\b.{0,40}\b(?:timer|countdown)\b',
  ).hasMatch(lower)) {
    return null;
  }
  final label = _timerControlLabel(original);
  return FastIntentHit(
    [
      ToolCall('pause_timer', {
        if (label != null) 'label': label,
      }),
    ],
    reason: 'pause-timer',
  );
}

FastIntentHit? _matchResumeTimer(String original, String lower) {
  // A duration means set, not resume ("start the timer for 5 minutes").
  if (_parseMinutesAndLabel(original, lower) != null) return null;
  if (!RegExp(
    r'\b(?:resume|unpause|continue)\b.{0,40}\b(?:timer|countdown)\b'
    r'|\bstart\s+(?:the\s+)?(?:timer|countdown)\b',
  ).hasMatch(lower)) {
    return null;
  }
  final label = _timerControlLabel(original);
  return FastIntentHit(
    [
      ToolCall('resume_timer', {
        if (label != null) 'label': label,
      }),
    ],
    reason: 'resume-timer',
  );
}

FastIntentHit? _matchSetTimer(String original, String lower) {
  final looksLikeSet = RegExp(
    r'\b(?:set|start|make)\b.+\btimer\b'
    r'|\btimer\s+for\b'
    r'|\bremind\s+me\b'
    r'|\bcount\s?down\b'
    r'|\bwake\s+me\b',
  ).hasMatch(lower);
  if (!looksLikeSet) return null;

  final parsed = _parseMinutesAndLabel(original, lower);
  if (parsed == null) return null;
  final (minutes, label) = parsed;
  if (minutes < 1 || minutes > 180) return null;

  return FastIntentHit(
    [
      ToolCall('set_timer', {
        'minutes': minutes,
        'label': label,
      }),
    ],
    reason: 'set-timer',
  );
}

FastIntentHit? _matchBattery(String lower) {
  if (RegExp(
    r'\b(?:battery|charged?|how much power|power left'
    r'|juice left|running low)\b',
  ).hasMatch(lower)) {
    return const FastIntentHit(
      [ToolCall('get_battery', {})],
      reason: 'battery',
    );
  }
  return null;
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

(int, String)? _parseMinutesAndLabel(String original, String lower) {
  // "two and a half hours" — must run before the plain hour check so the
  // "and a half" is not dropped as a label.
  final halfHours = RegExp(
    '\\b(${_numberToken.pattern})\\s+and\\s+a\\s+half\\s+${_hourUnit.pattern}',
  ).firstMatch(lower);
  if (halfHours != null) {
    final n = _parseNumberToken(halfHours.group(1)!);
    if (n != null) {
      return (n * 60 + 30, _labelAfter(original, halfHours.end));
    }
  }

  // "an hour and a half"
  final hourAndHalf =
      RegExp(r'\b(?:an?|one|1)\s+hour\s+and\s+a\s+half\b').firstMatch(lower);
  if (hourAndHalf != null) {
    return (90, _labelAfter(original, hourAndHalf.end));
  }

  // "half an hour" / "half hour"
  final halfHour = RegExp(r'\bhalf\s+(?:an\s+)?hour\b').firstMatch(lower);
  if (halfHour != null) {
    return (30, _labelAfter(original, halfHour.end));
  }

  final hour = _firstDuration(lower, unit: _hourUnit);
  if (hour != null) {
    final minutes = hour.$1 * 60;
    return (minutes, _labelAfter(original, hour.$2));
  }
  final minute = _firstDuration(lower, unit: _minuteUnit);
  if (minute != null) {
    return (minute.$1, _labelAfter(original, minute.$2));
  }
  // "set a timer for 3, tea" — bare number only when a timer verb is present.
  final bare = RegExp(r'\bfor\s+(\d+)\b').firstMatch(lower);
  if (bare != null) {
    final n = int.tryParse(bare.group(1)!);
    if (n == null) return null;
    return (n, _labelAfter(original, bare.end));
  }
  return null;
}

final _hourUnit = RegExp(r'\b(?:hours?|hrs?)\b');
final _minuteUnit = RegExp(r'\b(?:minutes?|mins?|min)\b');

/// `(value, endIndexInLower)` of the first `<number> <unit>` pair.
(int, int)? _firstDuration(String lower, {required RegExp unit}) {
    final pattern = RegExp(
      '\\b(${_numberToken.pattern})\\s*${unit.pattern}',
      caseSensitive: false,
    );
  final match = pattern.firstMatch(lower);
  if (match == null) return null;
  final n = _parseNumberToken(match.group(1)!);
  if (n == null) return null;
  return (n, match.end);
}

final _numberToken = RegExp(
  r'\d+|forty-five|a couple|a few|'
  r'one|two|three|four|five|six|seven|eight|nine|ten|'
  r'eleven|twelve|thirteen|fourteen|fifteen|sixteen|'
  r'seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|a|an',
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
String? _timerControlLabel(String original) {
  var rest = original.replaceAll(
    RegExp(
      r'\b(?:please|cancel|stop|clear|delete|pause|hold|resume|unpause|'
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
