// Agent-bar tests for M1: the framing/reassembly layer.
//
// Covers: MTU-driven frame sizing, codec round-trip through the full
// chunk -> frame -> reassemble path, in-order delivery, loss, duplicates,
// reordering (stale frames), end-of-stream variants, sequence wrap, and
// sender/receiver checksum agreement.

import 'dart:math';
import 'dart:typed_data';

import 'package:cute_bot/shared/adpcm.dart';
import 'package:cute_bot/shared/audio_transport.dart';
import 'package:cute_bot/shared/ble_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

/// Deterministic fake speech: a couple of sine-ish partials + noise.
Int16List makePcm(int sampleCount, {int seed = 7}) {
  final random = Random(seed);
  final samples = Int16List(sampleCount);
  for (var i = 0; i < sampleCount; i++) {
    final t = i / AudioWireFormat.sampleRate;
    final value = 6000 * sin(2 * pi * 220 * t) +
        2500 * sin(2 * pi * 470 * t) +
        (random.nextInt(1200) - 600);
    samples[i] = value.round().clamp(-32768, 32767);
  }
  return samples;
}

/// Runs a full utterance through a chunker at [mtu] and returns the frames.
List<AudioChunkMessage> chunkUtterance(Int16List pcm, int mtu,
    {UtteranceChunker? chunker}) {
  final c = chunker ?? UtteranceChunker(mtu: mtu);
  return [...c.addSamples(pcm), ...c.finish()];
}

/// Feeds [frames] into a reassembler and returns the completed utterances.
List<UtteranceResult> reassemble(Iterable<AudioChunkMessage> frames,
    {void Function(Int16List)? onPcm}) {
  final results = <UtteranceResult>[];
  final reassembler =
      UtteranceReassembler(onPcm: onPcm, onUtterance: results.add);
  for (final frame in frames) {
    // Encode/decode through the real wire format on the way.
    final decoded = BotMessage.decode(frame.encode()) as AudioChunkMessage;
    reassembler.add(decoded);
  }
  return results;
}

