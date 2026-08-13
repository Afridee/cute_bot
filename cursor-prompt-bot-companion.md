# Cursor Agent Brief — "Bot Companion" Flutter App

## What we're building

A Flutter app that pairs with a small physical desk robot (mic + speaker + BLE, eventually an
ESP32). The robot has no intelligence of its own — it's ears, a mouth, and a face. All thinking
happens on the phone, fully offline, using Gemma 4 (E2B or E4B) running on-device.

Interaction loop:

```
bot mic → BLE → phone → Gemma 4 (audio in, native) → text + optional tool calls
                                    ↓
                         TTS → BLE → bot speaker
                         tool calls → BLE → bot LEDs / servos
```

The bot should feel like a small living creature, not a voice assistant. Latency and personality
consistency matter more than benchmark intelligence.

## Current state of the repo

Fresh `flutter create` — nothing exists yet beyond the default counter app. You are building from
scratch, in the layout below. Create this structure in M0 and keep to it:

- `lib/shared/ble_protocol.dart` — service/characteristic UUIDs, message framing, and the **audio
  wire format** (sample rate, bit depth, codec). This is the contract. Both modes and, later, the
  ESP32 firmware implement it. The freeze happens in two stages: the **control plane** (UUIDs,
  message types, tool/control encoding) freezes after M0; the **audio plane** (codec, sample rate,
  chunk sizing) stays provisional until the M1 bandwidth gate passes, then freezes too. Once a
  part is frozen, changes to it require an explicit callout in your response.
- `lib/bot_simulator/` — peripheral (GATT server) mode. Turns a second Android phone into a
  stand-in for the ESP32 so we can build and test the real app before hardware exists.
- `lib/companion/` — central mode. The actual app.
- `README.md` — setup notes and known gaps, kept current as you go.

## Platform stance

**Android-first. Do not spend effort on iOS.** The design depends on a long-lived foreground
service holding a multi-GB model in memory and an always-live BLE connection. iOS kills background
compute and has no equivalent. If you write something that would need to differ on iOS, note it in
a comment and move on — don't build an abstraction for it yet.

Minimum target: Android 10 (API 29). Test device assumption: 8GB+ RAM Android phone.

---

## Milestones — build in this order, stop after each

Every milestone has two done bars. The **agent bar** is what you can verify yourself: it builds,
unit tests pass, in-process round-trips work. The **human bar** is the physical test I run on real
phones. "Stop after each milestone" means: hit the agent bar, report, and wait for me to confirm
the human bar before moving on. The human bar never blocks your report — it blocks the *next*
milestone.

### M0. Protocol contract + bot simulator
- Write `lib/shared/ble_protocol.dart` first: service/characteristic UUIDs, message types
  (audio chunk, control/tool command, battery, state), and framing constants. Keep it dependency-
  free plain Dart so the ESP32 port can crib from it later.
- The protocol must specify the **audio wire format**. Do the bandwidth math before picking it:
  raw 16 kHz / 16-bit mono PCM is 256 kbps, and realistic BLE notification throughput on Android
  is often 50–100 kbps even at MTU 517. Uncompressed PCM likely does not fit — default to ADPCM
  (4:1, trivially decodable on an ESP32) and treat Opus as an upgrade only if ESP32 CPU budget
  allows. Both encoder and decoder live in `lib/shared/` next to the protocol, dependency-free,
  so the firmware can port them.
- Decide **utterance endpointing** at the protocol level: how does the receiver know an utterance
  started and ended? v1 answer: push-to-talk (a hold-to-talk button on the simulator screen),
  with utterance boundaries carried by the frame header (sequence number + end-of-stream flag).
  VAD or a wake word can replace push-to-talk later without changing the wire format — but the
  boundary markers must exist in the protocol from day one.
- Decide **pairing/bonding** before the freeze: bonded-only vs open link. Anyone in BLE range can
  otherwise drive the servos and speaker. Open is acceptable for the simulator phase, but the
  decision affects the GATT contract, so record the chosen direction explicitly in
  `ble_protocol.dart` rather than leaving it implicit.
- Build `lib/bot_simulator/`: peripheral (GATT server) mode on a second Android phone —
  advertises the service, streams mic audio out, accepts audio in and plays it, accepts control
  writes and shows them on screen (LED color as a colored box is fine).
- Verify which Flutter package can do BLE *peripheral* mode on Android before writing code —
  `flutter_blue_plus` is central-only; peripheral likely needs `bluetooth_low_energy` or similar.
  This is a real risk; check it first and report what you picked.

