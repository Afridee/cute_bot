# Cute Bot

Flutter companion app for a small desk robot (mic + speaker + BLE; ESP32 later).
All intelligence runs on the phone, fully offline. The bot is ears, a mouth,
and a face.

**Milestone status: M0–M5 complete, including two-phone human bars.**
M2.5 keep-alive (CDM, resurrection, phone alerts, OEM Recents):
`Docs/m2.5-testing-guide.md`. M3 native audio:
`Docs/m3-testing-guide.md`. M4/M5 TTS / timer / battery:
`Docs/m4-testing-guide.md`.

Milestone numbering follows `cursor-prompt-bot-companion.md` for M0–M2 and
M3+. **M2.5** is background survivability. **M3** is the LLM layer.
**M4** is tools (`BotBody`, timer persistence, battery telemetry into
Gemma). **M5** is TTS to the bot speaker plus `persona.dart`.

## Layout

| Path | What it is |
|---|---|
| `lib/shared/ble_protocol.dart` | The BLE contract: UUIDs, frame header, message types, audio wire format, pairing stance. Dependency-free Dart; the ESP32 firmware ports from it. Control plane frozen after M0; audio plane provisional until the M1 bandwidth gate. |
| `lib/shared/adpcm.dart` | IMA ADPCM codec (4:1), self-contained blocks. Dependency-free, firmware-portable. |
| `lib/shared/audio_transport.dart` | M1 framing/reassembly: MTU-aware chunker (sender) and loss/duplicate/reorder-tolerant reassembler (receiver), plus the FNV-1a delivery checksum. Dependency-free, firmware-portable. |
| `lib/shared/log.dart` | Single logging channel with levels. `adb logcat | grep CuteBot`. |
| `lib/bot_simulator/` | Peripheral (GATT server) mode: a second Android phone standing in for the ESP32. |
| `lib/companion/` | Central mode — the actual app. `bot_link.dart` (scan / auto-connect / MTU 517 / reconnect backoff / prioritized writes); since M2 the UI is a thin client over the foreground service. |
| `lib/companion/brain/` | The LLM boundary: `bot_brain.dart` (the `BotBrain` interface, including `respondToCue` for timer fires), `fake_brain.dart`, `gemma_brain.dart`, `hybrid_brain.dart` + `fast_intent.dart` (NLP fast path), `sherpa_clip_asr.dart` (on-device ASR so spoken commands can hit that path), `brain_session.dart` (serialized conversation queue), `transcript.dart`, `pcm16.dart` / `latency_trace.dart` / `bot_tools.dart`. |
| `lib/companion/persona.dart` | M5: system prompt + few-shots. The only place personality lives. |
| `lib/companion/voice/` | M5: `Voice` interface, `FlutterTtsVoice` (`synthesizeToFile` → WAV → 16 kHz PCM), `FakeVoice`, sentence splitter, `ReplySpeaker` (sentence-by-sentence ADPCM over BLE). |
| `lib/companion/service/` | Foreground service plus `bot_body.dart` (tool dispatch), `timer_store.dart` (pending timers on the same KV store as the transcript), `service_ipc.dart`, `task_storage.dart`, `notification_text.dart`. |
| `lib/companion/companion_device_link.dart` | M2.5: Dart wrapper over the CDM MethodChannel — associate / disassociate / state for the "Android link" card. |
| `lib/companion/oem_care.dart` | M2.5: Dart face of OEM diagnostics — manufacturer/brand, sticky "service died behind our back" marker, Notification-access grant. |
| `lib/companion/oem_guidance_page.dart` | M2.5: one-shot "Keep the bot alive" page for vivo/iQOO (Notification access first, then Recents lock / autostart / background power). Auto-shown after an unexpected death; always reachable via **Keep-alive tips**. |
| `lib/companion/setup/` | First-run Companion setup in front of the debug panel. Order, copy, and block/skip rules: `Docs/companion-setup.md`. |
| `Docs/hardware-guide.md` | Desk-bot BOM, VAD, and firmware parity with the companion (same BLE contract as the simulator). |
| `android/app/src/main/kotlin/com/cutebot/cute_bot/` | M2.5 native layer. Restart funnel: `BotServiceStarter` (the one shared restart path). Wake sources: `BotPresenceService` (CDM, API 31+), `CuteBotNotificationListenerService` (isolated `:listener` process), `KeepAliveReceiver` (~60 s AlarmManager), `ServiceWatchdog` (15-min WorkManager). Cross-process: `CuteBotProcesses`, `DefaultProcessRelay`. Bind heal: `ListenerBindPoke`. OEM: `OemCareHandler`, `CuteBotApplication`. CDM chooser: `CompanionLinkHandler`. |