void main() {
  group('UtteranceChunker sizing', () {
    test('MTU 517 uses the nominal 320-sample frame', () {
      expect(UtteranceChunker.samplesPerFrameForMtu(517),
          AudioWireFormat.samplesPerFrame);
      // Nominal frame must actually fit the MTU it was designed for.
      expect(AudioWireFormat.audioFrameBytes, lessThanOrEqualTo(517 - 3));
    });

    test('default MTU 23 falls back to tiny frames that still fit', () {
      final samples = UtteranceChunker.samplesPerFrameForMtu(23);
      expect(samples, greaterThanOrEqualTo(2));
      expect(samples.isEven, isTrue);
      final frameBytes = FrameHeader.byteLength + adpcmBlockSize(samples);
      expect(frameBytes, lessThanOrEqualTo(23 - 3));
    });

    test('absurdly small MTU throws', () {
      expect(() => UtteranceChunker.samplesPerFrameForMtu(11),
          throwsArgumentError);
    });

    test('frames carry start/end flags and contiguous sequence', () {
      final frames = chunkUtterance(makePcm(1000), 517);
      expect(frames.first.isUtteranceStart, isTrue);
      expect(frames.last.isUtteranceEnd, isTrue);
      expect(frames.where((f) => f.isUtteranceStart), hasLength(1));
      expect(frames.where((f) => f.isUtteranceEnd), hasLength(1));
      for (var i = 0; i < frames.length; i++) {
        expect(frames[i].sequence, i);
      }
      // 1000 = 3 full 320-sample frames + 40-sample tail on the end frame.
      expect(frames, hasLength(4));
      expect(frames.last.adpcmBlock, isNotEmpty);
    });

    test('exact multiple of the frame size gets an empty end frame', () {
      final frames = chunkUtterance(makePcm(640), 517);
      expect(frames, hasLength(3));
      expect(frames.last.adpcmBlock, isEmpty);
      expect(frames.last.isUtteranceEnd, isTrue);
    });
  });

  group('codec round-trip through the wire', () {
    test('clean delivery reproduces the reference codec output exactly', () {
      final pcm = makePcm(3211); // odd tail: exercises padding
      final frames = chunkUtterance(pcm, 517);

      // Reference: decode each block directly with the codec.
      final reference = <int>[
        for (final f in frames)
          if (f.adpcmBlock.isNotEmpty) ...decodeAdpcmBlock(f.adpcmBlock),
      ];

      final results = reassemble(frames);
      expect(results, hasLength(1));
      final r = results.single;
      expect(r.pcm, reference);
      expect(r.framesLost, 0);
      expect(r.duplicateFrames, 0);
      expect(r.staleFrames, 0);
      expect(r.sawStart, isTrue);
      expect(r.sawEnd, isTrue);
      // Padding: 3211 rounds up to 3212 samples.
      expect(r.pcm.length, 3212);
    });

    test('decoded audio resembles the input (codec sanity)', () {
      final pcm = makePcm(3200);
      final frames = chunkUtterance(pcm, 517);
      final r = reassemble(frames).single;
      var errorEnergy = 0.0, signalEnergy = 0.0;
      for (var i = 0; i < pcm.length; i++) {
        final e = (r.pcm[i] - pcm[i]).toDouble();
        errorEnergy += e * e;
        signalEnergy += pcm[i].toDouble() * pcm[i];
      }
      // ADPCM is lossy but should stay well under 10% error energy here.
      expect(errorEnergy / signalEnergy, lessThan(0.1));
    });

    test('small-MTU frames round-trip too', () {
      final pcm = makePcm(500);
      final frames = chunkUtterance(pcm, 23);
      final r = reassemble(frames).single;
      expect(r.framesLost, 0);
      expect(r.pcm.length, greaterThanOrEqualTo(500));
    });

    test('sender and receiver checksums agree on clean delivery', () {
      final chunker = UtteranceChunker(mtu: 517);
      final frames = chunkUtterance(makePcm(2000), 517, chunker: chunker);
      final r = reassemble(frames).single;
      expect(r.checksum, chunker.checksum.value);
      expect(r.checksumHex, chunker.checksum.hex);
    });
  });

  group('loss', () {
    test('one lost frame: counted, silence substituted, timing preserved',
        () {
      final frames = chunkUtterance(makePcm(1600), 517); // 5 data + end
      final cleanLength = reassemble(frames).single.pcm.length;

      final lossy = [...frames]..removeAt(2);
      final r = reassemble(lossy).single;
      expect(r.framesLost, 1);
      expect(r.pcm.length, cleanLength);
      // The substituted span is silence.
      final start = 2 * AudioWireFormat.samplesPerFrame;
      final silence =
          r.pcm.sublist(start, start + AudioWireFormat.samplesPerFrame);
      expect(silence.every((s) => s == 0), isTrue);
      expect(r.sawEnd, isTrue);
    });

    test('lost frames break checksum agreement (that is the point)', () {
      final chunker = UtteranceChunker(mtu: 517);
      final frames = chunkUtterance(makePcm(1600), 517, chunker: chunker);
      final lossy = [...frames]..removeAt(1);
      final r = reassemble(lossy).single;
      expect(r.checksum, isNot(chunker.checksum.value));
    });

    test('lost first frame: utterance still reassembles, sawStart false',
        () {
      final frames = chunkUtterance(makePcm(1600), 517);
      final r = reassemble(frames.skip(1)).single;
      expect(r.sawStart, isFalse);
      expect(r.framesReceived, frames.length - 2); // minus start, minus end
      expect(r.sawEnd, isTrue);
    });

    test('lost end frame: finalized when the next utterance starts', () {
      final first = chunkUtterance(makePcm(960), 517);
      final second = chunkUtterance(makePcm(640), 517);
      final results = reassemble([
        ...first.take(first.length - 1), // end frame lost
        ...second,
      ]);
      expect(results, hasLength(2));
      expect(results[0].sawEnd, isFalse);
      expect(results[1].sawEnd, isTrue);
      expect(results[1].framesLost, 0);
    });

    test('lost end frame: reset() still delivers the clip (idle timeout)', () {
      final frames = chunkUtterance(makePcm(960), 517);
      UtteranceResult? result;
      final ra = UtteranceReassembler(onUtterance: (u) => result = u);
      for (final frame in frames.take(frames.length - 1)) {
        ra.add(frame);
      }
      expect(ra.inUtterance, isTrue);
      expect(result, isNull);
      ra.reset();
      expect(ra.inUtterance, isFalse);
      expect(result, isNotNull);
      expect(result!.sawEnd, isFalse);
      expect(result!.pcm, isNotEmpty);
    });

    test('huge sequence jump caps silence substitution', () {
      // Build directly: start frame seq 0, then a frame claiming seq 2000.
      final encoder = ImaAdpcmEncoder();
      final block = encoder.encodeBlock(makePcm(320));
      UtteranceResult? result;
      final ra = UtteranceReassembler(onUtterance: (u) => result = u);
      ra.add(AudioChunkMessage(
          sequence: 0, adpcmBlock: block, isUtteranceStart: true));
      ra.add(AudioChunkMessage(
          sequence: 2000, adpcmBlock: block, isUtteranceEnd: true));
      expect(result!.framesLost, 1999);
      // Substituted silence capped at 50 frames of 320 samples.
      expect(result!.pcm.length, (2 + 50) * 320);
      expect(ra.inUtterance, isFalse);
    });
  });

  group('duplicates and reordering', () {
    test('duplicate frame is dropped and counted', () {
      final frames = chunkUtterance(makePcm(1600), 517);
      final cleanPcm = reassemble(frames).single.pcm;

      final withDup = [...frames]..insert(3, frames[2]);
      final r = reassemble(withDup).single;
      expect(r.duplicateFrames, 1);
      expect(r.framesLost, 0);
      expect(r.pcm, cleanPcm);
      expect(r.sawEnd, isTrue);
    });

    test('reordered (late) frame is dropped as stale, slot already silenced',
        () {
      final frames = chunkUtterance(makePcm(1600), 517);
      // Deliver as 0, 2, 1, 3, ... — frame 1 arrives late.
      final reordered = [frames[0], frames[2], frames[1], ...frames.skip(3)];
      final r = reassemble(reordered).single;
      expect(r.framesLost, 1); // slot 1 was silenced when 2 arrived
      expect(r.staleFrames, 1); // then the real 1 got dropped
      expect(r.sawEnd, isTrue);
      expect(r.pcm.length, reassemble(frames).single.pcm.length);
    });

    test('reordered end frame still terminates the utterance', () {
      final frames = chunkUtterance(makePcm(960), 517); // 3 data + end
      // End frame overtakes the last data frame.
      final reordered = [
        ...frames.take(frames.length - 2),
        frames.last,
        frames[frames.length - 2],
      ];
      final results = reassemble(reordered);
      expect(results, hasLength(1));
      expect(results.single.sawEnd, isTrue);
    });
  });

  group('sequence wrap', () {
    test('utterance spanning 0xFFFF -> 0 reassembles with no false loss',
        () {
      final encoder = ImaAdpcmEncoder();
      UtteranceResult? result;
      final ra = UtteranceReassembler(onUtterance: (u) => result = u);
      final seqs = [0xFFFE, 0xFFFF, 0x0000, 0x0001];
      for (var i = 0; i < seqs.length; i++) {
        ra.add(AudioChunkMessage(
          sequence: seqs[i],
          adpcmBlock: encoder.encodeBlock(makePcm(320, seed: i)),
          isUtteranceStart: i == 0,
          isUtteranceEnd: i == seqs.length - 1,
        ));
      }
      expect(result!.framesLost, 0);
      expect(result!.framesReceived, 4);
      expect(result!.pcm.length, 4 * 320);
    });

    test('SequenceCounter wraps at 0xFFFF', () {
      final counter = SequenceCounter();
      for (var i = 0; i < 0xFFFF; i++) {
        counter.next();
      }
      expect(counter.next(), 0xFFFF);
      expect(counter.next(), 0);
    });
  });

  group('multiple utterances through one chunker', () {
    test('reset() rearms the chunker; sequence stays continuous', () {
      final chunker = UtteranceChunker(mtu: 517);
      final first = chunkUtterance(makePcm(640), 517, chunker: chunker);
      chunker.reset();
      final second = chunkUtterance(makePcm(640), 517, chunker: chunker);

      expect(second.first.isUtteranceStart, isTrue);
      // Continuous per-characteristic sequence across utterances.
      expect(second.first.sequence, first.last.sequence + 1);

      final results = reassemble([...first, ...second]);
      expect(results, hasLength(2));
      expect(results[0].sawEnd, isTrue);
      expect(results[1].sawEnd, isTrue);
      expect(results[1].framesLost, 0);
    });
  });
}
