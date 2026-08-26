// BrainSession: the serialized conversation queue plus the recovery
// lifecycle (load transcript -> warm -> respond -> persist), tested with
// FakeBrain at zero delays and an in-memory store.

import 'dart:async';
import 'dart:typed_data';

import 'package:cute_bot/companion/brain/bot_brain.dart';
import 'package:cute_bot/companion/brain/brain_session.dart';
import 'package:cute_bot/companion/brain/fake_brain.dart';
import 'package:cute_bot/companion/brain/transcript.dart';
import 'package:flutter_test/flutter_test.dart';

AudioClip _clip([int millis = 1200]) => AudioClip(pcm: Int16List(millis * 16));

FakeBrain _instantBrain() => FakeBrain(
      warmUpDelay: Duration.zero,
      thinkDelay: Duration.zero,
      tokenDelay: Duration.zero,
      prefillDelayPerEntry: Duration.zero,
    );

/// A brain whose respond() blocks until released — for proving turns
/// serialize instead of racing.
final class _GatedBrain implements BotBrain {
  final List<Completer<void>> gates = [];
  int concurrentTurns = 0;
  int maxConcurrentTurns = 0;

  @override
  Future<void> warmUp() async {}

  @override
  Stream<BrainEvent> respond(AudioClip audio, ConversationContext ctx) async* {
    concurrentTurns += 1;
    if (concurrentTurns > maxConcurrentTurns) {
      maxConcurrentTurns = concurrentTurns;
    }
    final gate = Completer<void>();
    gates.add(gate);
    await gate.future;
    concurrentTurns -= 1;
    yield const TextDelta('ok');
    yield const Done();
  }

  @override
  Stream<BrainEvent> respondToCue(String cue, ConversationContext ctx) =>
      respond(AudioClip(pcm: Int16List(0)), ctx);

  @override
  Future<void> dispose() async {}
}

void main() {
  test('start loads persisted transcript and reports replayed count',
      () async {
    final backing = InMemoryKeyValueStore();
    final seed = TranscriptStore(backing);
    await seed.load();
    await seed.append(TranscriptEntry(role: TranscriptRole.user, text: 'a'));
    await seed.append(TranscriptEntry(role: TranscriptRole.bot, text: 'b'));

    final session = BrainSession(
      brain: _instantBrain(),
      transcript: TranscriptStore(backing),
    );
    await session.start();

    expect(session.state, BrainSessionState.ready);
    expect(session.replayedEntries, 2);
    expect(session.transcript.length, 2);
  });

  test('handleUtterance appends user + bot entries and persists both',
      () async {
    final backing = InMemoryKeyValueStore();
    final session = BrainSession(
      brain: _instantBrain(),
      transcript: TranscriptStore(backing),
    );
    await session.start();
    await session.handleUtterance(_clip(1500));

    expect(session.state, BrainSessionState.ready);
    expect(session.lastResponseText, isNotEmpty);

    // Persisted, not just in memory: a fresh store sees both lines.
    final recovered = await TranscriptStore(backing).load();
    expect(recovered.length, 2);
    expect(recovered[0].role, TranscriptRole.user);
    expect(recovered[0].text, '(voice, 1.5 s)');
    expect(recovered[1].role, TranscriptRole.bot);
    expect(recovered[1].text, session.lastResponseText);
  });

  test('turns are serialized, never concurrent', () async {
    final brain = _GatedBrain();
    final session = BrainSession(
      brain: brain,
      transcript: TranscriptStore(InMemoryKeyValueStore()),
    );
    await session.start();

    final first = session.handleUtterance(_clip());
    final second = session.handleUtterance(_clip());

    // Let the first turn enter respond(); the second must still be queued.
    await Future<void>.delayed(Duration.zero);
    expect(brain.gates, hasLength(1));

    brain.gates[0].complete();
    await first;
    await Future<void>.delayed(Duration.zero);
    expect(brain.gates, hasLength(2));
    brain.gates[1].complete();
    await second;

    expect(brain.maxConcurrentTurns, 1);
  });

  test('utterances during warm-up are dropped and counted, not queued',
      () async {
    final session = BrainSession(
      brain: FakeBrain(
        warmUpDelay: const Duration(milliseconds: 50),
        thinkDelay: Duration.zero,
        tokenDelay: Duration.zero,
        prefillDelayPerEntry: Duration.zero,
      ),
      transcript: TranscriptStore(InMemoryKeyValueStore()),
    );
    final warming = session.start();
    await session.handleUtterance(_clip());
    expect(session.droppedUtterances, 1);
    await warming;
    expect(session.transcript, isEmpty);
  });

  test('tool calls surface through onToolCall', () async {
    final calls = <ToolCall>[];
    final session = BrainSession(
      brain: _instantBrain(),
      transcript: TranscriptStore(InMemoryKeyValueStore()),
      onToolCall: calls.add,
    );
    await session.start();
    await session.handleUtterance(_clip()); // FakeBrain: 1st turn has a tool
    expect(calls, hasLength(1));
    expect(calls.single.name, 'set_led');
  });

  test('noteIncomingAudio flips ready to thinking; cancelListening reverts',
      () async {
    final session = BrainSession(
      brain: _instantBrain(),
      transcript: TranscriptStore(InMemoryKeyValueStore()),
    );
    await session.start();
    expect(session.state, BrainSessionState.ready);

    session.noteIncomingAudio();
    expect(session.state, BrainSessionState.thinking);

    session.cancelListening();
    expect(session.state, BrainSessionState.ready);
  });

  test('cancelListening does not abort a turn already in flight', () async {
    final brain = _GatedBrain();
    final session = BrainSession(
      brain: brain,
      transcript: TranscriptStore(InMemoryKeyValueStore()),
    );
    await session.start();

    final turn = session.handleUtterance(_clip());
    await Future<void>.delayed(Duration.zero);
    expect(session.state, BrainSessionState.thinking);

    session.cancelListening();
    expect(session.state, BrainSessionState.thinking);

    brain.gates.single.complete();
    await turn;
    expect(session.state, BrainSessionState.ready);
  });

  test('a BrainError turn records the error and returns to ready', () async {
    // Brain not warmed inside: FakeBrain yields BrainError if respond is
    // forced early — simulate by disposing the brain under the session.
    final brain = _instantBrain();
    final session = BrainSession(
      brain: brain,
      transcript: TranscriptStore(InMemoryKeyValueStore()),
    );
    await session.start();
    await brain.dispose();
    await session.handleUtterance(_clip());

    expect(session.state, BrainSessionState.ready);
    expect(session.lastError, isNotNull);
    // No bot entry was persisted for the failed turn (only the user line).
    expect(session.transcript.where((e) => e.role == TranscriptRole.bot),
        isEmpty);
  });

  test('handleCue serializes behind a spoken turn and persists the reply',
      () async {
    final brain = _GatedBrain();
    final session = BrainSession(
      brain: brain,
      transcript: TranscriptStore(InMemoryKeyValueStore()),
    );
    await session.start();

    final spoken = session.handleUtterance(_clip());
    final cue = session.handleCue("A timer just finished: 'tea'.");
    await Future<void>.delayed(Duration.zero);
    expect(brain.gates, hasLength(1));

    brain.gates[0].complete();
    await spoken;
    await Future<void>.delayed(Duration.zero);
    expect(brain.gates, hasLength(2));
    brain.gates[1].complete();
    await cue;

    expect(brain.maxConcurrentTurns, 1);
    expect(session.transcript.where((e) => e.role == TranscriptRole.system),
        isNotEmpty);
    expect(session.lastResponseText, 'ok');
  });
}
