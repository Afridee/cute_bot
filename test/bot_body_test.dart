import 'package:cute_bot/companion/brain/transcript.dart';
import 'package:cute_bot/companion/expressions.dart';
import 'package:cute_bot/companion/service/bot_body.dart';
import 'package:cute_bot/companion/service/timer_store.dart';
import 'package:cute_bot/shared/ble_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<ControlMessage> sent;
  late TimerStore timers;
  late BotBody body;
  var seq = 0;
  ({int percent, int millivolts, bool charging})? battery;

  setUp(() async {
    sent = [];
    seq = 0;
    battery = (percent: 87, millivolts: 3970, charging: false);
    timers = TimerStore(InMemoryKeyValueStore());
    await timers.load();
    body = BotBody(
      timers: timers,
      sendControl: (message, label, {bool quiet = false}) => sent.add(message),
      nextSequence: () => seq++,
      waitForBattery: () async => battery,
      now: () => DateTime.fromMillisecondsSinceEpoch(1_000_000),
    );
  });

  test('express(delighted) writes LED + sound + wiggle', () async {
    final got = await body.invoke('express', {'mood': 'delighted'});
    expect(got.result['status'], 'ok');
    expect(got.result['mood'], 'delighted');
    expect(sent, hasLength(3));
    expect(sent[0], isA<SetLedCommand>());
    final led = sent[0] as SetLedCommand;
    expect((led.red, led.green, led.blue), (255, 105, 180)); // pink
    expect(led.pattern, LedPattern.blink);
    expect((sent[1] as PlaySoundCommand).sound, BotSound.chirp);
    expect(sent[2], isA<WiggleCommand>());
  });

  test('express(curious) is LED-only (no sound, no wiggle)', () async {
    await body.invoke('express', {'mood': 'curious'});
    expect(sent, hasLength(1));
    expect(sent.single, isA<SetLedCommand>());
    expect((sent.single as SetLedCommand).pattern, LedPattern.breathe);
  });

  test('showMood(curious) matches express(curious) actuation', () {
    body.showMood(BotMood.curious);
    expect(sent, hasLength(1));
    final led = sent.single as SetLedCommand;
    expect((led.red, led.green, led.blue), (0, 200, 255)); // cyan
    expect(led.pattern, LedPattern.breathe);
  });

  test('express unknown mood errors and writes nothing', () async {
    final got = await body.invoke('express', {'mood': 'explode'});
    expect(got.result['error'], contains('unknown mood'));
    expect(sent, isEmpty);
  });

  test('set_led / wiggle / play_sound write control frames', () async {
    await body.invoke('set_led', {'color': 'pink', 'pattern': 'blink'});
    await body.invoke('wiggle', {});
    await body.invoke('play_sound', {'name': 'purr'});
    expect(sent[0], isA<SetLedCommand>());
    expect((sent[0] as SetLedCommand).pattern, LedPattern.blink);
    expect(sent[1], isA<WiggleCommand>());
    expect((sent[2] as PlaySoundCommand).sound, BotSound.purr);
  });

  test('get_battery returns telemetry to the model', () async {
    final got = await body.invoke('get_battery', {});
    expect(sent.single, isA<GetBatteryCommand>());
    expect(got.result['percent'], 87);
    expect(got.result['millivolts'], 3970);
    expect(got.result['status'], 'ok');
  });

  test('get_battery unknown when the bot stays silent', () async {
    battery = null;
    final got = await body.invoke('get_battery', {});
    expect(got.result['status'], 'unknown');
  });

  test('set_timer persists and returns an armed timer', () async {
    final got = await body.invoke('set_timer', {'minutes': 3, 'label': 'tea'});
    expect(got.result['status'], 'ok');
    expect(got.armed, isNotNull);
    expect(got.armed!.label, 'tea');
    expect(got.armed!.minutes, 3);
    expect(got.armed!.firesAt.millisecondsSinceEpoch, 1_000_000 + 3 * 60 * 1000);
    expect(timers.pending, hasLength(1));
    expect(timers.pending.single.label, 'tea');
  });

  test('set_timer rejects minutes < 1', () async {
    final got = await body.invoke('set_timer', {'minutes': 0});
    expect(got.result['error'], contains('minutes'));
    expect(got.armed, isNull);
    expect(timers.pending, isEmpty);
  });

  test('set_timer default label', () async {
    final got = await body.invoke('set_timer', {'minutes': 1});
    expect(got.armed!.label, 'timer');
  });
}
