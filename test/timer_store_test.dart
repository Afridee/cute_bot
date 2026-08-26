import 'package:cute_bot/companion/brain/transcript.dart';
import 'package:cute_bot/companion/service/timer_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PendingTimer', () {
    test('map round-trip', () {
      final t = PendingTimer(
        id: 't1',
        minutes: 3,
        label: 'tea',
        firesAt: DateTime.fromMillisecondsSinceEpoch(1_700_000_000_000),
      );
      final decoded = PendingTimer.fromMap(t.toMap());
      expect(decoded, isNotNull);
      expect(decoded!.id, 't1');
      expect(decoded.minutes, 3);
      expect(decoded.label, 'tea');
      expect(decoded.firesAt.millisecondsSinceEpoch, 1_700_000_000_000);
    });

    test('isDueAt / remainingAt', () {
      final now = DateTime.fromMillisecondsSinceEpoch(1000);
      final t = PendingTimer(
        id: 't1',
        minutes: 1,
        label: 'x',
        firesAt: now.add(const Duration(seconds: 5)),
      );
      expect(t.isDueAt(now), isFalse);
      expect(t.remainingAt(now), const Duration(seconds: 5));
      expect(t.isDueAt(now.add(const Duration(seconds: 5))), isTrue);
      expect(t.remainingAt(now.add(const Duration(seconds: 9))), Duration.zero);
    });

    test('rejects garbage', () {
      expect(PendingTimer.fromMap(null), isNull);
      expect(PendingTimer.fromMap({'id': 't', 'minutes': 0, 'label': 'x', 'firesAt': 1}),
          isNull);
    });
  });

  group('TimerStore', () {
    test('add then load from a fresh store (kill survival)', () async {
      final backing = InMemoryKeyValueStore();
      final before = TimerStore(backing);
      await before.load();
      final timer = PendingTimer(
        id: 't1',
        minutes: 5,
        label: 'tea',
        firesAt: DateTime.fromMillisecondsSinceEpoch(50),
      );
      expect(await before.add(timer), isTrue);

      final after = TimerStore(backing);
      final recovered = await after.load();
      expect(recovered, hasLength(1));
      expect(recovered.single.id, 't1');
      expect(recovered.single.label, 'tea');
    });

    test('remove drops the id and persists', () async {
      final backing = InMemoryKeyValueStore();
      final store = TimerStore(backing);
      await store.load();
      await store.add(PendingTimer(
        id: 'a',
        minutes: 1,
        label: 'a',
        firesAt: DateTime.fromMillisecondsSinceEpoch(1),
      ));
      await store.add(PendingTimer(
        id: 'b',
        minutes: 1,
        label: 'b',
        firesAt: DateTime.fromMillisecondsSinceEpoch(2),
      ));
      expect((await store.remove('a'))?.id, 'a');
      expect(await TimerStore(backing).load(), hasLength(1));
      expect((await TimerStore(backing).load()).single.id, 'b');
    });

    test('caps at maxPending', () async {
      final store = TimerStore(InMemoryKeyValueStore());
      await store.load();
      for (var i = 0; i < TimerStore.maxPending; i++) {
        expect(
          await store.add(PendingTimer(
            id: 't$i',
            minutes: 1,
            label: 'n',
            firesAt: DateTime.fromMillisecondsSinceEpoch(i),
          )),
          isTrue,
        );
      }
      expect(
        await store.add(PendingTimer(
          id: 'overflow',
          minutes: 1,
          label: 'n',
          firesAt: DateTime.fromMillisecondsSinceEpoch(99),
        )),
        isFalse,
      );
      expect(store.pending, hasLength(TimerStore.maxPending));
    });

    test('corrupt data recovers empty', () async {
      final backing = InMemoryKeyValueStore();
      backing.values[TimerStore.storageKey] = '{not json';
      expect(await TimerStore(backing).load(), isEmpty);
    });
  });
}
