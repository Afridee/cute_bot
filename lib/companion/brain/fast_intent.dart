/// Rule-based NLU in front of the LLM.
///
/// The bot's action space is tiny (`express` / `set_timer` /
/// `cancel_timer` / `pause_timer` / `resume_timer` / `get_battery`)
/// and the persona few-shots are formulaic. High-confidence hits skip
/// Gemma's audio encode + thought block; anything hedged falls through.
/// Precision over recall — a wrong timer is worse than a slow one.
///
/// Tool intents are hand-written matchers (duration parsing, overlay slots,
/// ASR fuzz). Mood intents are data: see [_MoodBucket] below.
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
/// Checks run narrow-to-broad and the first hit wins, so the order below is
/// the specification:
///
/// 1. Tool intents first. A misrouted timer is the expensive mistake, and
///    `stop the timer` must reach `cancel_timer` before the annoyed bucket
///    can read it as frustration.
/// 2. `cannot-do` next: it owns `say something` / `play music`, which would
///    otherwise be eaten by the greeting and play buckets.
/// 3. `quiet` before the frustration buckets — `be quiet` is a request the
///    bot can honour (`yes`), not a mood to mirror.
/// 4. Bot-directed judgement (`scold`, `praise`) before anything generic, so
///    `bad bot` is a scold while `bad day` falls through to comfort.
/// 5. First-person distress (`comfort`, then `sleepy`) before `affection`,
///    which is what makes `i need a hug` sad rather than lovestruck.
/// 6. `annoyed` sits below all of the above: an interjection should never
///    outrank an explicit request or a stated feeling.
/// 7. Farewell before greeting, and the `hey`/`hi` greeting dead last —
///    it is the widest net in the file.
///
/// Optional [overlay] is additive and tool-only: defaults run first, enrolled
/// phrases/slots only if they miss. Mood matchers are default-only.
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
      _matchQuiet(lower) ??
      _matchScold(lower) ??
      _matchPraise(lower) ??
      _matchDance(lower) ??
      _matchPlay(lower) ??
      _matchStartle(lower) ??
      _matchComfort(lower) ??
      _matchSleepy(lower) ??
      _matchAnnoyed(lower) ??
      _matchAffection(lower) ??
      _matchConfusion(lower) ??
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

// ---------------------------------------------------------------------------
// Mood intents.
//
// Every rule below resolves to exactly one `express(mood)`, so the rules are
// data: an alternation, the mood it means, and the reason string the route
// log prints. [_matchBuckets] walks a list in order and takes the first hit,
// so inside a cluster the specific rows sit above the catch-all ones — the
// same discipline [matchText] applies across clusters.
//
// Precision here is softer than for timers (a slightly wrong mood is a
// personality quirk, a wrong timer is a bug), but the rules still lean on
// bot-directed phrasing: an address ("good boy", "you're clever") or a
// stated first-person feeling ("i'm exhausted"), not bare adjectives.
// ---------------------------------------------------------------------------

final class _MoodBucket {
  _MoodBucket(String pattern, this.mood, this.reason) : _re = RegExp(pattern);

  final RegExp _re;
  final BotMood mood;
  final String reason;

  bool hits(String lower) => _re.hasMatch(lower);
}

FastIntentHit? _matchBuckets(String lower, List<_MoodBucket> buckets) {
  for (final bucket in buckets) {
    if (!bucket.hits(lower)) continue;
    return FastIntentHit(
      [
        ToolCall('express', {'mood': bucket.mood.name}),
      ],
      reason: bucket.reason,
    );
  }
  return null;
}

/// What people call the bot out loud. `friend` is deliberately absent:
/// "good friend" is almost always about a person, not the robot.
const _petNoun = r'(?:bots?|robots?|droid|boy|girl|buddy|bud|pal|guy|gal|kid'
    r'|fella|fellow|dude|baby|pet|little one)';

