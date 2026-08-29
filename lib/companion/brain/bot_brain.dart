/// The LLM boundary (M2/M3).
///
/// This interface is defined *before* any inference code exists, per the
/// brief: M3's `GemmaBrain` and M2's [FakeBrain-style] stand-ins both live
/// behind it, so the service, the tool dispatch (M4) and the TTS path (M5)
/// never know which brain is installed.
///
/// Keep this file free of plugin imports — dart:typed_data only — so it can
/// be unit-tested without a device.
library;

import 'dart:typed_data';

import '../../shared/ble_protocol.dart' show AudioWireFormat;
import 'transcript.dart';

/// One recorded utterance, as reassembled from the radio.
final class AudioClip {
  const AudioClip({
    required this.pcm,
    this.sampleRate = AudioWireFormat.sampleRate,
  });

  /// Mono PCM-16 samples.
  final Int16List pcm;
  final int sampleRate;

  Duration get duration =>
      Duration(milliseconds: pcm.length * 1000 ~/ sampleRate);
}

/// Everything the brain gets to see beyond the current utterance.
///
/// After a process kill the KV cache is gone; recovery = replaying this
/// transcript into a fresh session (a full prefill). That is why the
/// transcript — not the session — is the durable artifact.
final class ConversationContext {
  ConversationContext({required List<TranscriptEntry> transcript})
      : transcript = List.unmodifiable(transcript);

  final List<TranscriptEntry> transcript;
}

/// Live tool dispatch. GemmaBrain uses this inside the generate loop so
/// the body moves before the turn ends; HybridBrain uses it on NLP hits.
typedef ToolExecutor = Future<Map<String, dynamic>> Function(
    String name, Map<String, dynamic> args);

/// The brain. One instance per service lifetime; [warmUp] once at service
/// start (tens of seconds for a real model), then [respond] per utterance.
///
/// Implementations must tolerate [respond] being called strictly
/// sequentially — the caller (BrainSession) serializes the conversation
/// queue, per the LiteRT-LM one-conversation-per-engine constraint.
abstract interface class BotBrain {
  /// Loads the model. Slow (tens of seconds warm-up is normal); must be a
  /// no-op when already warm.
  Future<void> warmUp();

  /// Responds to one utterance. Events stream in order and always end with
  /// exactly one [Done] or [BrainError].
  Stream<BrainEvent> respond(AudioClip audio, ConversationContext ctx);

  /// Responds to a non-audio cue (M4 timer fire). Same serialization and
  /// event contract as [respond] — never a second concurrent session.
  Stream<BrainEvent> respondToCue(String cue, ConversationContext ctx);

  Future<void> dispose();
}

/// Events streamed by [BotBrain.respond].
sealed class BrainEvent {
  const BrainEvent();
}

/// One chunk of response text (token delta from a streaming model).
final class TextDelta extends BrainEvent {
  const TextDelta(this.text);
  final String text;
}

/// A structured tool invocation (M4 dispatches these to the bot's body).
final class ToolCall extends BrainEvent {
  const ToolCall(this.name, this.arguments);
  final String name;
  final Map<String, Object?> arguments;

  /// Compact line for the transcript / debug panel: `express(delighted)`,
  /// `set_timer(3, tea)`, `cancel_timer()`, `get_battery()`.
  String get transcriptLine {
    if (arguments.isEmpty) return '$name()';
    return '$name(${arguments.values.join(', ')})';
  }

  @override
  String toString() => 'ToolCall($name, $arguments)';
}

/// The response completed normally. Terminal.
final class Done extends BrainEvent {
  const Done();
}

/// The response failed. Terminal. The conversation survives — the caller
/// decides whether to retry or move on.
final class BrainError extends BrainEvent {
  const BrainError(this.message);
  final String message;
}
