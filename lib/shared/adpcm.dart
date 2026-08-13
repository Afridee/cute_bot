/// IMA ADPCM codec (4 bits/sample, 4:1 vs 16-bit PCM) for the audio plane
/// of the BLE protocol.
///
/// KEEP THIS FILE DEPENDENCY-FREE PLAIN DART (dart:typed_data only) — the
/// ESP32 firmware ports this algorithm directly; it is a few lines of
/// integer C on that side.
///
/// AUDIO PLANE — PROVISIONAL until the M1 bandwidth gate passes
/// (see ble_protocol.dart).
///
/// ## Block layout
///
/// Every block is self-contained: the encoder's predictor state is written
/// into the block header, so a receiver can decode any block in isolation
/// and a lost block never desynchronizes the stream.
///
/// ```text
/// byte 0-1  int16 LE  predictor (predicted sample value entering the block)
/// byte 2    uint8     step index (0..88)
/// byte 3    uint8     reserved, must be 0
/// byte 4..  nibbles   4-bit codes, two samples per byte, LOW nibble first
/// ```
///
/// Note this differs from the WAV/DVI framing (which stores the first
/// sample verbatim in the header): here the header holds *state*, not a
/// sample, and every sample in the block is nibble-coded. Sample count per
/// block must be even.
library;

import 'dart:typed_data';

/// Standard IMA ADPCM step size table (89 entries).
const List<int> kAdpcmStepTable = [
  7, 8, 9, 10, 11, 12, 13, 14, 16, 17,
  19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
  50, 55, 60, 66, 73, 80, 88, 97, 107, 118,
  130, 143, 157, 173, 190, 209, 230, 253, 279, 307,
  337, 371, 408, 449, 494, 544, 598, 658, 724, 796,
  876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066,
  2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358,
  5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899,
  15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767,
];

/// Standard IMA ADPCM index adjustment table, indexed by the code's low
/// 3 bits (magnitude).
const List<int> kAdpcmIndexTable = [-1, -1, -1, -1, 2, 4, 6, 8];

/// Size in bytes of the block state header.
const int kAdpcmBlockHeaderBytes = 4;

/// Encoded size of a block holding [sampleCount] samples.
int adpcmBlockSize(int sampleCount) =>
    kAdpcmBlockHeaderBytes + sampleCount ~/ 2;

/// Number of samples in an encoded block of [blockBytes] bytes.
int adpcmSampleCount(int blockBytes) =>
    (blockBytes - kAdpcmBlockHeaderBytes) * 2;

int _clampSample(int value) => value.clamp(-32768, 32767);
int _clampIndex(int value) => value.clamp(0, 88);

/// Streaming IMA ADPCM encoder.
///
/// State (predictor + step index) persists across [encodeBlock] calls for
/// best quality on continuous audio, and is snapshotted into each block
/// header so every block decodes independently. Call [reset] at utterance
/// boundaries.
final class ImaAdpcmEncoder {
  int _predictor = 0;
  int _stepIndex = 0;

  void reset() {
    _predictor = 0;
    _stepIndex = 0;
  }

  /// Encodes [samples] (16-bit signed PCM, even count) into one
  /// self-contained block.
  Uint8List encodeBlock(Int16List samples) {
    if (samples.isEmpty || samples.length.isOdd) {
      throw ArgumentError(
          'sample count must be even and non-zero, got ${samples.length}');
    }
    final block = Uint8List(adpcmBlockSize(samples.length));
    final view = ByteData.sublistView(block);
    view.setInt16(0, _predictor, Endian.little);
    view.setUint8(2, _stepIndex);
    view.setUint8(3, 0);

    for (var i = 0; i < samples.length; i += 2) {
      final low = _encodeSample(samples[i]);
      final high = _encodeSample(samples[i + 1]);
      block[kAdpcmBlockHeaderBytes + i ~/ 2] = low | (high << 4);
    }
    return block;
  }

  int _encodeSample(int sample) {
    final step = kAdpcmStepTable[_stepIndex];
    var diff = sample - _predictor;
    var code = 0;
    if (diff < 0) {
      code = 8;
      diff = -diff;
    }
    if (diff >= step) {
      code |= 4;
      diff -= step;
    }
    if (diff >= step >> 1) {
      code |= 2;
      diff -= step >> 1;
    }
    if (diff >= step >> 2) {
      code |= 1;
    }

    _predictor = _clampSample(_predictor + _reconstructDiff(code, step));
    _stepIndex = _clampIndex(_stepIndex + kAdpcmIndexTable[code & 7]);
    return code;
  }
}

/// Reconstructed difference for [code] at [step] — shared by encoder and
/// decoder so both sides track the identical predictor.
int _reconstructDiff(int code, int step) {
  var diff = step >> 3;
  if (code & 4 != 0) diff += step;
  if (code & 2 != 0) diff += step >> 1;
  if (code & 1 != 0) diff += step >> 2;
  return (code & 8 != 0) ? -diff : diff;
}

/// Decodes one self-contained block produced by [ImaAdpcmEncoder.encodeBlock].
/// Pure function: all state comes from the block header, so blocks can be
/// decoded out of order and losses are contained.
Int16List decodeAdpcmBlock(Uint8List block) {
  if (block.length < kAdpcmBlockHeaderBytes + 1) {
    throw ArgumentError('block too short: ${block.length} bytes');
  }
  final view = ByteData.sublistView(block);
  var predictor = view.getInt16(0, Endian.little);
  var stepIndex = _clampIndex(view.getUint8(2));

  final sampleCount = adpcmSampleCount(block.length);
  final samples = Int16List(sampleCount);
  for (var i = 0; i < sampleCount; i++) {
    final byte = block[kAdpcmBlockHeaderBytes + i ~/ 2];
    final code = i.isEven ? byte & 0x0F : byte >> 4;
    final step = kAdpcmStepTable[stepIndex];
    predictor = _clampSample(predictor + _reconstructDiff(code, step));
    stepIndex = _clampIndex(stepIndex + kAdpcmIndexTable[code & 7]);
    samples[i] = predictor;
  }
  return samples;
}

// ---------------------------------------------------------------------------
// PCM16 byte helpers (little-endian), used on both sides of the codec.
// ---------------------------------------------------------------------------

/// Interprets [bytes] as 16-bit signed little-endian PCM.
Int16List pcm16BytesToSamples(Uint8List bytes) {
  if (bytes.length.isOdd) {
    throw ArgumentError('PCM16 byte length must be even, got ${bytes.length}');
  }
  final samples = Int16List(bytes.length ~/ 2);
  final view = ByteData.sublistView(bytes);
  for (var i = 0; i < samples.length; i++) {
    samples[i] = view.getInt16(i * 2, Endian.little);
  }
  return samples;
}

/// Serializes [samples] as 16-bit signed little-endian PCM.
Uint8List pcm16SamplesToBytes(Int16List samples) {
  final bytes = Uint8List(samples.length * 2);
  final view = ByteData.sublistView(bytes);
  for (var i = 0; i < samples.length; i++) {
    view.setInt16(i * 2, samples[i], Endian.little);
  }
  return bytes;
}