/// Impersonal nouns people reach for when cross. Kept off [_petNoun] so
/// praise never fires on "that's a good thing".
const _scoldNoun =
    r'(?:bots?|robots?|droid|boy|girl|guy|kid|thing|machine|toy)';

/// Optional endearment slot: "good *little* buddy".
const _petQualifier = r'(?:little |lil |tiny |wee |dumb |silly )?';

/// `<adjective> [little] <noun>` — the shape of address-style judgement.
/// Requiring the noun is what keeps "bad day" out of the scold bucket and
/// "good friend" out of praise.
String _addressed(String adjectives, String noun) =>
    '\\b(?:$adjectives)\\s+$_petQualifier$noun\\b';

/// The persona says the bot must `express(no)` when asked to do something
/// it cannot do. Only the literal impossibles — anything vaguer goes to
/// the LLM (the timer check already ran, so "can you set a timer for 5
/// minutes" never reaches this).
///
/// Runs before the mood clusters because it owns verbs they would otherwise
/// claim: `say something` (greeting), `play music` (play), `sing` (dance).
/// Things the body *can* do — wiggle, dance, blink, chirp — stay off the
/// list on purpose.
FastIntentHit? _matchCapabilityNo(String lower) =>
    _matchBuckets(lower, _capabilityBuckets);

final _capabilityBuckets = <_MoodBucket>[
  _MoodBucket(
    r'\bcan you (?:talk|speak|sing|say|whistle|read|write|walk|run|jump'
    r'|fly|swim|drive|cook|type|shout|yell|whisper|call)\b'
    r'|\bsay something\b|\bsay (?:hi|hello|my name|that|it)\b'
    r'|\bsing (?:me )?a song\b|\bsing along\b'
    r'|\btell me (?:a joke|a story|the time|a secret|about)\b'
    r"|\bwhat time is it\b|\bwhat'?s the (?:time|weather)\b"
    r'|\bplay (?:some )?(?:music|a song|the radio)\b'
    r'|\bcan you fetch\b|\bfetch it\b',
    BotMood.no,
    'cannot-do',
  ),
];

/// Acknowledge the request. Deliberately above the frustration buckets:
/// "be quiet" is something the bot can agree to, not a mood to mirror.
/// `stop it` / `stop beeping` stay with the LLM (no timer word, and they
/// are not hush/quiet).
FastIntentHit? _matchQuiet(String lower) =>
    _matchBuckets(lower, _quietBuckets);

final _quietBuckets = <_MoodBucket>[
  _MoodBucket(
    r'\bbe quiet\b|\bstay quiet\b|\bkeep quiet\b|\bquiet down\b'
    r'|\bquiet please\b'
    r'|\bkeep it down\b|\bpipe down\b|\bhush\b|\bshush\b|\bsh{2,}\b'
    r'|\btoo loud\b|\bnot so loud\b|\bless noise\b|\bno noise\b'
    r'|\bsilence please\b|\bsettle down\b|\bcalm down\b|\bbe still\b'
    r'|\bindoor voice\b',
    BotMood.yes,
    'quiet',
  ),
];

/// Conservative: the insult has to land on the bot, so "bad day" stays with
/// the comfort matcher below. Runs before praise so a mixed utterance
/// resolves to the complaint, and before comfort so "bad bot" is a scold.
///
/// `silly` / `goofy` are *not* scold words here — they read as affectionate
/// teasing, so they belong to the play bucket.
FastIntentHit? _matchScold(String lower) =>
    _matchBuckets(lower, _scoldBuckets);

