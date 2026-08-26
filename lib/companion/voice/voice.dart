/// TTS boundary (M5).
///
/// The TTS output path is not the phone speaker. Implementations return
/// 16 kHz mono PCM-16 that the service chunks over BLE. [FakeVoice] is
/// the unit-test / FakeBrain stand-in; [FlutterTtsVoice] is the product.
library;

import 'dart:math';
import 'dart:typed_data';

import '../../shared/ble_protocol.dart' show AudioWireFormat;

abstract interface class Voice {
  Future<void> warmUp();

  /// Synthesize [text] to 16 kHz mono PCM-16. Never plays locally.
  Future<Int16List> synthesize(String text);

  Future<void> dispose();
}

/// Sine-beep voice so FakeBrain two-phone tests still exercise BLE audio
/// out without a TTS engine. Duration scales with word count.
final class FakeVoice implements Voice {
  FakeVoice({this.msPerWord = 80});

  final int msPerWord;
  bool _warm = false;
  bool _disposed = false;

  @override
  Future<void> warmUp() async {
    if (_disposed) throw StateError('FakeVoice used after dispose');
    _warm = true;
  }

  @override
  Future<Int16List> synthesize(String text) async {
    if (_disposed || !_warm) {
      throw StateError('FakeVoice.synthesize before warmUp');
    }
    final words = text.trim().isEmpty ? 1 : text.trim().split(RegExp(r'\s+')).length;
    final samples = (words * msPerWord * AudioWireFormat.sampleRate / 1000)
        .round()
        .clamp(AudioWireFormat.samplesPerFrame, 16000);
    final out = Int16List(samples);
    const freq = 440.0;
    final rate = AudioWireFormat.sampleRate.toDouble();
    for (var i = 0; i < samples; i++) {
      final envelope = i < 40
          ? i / 40
          : (i > samples - 40 ? (samples - i) / 40 : 1.0);
      out[i] =
          (0.18 * envelope * 32767 * sin(2 * pi * freq * i / rate)).round();
    }
    return out;
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _warm = false;
  }
}
