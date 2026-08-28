/// PCM → text sidecar. Implementations must be safe to call from the
/// service isolate; a miss (null) means HybridBrain falls through to Gemma.
library;

import 'bot_brain.dart';

abstract interface class ClipAsr {
  /// Load native bindings / model files. Must not throw: a failed ASR
  /// leaves spoken turns on the LLM path.
  Future<void> warmUp();

  /// Transcript of [clip], or null when silent / not ready / empty.
  Future<String?> transcribe(AudioClip clip);

  Future<void> dispose();
}
