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

/// Hub default. Override with `--dart-define=GEMMA_MODEL_URL=…` (or
/// `config.json`) once the `.litertlm` is on a CDN / R2 bucket.
const String kGemma4E2BHubUrl =
    'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm';

/// Resolved install URL. Empty `GEMMA_MODEL_URL` keeps the Hub fallback.
String gemmaModelUrlFromEnvironment() {
  const override = String.fromEnvironment('GEMMA_MODEL_URL');
  return resolveGemmaModelUrl(override);
}

String resolveGemmaModelUrl(String override) {
  final url = override.trim();
  return url.isEmpty ? kGemma4E2BHubUrl : url;
}

/// `fromNetwork` should only send a Bearer token to Hugging Face. A token
/// on R2 / S3 / a custom CDN makes the GET fail.
String? downloadTokenForModelUrl(String url) {
  return isHuggingFaceModelUrl(url) ? huggingFaceTokenFromEnvironment() : null;
}

bool isHuggingFaceModelUrl(String url) {
  final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
  return host == 'huggingface.co' || host.endsWith('.huggingface.co');
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
