// M2 agent bar: "the transcript-persistence path round-trips under test."
// The store is exercised through the same KeyValueStore interface the
// service uses; a second TranscriptStore over the same backing data stands
// in for the process that comes back after a kill.

import 'package:cute_bot/companion/brain/transcript.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TranscriptEntry', () {
    test('map round-trip preserves role, text, timestamp', () {
      final entry = TranscriptEntry(
        role: TranscriptRole.bot,
        text: 'Beep!',
        timestamp: DateTime.fromMillisecondsSinceEpoch(1234567890),
      );
      final decoded = TranscriptEntry.fromMap(entry.toMap());
      expect(decoded, isNotNull);
      expect(decoded!.role, TranscriptRole.bot);
      expect(decoded.text, 'Beep!');
      expect(decoded.timestamp.millisecondsSinceEpoch, 1234567890);
    });

    test('rejects garbage, defaults unknown roles to system', () {
      expect(TranscriptEntry.fromMap(null), isNull);
      expect(TranscriptEntry.fromMap('nope'), isNull);
      expect(TranscriptEntry.fromMap({'role': 'user'}), isNull); // no text
      final odd = TranscriptEntry.fromMap({'role': 'alien', 'text': 'hi'});
      expect(odd!.role, TranscriptRole.system);
    });
  });

  group('TranscriptStore', () {
    test('append then load from a fresh store round-trips (kill survival)',
        () async {
      final backing = InMemoryKeyValueStore();

      final before = TranscriptStore(backing);
      await before.load();
      await before.append(
          TranscriptEntry(role: TranscriptRole.user, text: '(voice, 1.2 s)'));
      await before.append(
          TranscriptEntry(role: TranscriptRole.bot, text: 'Hello!'));

      // "Process death": a brand-new store over the same persisted bytes.
      final after = TranscriptStore(backing);
      final recovered = await after.load();

      expect(recovered.length, 2);
      expect(recovered[0].role, TranscriptRole.user);
      expect(recovered[0].text, '(voice, 1.2 s)');
      expect(recovered[1].role, TranscriptRole.bot);
      expect(recovered[1].text, 'Hello!');
    });

    test('load on empty store yields empty transcript', () async {
      final store = TranscriptStore(InMemoryKeyValueStore());
      expect(await store.load(), isEmpty);
    });

    test('corrupt persisted data recovers to empty, not a crash', () async {
      final backing = InMemoryKeyValueStore();
      backing.values[TranscriptStore.storageKey] = '{not json[';
      final store = TranscriptStore(backing);
      expect(await store.load(), isEmpty);

      // And the store still works after recovery.
      await store.append(
          TranscriptEntry(role: TranscriptRole.bot, text: 'fresh start'));
      final reloaded = await TranscriptStore(backing).load();
      expect(reloaded.single.text, 'fresh start');
    });

    test('non-list JSON recovers to empty', () async {
      final backing = InMemoryKeyValueStore();
      backing.values[TranscriptStore.storageKey] = '{"a": 1}';
      expect(await TranscriptStore(backing).load(), isEmpty);
    });

    test('caps at maxEntries, dropping oldest', () async {
      final backing = InMemoryKeyValueStore();
      final store = TranscriptStore(backing, maxEntries: 3);
      await store.load();
      for (var i = 0; i < 5; i++) {
        await store.append(
            TranscriptEntry(role: TranscriptRole.user, text: 'line $i'));
      }
      final reloaded = await TranscriptStore(backing).load();
      expect(reloaded.map((e) => e.text), ['line 2', 'line 3', 'line 4']);
    });

    test('append before load throws (misuse guard)', () async {
      final store = TranscriptStore(InMemoryKeyValueStore());
      expect(
        () => store.append(
            TranscriptEntry(role: TranscriptRole.user, text: 'x')),
        throwsStateError,
      );
    });

    test('clear removes persisted data', () async {
      final backing = InMemoryKeyValueStore();
      final store = TranscriptStore(backing);
      await store.load();
      await store
          .append(TranscriptEntry(role: TranscriptRole.user, text: 'x'));
      await store.clear();
      expect(backing.values.containsKey(TranscriptStore.storageKey), isFalse);
      expect(await TranscriptStore(backing).load(), isEmpty);
    });
  });
}