## Toolchain

- Flutter **3.44.9** (Dart 3.12.2), managed by FVM: `fvm flutter …`.
  Pinned in `.fvmrc`. `flutter_gemma` 1.0+ needs Dart ≥ 3.12 / Flutter ≥ 3.44;
  the previous 3.41.7 pin could not resolve it. The Flutter 3.10.6 on PATH
  (`~/Developer/flutter`) is stale — don't use it.
- Android only. minSdk **30** (Android 11). `libLiteRtLm` needs API 30+
  Bionic syscalls; the original brief's API 29 floor cannot load the model.
  arm64-v8a only (LiteRT-LM FFI). BLE does not work on emulators; use two
  physical phones. Companion wants 8GB+ RAM.

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
  store used for transcript persistence. (11.0.0 exists but we stayed on
  10.0.0 — every API M2 uses is here.)
- `flutter_gemma` 1.6.3 + `flutter_gemma_litertlm` 1.5.2 — M3. The brief
  named 1.5.2; `flutter_gemma_litertlm` 1.5.2 depends on `flutter_gemma
  ^1.6.1`, so the compatible pair is 1.6.3 + 1.5.2. `ModelType.gemma4`,
  native audio (`Message.withAudio`), and native function calling
  (`createChat` + `FunctionCallResponse`) are on this line. Initialize with
  `LiteRtLmEngine()` in the **service isolate**, not the UI isolate.
- `flutter_tts` 4.2.5 — M5. Named in the brief. `synthesizeToFile` (not
  `speak`) so PCM can be resampled to 16 kHz, ADPCM-encoded, and written
  to the bot speaker. The phone speaker stays silent.
- `sherpa_onnx` 1.13.6 — on-device ASR (zipformer-small English, CPU) so
  spoken clips become text for the NLP fast path. Gemma still takes native
  audio when the matcher misses.

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
`BrainSession` wrapping a `GemmaBrain` (or `FakeBrain` behind
`--dart-define=CUTEBOT_FAKE_BRAIN=true`) behind the `BotBrain` interface, so
swiping the app out of recents changes nothing the bot can see. Utterances
arriving off the radio flow straight into a strictly serialized conversation
queue (the LiteRT-LM one-conversation rule, enforced from day one); every
transcript line persists on append via flutter_foreground_task's store, and
on restart the session reloads the transcript, re-warms, and shows warming
state on the bot's OLED face (breathing blue) while it does. Kill → restart →
re-warm is handled as a normal lifecycle: START_STICKY + `allowAutoRestart`
cover system kills, `autoRunOnBoot` covers reboot, and the UI — now a thin
client — just renders `ServiceSnapshot`s pushed over the task channel and
runs the permission flows the service isolate cannot (BLE authorize needs an
Activity). `Docs/m2-testing-guide.md` walks the kill matrix.

## M2.5 (background survivability)

Our phone is the BLE *central*, so a dead app means nobody initiates the
connection. Resurrection is layered, and every wake-up funnels through one
native path, `BotServiceStarter`, which reuses flutter_foreground_task's
own persisted "user started and didn't stop" status and RESTART action;
when Android 12+ rejects the background start, it posts a tappable
"reopen the app" notification instead of failing silently.

