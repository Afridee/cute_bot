import 'package:cute_bot/companion/voice/speech_out.dart';
import 'package:cute_bot/companion/voice/voice.dart';
import 'package:cute_bot/shared/ble_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('speaks a completed sentence as one BLE utterance', () async {
    final frames = <AudioChunkMessage>[];
    final voice = FakeVoice(msPerWord: 20);
    await voice.warmUp();
    final speaker = ReplySpeaker(
      voice: voice,
      sendFrame: frames.add,
      mtu: () => 517,
      queuedFrames: () => 0,
    );

    await speaker.beginTurn();
    await speaker.update('Hello there.', isFinal: false);
    await speaker.update('Hello there. I am a tiny robot.', isFinal: true);
    await speaker.idle;

    expect(frames, isNotEmpty);
    expect(frames.first.isUtteranceStart, isTrue);
    expect(frames.last.isUtteranceEnd, isTrue);
    expect(speaker.speaking, isFalse);
    expect(speaker.firstAudioMs, isNotNull);
  });
}
