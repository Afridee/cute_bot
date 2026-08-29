// FakeBrain must honor the BotBrain contract M3's GemmaBrain will honor:
// warm-up gating, tool-only mute turns, terminal Done/BrainError.

import 'dart:typed_data';

import 'package:cute_bot/companion/brain/bot_brain.dart';
import 'package:cute_bot/companion/brain/fake_brain.dart';
import 'package:flutter_test/flutter_test.dart';

FakeBrain _instantBrain() => FakeBrain(
      warmUpDelay: Duration.zero,
      thinkDelay: Duration.zero,
      tokenDelay: Duration.zero,
      prefillDelayPerEntry: Duration.zero,
    );

AudioClip _clip([int millis = 1000]) =>
    AudioClip(pcm: Int16List(millis * 16)); // 16 kHz

ConversationContext _emptyCtx() => ConversationContext(transcript: const []);

void main() {
  test('respond before warmUp yields a single BrainError', () async {
    final brain = _instantBrain();
    final events = await brain.respond(_clip(), _emptyCtx()).toList();
    expect(events, hasLength(1));
    expect(events.single, isA<BrainError>());
  });

  test('warm respond is an express tool then exactly one Done', () async {
    final brain = _instantBrain();
    await brain.warmUp();
    final events = await brain.respond(_clip(), _emptyCtx()).toList();

    expect(events.last, isA<Done>());
    expect(events.whereType<Done>(), hasLength(1));
    expect(events.whereType<TextDelta>(), isEmpty);
    final toolCalls = events.whereType<ToolCall>();
    expect(toolCalls, hasLength(1));
    expect(toolCalls.single.name, 'express');
    expect(toolCalls.single.arguments['mood'], 'happy');
    expect(toolCalls.single.transcriptLine, 'express(happy)');
  });

  test('every respond is an express tool, cycling moods', () async {
    final brain = _instantBrain();
    await brain.warmUp();
    final first = await brain.respond(_clip(), _emptyCtx()).toList();
    final second = await brain.respond(_clip(), _emptyCtx()).toList();

    expect(first.whereType<ToolCall>().single.arguments['mood'], 'happy');
    expect(second.whereType<ToolCall>().single.arguments['mood'], 'curious');
  });

  test('overlapping warmUp shares one load', () async {
    final brain = FakeBrain(
      warmUpDelay: const Duration(milliseconds: 40),
      thinkDelay: Duration.zero,
      tokenDelay: Duration.zero,
      prefillDelayPerEntry: Duration.zero,
    );
    await Future.wait([brain.warmUp(), brain.warmUp()]);
    expect(brain.warmUpRuns, 1);
  });

  test('repeat warmUp is a no-op (never re-loads)', () async {
    final brain = FakeBrain(
      warmUpDelay: const Duration(milliseconds: 50),
      thinkDelay: Duration.zero,
      tokenDelay: Duration.zero,
      prefillDelayPerEntry: Duration.zero,
    );
    await brain.warmUp();
    final sw = Stopwatch()..start();
    await brain.warmUp();
    expect(sw.elapsedMilliseconds, lessThan(40));
  });

  test('respond after dispose yields BrainError', () async {
    final brain = _instantBrain();
    await brain.warmUp();
    await brain.dispose();
    final events = await brain.respond(_clip(), _emptyCtx()).toList();
    expect(events.single, isA<BrainError>());
  });

  test('respondToCue expresses alarm, no speech', () async {
    final brain = _instantBrain();
    await brain.warmUp();
    final events = await brain
        .respondToCue(
            "A timer just finished: 'tea'. Call express(alarm).", _emptyCtx())
        .toList();
    expect(events.whereType<TextDelta>(), isEmpty);
    final call = events.whereType<ToolCall>().single;
    expect(call.name, 'express');
    expect(call.arguments['mood'], 'alarm');
    expect(events.last, isA<Done>());
  });
}