**CDM (wake on approach).** The user links the bot once ("Link bot to
Android", a chooser filtered on the bot service UUID); the phone **bonds**
during association (so it holds the IRK and can resolve the bot's rotating
random address — recorded in `ble_protocol.dart`). On Android 12+ the OS
watches for the bot itself and binds `BotPresenceService` when it appears.
On API 29–30 association still works; wake-on-approach does not exist there.

**OEM cleaners (vivo/iQOO).** Measured on the iQOO Neo 10: the stock
cleaner FORCE-STOPS or SIGKILLs the app (even an individual Recents swipe;
locking the Recents card only protects against "clean all"). A package
FORCE_STOP is beyond sticky FGS restart, CDM, the watchdog, and alarms
until something *external* re-enters the process. The path that works is
Notification access: `CuteBotNotificationListenerService` runs in an
isolated `:listener` process so a Recents swipe can leave the system bind
intact; `onListenerConnected` / FGS-notification removal then hops through
`DefaultProcessRelay` and restarts the default-process FGS (this is how
Nothing X survives the same cleaner). A dummy `ListenerBindPoke` component
is flipped to fire `PACKAGE_CHANGED` so NotificationManagerService rebinds
us — we never disable the listener itself, because on vivo that revokes
access. Granting Notification access also powers **phone alerts on the
bot** (cyan blink + chirp; content is never read). An ask-once
`OemGuidancePage` teaches this on vivo/iQOO after an unexpected death.

**Clocks.** While the bot is wanted, `KeepAliveAlarm` schedules a ~60 s
`setExactAndAllowWhileIdle` wake (`KeepAliveReceiver`) that survives a
cleaner SIGKILL (not a FORCE_STOP) and re-arms, heals the listener bind,
and calls `ensureRunning`. The 15-minute WorkManager watchdog is the slow
safety net. The persistent notification is LOW importance (never buzzes)
and always shows `connection · battery · brain` (e.g.
`Connected · 82% · idle`), throttled; the battery-exemption dialog is
offered exactly once per install and a refusal is remembered.

## M3 in one paragraph

The service isolate loads Gemma 4 E2B (`.litertlm`, ~2.6 GB, ungated
litert-community bundle) once at warm-up via `flutter_gemma` +
`LiteRtLmEngine`, then holds one `createChat` session for the process
lifetime. Utterances arrive as 16 kHz PCM-16, get wrapped as a PCM WAV (LiteRT-LM's
miniaudio decoder needs a container, not raw samples), and go in as
`Message.withAudio` — no STT stage. Each turn clears chat history and
re-seeds a short text tail of recent bot replies; old audio clips are
not kept in the 4096-token window. Function calls come back as
structured `FunctionCallResponse` (Gemma 4 native `<|tool_call>` tokens,
`ModelType.gemma4`). Live results come from `BotBody` (LED / wiggle /
sound / timer / battery) and are fed back via `Message.toolResponse`
before the spoken follow-up. Each turn logs `submit` / `ttf` / `decode`
/ `total`; **ttf** is still end-of-speech → first token. First audio
out of the bot speaker is `ReplySpeaker: first audio Xms` in logcat
(M5). `Docs/m3-testing-guide.md` walks the on-phone model test.

## M4 in one paragraph

Tool dispatch lives in `BotBody`. `set_led` / `wiggle` / `play_sound`
are BLE control writes (the simulator already shows them). `get_battery`
writes the command, waits up to 2 s for telemetry, and returns
percent / mV to the model. `set_timer` persists on the same KV store as
the transcript (survives kill → restart) and arms a Dart timer; when it
fires, the announcement enters `BrainSession.handleCue` on the **same**
serialized conversation queue as spoken turns — never a second LiteRT
session. Due timers restore after brain warm-up.

## M5 in one paragraph

`persona.dart` is the system prompt + few-shots. Replies stream as
`TextDelta`s; `ReplySpeaker` synthesizes completed sentences through
`flutter_tts.synthesizeToFile`, parses the WAV, resamples to 16 kHz,
and ships one BLE utterance (start → frames → end) on audio-to-bot.
The simulator already sets `BotState.speaking` on that start flag and
mutes by not capturing; the companion also drops inbound mic frames
while TTS is in flight (half-duplex). Captions still go to the
simulator screen as a subtitle. `Docs/m4-testing-guide.md` is the
two-phone TTS / timer / battery human bar (passed).

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
  v1 half-duplex is confirmed on the simulator: companion drops inbound
  mic while `ReplySpeaker` is sending, and the simulator sets
  `BotState.speaking` on audio-to-bot start (so firmware can mute the
  mic the same way). Hold-to-talk during playback does not start a
  new companion turn.
- Simulator battery telemetry is faked (87%, 3970 mV).
- `show_text` carries UTF-8 captions for the simulator screen and the desk
  bot's OLED (e.g. `thinking…`, tool lines). The companion still sends a
  **final** caption (and streams only if TTS failed) with
  `reconnectOnWriteFailure: false`. Firmware must ACK unknown / optional
  control ids — an ATT error reconnects the phone. See the firmware table
  in `Docs/hardware-guide.md`.
- **Boot restart (M2):** `autoRunOnBoot` uses a BOOT_COMPLETED receiver.
  `connectedDevice` services are allowed to start from BOOT_COMPLETED on
  Android 15+, but Android 12+ background-start restrictions and OEM battery
  managers can still block it. Since M2.5 a blocked boot start is covered
  by the notification-listener rebind (if access is granted) and then the
  15-minute WorkManager watchdog, which posts the tappable "reopen the app"
  notification instead of failing silently. The keep-alive alarm does not
  survive reboot; `CuteBotApplication` re-arms it the next time any of our
  processes starts.
- **CDM presence end-to-end (M2.5):** confirmed on two phones (human bar
  passed). Association chooser, bonding against the
  `bluetooth_low_energy` simulator peripheral, and appeared→resurrect
  without opening the app. Procedure: `Docs/m2.5-testing-guide.md`.
- **vivo Recents swipe vs Settings Force stop (M2.5):** Recents recovery
  passed on the human bar. A Recents swipe on vivo can SIGKILL the
  default process while leaving `:listener` (and a pre-armed keep-alive
  alarm) able to restart the FGS. A package FORCE_STOP (Settings → Force
  stop, and sometimes vivo's single-cleaner) kills every process and
  cancels alarms; self-recovery then depends on `system_server` rebinding
  the enabled notification listener. If the OEM never rebinds, only
  opening the app recovers — that is Android, not a missed restart path.
  The guidance page tells vivo users to leave with Home, lock the Recents
  card, and grant Notification access.
- **Notification timeout (M2.5):** skipped. `flutter_foreground_task` doesn't
  expose `Notification.setTimeoutAfter`, and re-posting the service's own
  foreground notification from outside would race the plugin's updates. The
  keep-alive alarm and watchdog cover the wedged-service case instead.
- **BLE from the service isolate (M2):** verified by source inspection of
  `bluetooth_low_energy_android` 6.2.1 — scan/connect/notify are
  Context-only; only `authorize()`/`showAppSettings()` need an Activity, so
  the UI grants permissions before the service starts. Confirmed on
  device: the bot replies with only the foreground service running
  (M3 / M2.5).
- The service's warming/thinking face expressions assume the bot is connected;
  a bot that reconnects mid-state gets a re-send, but a bot that was never
  connected during warm-up simply misses the show. Harmless, revisit with
  real hardware.
- iOS is deliberately unsupported (long-lived foreground service + multi-GB
  model has no iOS equivalent).
- **Native audio on the E2B `.litertlm` (M3):** flutter_gemma 1.6.3 exposes
  `supportAudio` + `Message.withAudio` with no model-version gate. Audio
  bytes must be a PCM WAV — raw PCM16 fails native start-stream with
  miniaudio error -10 (`MA_INVALID_FILE`). The remaining risk is whether
  *this* `gemma-4-E2B-it.litertlm` file actually bundles the audio encoder.
  If a spoken clip produces a generic "I can't hear you" / empty reply, the
  fallback is `flutter_gemma_speech` (STT stage), which the brief named.
  The audio *encoder* is loaded on CPU (plugin default). Pinning it to GPU
  made every `engine_create` fail, including the CPU text fallback,
  because the FFI retry only changes the text backend.
- **`openChat` rejects native audio** on `.litertlm`: concurrent
  `openSession` handles replay history as text only. We use `createChat`
  → `createSession`. LiteRT-LM's `FfiInferenceModel.createChat` still
  forwards `tools` (the base `InferenceModel.createChat` in flutter_gemma
  1.6.3 does not). Flagged in `gemma_brain.dart`.
- **Latency budget:** the M4/M5 two-phone path is confirmed (first
  audio out of the simulator speaker). ttf (end of speech → first
  token) is still the M3 number; M5 adds `ReplySpeaker: first audio
  Xms` (turn start → first BLE audio frame). The product budget is
  end-of-speech → first audio out of the bot speaker ≤ 2 s on E2B
  (3.5 s ceiling) — that is ttf + TTS synth of the first sentence +
  first BLE write. Log both every turn.
- **minSdk 30 / Flutter 3.44.9:** hard requirements of `libLiteRtLm` and
  `flutter_gemma` 1.0+. Android 10 phones and the old 3.41.7 pin cannot
  run M3.
