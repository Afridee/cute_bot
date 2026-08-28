# Cute Bot — hardware guide

Shopping list and concepts for building a **physical desk bot** that pairs with
the Flutter companion app. The bot is dumb hardware — mic, speaker, **OLED
face**, and BLE. All intelligence runs on an **8GB+ Android phone**, fully
offline (Gemma 4).

Firmware for the ESP32 is not in this repo yet; the BLE contract lives in
`lib/shared/ble_protocol.dart` and is what firmware must implement. The
**Bot Simulator** visor (`lib/bot_simulator/visor/`) is the reference for how
the OLED face should look and move — port that eye engine to firmware, driven
by the same `set_led` signatures the phone already sends.

---

## Minimal product (recommended starting point)

This is the scope we settled on for v1:

- **No body motion** — no servo, no `wiggle()` hardware
- **Natural listening** — VAD on the bot (not push-to-talk)
- **Face** — **0.96″ 128×64 SSD1306** I2C OLED (animated eyes on a black visor)
- **Ears + mouth** — mic in, speaker out over BLE

### Buy list (bot only)

| Qty | Part | Role |
|-----|------|------|
| 1 | **ESP32-S3 dev board** (USB-C; external antenna optional) | MCU + BLE + Wi‑Fi on one chip |
| 1 | **USB data cable** | Flash firmware, bench power |
| 1 | **INMP441** or **ICS-43434** I2S MEMS mic breakout | Ears — 16 kHz mono before ADPCM |
| 1 | **MAX98357A** I2S amp breakout | Drives the speaker from phone TTS |
| 1 | **Small 8 Ω speaker** (~28–40 mm, 1–3 W) | Mouth |
| 1 | **0.96″ 128×64 SSD1306 OLED, 4-pin I2C** (white; blue OK) | Face — animated visor eyes |
| 1 | **3.7 V LiPo**, 1000–2000 mAh | Portable power |
| 1 | **LiPo charger + protection** (TP4056 or integrated module) | Safe charging |
| — | **Voltage divider** (e.g. 100 kΩ + 100 kΩ) | Battery % / mV for `get_battery()` |
| 1 | **Breadboard** + **Dupont jumpers** | First bring-up |

**Cheapest bench path:** skip LiPo initially — power the ESP32 from USB until
audio + BLE work.

### Face display — buy this

**v1 SKU:** **0.96″ 128×64 SSD1306, 4-pin I2C** (GND / VCC / SCL / SDA).
This is the cost-effective part: commodity module, ~$1–5, every ESP32 OLED
example talks to it, 128 columns map 1:1 (no SH1106 offset), and 128×64 is
the same **2:1** as `BotVisor` (`aspectRatio: 2.0`).

Search: `0.96 OLED SSD1306 I2C 128x64 4 pin`. Prefer **white** pixels (closest
to the visor line-art). **Blue** is usually a bit cheaper and is fine. I2C
address is almost always **0x3C** (some boards are 0x3D — check the listing
or a solder jumper). 3.3 V-tolerant (ESP32-S3 is 3.3 V); modules with a
regulator that accept 3.3–5 V are OK. Wire **SDA/SCL** to the board’s
default I2C pins (many S3 boards use GPIO 8/9).

| Skip | Why |
|------|-----|
| 0.91″ **128×32** | Half the height; you would crop or squash the visor |
| **7-pin SPI** SSD1306 | Works, costs the same or more, burns extra pins; I2C is enough |
| **1.3″ SH1106** | Same 128×64, larger pixels, usually **more** money, 132-column RAM (2 px offset). Nice upgrade later, not the cheap path |
| Yellow/blue **split** 0.96″ | Two-tone panel; visor needs one black field |
| Color OLED (SSD1331 / SSD1351) / TFT / touch | 3–10× the price; visor is 1-bit line-art |

**Optional later:** 1.3″ 128×64 **SH1106** I2C if you want a bigger desk face.
Use a SH1106 driver (u8g2 / Adafruit SH110X), not the SSD1306 one.

### Not on the bot (still required)

| Item | Why |
|------|-----|
| **Android phone, 8GB+ RAM, API 30+** | BLE central, foreground service, ~2.6 GB Gemma model |
| **Wi‑Fi** | One-time model download on first run |

Until ESP32 firmware exists, you can test the **phone side** with a **second
Android phone** in **Bot Simulator** mode (no robot hardware).

