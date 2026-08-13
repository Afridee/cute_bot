import 'dart:math';
import 'dart:typed_data';

import 'package:cute_bot/shared/adpcm.dart';
import 'package:cute_bot/shared/ble_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

Int16List sine({
  required int samples,
  required double frequency,
  required double amplitude,
  int sampleRate = AudioWireFormat.sampleRate,
}) {
  final out = Int16List(samples);
  for (var i = 0; i < samples; i++) {
    out[i] = (amplitude * sin(2 * pi * frequency * i / sampleRate)).round();
  }
  return out;
}

/// Signal-to-noise ratio in dB of [decoded] against [original].
double snrDb(Int16List original, Int16List decoded) {
  var signal = 0.0;
  var noise = 0.0;
  for (var i = 0; i < original.length; i++) {
    signal += original[i] * original[i];
    final e = original[i] - decoded[i];
    noise += e * e;
  }
  if (noise == 0) return double.infinity;
  return 10 * log(signal / noise) / ln10;
}

void main() {
  group('ADPCM block format', () {
    test('encoded block has the documented size (4:1 + 4-byte header)', () {
      final encoder = ImaAdpcmEncoder();
      final block = encoder.encodeBlock(Int16List(320));
      expect(block.length, 4 + 320 ~/ 2);
      expect(block.length, AudioWireFormat.adpcmBlockBytes);
    });

    test('rejects odd and empty sample counts', () {
      final encoder = ImaAdpcmEncoder();
      expect(() => encoder.encodeBlock(Int16List(321)), throwsArgumentError);
      expect(() => encoder.encodeBlock(Int16List(0)), throwsArgumentError);
    });

    test('decode rejects blocks shorter than header', () {
      expect(() => decodeAdpcmBlock(Uint8List(4)), throwsArgumentError);
    });

    test('silence round-trips to (near) silence', () {
      final encoder = ImaAdpcmEncoder();
      final decoded = decodeAdpcmBlock(encoder.encodeBlock(Int16List(320)));
      expect(decoded.length, 320);
      for (final s in decoded) {
        expect(s.abs(), lessThanOrEqualTo(16));
      }
    });
  });

  group('ADPCM fidelity', () {
    test('sine round-trip SNR is acceptable after adaptation', () {
      const frameSamples = AudioWireFormat.samplesPerFrame;
      const frames = 50; // 1 second
      final signal =
          sine(samples: frameSamples * frames, frequency: 440, amplitude: 12000);

      final encoder = ImaAdpcmEncoder();
      final decoded = Int16List(signal.length);
      for (var f = 0; f < frames; f++) {
        final chunk = Int16List.sublistView(
            signal, f * frameSamples, (f + 1) * frameSamples);
        decoded.setRange(f * frameSamples, (f + 1) * frameSamples,
            decodeAdpcmBlock(encoder.encodeBlock(chunk)));
      }

      // Skip the first frame: the encoder starts from zero state and needs
      // a few ms to adapt.
      final s = Int16List.sublistView(signal, frameSamples);
      final d = Int16List.sublistView(decoded, frameSamples);
      expect(snrDb(s, d), greaterThan(20));
    });

    test('full-scale signal does not overflow or wrap', () {
      final signal =
          sine(samples: 640, frequency: 1000, amplitude: 32767);
      final encoder = ImaAdpcmEncoder();
      final block1 =
          encoder.encodeBlock(Int16List.sublistView(signal, 0, 320));
      final block2 =
          encoder.encodeBlock(Int16List.sublistView(signal, 320, 640));
      for (final s in [...decodeAdpcmBlock(block1), ...decodeAdpcmBlock(block2)]) {
        expect(s, inInclusiveRange(-32768, 32767));
      }
    });
  });

  group('ADPCM block independence (loss containment)', () {
    test('a block decodes identically alone or mid-stream', () {
      final signal = sine(samples: 960, frequency: 300, amplitude: 9000);
      final encoder = ImaAdpcmEncoder();
      final blocks = <Uint8List>[];
      for (var f = 0; f < 3; f++) {
        blocks.add(encoder.encodeBlock(
            Int16List.sublistView(signal, f * 320, (f + 1) * 320)));
      }

      // Decode block 2 in isolation (as if blocks 0-1 were lost); must be
      // byte-identical to decoding it in sequence, because all decoder
      // state lives in the block header.
      final inSequence = blocks.map(decodeAdpcmBlock).toList();
      final isolated = decodeAdpcmBlock(blocks[2]);
      expect(isolated, inSequence[2]);
    });

    test('encoder reset returns to a deterministic state', () {
      final signal = sine(samples: 320, frequency: 500, amplitude: 8000);
      final encoder = ImaAdpcmEncoder();
      final first = encoder.encodeBlock(signal);
      encoder.encodeBlock(signal); // mutate state
      encoder.reset();
      final afterReset = encoder.encodeBlock(signal);
      expect(afterReset, first);
    });
  });

  group('PCM16 byte helpers', () {
    test('round-trip including negative values and extremes', () {
      final samples = Int16List.fromList([0, 1, -1, 32767, -32768, 12345]);
      expect(pcm16BytesToSamples(pcm16SamplesToBytes(samples)), samples);
    });

    test('bytes are little-endian', () {
      final bytes = pcm16SamplesToBytes(Int16List.fromList([0x0102]));
      expect(bytes, [0x02, 0x01]);
    });

    test('rejects odd byte length', () {
      expect(() => pcm16BytesToSamples(Uint8List(3)), throwsArgumentError);
    });
  });
}
