# Cute Bot — hardware guide

Shopping list and concepts for building a **physical desk bot** that pairs with
the Flutter companion app. The bot is dumb hardware — mic, speaker, face
(LEDs), and BLE. All intelligence runs on an **8GB+ Android phone**, fully
offline (Gemma 4).

Firmware for the ESP32 is not in this repo yet; the BLE contract lives in
`lib/shared/ble_protocol.dart` and is what firmware must implement.

---

## Minimal product (recommended starting point)

This is the scope we settled on for v1:

- **No body motion** — no servo, no `wiggle()` hardware
- **Natural listening** — VAD on the bot (not push-to-talk)
- **Face** — RGB LED “eyes”
- **Ears + mouth** — mic in, speaker out over BLE

### Buy list (bot only)

| Qty | Part | Role |
|-----|------|------|
| 1 | **ESP32-S3 dev board** (USB-C; external antenna optional) | MCU + BLE + Wi‑Fi on one chip |
| 1 | **USB data cable** | Flash firmware, bench power |
| 1 | **INMP441** or **ICS-43434** I2S MEMS mic breakout | Ears — 16 kHz mono before ADPCM |
| 1 | **MAX98357A** I2S amp breakout | Drives the speaker from phone TTS |
| 1 | **Small 8 Ω speaker** (~28–40 mm, 1–3 W) | Mouth |
| 2 | **WS2812B** RGB LEDs (or one NeoPixel pair) | Eyes — maps to `set_led(r,g,b,pattern)` |
| 1 | **3.7 V LiPo**, 1000–2000 mAh | Portable power |
| 1 | **LiPo charger + protection** (TP4056 or integrated module) | Safe charging |
| — | **Voltage divider** (e.g. 100 kΩ + 100 kΩ) | Battery % / mV for `get_battery()` |
| 1 | **Breadboard** + **Dupont jumpers** | First bring-up |

**Cheapest bench path:** skip LiPo initially — power the ESP32 from USB until
audio + BLE work. One WS2812B instead of two if you only need a single “mood”
LED.

### Not on the bot (still required)

| Item | Why |
|------|-----|
| **Android phone, 8GB+ RAM, API 30+** | BLE central, foreground service, ~2.6 GB Gemma model |
| **Wi‑Fi** | One-time model download on first run |

Until ESP32 firmware exists, you can test the **phone side** with a **second
Android phone** in **Bot Simulator** mode (no robot hardware).

### One-line cart

ESP32-S3 → INMP441 → MAX98357A + speaker → 2× WS2812B → LiPo + charger →
breadboard + wires → 8GB+ Android phone.

---

## What you do **not** need

| Item | Why |
|------|-----|
| Separate Bluetooth module | BLE is built into ESP32 |
| Servo (minimal v1) | No wiggle |
| Push-to-talk button | VAD replaces it |
| VAD chip or extra sensor | VAD is firmware on the ESP32 |
| Raspberry Pi / second phone on the bot | Bot has no brain |
| Display | `show_text` is simulator-only; real bot uses speaker (TTS is M5) |
| Opus hardware | Protocol uses **IMA ADPCM** on ESP32 |
| Passive buzzer | Built-in sounds use the same speaker |

---

## Block diagram (minimal)

```text
Phone (Companion)  ←—— BLE ——→  ESP32-S3
                                    ├─ I2S → INMP441  (+ VAD in firmware)
                                    ├─ I2S → MAX98357A → speaker
                                    ├─ GPIO → WS2812B eyes
                                    └─ ADC → battery sense
```

---

## Bluetooth on ESP32

**Yes — Bluetooth comes with the ESP32.** No nRF52, HC-05, or other add-on.

| Chip | Bluetooth | Wi‑Fi |
|------|-----------|-------|
| ESP32 (classic) | BLE 4.2 + Bluetooth Classic | Yes |
| ESP32-S3 | BLE 5.0 | Yes |

Cute Bot uses **BLE** for audio, control, and telemetry. A normal dev board
with an on-board PCB antenna is fine for a desk bot. For more range, pick a
board with an **external antenna**.

---

## Natural listening — what is VAD?

**VAD** = **Voice Activity Detection**.

Software on the bot (not the phone) that decides when someone is **actually
speaking** vs silence, room noise, fan hum, keyboard clicks, etc.

| State | Meaning |
|-------|---------|
| Speech | Someone is talking → start streaming mic over BLE |
| Non-speech | Quiet or background → don’t treat as an utterance |

When VAD sees speech start → send **start-of-utterance** on the first audio
frame. When speech stops for a short time (e.g. 300–800 ms silence) → send
**end-of-utterance**.

### VAD vs push-to-talk