### One-line cart

ESP32-S3 → INMP441 → MAX98357A + speaker → 0.96″ 128×64 SSD1306 I2C OLED → LiPo +
charger → breadboard + wires → 8GB+ Android phone.

---

## What you do **not** need

| Item | Why |
|------|-----|
| Separate Bluetooth module | BLE is built into ESP32 |
| Servo (minimal v1) | No wiggle |
| Push-to-talk button | VAD replaces it |
| VAD chip or extra sensor | VAD is firmware on the ESP32 |
| Raspberry Pi / second phone on the bot | Bot has no brain |
| WS2812B / NeoPixel “eyes” | Face is the OLED; mood comes from `set_led` on the wire, not separate RGB LEDs |
| Opus hardware | Protocol uses **IMA ADPCM** on ESP32 |
| Passive buzzer | Built-in sounds use the same speaker |
| Color OLED / TFT / touch | Visor is 1-bit line-art; 0.96″ SSD1306 I2C is the cheap face |

---

## Block diagram (minimal)

```text
Phone (Companion)  ←—— BLE ——→  ESP32-S3
                                    ├─ I2S → INMP441  (+ VAD in firmware)
                                    ├─ I2S → MAX98357A → speaker
                                    ├─ I2C → 0.96″ 128×64 SSD1306 (visor face)
                                    └─ ADC → battery sense
```

---

## OLED face (firmware design)

The physical bot does **not** receive drawn frames over BLE. The phone sends
compact actuator commands; firmware renders the face locally.

### Wire → mood → pixels

1. **`set_led(r, g, b, pattern)`** — the companion’s expression catalog
   (`lib/companion/expressions.dart`) expands each mood into a color + pattern
   (+ optional sound / wiggle). Firmware should **reverse-map** the last LED
   command to a visor mood, using the same signatures as
   `lib/bot_simulator/visor/mood_from_led.dart` (e.g. pink+breathe → love,
   purple+breathe → thinking, LED off → neutral).
2. **Eye engine** — port the parametric poses and idle loops from
   `face_pose.dart` + `bot_visor.dart` (morph ~350 ms, mood-specific idle,
   periodic blink). The simulator’s Flutter painter is the art reference;
   firmware draws equivalent arcs/hearts/sparkles into the OLED framebuffer.
3. **`show_text(utf8, isFinal)`** — optional **timer countdown only** on the
   OLED: `HH:MM:SS` below the eyes in the visor neon color. Thinking / tool
   lines stay on the phone. ACK and ignore if you skip the row in v1, but do
   not ATT-error.

### Lifecycle the companion already sends

These flow today from `BotService` and should look alive on hardware:

| Phase | BLE | OLED |
|-------|-----|------|
| Warming | blue breathe (`sleepy`) | Half-lidded sleepy face |
| Thinking | purple breathe | Orbiting-pupil “thinking” animation |
| Reply | mood from `express(...)` | Matching mood (hearts, arcs, …) |
| Timer pending | `show_text` `HH:MM:SS` (~1 Hz) | Neon countdown below the eyes |
| ~8 s idle | LED off | Neutral resting face (gentle drift + blink) |
| ~60 s idle | blue breathe | Dozing sleepy face |

Sounds (`play_sound`) still come from the **speaker**, not the OLED.
While a timer is pending, the phone streams remaining `HH:MM:SS` on
`show_text`. Firmware only renders the countdown — it does not run its own
clock (`set_timer` / `cancel_timer` / `pause_timer` / `resume_timer` stay
on the phone). Pause stops the 1 Hz writes so the last remaining time
freezes on the face; cancel clears the line.

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

From `lib/shared/ble_protocol.dart`. The companion does **not** treat the
simulator as a special peer — the same writes, notifies, and probes hit a
real ESP32. Firmware that only implements “advertise and look connectable”
will drop the link.

