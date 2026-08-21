// Pure helpers around the Gemma path: PCM packing and latency traces.
// GemmaBrain itself talks to flutter_gemma and is the human-bar test.

import 'dart:typed_data';

import 'package:cute_bot/companion/brain/bot_tools.dart';
import 'package:cute_bot/companion/brain/latency_trace.dart';
import 'package:cute_bot/companion/brain/pcm16.dart';
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
      expect(stubToolResult('wiggle', const {}), containsPair('status', 'ok'));
      expect(stubToolResult('nope', const {})['error'], contains('unknown'));
    });
  });
}