final _scoldBuckets = <_MoodBucket>[
  _MoodBucket(
    _addressed(
          'bad|stupid|dumb|naughty|useless|broken|worthless|terrible|awful'
          '|horrible|annoying|noisy|lazy|rubbish',
          _scoldNoun,
        ) +
        r"|\byou(?:'?re| are)\s+(?:so\s+|such\s+a\s+|being\s+|really\s+)*"
        r'(?:bad|naughty|useless|broken|annoying|in trouble|a menace)\b'
        r'|\bgo away\b|\bleave me alone\b|\bget lost\b|\bshame on you\b'
        r"|\bi'?m mad at you\b|\bi'?m cross with you\b|\bnaughty\b"
        r'|\bstop bothering me\b',
    BotMood.sad,
    'scold',
  ),
];

/// Thanks / well-done / address-style compliments. Above [_matchAffection]
/// so "sweet boy" is praise while a bare "you're sweet" is affection, and
/// above the play and greeting buckets so "good job, buddy" cannot be read
/// as either.
FastIntentHit? _matchPraise(String lower) =>
    _matchBuckets(lower, _praiseBuckets);

final _praiseBuckets = <_MoodBucket>[
  _MoodBucket(
    r'\bthank you\b|\bthanks\b|\bthank u\b|\bthx\b|\bta very much\b'
    r'|\bappreciate (?:it|you|that)\b|\bmuch obliged\b',
    BotMood.happy,
    'thanks',
  ),
  // Achievement praise reads as pride rather than plain happiness.
  _MoodBucket(
    r'\bwell done\b|\bgood job\b|\bnice job\b|\bgreat job\b|\bgood work\b'
    r'|\bnice work\b|\bgreat work\b|\bnice one\b|\byou did it\b'
    r'|\byou nailed it\b|\bnailed it\b|\bproud of you\b|\bway to go\b'
    r'|\bwell played\b|\bbravo\b|\batta ?(?:boy|girl)\b|\bgood call\b'
    r'|\byou got it right\b|\bperfect job\b',
    BotMood.proud,
    'well-done',
  ),
  _MoodBucket(
    _addressed(
          'good|great|sweet|clever|smart|brilliant|best|brave|nice|lovely'
          '|precious|perfect|amazing|awesome|wonderful|excellent|handsome'
          '|pretty|champion|star',
          _petNoun,
        ) +
        r"|\byou(?:'?re| are)\s+(?:such\s+)?(?:a\s+|the\s+|so\s+|very\s+"
        r'|really\s+|quite\s+)*(?:good|great|clever|smart|brilliant|amazing'
        r'|awesome|wonderful|excellent|impressive|helpful|the best|best)\b'
        r'|\bgood (?:helper|listener|little helper)\b'
        r"|\byou'?re my favou?rite\b|\bbest (?:bot|robot|buddy|boy|girl) ever\b"
        r'|\bnice bot\b|\bwhat a (?:good|clever|smart) (?:bot|boy|girl)\b'
        r'|\bi like you\b|\byou did great\b',
    BotMood.happy,
    'praise',
  ),
];

/// Dance / wiggle, plus the celebration cluster — both land on `delighted`,
/// but they keep separate reasons so the route log stays legible.
/// "boogie" is intentionally missing: `boogie time` is not a dance request.
FastIntentHit? _matchDance(String lower) =>
    _matchBuckets(lower, _danceBuckets);

final _danceBuckets = <_MoodBucket>[
  _MoodBucket(
    r'\bdance\b|\bdancing\b|\bwiggle\b|\bwiggles\b|\bshimmy\b'
    r'|\bshake it\b|\bspin around\b|\bbust a move\b|\bdance party\b',
    BotMood.delighted,
    'dance',
  ),
  _MoodBucket(
    r'\byay+\b|\bwoo-?hoo+\b|\bwoo+\b|\byippee\b|\bhoo?ray\b|\bhurray\b'
    r"|\bwe did it\b|\bi did it\b|\bwe won\b|\bi won\b|\blet'?s celebrate\b"
    r'|\bcelebrate\b|\bparty time\b|\bgreat news\b|\bguess what\b'
    r"|\bi'?m (?:so |really )?excited\b|\bso exciting\b|\bhow exciting\b"
    r'|\bi got the job\b|\bcongrats\b|\bcongratulations\b|\bit worked\b',
    BotMood.delighted,
    'celebrate',
  ),
];

