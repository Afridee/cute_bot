/// flutter_tts-backed [Voice] (M5).
///
/// Uses `synthesizeToFile` so we get PCM we can ADPCM and write to the bot
/// speaker. Never calls `speak()` — that would play on the phone.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_tts/flutter_tts.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../shared/ble_protocol.dart' show AudioWireFormat;
import '../../shared/log.dart';
import '../brain/pcm16.dart';
import 'voice.dart';

const String _tag = 'FlutterTtsVoice';

final class FlutterTtsVoice implements Voice {
  FlutterTtsVoice({FlutterTts? tts}) : _tts = tts ?? FlutterTts();

  final FlutterTts _tts;
  bool _warm = false;
  bool _disposed = false;
  int _fileSeq = 0;

  @override
  Future<void> warmUp() async {
    if (_disposed) throw StateError('FlutterTtsVoice used after dispose');
    if (_warm) return;
    await _tts.awaitSynthCompletion(true);
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.92);
    await _tts.setPitch(1.12);
    await _tts.setVolume(1.0);
    _warm = true;
    Log.i(_tag, 'TTS engine ready');
  }

  @override
  Future<Int16List> synthesize(String text) async {
    if (_disposed) throw StateError('FlutterTtsVoice used after dispose');
    if (!_warm) await warmUp();
    final trimmed = text.trim();
    if (trimmed.isEmpty) return Int16List(0);

    final dir = await getTemporaryDirectory();
    final path = p.join(dir.path, 'cutebot_tts_${_fileSeq++}.wav');
    final file = File(path);
    try {
      final result = await _tts.synthesizeToFile(trimmed, path, true);
      if (result != 1 && result != true) {
        throw StateError('synthesizeToFile returned $result');
      }
      if (!file.existsSync() || file.lengthSync() == 0) {
        throw StateError('synthesizeToFile wrote an empty file');
      }
      final wav = parseWavPcm(file.readAsBytesSync());
      return resamplePcm16(
        wav.pcm,
        fromRate: wav.sampleRate,
        toRate: AudioWireFormat.sampleRate,
      );
    } finally {
      try {
        if (file.existsSync()) file.deleteSync();
      } catch (e) {
        Log.w(_tag, 'tts temp delete failed: $e');
      }
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _warm = false;
    try {
      await _tts.stop();
    } catch (_) {}
  }
}