| Companion feature | Wire surface | Firmware |
|-------------------|--------------|----------|
| Scan / CDM link | Advertise name `CuteBot` **and** service UUID `cb070001-…` in the **primary** advertisement | Required. Flags + name + 128-bit UUID = 30 of 31 ADV bytes. Scan-response-only UUID is not enough for CDM. |
| Mic → phone | Notify `audioFromBot`, IMA ADPCM, 16 kHz, start/end flags | Required. VAD (or a button) sets the same flags the simulator’s hold-to-talk sets. Do not notify a frame larger than MTU−3. Wait until MTU ≥ 171 (or shrink the block). |
| Phone → speaker (TTS) | Write-without-response `audioToBot`, same audio format | Required. Decode each self-contained ADPCM block. On **start-of-utterance**, set `BotState.speaking` and **mute the mic** (no AEC on ESP32). On end, unmute. |
| Face mood | Control `set_led(r, g, b, pattern)` — off, solid, blink, breathe | Required. Firmware maps each signature to a visor mood and runs the OLED eye engine. Also used for warming / thinking / phone alerts / expression decay. |
| Captions | Control `show_text` | Recommended. Render **timer countdown only** (`HH:MM:SS`) below the eyes in the visor neon color. **ACK and ignore** if skipped in v1. Do not ATT-error — that reconnects the phone. |
| Chirps / beeps | Control `play_sound(name)` — chirp, beep, purr, alarm | Required (samples in firmware). Companion chirps on reply start and phone alerts. |
| Battery | Control `get_battery()` → telemetry notify `%` + mV | Required, and **fast** (≤ 1 s). Companion probes this whenever inbound has gone quiet; a missed notify looks like a dead CCCD and forces reconnect. |
| Wiggle | Control `wiggle()` | Optional. **ACK and no-op** if there is no servo. Do not ATT-error. |
| Unknown command id | Any other control id | **ACK and ignore.** Same rule as optional actuators. |

Request MTU **517** on connect; audio frames need MTU ≥ 171. Characteristics:

| UUID | Properties |
|------|------------|
| `cb070002` audio-from-bot | Notify (+ CCCD 0x2902) |
| `cb070003` audio-to-bot | Write without response |
| `cb070004` control | Write (with response) |
| `cb070005` telemetry | Read + notify (+ CCCD) |

GATT permissions stay **open** for now (`PairingPolicy.open`). Bonding is a
CDM implementation detail on the phone, not encrypted characteristics.

Malformed frames: drop them. Never crash. Prefer ACK over an ATT error on
a write that landed on the right characteristic.

### What the companion will do on a live ESP32 (same as simulator)

These already flow over BLE today; they must work on hardware:

1. Auto-connect by service UUID, MTU 517, subscribe audio + telemetry.
2. Spoken utterances → Gemma → TTS ADPCM on `audioToBot`.
3. `set_led` / `play_sound` for brain state, tools, and phone alerts.
4. `show_text` for timer `HH:MM:SS` below the eyes while a countdown is pending.
5. `get_battery` for the model **and** as a notify-liveness probe.
6. `set_timer` / `cancel_timer` / `pause_timer` / `resume_timer` live on
   the phone (no firmware). Pause freezes the last `show_text` countdown;
   cancel clears it.
7. CDM “Link bot to Android” for wake-on-approach.

Push-to-talk is **simulator UI only**. The desk bot listens with VAD; the
phone already reassembles on start/end flags.

Pairing: moves to **bonded-only** before real hardware ships (CDM wake-on-
approach uses bonding on the phone side). See `PairingPolicy` in
`ble_protocol.dart`.

---

## Power and battery notes

- **VAD + OLED:** mic stays active; the display refreshes for animation —
  expect shorter runtime than push-to-talk. 1500–2000 mAh is reasonable for
  a desk bot. Dim or pause heavy idle animation when on battery if needed.
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
| WS2812B strip | Accent glow under the visor bezel (not the primary face) |
| Cardboard / 3D-printed shell | Mechanical layout, mic/speaker separation, OLED window |
| Board with external BLE antenna | Longer range |

---

## Related docs

| Doc | Contents |
|-----|----------|
| `README.md` | App architecture, milestones, protocol summary |
| `lib/shared/ble_protocol.dart` | Full BLE contract for firmware port |
| `lib/bot_simulator/visor/` | Reference visor art + animation (port to OLED) |
| `Docs/m0-testing-guide.md` | Simulator + nRF Connect human-bar test |
| `Docs/m1-testing-guide.md` | Two-phone bandwidth gate |
| `Docs/m2.5-testing-guide.md` | Keep-alive / CDM / phone-alerts human bar (passed) |
| `Docs/m4-testing-guide.md` | Two-phone TTS / timer / battery human bar (passed) |
| `Docs/companion-setup.md` | Phone first-run setup |