/// Invitations to mess about. The `let's go` rule carries a lookahead so
/// "let's go to bed" keeps falling through to the sleepy bucket.
FastIntentHit? _matchPlay(String lower) => _matchBuckets(lower, _playBuckets);

final _playBuckets = <_MoodBucket>[
  _MoodBucket(
    r"\bwan?na play\b|\blet'?s play\b|\bplay with me\b|\bplay ?time\b"
    r'|\bpeek-?a-?boo\b|\btickle\b|\bhide and seek\b|\bplay tag\b'
    r"|\btag,? you'?re it\b|\bchase me\b|\bcatch me\b|\brace you\b"
    r'|\bhigh five\b|\bboop\b'
    r"|\blet'?s go\b(?!\s+(?:to|home|out|inside|upstairs)\b)"
    r'|\bdo (?:it|that) again\b|\bone more time\b|\bonce more\b|^again\b'
    r"|\byou(?:'?re| are)\s+(?:so\s+|such\s+a\s+)*"
    r'(?:silly|goofy|cheeky|funny)\b'
    r'|\bsilly (?:bot|robot|boy|girl|guy)\b|\bwhat a goof\b'
    r'|\bdo a trick\b|\bshow me a trick\b|\bfun time\b|\bhaving fun\b'
    r'|\bare you ticklish\b',
    BotMood.playful,
    'play',
  ),
];

/// Deliberately tiny. `boo` is word-bounded so "boogie" cannot reach it, and
/// the lookaheads keep "boo hoo" (crying) and "surprise party" (a plan) out.
FastIntentHit? _matchStartle(String lower) =>
    _matchBuckets(lower, _startleBuckets);

final _startleBuckets = <_MoodBucket>[
  _MoodBucket(
    r'\bboo\b(?!\s*hoo)|\bsurprise\b(?!\s+party)|\bgotcha\b'
    r'|\bwatch out\b|\blook out\b|\bheads up\b',
    BotMood.startled,
    'startle',
  ),
];

/// First-person distress only. Open-ended emotional talk ("I am feeling a
/// bit sad today") stays with the LLM on purpose — the fast path can only
/// blink a colour, and hedged sadness deserves the model's turn.
///
/// The intensifier list excludes `feeling`, which is exactly what keeps
/// that sentence a miss.
FastIntentHit? _matchComfort(String lower) =>
    _matchBuckets(lower, _comfortBuckets);

final _comfortBuckets = <_MoodBucket>[
  _MoodBucket(
    r"\bi(?:'?m| am)\s+(?:so\s+|really\s+|very\s+|super\s+|just\s+|kinda\s+"
    r'|quite\s+|pretty\s+)*(?:sad|down|blue|lonely|stressed|upset|miserable'
    r'|heartbroken|overwhelmed|worn out|fed up|struggling)\b'
    r'|\bfeeling (?:down|low|blue|awful|terrible|lousy|rough|rubbish)\b'
    r'|\b(?:bad|rough|long|hard|terrible|awful|horrible|tough|stressful)'
    r'\s+(?:day|week|morning|night|shift)\b'
    r'|\bworst day\b|\bi need a hug\b|\bi could use a hug\b'
    r"|\bi feel awful\b|\bi'?m crying\b|\bi got fired\b|\bi failed\b"
    r'|\bnothing went right\b|\bcheer me up\b|\bi miss (?:her|him|them)\b',
    BotMood.sad,
    'comfort',
  ),
];

/// Winding down. Sits below comfort so "i'm exhausted and sad" reads as
/// sadness, and above farewell so "see you tomorrow" stays a sleepy
/// goodnight rather than a sad goodbye.
///
/// `good night` is *not* here: it keeps its own `good-night` reason in
/// [_matchGreeting].
FastIntentHit? _matchSleepy(String lower) =>
    _matchBuckets(lower, _sleepyBuckets);