**Done when (agent bar):** protocol encode/decode round-trips under unit test, including the audio
codec. **(Human bar):** the simulator advertises; a generic BLE scanner app (e.g. nRF Connect) can
connect, see the characteristics, and receive notifications; *and* writes to the audio-in and
control characteristics produce the expected playback / on-screen effect. Both directions — not
just advertise-and-notify.

### M1. BLE central: connect and stay connected
- Scan for the bot's service UUID, auto-connect, auto-reconnect on drop with backoff.
- Negotiate MTU immediately on connect (request 517, handle the OS giving you less).
- Implement chunk framing over the negotiated MTU — raw audio chunks exceed BLE packet size and
  playback is choppy without it. Frame header should carry a sequence number and an end-of-stream
  flag so the receiver can reassemble and detect loss.
- The framing/reassembly layer is pure Dart — **write unit tests for it** (ordering, loss,
  duplicates, end-of-stream, codec round-trip) before any two-phone test. This is the most
  bug-prone code in the milestone and the only part you can verify without hardware.
- Control writes (tool commands) share the connection with audio. Give them priority — a
  `set_led` must not sit behind a queue of audio chunks.
- Surface connection state in the UI as a plain debug panel. Pretty comes later.

**Done when (agent bar):** framing and codec unit tests pass, including loss/reorder cases.
**(Human bar):** two phones, one in simulator mode and one in companion mode, hold a connection
across a walk out of the room and back; a spoken utterance arrives at the companion intact enough
to play back byte-identical; *and* audio sustains ≥ 1× real time with transport latency under
~300 ms. Byte-identical alone is not enough — a stream that arrives intact at 0.3× real time
fails this milestone.

**This is the bandwidth gate.** If real-time duplex audio doesn't hold at acceptable quality after
the codec + framing work, stop and raise the Bluetooth Classic / A2DP fallback question before
starting M2 — that decision reopens the audio plane of the protocol, which is exactly why the
audio plane isn't frozen until this gate passes.

### M2. Foreground service
- `flutter_foreground_task` (or a hand-written Android foreground service via platform channel if
  the package fights you — say which you chose and why).
- The service owns the BLE connection *and* the model. Not the UI isolate. Killing the Activity
  must not kill the bot.
- **Isolate reality check:** the foreground service runs its own Dart isolate (separate engine),
  so the model must be loaded and owned *in that isolate*. This works because the litertlm engine
  is FFI-based; verify flutter_gemma initializes cleanly off the main isolate before building on
  it, and flag immediately if it doesn't — that changes the architecture. **The same check applies
  to the BLE package**: platform-channel plugins have background-engine quirks, so verify the
  chosen central package scans/connects/notifies from the service isolate before building on it,
  and flag immediately if it doesn't.
- Declare the correct `foregroundServiceType` in the manifest (`connectedDevice` for the BLE link;
  required on Android 14+, harmless on our API 29 floor). Don't use `specialUse` unless nothing
  else fits.
- **A foreground service is not immortal.** A process holding a multi-GB native allocation is the
  first thing the low-memory killer takes on an 8GB phone, and OEM battery managers kill foreground
  services on their own schedule. Treat kill → restart → re-warm as a *normal* lifecycle, not an
  error: persist the conversation *transcript* outside process memory — the KV cache cannot be
  checkpointed, so recovery means replaying the transcript into a fresh session, which costs a
  full prefill on top of the tens-of-seconds warm-up; budget for that in the recovery UX —
  auto-restart the service (START_STICKY or equivalent), and show warming state on the bot while
  the model reloads and re-prefills. Any other durable state (pending timers, see M4) gets the
  same persistence treatment.
- Survive **reboot**, not just process death: a `BOOT_COMPLETED` receiver that restarts the
  service. Mind Android 12+ restrictions on starting foreground services from the background —
  if the OS blocks the restart path, post a notification the user can tap rather than failing
  silently.
- Handle: doze mode, battery optimization exemption request, Bluetooth being toggled off and back
  on.
- Expose service state to the UI over a stream, not by polling.

**Done when (agent bar):** the service starts, owns a `FakeBrain` and the BLE layer in its own
isolate, streams state to the UI, and the transcript-persistence path round-trips under test.
**(Human bar):** app is swiped out of recents, bot still responds. App is force-killed
(`adb shell am kill`), service comes back on its own, and the bot recovers to responding without
the user opening the UI. Phone is rebooted, service comes back.

### M3. LLM layer — behind an interface, from the first line
Define this before writing any inference code:

```dart
abstract interface class BotBrain {
  Future<void> warmUp();
  Stream<BrainEvent> respond(AudioClip audio, ConversationContext ctx);
  Future<void> dispose();
}
```

`BrainEvent` is a sealed class: `TextDelta`, `ToolCall`, `Done`, `BrainError`.

