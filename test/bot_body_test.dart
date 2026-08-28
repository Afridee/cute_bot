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

  test('set_timer acks with a yes expression (set_timer is terminal)', () async {
    await body.invoke('set_timer', {'minutes': 3, 'label': 'tea'});
    // BotMood.yes = green blink + chirp.
    expect(sent, hasLength(2));
    final led = sent[0] as SetLedCommand;
    expect((led.red, led.green, led.blue), (0, 255, 0));
    expect(led.pattern, LedPattern.blink);
    expect((sent[1] as PlaySoundCommand).sound, BotSound.chirp);
  });

  test('set_timer rejects an empty duration and does not ack', () async {
    final got = await body.invoke('set_timer', {'minutes': 0});
    expect(got.result['error'], contains('duration'));
    expect(got.armed, isNull);
    expect(timers.pending, isEmpty);
    expect(sent, isEmpty);
  });

  test('set_timer with seconds fires in that many seconds', () async {
    final got = await body.invoke('set_timer', {'seconds': 20, 'label': 'rest'});
    expect(got.result['status'], 'ok');
    expect(got.armed, isNotNull);
    expect(got.armed!.minutes, 0);
    expect(got.armed!.totalSeconds, 20);
    expect(got.armed!.label, 'rest');
    expect(got.armed!.firesAt.millisecondsSinceEpoch, 1_000_000 + 20 * 1000);
  });

  test('set_timer minutes plus seconds', () async {
    final got =
        await body.invoke('set_timer', {'minutes': 1, 'seconds': 30, 'label': 'tea'});
    expect(got.armed!.totalSeconds, 90);
    expect(got.armed!.firesAt.millisecondsSinceEpoch, 1_000_000 + 90 * 1000);
  });

  test('set_timer default label', () async {
    final got = await body.invoke('set_timer', {'minutes': 1});
    expect(got.armed!.label, 'timer');
  });

  test('cancel_timer drops the pending timer and acks yes', () async {
    await body.invoke('set_timer', {'minutes': 3, 'label': 'tea'});
    sent.clear();
    final got = await body.invoke('cancel_timer', {});
    expect(got.result['status'], 'ok');
    expect(got.cancelledId, isNotNull);
    expect(timers.pending, isEmpty);
    expect(sent, hasLength(2)); // yes = green blink + chirp
  });

  test('cancel_timer with no pending timer acks no', () async {
    final got = await body.invoke('cancel_timer', {});
    expect(got.result['error'], contains('no matching timer'));
    expect(got.cancelledId, isNull);
    expect(sent, hasLength(1));
    final led = sent.single as SetLedCommand;
    expect((led.red, led.green, led.blue), (255, 0, 0));
  });

  test('pause_timer freezes remaining; resume_timer continues', () async {
    await body.invoke('set_timer', {'minutes': 3, 'label': 'tea'});
    sent.clear();
    final paused = await body.invoke('pause_timer', {});
    expect(paused.result['status'], 'ok');
    expect(paused.paused, isNotNull);
    expect(paused.paused!.isPaused, isTrue);
    expect(timers.pending.single.isPaused, isTrue);
    expect(paused.paused!.remainingAt(DateTime.fromMillisecondsSinceEpoch(1_000_000)),
        const Duration(minutes: 3));
    expect(sent, isNotEmpty);

    sent.clear();
    final resumed = await body.invoke('resume_timer', {});
    expect(resumed.result['status'], 'ok');
    expect(resumed.resumed, isNotNull);
    expect(resumed.resumed!.isPaused, isFalse);
    expect(timers.pending.single.isPaused, isFalse);
  });

  test('pause_timer / cancel_timer match by label', () async {
    final t = DateTime.fromMillisecondsSinceEpoch(1_000_000);
    await timers.add(PendingTimer(
      id: 'tea-id',
      minutes: 3,
      label: 'tea',
      firesAt: t.add(const Duration(minutes: 3)),
    ));
    await timers.add(PendingTimer(
      id: 'bread-id',
      minutes: 5,
      label: 'bread',
      firesAt: t.add(const Duration(minutes: 5)),
    ));
    final paused = await body.invoke('pause_timer', {'label': 'tea'});
    expect(paused.paused!.id, 'tea-id');
    expect(timers.pending.where((x) => x.id == 'tea-id').single.isPaused, isTrue);
    expect(
        timers.pending.where((x) => x.id == 'bread-id').single.isPaused, isFalse);

    final cancelled = await body.invoke('cancel_timer', {'label': 'bread'});
    expect(cancelled.cancelledId, 'bread-id');
    expect(timers.pending.single.id, 'tea-id');
  });
}