final _sleepyBuckets = <_MoodBucket>[
  _MoodBucket(
    r'\bgo to sleep\b|\bgo to bed\b|\bgoing to (?:sleep|bed)\b|\bnap ?time\b'
    r'|\btime for bed\b|\bbed ?time\b|\bsweet dreams\b|\bsee you tomorrow\b'
    r'|\bnight night\b|\bnighty ?night\b|\blights out\b|\bturning in\b'
    r'|\bsleep well\b|\bsleep tight\b|\bsleepy time\b|\bcall it a night\b'
    r'|\bcall it a day\b|\brest now\b|\bget some rest\b',
    BotMood.sleepy,
    'wind-down',
  ),
  _MoodBucket(
    r"\bi(?:'?m| am)\s+(?:so\s+|really\s+|very\s+|super\s+|just\s+|kinda\s+"
    r'|quite\s+|pretty\s+)*(?:tired|sleepy|exhausted|beat|knackered|drained'
    // "i'm tired *of* this" is frustration, not drowsiness.
    r'|wiped|dozing off|falling asleep|off to bed|ready for bed)\b(?!\s+of\b)'
    r'|\bneed (?:a nap|some sleep|to sleep|sleep)\b|\btaking a nap\b'
    r'|\byawn(?:ing)?\b|\bso sleepy\b|\bso tired\b|\bcan barely keep my eyes\b'
    r'|\bare you sleepy\b|\bare you tired\b',
    BotMood.sleepy,
    'sleepy',
  ),
];

/// Interjection-level frustration. Last of the negative moods on purpose:
/// `stop the timer` is already a cancel, `be quiet` is already a request,
/// and a stated feeling ("i'm stressed") should win over a grumble. No
/// `stop …` rule lives here, which is what keeps "stop beeping" a miss.
FastIntentHit? _matchAnnoyed(String lower) =>
    _matchBuckets(lower, _annoyedBuckets);

final _annoyedBuckets = <_MoodBucket>[
  _MoodBucket(
    r'\bugh+\b|\bgrr+\b|\bargh+\b|\bblah\b|\boh (?:man|no)\b'
    // Bare "that's enough" only — "that's enough sugar" is about the sugar.
    r"|\benough already\b|\bthat'?s enough\b(?!\s+\w)|\benough of that\b"
    r'|\bknock it off\b|\bcut it out\b|\boh come on\b|\bcome on now\b'
    r'|\bseriously\b|\bnot again\b|\bso annoying\b|\bhow annoying\b'
    r"|\bi'?m annoyed\b|\bi'?m frustrated\b|\bso frustrating\b"
    r'|\bgive me a break\b|\bwhat a mess\b|\bfor crying out loud\b',
    BotMood.annoyed,
    'annoyed',
  ),
];

/// Warmth aimed at the bot. Below comfort so "i need a hug" is answered with
/// sympathy, not a purr, and below praise so "sweet girl" is happy while a
/// plain "you're sweet" is love.
FastIntentHit? _matchAffection(String lower) =>
    _matchBuckets(lower, _affectionBuckets);

final _affectionBuckets = <_MoodBucket>[
  _MoodBucket(
    r'\blove (?:you|ya)\b|\bluv you\b|\bi love this (?:bot|robot|guy|thing)\b'
    r'|\bmiss(?:ed)? (?:you|ya)\b'
    r"|\byou(?:'?re| are)\s+(?:so\s+|too\s+|very\s+|really\s+|such\s+a\s+"
    r'|the\s+)*(?:cute|adorable|sweet|lovely|precious|darling|charming'
    r'|cutest|sweetest)\b'
    r'|\bcutie\b|\bsweetie\b|\bsweetheart\b|\bmy little (?:guy|girl|buddy'
    r'|friend|robot|bot|one)\b'
    r'|\bhugs?\b|\bcuddle\b|\bsnuggle\b|\bsmooch\b'
    r'|\bkiss (?:you|me)\b|\bkisses\b|\bkissy\b'
    r'|\bcome here\b|\bcome to me\b|\bpet you\b|\bscratch your head\b'
    r'|\byou make me happy\b|\bglad you'
    r"'?re here\b|\bmy favou?rite (?:bot|robot|little)\b",
    BotMood.love,
    'affection',
  ),
];