**Latency budget — the number that defines "done" for the whole product:** end of user speech →
first audio out of the bot speaker ≤ 2 s warm on E2B; 3.5 s is the acceptability ceiling. Note
that the clip-based `respond(AudioClip, …)` design is fully sequential — record → prefill →
decode → TTS → transmit — so worst-case latency is the *sum* of those stages. Instrument each
stage separately from the first working build and report the breakdown at every milestone stop
from here on. If the budget is blown, say where, with numbers.

Then implement `GemmaBrain`. Constraints from the runtime that shape the design — respect these,
they are not negotiable:

- **One Conversation per Engine in LiteRT-LM.** Chat and tool-execution paths cannot hold sessions
  simultaneously. Build a single serialized conversation queue with explicit engine handoff.
  Do not attempt concurrent sessions.
- **Warm-up is slow** (tens of seconds on CPU-only devices). Model load happens once at service
  start, never per-request. Expose a `warming` state so the UI and the bot's LEDs can show it.
- Use Gemma 4's **native audio input** — do not add a separate speech-to-text stage.
- Use Gemma 4's **native function calling** with constrained decoding for structured tool output.
  Never regex-parse tool calls out of free text.

### Package + model facts (verified Aug 2026 — re-verify, don't trust blindly)

- Use **`flutter_gemma` 1.5.x** (current: 1.5.2). It's now split into a core package plus engine
  add-ons — you need `flutter_gemma` **and** `flutter_gemma_litertlm` for `.litertlm` models.
  Do not copy older single-package setup snippets.
- Load Gemma 4 with **`ModelType.gemma4`**, not `gemmaIt` — that's what routes its native
  `<|tool_call>` tokens through the LiteRT-LM chat-template path. `gemmaIt` is Gemma 3 and earlier.
- **Function calling is confirmed full-support for Gemma 4 E2B/E4B**: pass `tools` (JSON-schema
  style) and `supportsFunctionCalls: true` to `createChat`, handle `FunctionCallResponse` on the
  response stream, return results via `Message.toolResponse`. See fluttergemma.dev/docs/function-calling.
- Model file: `https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm/resolve/main/gemma-4-E4B-it.litertlm`
  (~4.3GB, ungated). E2B is ~2.4GB and worth trying first — this project values latency.
- If Gemma 4 audio input turns out not to be exposed, `flutter_gemma_speech` (STT/TTS/voice loop)
  exists as an official add-on fallback — prefer that over hand-rolling a platform channel.

### Field notes from a sibling project (same stack, verified in production code)

Another app of mine runs Gemma 4 E4B as a `.litertlm` bundle on flutter_gemma (an older 0.13.x,
so API names may have shifted — the *patterns* are what transfer). Text chat with streaming works
on this stack. Treat the following as known-good patterns, not guesses:

- **Session lifecycle is the #1 source of bugs.** `flutter_gemma`'s `createChat` replaces the
  active session *without closing the old one* — close it yourself first or memory grows.
  Conversely, close/recreate cycles per request can trip LiteRT on some devices. The stable
  pattern: one long-lived chat, reset between exchanges with `clearHistory()`, and an explicit
  async lock so any second consumer (in our case: the tool-execution path) is serialized rather
  than racing the chat.
- **Size the context window generously.** LiteRT does not degrade gracefully when `maxTokens` is
  too small for template + input — inference *fails* (invoke status 13). 2048 was a working floor
  for text; budget with ~4 chars/token and reserve headroom (several hundred tokens) for the chat
  template and the decode. Audio input will eat context too — verify before assuming 2048 is enough.
- **Warm-up:** `FlutterGemma.getActiveModel(maxTokens: …)` once, guarded so repeat calls are
  no-ops. Tens of seconds is normal for E4B; E2B is worth trying first since this project values
  latency over intelligence.
- **Streaming:** `generateChatResponseAsync()` yields token deltas — this is what `TextDelta`
  should wrap. Works reliably.
- **Decoding params:** ~0.8 temp / topK 40 / topP 0.95 is fine for chatty output; drop to ~0.35
  temp for turns where structure matters. Tool-call turns should run at the low setting.
- **The model does not follow formatting instructions reliably.** Even with explicit rules in the
  system prompt, E4B emits mangled markup (duplicated markers, invented syntax) often enough that
  the sibling project needed post-hoc cleanup. This is why the constrained-decoding rule above
  exists — prompt-and-parse for tool calls *will* produce garbage on this model class.
- **Gated model files** need `FlutterGemma.initialize(huggingFaceToken: …)`; pass the token via
  `--dart-define=HUGGINGFACE_TOKEN=…`. The Gemma 4 `.litertlm` above is ungated.

