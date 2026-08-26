// Pure helpers around the Gemma path: PCM packing and latency traces.
// GemmaBrain itself talks to flutter_gemma and is the human-bar test.

import 'dart:typed_data';

import 'package:cute_bot/companion/brain/bot_tools.dart';
import 'package:cute_bot/companion/brain/brain_session.dart';
import 'package:cute_bot/companion/brain/context_window.dart';
import 'package:cute_bot/companion/brain/latency_trace.dart';
import 'package:cute_bot/companion/brain/pcm16.dart';
import 'package:cute_bot/companion/brain/transcript.dart';
import 'package:cute_bot/companion/expressions.dart';
import 'package:cute_bot/companion/persona.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('pcm16ToLittleEndianBytes', () {
    test('packs each sample as little-endian int16', () {
      final pcm = Int16List.fromList([0, 1, -1, 32767, -32768]);
      final bytes = pcm16ToLittleEndianBytes(pcm);
      expect(bytes, hasLength(10));
      final data = ByteData.sublistView(bytes);
      expect(data.getInt16(0, Endian.little), 0);
      expect(data.getInt16(2, Endian.little), 1);
      expect(data.getInt16(4, Endian.little), -1);
      expect(data.getInt16(6, Endian.little), 32767);
      expect(data.getInt16(8, Endian.little), -32768);
    });

    test('empty clip yields empty bytes', () {
      expect(pcm16ToLittleEndianBytes(Int16List(0)), isEmpty);
    });
  });

  group('pcm16ToWav', () {
    test('is a 16 kHz mono PCM WAV miniaudio can sniff', () {
      final pcm = Int16List.fromList([0, 1, -1, 32767, -32768]);
      final wav = pcm16ToWav(pcm);
      expect(wav, hasLength(44 + pcm.length * 2));
      expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
      expect(String.fromCharCodes(wav.sublist(12, 16)), 'fmt ');
      expect(String.fromCharCodes(wav.sublist(36, 40)), 'data');
      final header = ByteData.sublistView(wav);
      expect(header.getUint32(4, Endian.little), 36 + pcm.length * 2);
      expect(header.getUint16(20, Endian.little), 1); // PCM
      expect(header.getUint16(22, Endian.little), 1); // mono
      expect(header.getUint32(24, Endian.little), 16000);
      expect(header.getUint32(28, Endian.little), 16000 * 2); // byte rate
      expect(header.getUint16(32, Endian.little), 2); // block align
      expect(header.getUint16(34, Endian.little), 16);
      expect(header.getUint32(40, Endian.little), pcm.length * 2);
      expect(wav.sublist(44), pcm16ToLittleEndianBytes(pcm));
    });

    test('empty clip is still a valid 44-byte header', () {
      final wav = pcm16ToWav(Int16List(0), sampleRate: 8000);
      expect(wav, hasLength(44));
      final header = ByteData.sublistView(wav);
      expect(header.getUint32(24, Endian.little), 8000);
      expect(header.getUint32(40, Endian.little), 0);
    });
  });

  group('parseWavPcm', () {
    test('round-trips pcm16ToWav', () {
      final pcm = Int16List.fromList([0, 1, -1, 32767, -32768]);
      final parsed = parseWavPcm(pcm16ToWav(pcm, sampleRate: 16000));
      expect(parsed.sampleRate, 16000);
      expect(parsed.pcm, pcm);
    });
  });

  group('resamplePcm16', () {
    test('same rate is a copy', () {
      final pcm = Int16List.fromList([1, 2, 3]);
      final out = resamplePcm16(pcm, fromRate: 16000, toRate: 16000);
      expect(out, pcm);
      expect(identical(out, pcm), isFalse);
    });

    test('downsamples 32 kHz to 16 kHz at half length', () {
      final pcm = Int16List.fromList([0, 100, 200, 300, 400, 500, 600, 700]);
      final out = resamplePcm16(pcm, fromRate: 32000, toRate: 16000);
      expect(out.length, 4);
    });
  });

  group('LatencyTrace', () {
    test('summary names the stages a logcat grepping human will look for', () {
      const trace = LatencyTrace(
        downloadMs: 120000,
        modelLoadMs: 18000,
        chatCreateMs: 400,
        submitMs: 90,
        firstTokenMs: 1100,
        decodeMs: 350,
        totalMs: 1450,
        backend: 'gpu',
      );
      expect(trace.summary, contains('ttf 1100ms'));
      expect(trace.summary, contains('gpu'));
      expect(trace.summary, contains('dl 120000ms'));
    });

    test('round-trips through a snapshot map', () {
      const original = LatencyTrace(
        submitMs: 10,
        firstTokenMs: 800,
        decodeMs: 200,
        totalMs: 1000,
        backend: 'cpu',
        firstTokenText: 'Hi',
      );
      final decoded = LatencyTrace.fromMap(original.toMap());
      expect(decoded, isNotNull);
      expect(decoded!.firstTokenMs, 800);
      expect(decoded.backend, 'cpu');
      expect(decoded.firstTokenText, 'Hi');
      expect(decoded.downloadMs, isNull);
    });
  });

  group('stubToolResult', () {
    test('known tools return status, unknown tools error', () {
      expect(stubToolResult('express', const {'mood': 'happy'}),
          containsPair('status', 'ok'));
      expect(stubToolResult('nope', const {})['error'], contains('unknown'));
      expect(needsToolFollowUp('get_battery'), isTrue);
      expect(needsToolFollowUp('express'), isFalse);
      expect(needsToolFollowUp('set_timer'), isFalse);
    });

    test('model-facing tools are express, set_timer, get_battery', () {
      expect(kBotTools.map((t) => t.name).toList(),
          ['express', 'set_timer', 'get_battery']);
    });
  });

  group('expressions', () {
    test('every BotMood has a catalog row', () {
      for (final mood in BotMood.values) {
        expect(kExpressions[mood], isNotNull, reason: mood.name);
        expect(expressionFor(mood.name)?.mood, mood);
      }
    });

    test('unknown mood is null', () {
      expect(expressionFor('explode'), isNull);
      expect(expressionFor(null), isNull);
    });

    test('systemMoodForBrainState maps lifecycle to catalog moods', () {
      expect(systemMoodForBrainState(BrainSessionState.thinking),
          BotMood.curious);
      expect(systemMoodForBrainState(BrainSessionState.warming),
          BotMood.sleepy);
      expect(systemMoodForBrainState(BrainSessionState.ready), isNull);
      expect(systemMoodForBrainState(BrainSessionState.responding), isNull);
      expect(systemMoodForBrainState(BrainSessionState.cold), isNull);
    });
  });

  group('persona budget', () {
    test('decode cap leaves room for Gemma 4 thought plus a tool call', () {
      expect(kPersonaMaxOutputTokens, 192);
      expect(kPersonaMaxOutputTokens, greaterThanOrEqualTo(128));
    });
  });

  group('parseLeakedToolCalls', () {
    test('recovers the few-shot express(mood) line', () {
      final calls = parseLeakedToolCalls('express(curious)');
      expect(calls, hasLength(1));
      expect(calls.single.name, 'express');
      expect(calls.single.arguments['mood'], 'curious');
    });

    test('recovers express after thought prose', () {
      final calls = parseLeakedToolCalls(
        '<|channel>thought\nuser said hi so I should greet\n'
        '<channel|>express(happy)',
      );
      expect(calls.single.transcriptLine, 'express(happy)');
    });

    test('recovers set_timer then express in one blob', () {
      final calls = parseLeakedToolCalls('set_timer(3, tea) then express(yes)');
      expect(calls.map((c) => c.transcriptLine).toList(),
          ['set_timer(3, tea)', 'express(yes)']);
    });

    test('strips quotes on timer labels', () {
      final calls = parseLeakedToolCalls('set_timer(5, "steep")');
      expect(calls.single.arguments['label'], 'steep');
    });

    test('ignores unknown moods and empty text', () {
      expect(parseLeakedToolCalls(''), isEmpty);
      expect(parseLeakedToolCalls('express(explode)'), isEmpty);
      expect(parseLeakedToolCalls('hello there'), isEmpty);
    });

    test('recovers get_battery()', () {
      expect(parseLeakedToolCalls('get_battery()').single.name, 'get_battery');
    });
  });

  group('rollingTextWindow', () {
    TranscriptEntry voice([String secs = '1.2']) => TranscriptEntry(
          role: TranscriptRole.user,
          text: '(voice, $secs s)',
        );
    TranscriptEntry bot(String text) =>
        TranscriptEntry(role: TranscriptRole.bot, text: text);
    TranscriptEntry system(String text) =>
        TranscriptEntry(role: TranscriptRole.system, text: text);
    TranscriptEntry userText(String text) =>
        TranscriptEntry(role: TranscriptRole.user, text: text);

    test('empty transcript yields an empty seed', () {
      expect(rollingTextWindow(const []), isEmpty);
    });

    test('drops the trailing (voice, X s) user placeholder', () {
      final seed = rollingTextWindow([bot('Hi!'), voice()]);
      expect(seed, hasLength(1));
      expect(seed.single.text, 'Hi!');
      expect(seed.single.role, TranscriptRole.bot);
    });

    test('drops every user voice placeholder and keeps bot text', () {
      final seed = rollingTextWindow([
        voice('0.4'),
        bot('Hello'),
        voice('0.8'),
        bot('Again'),
        voice('1.1'),
      ]);
      expect(seed.map((e) => e.text).toList(), ['Hello', 'Again']);
    });

    test('keeps system lines among seedable text', () {
      final seed = rollingTextWindow([
        system('booted'),
        voice(),
        bot('ready'),
      ]);
      expect(seed.map((e) => e.text).toList(), ['booted', 'ready']);
    });

    test('does not seed non-voice user text either', () {
      final seed = rollingTextWindow([
        userText('typed in the UI'),
        bot('ok'),
      ]);
      expect(seed.map((e) => e.text).toList(), ['ok']);
    });

    test('caps at 16 seedable bot lines, oldest dropped', () {
      final bots = [for (var i = 0; i < 17; i++) bot('b$i')];
      final seed = rollingTextWindow(bots);
      expect(seed, hasLength(kContextEntryCap));
      expect(seed.first.text, 'b1');
      expect(seed.last.text, 'b16');
    });

    test('does not reorder seedable lines', () {
      final seed = rollingTextWindow([
        bot('one'),
        voice(),
        bot('two'),
        bot('three'),
      ]);
      expect(seed.map((e) => e.text).toList(), ['one', 'two', 'three']);
    });

    test('mixed 30-line transcript yields the last 16 bot lines', () {
      final transcript = <TranscriptEntry>[];
      for (var i = 0; i < 10; i++) {
        transcript.add(voice('$i.0'));
        transcript.add(bot('b$i'));
      }
      for (var i = 10; i < 20; i++) {
        transcript.add(bot('b$i'));
      }
      expect(transcript, hasLength(30));
      final seed = rollingTextWindow(transcript);
      expect(seed, hasLength(kContextEntryCap));
      expect(seed.every((e) => e.role == TranscriptRole.bot), isTrue);
      expect(seed.map((e) => e.text).toList(),
          [for (var i = 4; i < 20; i++) 'b$i']);
    });

    test('fewer than 16 bot lines is not padded', () {
      final seed = rollingTextWindow([voice(), bot('only')]);
      expect(seed.map((e) => e.text).toList(), ['only']);
    });
  });
}
