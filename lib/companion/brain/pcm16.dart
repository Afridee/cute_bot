/// PCM-16 helpers for the Gemma audio path (M3).
///
/// The radio path delivers [Int16List] at 16 kHz mono. LiteRT-LM's
/// conversation API feeds the audio blob to miniaudio, which needs a
/// container it can sniff — a standard PCM WAV, not raw samples.
/// flutter_gemma's own example sends WAV for the same reason; raw PCM
/// fails native start-stream with miniaudio error -10 (`MA_INVALID_FILE`).
library;

import 'dart:typed_data';

/// Packs [pcm] as little-endian PCM-16 bytes, regardless of host endianness.
Uint8List pcm16ToLittleEndianBytes(Int16List pcm) {
  final out = Uint8List(pcm.length * 2);
  final data = ByteData.view(out.buffer, out.offsetInBytes, out.lengthInBytes);
  for (var i = 0; i < pcm.length; i++) {
    data.setInt16(i * 2, pcm[i], Endian.little);
  }
  return out;
}

/// Wraps [pcm] in a 44-byte PCM WAV header for LiteRT-LM / miniaudio.
///
/// [sampleRate] defaults to the BLE wire rate (16 kHz). Channels are
/// always 1; bits per sample always 16.
Uint8List pcm16ToWav(Int16List pcm, {int sampleRate = 16000}) {
  const channels = 1;
  const bitsPerSample = 16;
  final pcmBytes = pcm16ToLittleEndianBytes(pcm);
  final byteRate = sampleRate * channels * (bitsPerSample ~/ 8);
  final blockAlign = channels * (bitsPerSample ~/ 8);
  final dataSize = pcmBytes.length;
  final fileSize = 36 + dataSize;

  final wav = Uint8List(44 + dataSize);
  final header = ByteData.sublistView(wav, 0, 44);
  wav.setAll(0, 'RIFF'.codeUnits);
  header.setUint32(4, fileSize, Endian.little);
  wav.setAll(8, 'WAVE'.codeUnits);
  wav.setAll(12, 'fmt '.codeUnits);
  header.setUint32(16, 16, Endian.little); // PCM fmt chunk size
  header.setUint16(20, 1, Endian.little); // audio format = PCM
  header.setUint16(22, channels, Endian.little);
  header.setUint32(24, sampleRate, Endian.little);
  header.setUint32(28, byteRate, Endian.little);
  header.setUint16(32, blockAlign, Endian.little);
  header.setUint16(34, bitsPerSample, Endian.little);
  wav.setAll(36, 'data'.codeUnits);
  header.setUint32(40, dataSize, Endian.little);
  wav.setAll(44, pcmBytes);
  return wav;
}

/// Parsed PCM WAV (Android TTS `synthesizeToFile` output).
final class WavPcm {
  const WavPcm({required this.pcm, required this.sampleRate});

  /// Mono PCM-16. Stereo sources are averaged.
  final Int16List pcm;
  final int sampleRate;
}

