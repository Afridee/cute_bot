import 'dart:typed_data';

import 'package:cute_bot/companion/brain/bot_brain.dart';
import 'package:cute_bot/companion/brain/clip_asr.dart';
import 'package:cute_bot/companion/brain/fake_brain.dart';
import 'package:cute_bot/companion/brain/hybrid_brain.dart';
import 'package:flutter_test/flutter_test.dart';

AudioClip _clip([int millis = 400]) => AudioClip(pcm: Int16List(millis * 16));

ConversationContext _emptyCtx() => ConversationContext(transcript: const []);

FakeBrain _inner() => FakeBrain(
      warmUpDelay: Duration.zero,
      thinkDelay: Duration.zero,
      tokenDelay: Duration.zero,
      prefillDelayPerEntry: Duration.zero,
    );

void main() {
  test('timer cue skips the inner brain', () async {
    final inner = _inner();
    final hybrid = HybridBrain(inner: inner);
    await hybrid.warmUp();

    final events = await hybrid
        .respondToCue(
            "A timer just finished: 'tea'. Call express(alarm).", _emptyCtx())
        .toList();

    expect(events.whereType<ToolCall>().single.transcriptLine,
        'express(alarm)');
    expect(events.last, isA<Done>());
    expect(hybrid.lastLatency?.backend, 'nlp');
    // FakeBrain would have cycled to happy on a miss; alarm is the NLP hit.
  });

  test('unknown cue falls through to the inner brain', () async {
    var cueTurns = 0;
    final hybrid = HybridBrain(
      inner: _CountingBrain(_inner(), onCue: () => cueTurns++),
    );
    await hybrid.warmUp();

    final events = await hybrid
        .respondToCue('A notification arrived from Maps.', _emptyCtx())
        .toList();

    expect(cueTurns, 1);
    expect(events.whereType<ToolCall>().single.arguments['mood'], 'alarm');
    expect(hybrid.lastLatency, isNull);
  });

  test('spoken turn without ASR always uses the inner brain', () async {
    final inner = _inner();
    final hybrid = HybridBrain(inner: inner);
    await hybrid.warmUp();

    final events = await hybrid.respond(_clip(), _emptyCtx()).toList();
    expect(events.whereType<ToolCall>().single.arguments['mood'], 'happy');
  });

  test('transcribed speech can skip the model', () async {
    final inner = _inner();
    var innerTurns = 0;
    final hybrid = HybridBrain(
      inner: _CountingBrain(inner, onRespond: () => innerTurns++),
      asr: _ScriptedAsr('do a little dance'),
    );
    await hybrid.warmUp();

    final events = await hybrid.respond(_clip(), _emptyCtx()).toList();
    expect(events.whereType<ToolCall>().single.transcriptLine,
        'express(delighted)');
    expect(innerTurns, 0);
    expect(hybrid.lastLatency?.backend, 'nlp');
  });

  test('onRoute reports Fast intent hits and LLM misses', () async {
    final routes = <({bool fast, String? text, String? reason})>[];
    void capture({required bool fastIntent, String? text, String? reason}) {
      routes.add((fast: fastIntent, text: text, reason: reason));
    }

    final hitBrain = HybridBrain(
      inner: _inner(),
      asr: _ScriptedAsr('do a little dance'),
      onRoute: capture,
    );
    await hitBrain.warmUp();
    await hitBrain.respond(_clip(), _emptyCtx()).toList();
    expect(routes, hasLength(1));
    expect(routes.single.fast, isTrue);
    expect(routes.single.text, 'do a little dance');
    expect(routes.single.reason, 'dance');

    routes.clear();
    final missBrain = HybridBrain(
      inner: _inner(),
      asr: _ScriptedAsr('tell me a joke about tea'),
      onRoute: capture,
    );
    await missBrain.warmUp();
    await missBrain.respond(_clip(), _emptyCtx()).toList();
    expect(routes, hasLength(1));
    expect(routes.single.fast, isFalse);
    expect(routes.single.text, 'tell me a joke about tea');
    expect(routes.single.reason, isNull);
  });

  test('ASR text is logged even when the matcher misses', () async {
    var heard = '';
    final hybrid = HybridBrain(
      inner: _inner(),
      asr: _ScriptedAsr('tell me a joke about tea'),
      onHeard: (text) => heard = text,
    );
    await hybrid.warmUp();
    await hybrid.respond(_clip(), _emptyCtx()).toList();
    expect(heard, 'tell me a joke about tea');
    expect(hybrid.lastHeardText, 'tell me a joke about tea');
  });

  test('transcribed miss still reaches the inner brain', () async {
    final inner = _inner();
    final hybrid = HybridBrain(
      inner: inner,
      asr: _ScriptedAsr('tell me a joke about tea'),
    );
    await hybrid.warmUp();

    final events = await hybrid.respond(_clip(), _emptyCtx()).toList();
    expect(events.whereType<ToolCall>().single.arguments['mood'], 'happy');
  });

  test('get_battery hit follows up with an expression when tools are live',
      () async {
    final inner = _inner();
    final dispatched = <String>[];
    final hybrid = HybridBrain(
      inner: inner,
      asr: _ScriptedAsr('how much battery do you have?'),
      executeTool: (name, args) async {
        dispatched.add(name);
        if (name == 'get_battery') {
          return {'status': 'ok', 'percent': 12};
        }
        return {'status': 'ok', ...args};
      },
    );
    await hybrid.warmUp();

    final events = await hybrid.respond(_clip(), _emptyCtx()).toList();
    expect(
      events.whereType<ToolCall>().map((c) => c.transcriptLine).toList(),
      ['get_battery()', 'express(low_battery)'],
    );
    expect(dispatched, ['get_battery', 'express']);
  });
}

final class _ScriptedAsr implements ClipAsr {
  _ScriptedAsr(this.text);
  final String? text;

  @override
  Future<void> warmUp() async {}

  @override
  Future<String?> transcribe(AudioClip clip) async => text;

  @override
  Future<void> dispose() async {}
}

final class _CountingBrain implements BotBrain {
  _CountingBrain(this._inner, {this.onRespond, this.onCue});

  final BotBrain _inner;
  final void Function()? onRespond;
  final void Function()? onCue;

  @override
  Future<void> warmUp() => _inner.warmUp();

  @override
  Stream<BrainEvent> respond(AudioClip audio, ConversationContext ctx) {
    onRespond?.call();
    return _inner.respond(audio, ctx);
  }

  @override
  Stream<BrainEvent> respondToCue(String cue, ConversationContext ctx) {
    onCue?.call();
    return _inner.respondToCue(cue, ctx);
  }

  @override
  Future<void> dispose() => _inner.dispose();
}
