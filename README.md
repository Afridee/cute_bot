# Cute Bot

Flutter companion app for a small desk robot (mic + speaker + BLE; ESP32 later).
All intelligence runs on the phone, fully offline. The bot is ears, a mouth,
and a face.

**Milestone status: M2 complete (agent bar). Awaiting the M2 human-bar test —
kill/reboot survival on real phones. See `Docs/m2-testing-guide.md`.**

## Layout

| Path | What it is |
|---|---|
| `lib/shared/ble_protocol.dart` | The BLE contract: UUIDs, frame header, message types, audio wire format, pairing stance. Dependency-free Dart; the ESP32 firmware ports from it. Control plane frozen after M0; audio plane provisional until the M1 bandwidth gate. |
| `lib/shared/adpcm.dart` | IMA ADPCM codec (4:1), self-contained blocks. Dependency-free, firmware-portable. |
| `lib/shared/audio_transport.dart` | M1 framing/reassembly: MTU-aware chunker (sender) and loss/duplicate/reorder-tolerant reassembler (receiver), plus the FNV-1a delivery checksum. Dependency-free, firmware-portable. |
| `lib/shared/log.dart` | Single logging channel with levels. `adb logcat | grep CuteBot`. |
| `lib/bot_simulator/` | Peripheral (GATT server) mode: a second Android phone standing in for the ESP32. |
| `lib/companion/` | Central mode — the actual app. `bot_link.dart` (scan / auto-connect / MTU 517 / reconnect backoff / prioritized writes); since M2 the UI is a thin client over the foreground service. |
| `lib/companion/brain/` | The LLM boundary: `bot_brain.dart` (the M3 `BotBrain` interface, defined before any inference code), `fake_brain.dart` (canned responses at realistic delays), `brain_session.dart` (serialized conversation queue + recovery), `transcript.dart` (durable transcript behind a `KeyValueStore`). |
| `lib/companion/service/` | M2 foreground service: `bot_service.dart` (the service isolate that owns BotLink + the brain), `service_ipc.dart` (UI↔service message schema), `task_storage.dart` (persistence backend). |

## Toolchain

- Flutter **3.41.7** (Dart 3.11.5), managed by FVM: `~/fvm/versions/stable/bin/flutter`.
  The Flutter 3.10.6 on PATH (`~/Developer/flutter`) is stale — don't use it.
- Android only. minSdk 29 (Android 10). BLE does not work on emulators; use
  two physical phones.

## Dependencies (and why)

- `bluetooth_low_energy` 6.2.1 — the one BLE package for **both** roles.
  Peripheral (GATT server) mode for the simulator, central mode for the
  companion in M1. `flutter_blue_plus` is central-only, which rules it out.
- `record` 6.2.1 — simulator mic capture as a PCM16 stream. (7.x needs
  Dart ≥ 3.12; this project is on 3.11.5.)
- `flutter_pcm_sound` 3.3.3 — simulator real-time raw PCM16 playback (also
  used by the service isolate for the live-monitor diagnostic since M2).
- `flutter_foreground_task` 10.0.0 — the M2 foreground service. Named in the
  brief; chosen over a hand-written platform-channel service because it
  already does the hard parts: a separate service-owned Flutter engine with
  automatic plugin registration, two-way isolate messaging, START_STICKY,
  `allowAutoRestart` (system-kill recovery), `autoRunOnBoot` (BOOT_COMPLETED
  receiver), battery-optimization helpers, and a SharedPreferences-backed
  store used for transcript persistence. (11.0.0 exists but needs a newer
  Dart than 3.11.5; 10.0.0 has every API M2 uses.)

## Protocol summary (v1)

- Service `cb070001-…`; characteristics: audio-from-bot (notify),
  audio-to-bot (write w/o response), control (write), telemetry (read+notify).
- Every frame: 4-byte header — type, flags, uint16 LE sequence.
- Audio: 16 kHz / 16-bit mono PCM → IMA ADPCM 4:1 (~64 kbps), 20 ms
  self-contained blocks (164 B encoded, 168 B framed → needs MTU ≥ 171).
- Endpointing: push-to-talk; start/end-of-utterance flags in the frame header.
- Pairing: **open link** for the simulator phase; moves to bonded-only +
  encrypted writes before real hardware. Recorded in `ble_protocol.dart`.

## M1 in one paragraph

