import 'dart:math';
import 'dart:typed_data';

import 'package:cute_bot/shared/adpcm.dart';
import 'package:cute_bot/shared/ble_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('frame header', () {
    test('is 4 bytes, little-endian sequence', () {
      final frame =
          const BotStateMessage(sequence: 0x1234, state: BotState.idle).encode();
      expect(frame[0], MessageType.botState);
      expect(frame[1], 0); // no flags
      expect(frame[2], 0x34); // seq LE low byte first
      expect(frame[3], 0x12);
    });

    test('decode rejects frames shorter than the header', () {
      expect(() => BotMessage.decode(Uint8List(3)),
          throwsA(isA<ProtocolException>()));
    });

    test('decode rejects unknown message types', () {
      final frame = Uint8List.fromList([0x7F, 0, 0, 0]);
      expect(() => BotMessage.decode(frame), throwsA(isA<ProtocolException>()));
    });
  });

  group('audio chunk messages', () {
    test('round-trip with real codec output (agent bar)', () {
      // End-to-end: PCM -> ADPCM -> frame -> decode frame -> ADPCM -> PCM.
      final rng = Random(42);
      final pcm = Int16List.fromList(List.generate(
          AudioWireFormat.samplesPerFrame, (_) => rng.nextInt(65536) - 32768));
      final encoder = ImaAdpcmEncoder();
      final block = encoder.encodeBlock(pcm);

      final sent = AudioChunkMessage(
        sequence: 7,
        adpcmBlock: block,
        isUtteranceStart: true,
      );
      final wire = sent.encode();
      expect(wire.length, AudioWireFormat.audioFrameBytes);

      final received = BotMessage.decode(wire) as AudioChunkMessage;
      expect(received.sequence, 7);
      expect(received.isUtteranceStart, isTrue);
      expect(received.isUtteranceEnd, isFalse);
      expect(received.adpcmBlock, block);

      // The payload survives framing byte-for-byte, so decode must produce
      // exactly what a direct codec round-trip produces.
      expect(decodeAdpcmBlock(received.adpcmBlock), decodeAdpcmBlock(block));
    });

    test('utterance boundary flags round-trip', () {
      final block = ImaAdpcmEncoder().encodeBlock(Int16List(320));
      final end = BotMessage.decode(AudioChunkMessage(
        sequence: 99,
        adpcmBlock: block,
        isUtteranceEnd: true,
      ).encode()) as AudioChunkMessage;
      expect(end.isUtteranceEnd, isTrue);
      expect(end.isUtteranceStart, isFalse);
    });

    test('empty end-of-utterance frame is legal', () {
      final decoded = BotMessage.decode(AudioChunkMessage(
        sequence: 5,
        adpcmBlock: Uint8List(0),
        isUtteranceEnd: true,
      ).encode()) as AudioChunkMessage;
      expect(decoded.adpcmBlock, isEmpty);
      expect(decoded.isUtteranceEnd, isTrue);
    });

    test('truncated audio payload is rejected', () {
      final frame = Uint8List.fromList([MessageType.audioChunk, 0, 0, 0, 1, 2]);
      expect(() => BotMessage.decode(frame), throwsA(isA<ProtocolException>()));
    });

    test('audio frame fits the preferred MTU', () {
      expect(AudioWireFormat.audioFrameBytes, lessThanOrEqualTo(kPreferredMtu - 3));
    });
  });

  group('control messages', () {
    test('set_led round-trips', () {
      final decoded = BotMessage.decode(const SetLedCommand(
        sequence: 1,
        red: 255,
        green: 128,
        blue: 0,
        pattern: LedPattern.breathe,
      ).encode()) as SetLedCommand;
      expect(decoded.red, 255);
      expect(decoded.green, 128);
      expect(decoded.blue, 0);
      expect(decoded.pattern, LedPattern.breathe);
      expect(decoded.sequence, 1);
    });

    test('wiggle round-trips', () {
      expect(BotMessage.decode(const WiggleCommand(sequence: 2).encode()),
          isA<WiggleCommand>());
    });

    test('play_sound round-trips', () {
      final decoded = BotMessage.decode(
              const PlaySoundCommand(sequence: 3, sound: BotSound.purr).encode())
          as PlaySoundCommand;
      expect(decoded.sound, BotSound.purr);
    });

    test('get_battery round-trips', () {
      expect(BotMessage.decode(const GetBatteryCommand(sequence: 4).encode()),
          isA<GetBatteryCommand>());
    });

    test('show_text round-trips UTF-8 and the final flag', () {
      final utf8Bytes = Uint8List.fromList([
        0x68, 0x69, 0x20, // "hi "
        0xF0, 0x9F, 0xA4, 0x96, // U+1F916 robot
      ]);
      final decoded = BotMessage.decode(ShowTextCommand(
        sequence: 5,
        utf8Text: utf8Bytes,
        isFinal: false,
      ).encode()) as ShowTextCommand;
      expect(decoded.sequence, 5);
      expect(decoded.isFinal, isFalse);
      expect(decoded.utf8Text, utf8Bytes);
      expect(decoded.commandId, ControlCommandId.showText);

      final done = BotMessage.decode(ShowTextCommand(
        sequence: 6,
        utf8Text: utf8Bytes,
      ).encode()) as ShowTextCommand;
      expect(done.isFinal, isTrue);
    });

    test('show_text with empty payload is legal', () {
      final decoded = BotMessage.decode(ShowTextCommand(
        sequence: 7,
        utf8Text: Uint8List(0),
        isFinal: true,
      ).encode()) as ShowTextCommand;
      expect(decoded.utf8Text, isEmpty);
      expect(decoded.isFinal, isTrue);
    });

    test('malformed control frames are rejected', () {
      // No command id.
      expect(() => BotMessage.decode(Uint8List.fromList([MessageType.control, 0, 0, 0])),
          throwsA(isA<ProtocolException>()));
      // Unknown command id: ACK-and-ignore, never an ATT error.
      final ignored = BotMessage.decode(
              Uint8List.fromList([MessageType.control, 0, 0, 0, 0x7F, 0x01]))
          as IgnoredControlCommand;
      expect(ignored.rawCommandId, 0x7F);
      expect(ignored.rawArgs, [0x01]);
      expect(BotMessage.decode(ignored.encode()), isA<IgnoredControlCommand>());
      // set_led with missing args.
      expect(
          () => BotMessage.decode(Uint8List.fromList(
              [MessageType.control, 0, 0, 0, ControlCommandId.setLed, 255])),
          throwsA(isA<ProtocolException>()));
      // Unknown LED pattern.
      expect(
          () => BotMessage.decode(Uint8List.fromList(
              [MessageType.control, 0, 0, 0, ControlCommandId.setLed, 1, 2, 3, 9])),
          throwsA(isA<ProtocolException>()));
      // show_text with missing flags byte.
      expect(
          () => BotMessage.decode(Uint8List.fromList(
              [MessageType.control, 0, 0, 0, ControlCommandId.showText])),
          throwsA(isA<ProtocolException>()));
    });
  });

  group('telemetry and state', () {
    test('battery status round-trips, millivolts little-endian', () {
      final wire = const BatteryStatusMessage(
        sequence: 10,
        percent: 87,
        charging: true,
        millivolts: 4123,
      ).encode();
      final decoded = BotMessage.decode(wire) as BatteryStatusMessage;
      expect(decoded.percent, 87);
      expect(decoded.charging, isTrue);
      expect(decoded.millivolts, 4123);
      // payload: [kind][percent][charging][mV lo][mV hi]
      expect(wire[7], 4123 & 0xFF);
      expect(wire[8], 4123 >> 8);
    });

    test('bot state round-trips for every state', () {
      for (final state in BotState.values) {
        final decoded = BotMessage.decode(
                BotStateMessage(sequence: 0, state: state).encode())
            as BotStateMessage;
        expect(decoded.state, state);
      }
    });

    test('malformed telemetry/state frames are rejected', () {
      expect(
          () => BotMessage.decode(
              Uint8List.fromList([MessageType.telemetry, 0, 0, 0])),
          throwsA(isA<ProtocolException>()));
      expect(
          () => BotMessage.decode(Uint8List.fromList(
              [MessageType.telemetry, 0, 0, 0, TelemetryKind.battery, 1])),
          throwsA(isA<ProtocolException>()));
      expect(
          () => BotMessage.decode(
              Uint8List.fromList([MessageType.botState, 0, 0, 0])),
          throwsA(isA<ProtocolException>()));
      expect(
          () => BotMessage.decode(
              Uint8List.fromList([MessageType.botState, 0, 0, 0, 200])),
          throwsA(isA<ProtocolException>()));
    });
  });

  group('sequence counter', () {
    test('increments and wraps at 0xFFFF', () {
      final counter = SequenceCounter();
      expect(counter.next(), 0);
      expect(counter.next(), 1);
      for (var i = 2; i <= FrameHeader.maxSequence; i++) {
        counter.next();
      }
      expect(counter.next(), 0); // wrapped
    });

    test('reset starts over', () {
      final counter = SequenceCounter();
      counter.next();
      counter.next();
      counter.reset();
      expect(counter.next(), 0);
    });
  });
}