Both use the **same BLE wire format**. Only the *source* of utterance
boundaries changes:

| Method | How boundaries are set |
|--------|------------------------|
| Push-to-talk | Hold a button; release = end |
| VAD | Bot detects start/stop automatically |

The companion app already reassembles utterances from start/end flags
(`UtteranceReassembler`). VAD is implemented in **ESP32 firmware** — no app
protocol change.

### Tradeoffs

- **Pros:** Hands-free; feels like a creature listening
- **Cons:** May cut off mid-sentence if you pause; may react to TV or other
  voices; always-on mic uses more battery than PTT; needs tuning (timeout,
  sensitivity)

### Half-duplex (echo)

The bot’s mic and speaker are close together. ESP32 has **no hardware acoustic
echo cancellation**. Firmware should **mute or ignore the mic while the bot is
speaking** (`BotState.speaking` exists in the protocol for this). The two-phone
simulator masks echo because Android phones do AEC in hardware — don’t assume
the real bot behaves the same.

---

## What is ESP-SR?

**ESP-SR** is **Espressif’s speech-recognition software library** for ESP32 —
free firmware, not hardware. Same ESP32 + same mic; nothing extra to buy.

| Feature | Use for Cute Bot |
|---------|------------------|
| VAD | Better start/stop detection than a simple loudness threshold |
| Wake word | Optional “hey bot” before listening |
| Noise suppression | Less background noise treated as speech |
| Command recognition | Fixed short phrases — **not** used for Gemma chat |

### Simple VAD vs ESP-SR

| | Simple energy VAD | ESP-SR |
|--|-------------------|--------|
| Cost | Free, small code | Free, larger binary, more RAM/CPU |
| Quality | OK on a quiet desk | Better in noisy rooms |
| Effort | Easy to write | More setup (models, Espressif APIs) |
| Extra parts | None | None |

**You don’t need ESP-SR for v1.** Gemma runs on the phone; ESP-SR only helps
detect *when* the user is talking (and optionally a wake word).

Suggested path:

1. **Prototype:** simple energy VAD (threshold + silence timeout).
2. **Later:** try ESP-SR if utterances cut off, TV triggers false starts, or
   you want a wake word.

---

## Protocol mapping (firmware must implement)

From `lib/shared/ble_protocol.dart`:

| Bot capability | Wire surface |
|----------------|--------------|
| Mic → phone | GATT notify `audioFromBot`, IMA ADPCM, 16 kHz, start/end flags |
| Phone → speaker | GATT write `audioToBot`, same audio format |
| LED eyes | Control `set_led(r, g, b, pattern)` — off, solid, blink, breathe |
| Chirps / beeps | Control `play_sound(name)` — chirp, beep, purr, alarm (samples in firmware) |
| Battery | Control `get_battery()` → telemetry % + millivolts |
| Wiggle | Control `wiggle()` — **ignore or no-op in minimal v1** |

Request MTU **517** on connect; audio frames need MTU ≥ 171. Advertised name:
`CuteBot`.

Pairing: moves to **bonded-only** before real hardware ships (CDM wake-on-
approach uses bonding on the phone side). See `PairingPolicy` in
`ble_protocol.dart`.

---

## Power and battery notes

- **VAD:** mic stays active; streaming while you talk — expect shorter runtime
  than push-to-talk. 1500–2000 mAh is reasonable for a desk bot.
- **Bench dev:** USB power from the dev board is enough until wireless power
  is stable.
- **LiPo:** use a module with **protection** (overcharge / over-discharge).
  Voltage divider into ESP32 ADC is enough for v1; a fuel gauge is optional.

---

## Tools (if you don’t have them)

| Tool | Notes |
|------|-------|
| Computer with USB | PlatformIO or Arduino-ESP32 / ESP-IDF |
| Multimeter | Battery voltage, wiring checks |
| Logic analyzer (optional) | I2S / timing debug |

---

## Full prototype (optional extras)

If you expand beyond minimal v1 later:

| Add-on | Maps to |
|--------|---------|
| SG90 micro servo | `wiggle()` |
| Tactile button | Push-to-talk (alternative to VAD) |
| Cardboard / 3D-printed shell | Mechanical layout, mic/speaker separation |
| Board with external BLE antenna | Longer range |

---

## Related docs

| Doc | Contents |
|-----|----------|
| `README.md` | App architecture, milestones, protocol summary |
| `lib/shared/ble_protocol.dart` | Full BLE contract for firmware port |
| `Docs/m0-testing-guide.md` | Simulator + nRF Connect human-bar test |
| `Docs/m1-testing-guide.md` | Two-phone bandwidth gate |
| `Docs/companion-setup.md` | Phone first-run setup |
