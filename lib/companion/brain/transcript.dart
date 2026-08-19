/// Conversation transcript and its persistence path (M2).
///
/// A foreground service is not immortal: the low-memory killer and OEM
/// battery managers take it on their own schedule, and the model's KV cache
/// cannot be checkpointed. So the *transcript* is the durable artifact —
/// persisted outside process memory on every append, replayed into a fresh
/// brain session after kill → restart → re-warm.
///
/// Storage sits behind [KeyValueStore] so this whole path unit-tests in
/// memory; the service plugs in flutter_foreground_task's store (backed by
/// SharedPreferences). Pending timers (M4) will reuse the same interface.
library;

import 'dart:convert';

/// Who said it.
enum TranscriptRole { user, bot, system }

TranscriptRole _roleFromName(Object? name) => TranscriptRole.values.firstWhere(
      (r) => r.name == name,
      orElse: () => TranscriptRole.system,
    );

/// One transcript line. Until STT/native audio lands (M3), user entries are
/// placeholders like "(voice, 1.2 s)" — the shape of the recovery path is
/// what M2 proves, not the content.
final class TranscriptEntry {
  TranscriptEntry({
    required this.role,
    required this.text,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  final TranscriptRole role;
  final String text;
  final DateTime timestamp;

  Map<String, Object?> toMap() => {
        'role': role.name,
        'text': text,
        'at': timestamp.millisecondsSinceEpoch,
      };

  static TranscriptEntry? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final text = raw['text'];
    if (text is! String) return null;
    final at = raw['at'];
    return TranscriptEntry(
      role: _roleFromName(raw['role']),
      text: text,
      timestamp: DateTime.fromMillisecondsSinceEpoch(
          at is int ? at : DateTime.now().millisecondsSinceEpoch),
    );
  }
}

/// Minimal durable storage. Values must be JSON-encodable strings on the
/// real backend, so this interface only deals in strings.
abstract interface class KeyValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> remove(String key);
}

/// Test double, and a reference for the semantics the real store must have.
final class InMemoryKeyValueStore implements KeyValueStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> remove(String key) async => values.remove(key);
}

/// Append-mostly transcript store with write-through persistence.
///
/// Usage: `load()` once at session start (this is the recovery read), then
/// `append()` per line. Every append persists synchronously-in-order, so a
/// kill at any moment loses at most the line being written.
final class TranscriptStore {
  TranscriptStore(this._store, {this.maxEntries = 200});

  static const String storageKey = 'transcript_v1';

  final KeyValueStore _store;

  /// Cap on persisted entries; oldest drop first. Generous relative to what
  /// a re-prefill can afford (M3 will budget tokens, not entries).
  final int maxEntries;

  final List<TranscriptEntry> _entries = [];
  bool _loaded = false;

  /// In-memory view, oldest first. Valid after [load].
  List<TranscriptEntry> get entries => List.unmodifiable(_entries);

  /// Reads the persisted transcript. Malformed or missing data yields an
  /// empty transcript — recovery must never fail on a corrupt store.
  Future<List<TranscriptEntry>> load() async {
    _entries.clear();
    _loaded = true;
    final raw = await _store.read(storageKey);
    if (raw == null) return entries;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        for (final item in decoded) {
          final entry = TranscriptEntry.fromMap(item);
          if (entry != null) _entries.add(entry);
        }
      }
    } on FormatException {
      // Corrupt store: start fresh rather than wedging recovery.
    }
    return entries;
  }

  Future<void> append(TranscriptEntry entry) async {
    if (!_loaded) {
      throw StateError('TranscriptStore.append before load()');
    }
    _entries.add(entry);
    if (_entries.length > maxEntries) {
      _entries.removeRange(0, _entries.length - maxEntries);
    }
    await _persist();
  }

  Future<void> clear() async {
    _entries.clear();
    _loaded = true;
    await _store.remove(storageKey);
  }

  Future<void> _persist() => _store.write(
        storageKey,
        jsonEncode([for (final e in _entries) e.toMap()]),
      );
}
