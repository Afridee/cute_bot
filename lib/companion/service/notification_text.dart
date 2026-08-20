// Persistent-notification text formatting (M2.5), kept as a pure
// function so it is unit-testable without a service or a device.
//
// Shape: "connection · battery · brain", e.g. "Connected · 82% · idle".
// Battery is the last value the bot reported and is omitted until the
// first telemetry arrives. The brain segment describes the brain session,
// with "ready" rendered as "idle" — to the person glancing at the shade
// the bot is idle, not "ready" for some unnamed thing.

import '../bot_link.dart';
import '../brain/brain_session.dart';

String formatServiceNotificationText({
  required BotLinkState linkState,
  required BrainSessionState brainState,
  int? batteryPercent,
}) {
  final link = switch (linkState) {
    BotLinkState.ready => 'Connected',
    BotLinkState.scanning => 'Looking for bot',
    BotLinkState.connecting ||
    BotLinkState.configuring =>
      'Connecting',
    BotLinkState.reconnectWait => 'Reconnecting',
    BotLinkState.bluetoothOff => 'Bluetooth off',
    BotLinkState.unauthorized => 'Needs permission',
    BotLinkState.unsupported => 'BLE unsupported',
    BotLinkState.idle => 'Bot offline',
  };
  final brain = switch (brainState) {
    BrainSessionState.warming => 'warming up',
    BrainSessionState.ready => 'idle',
    BrainSessionState.thinking => 'thinking',
    BrainSessionState.responding => 'responding',
    BrainSessionState.cold => 'brain off',
  };
  return [
    link,
    if (batteryPercent != null) '$batteryPercent%',
    brain,
  ].join(' · ');
}