Start with a `FakeBrain` that returns canned responses after a realistic delay, so M1/M2 can be
tested without the model. Ship both.

### M4. Tools = the bot's body
Register these tools with the model. Each maps to a BLE write:

| Tool | Effect |
|---|---|
| `set_led(color, pattern)` | eye/LED expression |
| `wiggle()` | servo motion |
| `play_sound(name)` | chirp/beep from a small on-device set |
| `set_timer(minutes, label)` | phone-side timer, bot announces |
| `get_battery()` | reads bot battery, returns to model |

Tool dispatch lives behind a `BotActuator` interface so the simulator can implement it as on-screen
animation while real hardware implements it as BLE writes.

Two rules for `set_timer`: the firing announcement enters the same serialized conversation queue
as everything else — never a second concurrent session racing the chat — and pending timers
persist outside process memory (M2's persistence path) so a service kill/restart doesn't silently
drop them.

### M5. TTS and persona
- `flutter_tts` first; keep the TTS call behind a `Voice` interface so a neural TTS can replace it.
- **The TTS output path is not the phone speaker.** By default `flutter_tts` plays locally; to
  reach the bot you need PCM you can chunk over BLE, which on Android means `synthesizeToFile` —
  and that means a full utterance is synthesized before the first byte can ship. Cut the stall by
  synthesizing sentence-by-sentence as `TextDelta`s accumulate, and resample/encode the output to
  the audio wire format in `ble_protocol.dart` before transmit. This path is part of the M3
  latency budget — measure it.
- Persona lives in one file, `lib/companion/persona.dart`, as a system prompt plus a handful of
  few-shot exchanges. Not scattered through the code.
- Responses should be short. Cap generation length; a desk robot that monologues is not cute.

---

## Rules for you, the agent

1. **Verify APIs before using them.** `flutter_gemma`, LiteRT-LM, `flutter_blue_plus`, and
   `flutter_foreground_task` have all changed recently and your training data is likely stale.
   Look up current docs and current package versions. If you cannot verify a method signature,
   say so rather than inventing one.
2. **Dependencies.** Packages this brief already names (`flutter_gemma` + engine add-ons,
   `flutter_foreground_task`, `flutter_tts`, one BLE central package, one BLE peripheral package)
   are propose-and-proceed: state the package, the version, and why, then continue. Anything
   *not* named here requires asking first — state what it replaces and wait.
3. **Do not touch `ble_protocol.dart` silently.** It's a contract with future firmware.
4. **Prefer boring code.** No code generation, no build_runner, minimal state management
   (`ChangeNotifier` or Riverpod — pick one, say which, stick to it).
5. **Stop at each milestone.** Report what works, what you couldn't verify, and what you'd do next.
   Do not run ahead into M4 while M2 is unproven.
6. **Write the failure paths.** BLE drops, Bluetooth off, permission denied, model OOM, service
   killed. On a device that's meant to run all day, the failure paths *are* the product.
7. **Log through one channel** with levels, so the foreground service is debuggable via `logcat`
   without a debugger attached.
8. When something is genuinely ambiguous, ask rather than guessing. One good question beats a
   thousand lines in the wrong direction.

## Known unknowns — flag these if you hit them

- Gemma 4 text chat + streaming and native function calling are **confirmed supported** in
  flutter_gemma 1.5.x (see M3 facts). The remaining unverified piece is **native audio input** —
  whether flutter_gemma exposes Gemma 4's audio modality, or whether we fall back to
  `flutter_gemma_speech` (STT stage) or LiteRT-LM via platform channel. Check before building M3.
- Which package provides BLE **peripheral** mode for the simulator (M0) — `flutter_blue_plus` is
  central-only. Resolve before writing simulator code.
- Whether BLE has the bandwidth for acceptable-quality duplex audio *even after codec
  compression*, or whether we need to fall back to Bluetooth Classic / A2DP for the audio path
  while keeping BLE for control. This is now an explicit gate at the end of M1 — don't paper over
  it with more buffering.
- **Echo.** The bot's mic and speaker are inches apart and an ESP32 has no acoustic echo
  cancellation, so the model will hear its own TTS. The two-phone simulator *masks* this, because
  Android phones do AEC in hardware — do not treat simulator behavior as evidence the problem
  doesn't exist. Half-duplex (mute the bot mic while the bot speaks) is the acceptable v1 answer,
  but make it a deliberate, protocol-visible state, not an accident of buffering.
- Battery cost of an always-warm model — and of the bot streaming mic audio continuously, if
  endpointing ever moves from push-to-talk to always-listening VAD. Measure before optimizing.
