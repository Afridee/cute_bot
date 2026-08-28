import 'package:cute_bot/companion/brain/transcript.dart';
import 'package:cute_bot/companion/service/timer_store.dart';
import 'package:cute_bot/shared/timer_display.dart';
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
      expect(decoded.isPaused, isFalse);
    });

    test('paused map round-trip', () {
      final t = PendingTimer(
        id: 't1',
        minutes: 3,
        label: 'tea',
        firesAt: DateTime.fromMillisecondsSinceEpoch(1_700_000_000_000),
        pausedRemaining: const Duration(seconds: 42),
      );
      final decoded = PendingTimer.fromMap(t.toMap());
      expect(decoded!.isPaused, isTrue);
      expect(decoded.pausedRemaining, const Duration(seconds: 42));
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

    test('pause freezes remaining; resume continues from the freeze', () {
      final now = DateTime.fromMillisecondsSinceEpoch(1000);
      final t = PendingTimer(
        id: 't1',
        minutes: 1,
        label: 'x',
        firesAt: now.add(const Duration(seconds: 30)),
      );
      final paused = t.pauseAt(now);
      expect(paused.isPaused, isTrue);
      expect(paused.remainingAt(now.add(const Duration(seconds: 10))),
          const Duration(seconds: 30));
      expect(paused.isDueAt(now.add(const Duration(hours: 1))), isFalse);
      final later = now.add(const Duration(seconds: 10));
      final resumed = paused.resumeAt(later);
      expect(resumed.isPaused, isFalse);
      expect(resumed.remainingAt(later), const Duration(seconds: 30));
      expect(resumed.isDueAt(later.add(const Duration(seconds: 30))), isTrue);
    });

    test('rejects garbage', () {
      expect(PendingTimer.fromMap(null), isNull);
      expect(PendingTimer.fromMap({'id': 't', 'minutes': 0, 'label': 'x', 'firesAt': 1}),
          isNull);
    });
  });

  group('formatTimerCountdown', () {
    test('formats HH:MM:SS remaining', () {
      final now = DateTime.fromMillisecondsSinceEpoch(0);
      final t = PendingTimer(
        id: 't1',
        minutes: 1,
        label: '',
        firesAt: now.add(const Duration(seconds: 5)),
      );
      expect(formatTimerCountdown(t, now), '00:00:05');
      expect(
        formatTimerCountdown(
          PendingTimer(
            id: 't2',
            minutes: 1,
            label: '',
            firesAt: now.add(const Duration(minutes: 1)),
          ),
          now,
        ),
        '00:01:00',
      );
      expect(
        formatTimerCountdown(
          PendingTimer(
            id: 't3',
            minutes: 180,
            label: '',
            firesAt: now.add(const Duration(minutes: 180)),
          ),
          now,
        ),
        '03:00:00',
      );
    });

    test('isTimerDisplayText matches wire shape', () {
      expect(isTimerDisplayText('00:04:59'), isTrue);
      expect(isTimerDisplayText('03:00:00'), isTrue);
      expect(isTimerDisplayText('thinking…'), isFalse);
      expect(isTimerDisplayText('set_timer(1, tea)'), isFalse);
    });

    test('soonestPendingTimer picks earliest firesAt', () {
      final a = PendingTimer(
        id: 'a',
        minutes: 1,
        label: 'a',
        firesAt: DateTime.fromMillisecondsSinceEpoch(200),
      );
      final b = PendingTimer(
        id: 'b',
        minutes: 1,
        label: 'b',
        firesAt: DateTime.fromMillisecondsSinceEpoch(100),
      );
      expect(soonestPendingTimer([a, b])?.id, 'b');
      expect(soonestPendingTimer(const []), isNull);
    });

    test('soonestPendingTimer skips paused timers', () {
      final running = PendingTimer(
        id: 'run',
        minutes: 1,
        label: 'a',
        firesAt: DateTime.fromMillisecondsSinceEpoch(200),
      );
      final paused = PendingTimer(
        id: 'pause',
        minutes: 1,
        label: 'b',
        firesAt: DateTime.fromMillisecondsSinceEpoch(50),
        pausedRemaining: const Duration(seconds: 9),
      );
      expect(soonestPendingTimer([running, paused])?.id, 'run');
      expect(timerForDisplay([running, paused])?.id, 'run');
      expect(timerForDisplay([paused])?.id, 'pause');
    });

    test('pickTimer prefers running, or paused when asked', () {
      final running = PendingTimer(
        id: 'run',
        minutes: 1,
        label: 'tea',
        firesAt: DateTime.fromMillisecondsSinceEpoch(200),
      );
      final paused = PendingTimer(
        id: 'pause',
        minutes: 1,
        label: 'bread',
        firesAt: DateTime.fromMillisecondsSinceEpoch(50),
        pausedRemaining: const Duration(seconds: 9),
      );
      expect(pickTimer([running, paused])?.id, 'run');
      expect(pickTimer([running, paused], preferPaused: true)?.id, 'pause');
      expect(pickTimer([running, paused], label: 'bread')?.id, 'pause');
      expect(pickTimer([running, paused], label: 'tea')?.id, 'run');
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

    test('update persists a pause across load', () async {
      final backing = InMemoryKeyValueStore();
      final store = TimerStore(backing);
      await store.load();
      final timer = PendingTimer(
        id: 'a',
        minutes: 1,
        label: 'tea',
        firesAt: DateTime.fromMillisecondsSinceEpoch(50_000),
      );
      await store.add(timer);
      await store.update(timer.pauseAt(DateTime.fromMillisecondsSinceEpoch(20_000)));
      final recovered = await TimerStore(backing).load();
      expect(recovered.single.isPaused, isTrue);
      expect(recovered.single.pausedRemaining, const Duration(seconds: 30));
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
