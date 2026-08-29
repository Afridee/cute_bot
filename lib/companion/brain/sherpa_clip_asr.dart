/// On-device ASR for BLE utterances (sherpa-onnx Whisper base.en).
///
/// The companion already has a complete 16 kHz clip, so this is offline
/// (non-streaming) decode on CPU — it must not fight LiteRT for the GPU.
/// ~161 MB int8 (encoder + decoder), English, downloaded once next to
/// the Gemma bundle. A failed warm-up is non-fatal: [transcribe] returns
/// null and Gemma still hears.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../../shared/log.dart';
import 'bot_brain.dart';
import 'clip_asr.dart';
import 'gemma_init.dart';
import 'model_download.dart';
import 'pcm16.dart';

const String _tag = 'ClipAsr';

const String kAsrRepo =
    'https://huggingface.co/csukuangfj/sherpa-onnx-whisper-base.en/resolve/main';

const _AsrFile _encoderFile = _AsrFile(
  name: 'base.en-encoder.int8.onnx',
  minBytes: 20000000,
);
const _AsrFile _decoderFile = _AsrFile(
  name: 'base.en-decoder.int8.onnx',
  minBytes: 100000000,
);
const _AsrFile _tokensFile = _AsrFile(
  name: 'base.en-tokens.txt',
  minBytes: 100000,
);

const List<_AsrFile> _asrFiles = [
  _encoderFile,
  _decoderFile,
  _tokensFile,
];

const List<String> _legacyCacheFolders = [
  'zipformer-small-en',
  'zipformer-gigaspeech-en',
  'whisper-tiny-en',
];

final class _AsrFile {
  const _AsrFile({required this.name, required this.minBytes});
  final String name;
  final int minBytes;
}

final class SherpaClipAsr implements ClipAsr {
  SherpaClipAsr({this.baseUrl = kAsrRepo});

  final String baseUrl;

  sherpa.OfflineRecognizer? _recognizer;
  bool _warm = false;
  bool _disposed = false;
  Future<void>? _warmUpInFlight;

  @override
  Future<void> warmUp() {
    if (_disposed || _warm) return Future.value();
    return _warmUpInFlight ??= _warmUp().whenComplete(() {
      _warmUpInFlight = null;
    });
  }

  Future<void> _warmUp() async {
    try {
      sherpa.initBindings();
      final dir = Directory(p.join(
        (await getApplicationDocumentsDirectory()).path,
        'asr',
        'whisper-base-en',
      ));
      await dir.create(recursive: true);
      final token = downloadTokenForModelUrl(baseUrl);
      await Future.wait([
        for (final file in _asrFiles)
          downloadModelFile(
            url: '$baseUrl/${file.name}',
            dest: File(p.join(dir.path, file.name)),
            token: token,
            minCompleteBytes: file.minBytes,
            chunkCount: file.minBytes > 1000000 ? kModelDownloadChunks : 1,
            isCancelled: () => _disposed,
          ),
      ]);
      if (_disposed) return;

      final model = sherpa.OfflineModelConfig(
        whisper: sherpa.OfflineWhisperModelConfig(
          encoder: p.join(dir.path, _encoderFile.name),
          decoder: p.join(dir.path, _decoderFile.name),
          language: 'en',
          task: 'transcribe',
        ),
        tokens: p.join(dir.path, _tokensFile.name),
        modelType: 'whisper',
        numThreads: 2,
        debug: false,
        provider: 'cpu',
      );
      _recognizer = sherpa.OfflineRecognizer(
        sherpa.OfflineRecognizerConfig(model: model),
      );
      _warm = true;
      Log.i(_tag, 'whisper-base-en ready');
      await _deleteLegacyCaches(dir.parent);
    } catch (e, stack) {
      Log.w(_tag, 'warm-up failed; spoken turns stay on Gemma: $e');
      Log.w(_tag, '$stack');
      _recognizer?.free();
      _recognizer = null;
      _warm = false;
    }
  }

  /// Best-effort: leftover zipformer / tiny.en weights cannot be reused
  /// and should not sit on the phone.
  Future<void> _deleteLegacyCaches(Directory asrDir) async {
    for (final name in _legacyCacheFolders) {
      try {
        final legacy = Directory(p.join(asrDir.path, name));
        if (await legacy.exists()) {
          await legacy.delete(recursive: true);
          Log.i(_tag, 'removed leftover asr/$name');
        }
      } catch (e) {
        Log.w(_tag, 'could not remove leftover $name: $e');
      }
    }
  }

  @override
  Future<String?> transcribe(AudioClip clip) async {
    if (_disposed || !_warm) return null;
    final recognizer = _recognizer;
    if (recognizer == null) return null;
    if (clip.pcm.isEmpty || clipLooksSilent(clip.pcm)) return null;

    final watch = Stopwatch()..start();
    sherpa.OfflineStream? stream;
    try {
      var pcm = clip.pcm;
      var rate = clip.sampleRate;
      if (rate != 16000) {
        pcm = resamplePcm16(pcm, fromRate: rate, toRate: 16000);
        rate = 16000;
      }
      stream = recognizer.createStream();
      stream.acceptWaveform(
        samples: pcm16ToFloat32(pcm),
        sampleRate: rate,
      );
      recognizer.decode(stream);
      final text = recognizer.getResult(stream).text.trim();
      watch.stop();
      if (text.isEmpty) {
        Log.i(_tag, 'empty (${watch.elapsedMilliseconds}ms)');
        return null;
      }
      Log.i(_tag, '"$text" (${watch.elapsedMilliseconds}ms)');
      return text;
    } catch (e, stack) {
      Log.w(_tag, 'transcribe failed: $e');
      Log.w(_tag, '$stack');
      return null;
    } finally {
      stream?.free();
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _warm = false;
    try {
      _recognizer?.free();
    } catch (_) {}
    _recognizer = null;
  }
}
