/// Per-user additive overlay on [matchText].
///
/// Zipformer mangles some speakers in ways the default regex cannot see
/// (`pause the timer` → `WAS THE TEMPER`). Enrollment records those
/// substitutions; matching stays deterministic. Missing or empty overlay
/// is today's matcher. Never replaces defaults — only unions.
library;

import 'dart:convert';

/// Intents the overlay may extend. Greeting / dance / etc. stay default-only.
enum FastIntentId {
  pauseTimer,
  cancelTimer,
  resumeTimer,
  setTimer,
  battery,
}

extension FastIntentIdJson on FastIntentId {
  String get jsonKey => switch (this) {
        FastIntentId.pauseTimer => 'pause_timer',
        FastIntentId.cancelTimer => 'cancel_timer',
        FastIntentId.resumeTimer => 'resume_timer',
        FastIntentId.setTimer => 'set_timer',
        FastIntentId.battery => 'battery',
      };
}

/// Aliases for one intent. Empty lists = no overlay for that intent.
final class FastIntentAliases {
  const FastIntentAliases({
    this.phrases = const [],
    this.verb = const [],
    this.noun = const [],
  });

  static const empty = FastIntentAliases();

  /// Normalized token-span phrases (`was the temper`). Contain-search at
  /// match time, not whole-string equality.
  final List<String> phrases;

  /// Extra control verbs. Never common English (`was`, `is`, `the`).
  final List<String> verb;

  /// Extra timer/battery nouns (`temper`, `tamper`).
  final List<String> noun;

  bool get isEmpty => phrases.isEmpty && verb.isEmpty && noun.isEmpty;

  Map<String, Object?> toMap() => {
        'phrases': phrases,
        'verb': verb,
        'noun': noun,
      };

  static FastIntentAliases fromMap(Object? raw) {
    if (raw is! Map) return empty;
    return FastIntentAliases(
      phrases: _stringList(raw['phrases']),
      verb: _stringList(raw['verb']),
      noun: _stringList(raw['noun']),
    );
  }
}

List<String> _stringList(Object? raw) {
  if (raw is! List) return const [];
  return [
    for (final item in raw)
      if (item is String && item.trim().isNotEmpty) item.trim(),
  ];
}

/// Versioned overlay persisted as `fast_intent_overlay_v1`.
final class FastIntentOverlay {
  const FastIntentOverlay({this.intents = const {}});

  static const int version = 1;

  final Map<FastIntentId, FastIntentAliases> intents;

  FastIntentAliases of(FastIntentId id) => intents[id] ?? FastIntentAliases.empty;

  bool get isEmpty => intents.values.every((a) => a.isEmpty);

  String encode() => jsonEncode({
        'version': version,
        'intents': {
          for (final id in FastIntentId.values)
            id.jsonKey: of(id).toMap(),
        },
      });

  /// Null when [raw] is missing, empty, or corrupt — caller uses defaults.
  static FastIntentOverlay? decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final version = decoded['version'];
      if (version is! int || version != FastIntentOverlay.version) return null;
      final intentsRaw = decoded['intents'];
      if (intentsRaw is! Map) {
        return const FastIntentOverlay();
      }
      final intents = <FastIntentId, FastIntentAliases>{};
      for (final id in FastIntentId.values) {
        intents[id] = FastIntentAliases.fromMap(intentsRaw[id.jsonKey]);
      }
      return FastIntentOverlay(intents: intents);
    } on FormatException {
      return null;
    } catch (_) {
      return null;
    }
  }
}

/// Lowercase, strip punctuation, collapse whitespace, split on non-alnum.
List<String> tokenizeUtterance(String text) {
  return [
    for (final tok in text.toLowerCase().split(RegExp(r'[^a-z0-9]+')))
      if (tok.isNotEmpty) tok,
  ];
}

/// Tokenize and rejoin — the normalized form stored as a phrase.
String normalizeUtterance(String text) => tokenizeUtterance(text).join(' ');
