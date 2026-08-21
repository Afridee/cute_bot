/// FlutterGemma bring-up for the service isolate (M3).
///
/// The foreground service runs its own Dart isolate, so this must be called
/// *there* — `main()` of the UI isolate never sees the model. Repeat calls
/// are no-ops.
library;

import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_litertlm/flutter_gemma_litertlm.dart';

import '../../shared/log.dart';

const String _tag = 'GemmaInit';

Future<void>? _inFlight;

/// HuggingFace token from `--dart-define=HUGGINGFACE_TOKEN=…`. Empty means
/// send nothing — the litert-community Gemma 4 `.litertlm` is ungated; a
/// bare `Authorization: Bearer` header would only hurt.
String? huggingFaceTokenFromEnvironment() {
  const token = String.fromEnvironment('HUGGINGFACE_TOKEN');
  return token.isEmpty ? null : token;
}

/// Registers the LiteRT-LM engine. Safe to call more than once.
Future<void> ensureGemmaInitialized() {
  return _inFlight ??= _initialize();
}

Future<void> _initialize() async {
  final token = huggingFaceTokenFromEnvironment();
  Log.i(_tag,
      'FlutterGemma.initialize (engine: LiteRtLm, hf token: ${token == null ? 'no' : 'yes'})');
  await FlutterGemma.initialize(
    inferenceEngines: const [LiteRtLmEngine()],
    huggingFaceToken: token,
  );
}