The companion scans for the bot service UUID, connects to the first match,
requests MTU 517 immediately (and adapts frame size if it gets less),
subscribes to audio + telemetry, and reconnects on drop with exponential
backoff (0.5 s doubling to 30 s; rescan rather than reuse the old handle,
because Android peripherals rotate their random address). Outbound writes go
through a single prioritized queue: control commands (write-with-response)
always jump ahead of audio frames (write-without-response). Incoming
utterances are reassembled with silence substituted for lost frames, played
live, and scored for the bandwidth gate: ×-real-time rate, kbps, worst
inter-frame gap, loss/dup/stale counts, and an FNV-1a checksum the simulator
also displays for the byte-identical check. `Docs/m1-testing-guide.md` walks
the two-phone test.

## M2 in one paragraph

The bot lives in an Android foreground service (`foregroundServiceType=
connectedDevice`), in its own Flutter engine/isolate. That isolate — not the
UI — owns the BLE central link, an `UtteranceReassembler`, and a
`BrainSession` wrapping a `FakeBrain` behind the M3 `BotBrain` interface, so
swiping the app out of recents changes nothing the bot can see. Utterances
arriving off the radio flow straight into a strictly serialized conversation
queue (the LiteRT-LM one-conversation rule, enforced from day one); every
transcript line persists on append via flutter_foreground_task's store, and
on restart the session reloads the transcript, re-warms, and shows warming
state on the bot's LEDs (breathing blue) while it does. Kill → restart →
re-warm is handled as a normal lifecycle: START_STICKY + `allowAutoRestart`
cover system kills, `autoRunOnBoot` covers reboot, and the UI — now a thin
client — just renders `ServiceSnapshot`s pushed over the task channel and
runs the permission flows the service isolate cannot (BLE authorize needs an
Activity). `Docs/m2-testing-guide.md` walks the kill matrix.

## Running the M0 human-bar test

1. `flutter run` on phone #2 (the "bot"), pick **Bot Simulator**. It should
   show "Advertising CuteBot".
2. On phone #1, open nRF Connect, scan, connect to **CuteBot**.
3. In nRF Connect, request MTU 517 (⋮ → Request MTU) — audio notifications
   are 168 bytes and silently fail at the default MTU 23.
4. Subscribe to `cb070002` (audio) and `cb070005` (telemetry).
5. Hold **Hold to talk** on the simulator → audio chunk notifications stream
   on `cb070002`; release → final frame has the end-of-utterance flag (0x02).
6. Write to control `cb070004`, e.g. `02 00 00 00 01 FF 00 80 01`
   (set_led: purple-ish, solid) → the LED box changes color.
   `02 00 01 00 02` → wiggle. `02 00 02 00 03 01` → beep.
   `02 00 03 00 04` → get_battery, answered on telemetry.
7. Write an audio frame to `cb070003` → simulator plays it.
   Small valid test frame: `01 03 00 00 00 00 00 00 41 44` (start+end flags,
   4 samples — a click, but proves decode + playback).

## Known gaps / open questions

- **Bandwidth gate (M1):** whether ADPCM-over-notifications sustains ≥ 1×
  real time at < 300 ms latency on real phones is *the* open risk. The audio
  plane of the protocol stays provisional until that test passes. Fallback:
  Bluetooth Classic / A2DP for audio, BLE for control.
- Prepared (long) writes are rejected; every frame must fit one write at the
  negotiated MTU. Fine for the companion (it negotiates 517); nRF Connect
  users must request a bigger MTU manually.
- Echo: the two-phone simulator has hardware AEC, the real bot will not.
  Half-duplex is the planned v1 answer; `BotState.speaking` exists in the
  protocol for exactly that.
- Simulator battery telemetry is faked (87%, 3970 mV).
- **Boot restart (M2):** `autoRunOnBoot` uses a BOOT_COMPLETED receiver.
  `connectedDevice` services are allowed to start from BOOT_COMPLETED on
  Android 15+, but Android 12+ background-start restrictions and OEM battery
  managers can still block it; if the human-bar reboot test fails on a given
  device, the fallback the brief asks for (a tappable notification instead of
  silent failure) still needs building.
- **BLE from the service isolate (M2):** verified by source inspection of
  `bluetooth_low_energy_android` 6.2.1 — scan/connect/notify are
  Context-only; only `authorize()`/`showAppSettings()` need an Activity, so
  the UI grants permissions before the service starts. Needs on-device
  confirmation in the M2 human bar.
- The service's warming/thinking LED expressions assume the bot is connected;
  a bot that reconnects mid-state gets a re-send, but a bot that was never
  connected during warm-up simply misses the show. Harmless, revisit with
  real hardware.
- iOS is deliberately unsupported (long-lived foreground service + multi-GB
  model has no iOS equivalent).
