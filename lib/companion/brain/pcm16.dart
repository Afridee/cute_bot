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
