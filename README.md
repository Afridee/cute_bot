# Cute Bot

Flutter companion app for a small desk robot (mic + speaker + BLE; ESP32 later).
All intelligence runs on the phone, fully offline. The bot is ears, a mouth,
and a face.

**Milestone status: M0 complete (agent bar). Awaiting the M0 human-bar test.**

## Layout

| Path | What it is |
|---|---|
| `lib/shared/ble_protocol.dart` | The BLE contract: UUIDs, frame header, message types, audio wire format, pairing stance. Dependency-free Dart; the ESP32 firmware ports from it. Control plane frozen after M0; audio plane provisional until the M1 bandwidth gate. |
| `lib/shared/adpcm.dart` | IMA ADPCM codec (4:1), self-contained blocks. Dependency-free, firmware-portable. |
| `lib/shared/log.dart` | Single logging channel with levels. `adb logcat | grep CuteBot`. |
| `lib/bot_simulator/` | Peripheral (GATT server) mode: a second Android phone standing in for the ESP32. |
| `lib/companion/` | Central mode — the actual app. Placeholder until M1. |

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
- `flutter_pcm_sound` 3.3.3 — simulator real-time raw PCM16 playback.

## Protocol summary (v1)

- Service `cb070001-…`; characteristics: audio-from-bot (notify),
  audio-to-bot (write w/o response), control (write), telemetry (read+notify).
- Every frame: 4-byte header — type, flags, uint16 LE sequence.
- Audio: 16 kHz / 16-bit mono PCM → IMA ADPCM 4:1 (~64 kbps), 20 ms
  self-contained blocks (164 B encoded, 168 B framed → needs MTU ≥ 171).
- Endpointing: push-to-talk; start/end-of-utterance flags in the frame header.
- Pairing: **open link** for the simulator phase; moves to bonded-only +
  encrypted writes before real hardware. Recorded in `ble_protocol.dart`.

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
- iOS is deliberately unsupported (long-lived foreground service + multi-GB
  model has no iOS equivalent).