/// Reads a PCM WAV (format 1). Walks chunks so a `LIST`/`fact` between
/// `fmt ` and `data` does not break us. 8-bit unsigned is expanded; 16-bit
/// little-endian is the common Android TTS case.
WavPcm parseWavPcm(Uint8List bytes) {
  if (bytes.length < 44) {
    throw FormatException('WAV too short (${bytes.length} bytes)');
  }
  if (String.fromCharCodes(bytes.sublist(0, 4)) != 'RIFF' ||
      String.fromCharCodes(bytes.sublist(8, 12)) != 'WAVE') {
    throw FormatException('not a RIFF/WAVE file');
  }

  var offset = 12;
  int? sampleRate;
  int? channels;
  int? bitsPerSample;
  Uint8List? dataBytes;

  while (offset + 8 <= bytes.length) {
    final id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    final size = ByteData.sublistView(bytes, offset + 4, offset + 8)
        .getUint32(0, Endian.little);
    final start = offset + 8;
    final end = start + size;
    if (end > bytes.length) {
      throw FormatException('WAV chunk "$id" overruns file');
    }
    if (id == 'fmt ') {
      if (size < 16) {
        throw FormatException('fmt chunk too small ($size)');
      }
      final fmt = ByteData.sublistView(bytes, start, start + size);
      final format = fmt.getUint16(0, Endian.little);
      if (format != 1) {
        throw FormatException('WAV audio format $format is not PCM');
      }
      channels = fmt.getUint16(2, Endian.little);
      sampleRate = fmt.getUint32(4, Endian.little);
      bitsPerSample = fmt.getUint16(14, Endian.little);
    } else if (id == 'data') {
      dataBytes = Uint8List.sublistView(bytes, start, end);
    }
    offset = end + (size.isOdd ? 1 : 0); // chunks are word-aligned
  }

  if (sampleRate == null ||
      channels == null ||
      bitsPerSample == null ||
      dataBytes == null) {
    throw FormatException('WAV missing fmt or data chunk');
  }
  if (channels < 1) {
    throw FormatException('WAV has no channels');
  }
  if (sampleRate < 1000) {
    throw FormatException('WAV sample rate $sampleRate is unusable');
  }

  final pcm = _pcm16Mono(dataBytes, channels: channels, bits: bitsPerSample);
  return WavPcm(pcm: pcm, sampleRate: sampleRate);
}

Int16List _pcm16Mono(Uint8List data, {required int channels, required int bits}) {
  if (bits == 16) {
    final frameCount = data.length ~/ (2 * channels);
    final out = Int16List(frameCount);
    final view = ByteData.sublistView(data);
    for (var i = 0; i < frameCount; i++) {
      var acc = 0;
      for (var ch = 0; ch < channels; ch++) {
        acc += view.getInt16((i * channels + ch) * 2, Endian.little);
      }
      out[i] = (acc / channels).round().clamp(-32768, 32767);
    }
    return out;
  }
  if (bits == 8) {
    final frameCount = data.length ~/ channels;
    final out = Int16List(frameCount);
    for (var i = 0; i < frameCount; i++) {
      var acc = 0;
      for (var ch = 0; ch < channels; ch++) {
        acc += (data[i * channels + ch] - 128) << 8;
      }
      out[i] = (acc / channels).round().clamp(-32768, 32767);
    }
    return out;
  }
  throw FormatException('WAV bits-per-sample $bits is not 8 or 16');
}

/// Normalized mono samples for sherpa-onnx (`[-1, 1]`).
Float32List pcm16ToFloat32(Int16List pcm) {
  final out = Float32List(pcm.length);
  for (var i = 0; i < pcm.length; i++) {
    out[i] = pcm[i] / 32768.0;
  }
  return out;
}

/// True when the clip is effectively silence (fake utterances, VAD leaks).
/// Peak of 400/32768 is well below speech on the bot mic.
bool clipLooksSilent(Int16List pcm, {int peakFloor = 400}) {
  for (final s in pcm) {
    if (s.abs() >= peakFloor) return false;
  }
  return true;
}

/// Linear-interpolation resample to [toRate]. Same rate is a no-op copy.
Int16List resamplePcm16(Int16List input,
    {required int fromRate, required int toRate}) {
  if (fromRate == toRate) return Int16List.fromList(input);
  if (fromRate <= 0 || toRate <= 0) {
    throw ArgumentError('sample rates must be positive');
  }
  if (input.isEmpty) return Int16List(0);
  final outLen = (input.length * toRate / fromRate).round().clamp(1, 1 << 28);
  final out = Int16List(outLen);
  final last = input.length - 1;
  for (var i = 0; i < outLen; i++) {
    final src = i * fromRate / toRate;
    final i0 = src.floor().clamp(0, last);
    final i1 = (i0 + 1).clamp(0, last);
    final frac = src - i0;
    out[i] = (input[i0] * (1 - frac) + input[i1] * frac).round();
  }
  return out;
}