/// Honest bafflement. Narrow: only utterances that are explicitly about
/// (mis)understanding, so ordinary questions still reach the LLM.
FastIntentHit? _matchConfusion(String lower) =>
    _matchBuckets(lower, _confusionBuckets);

final _confusionBuckets = <_MoodBucket>[
  _MoodBucket(
    r'\bhuh\b|\bwhat\?|\bwhat do you mean\b|\bwhat was that\b'
    r'|\bdo you understand\b|\bdid you (?:get|catch|hear) that\b'
    r'|\bdoes that make sense\b|\bmakes no sense\b'
    r'|\bare you (?:confused|lost|stuck|broken)\b|\bany idea\b',
    BotMood.confused,
    'confused',
  ),
];

/// Leaving. Below the sleepy bucket so bedtime phrasing wins, above the
/// greeting catch-all so "see you" is not read as a hello.
FastIntentHit? _matchFarewell(String lower) =>
    _matchBuckets(lower, _farewellBuckets);

final _farewellBuckets = <_MoodBucket>[
  _MoodBucket(
    r'\bgood-?bye\b|\bbye-?bye\b|\bbye\b|\bfarewell\b|\bciao\b|\badios\b'
    r'|\bsee (?:you|ya)\b|\bcatch (?:you|ya) later\b'
    r'|\btalk (?:to you )?later\b|\bgotta go\b|\bgot to go\b'
    r"|\bi have to go\b|\bi need to go\b|\bi'?m leaving\b|\bleaving now\b"
    r"|\bi'?m heading (?:out|off|home)\b|\bi'?m off\b|\bheading home\b"
    r'|\btake care\b(?!\s+of\b)|\buntil tomorrow\b|\bback later\b'
    r'|\bhave to run\b'
    r'|\bwish me luck\b',
    BotMood.sad,
    'goodbye',
  ),
];

/// The widest net in the file, so it runs last: hellos, pings, and
/// are-you-there checks all land on `curious`.
FastIntentHit? _matchGreeting(String lower) =>
    _matchBuckets(lower, _greetingBuckets);

final _greetingBuckets = <_MoodBucket>[
  // Its own reason so the log distinguishes a goodnight from a hello.
  _MoodBucket(r'\bgood night\b', BotMood.sleepy, 'good-night'),
  _MoodBucket(
    r'\b(?:hey|hi|hiya|hello|howdy|yo|sup|psst|greetings)\b'
    r'|\bgood (?:morning|evening|afternoon)\b'
    r'|\b(?:are )?you awake\b|\bwake up\b|\bare you (?:there|around|up)\b'
    r"|\byou there\b|\banyone home\b|\banybody home\b|\bknock knock\b"
    r'|\bcan you hear me\b|\bare you listening\b|\bcan you see me\b'
    r"|\bwhat'?s up\b|\bwhat'?cha (?:doing|up to)\b"
    r'|\bwhat are you (?:doing|up to)\b|\bwhat you (?:doing|up to)\b'
    r'|\bare you (?:ok|okay|alright|well)\b|\bhow are you\b'
    r"|\bhow'?s it going\b|\bhow you doing\b|\bare you busy\b"
    r'|\blook at me\b|\bover here\b|\bdo you see me\b|\bpay attention\b'
    r'|\bcheck this out\b|\blook what i\b',
    BotMood.curious,
    'greeting',
  ),
];

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
