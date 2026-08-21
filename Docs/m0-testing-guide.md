# M0 Human-Bar Testing Guide

> **Status:** M0 is complete. This guide is the original human bar (nRF
> Connect against the simulator). The Companion app exists as of M1 and
> **does** scan/connect — ignore the "placeholder" row below if you are
> not specifically re-running M0. Current product status: `README.md`.

## Purpose

M0 is the first milestone in the Cute Bot project: define the BLE protocol contract
and prove it works on real hardware. The **agent bar** (unit tests, in-process
round-trips) is already complete — this guide is for the **human bar**, the physical
test that confirms the simulator behaves correctly when a real BLE central connects.

The human bar exists because BLE behavior on Android phones cannot be fully
simulated in CI. Advertising, MTU negotiation, notification throughput, and
characteristic read/write semantics must be exercised on two physical devices
before M1 (the Companion app as BLE central) begins.

The Companion app is **not** used for M0 — it is a placeholder until M1. Instead,
**nRF Connect** acts as a generic BLE client to validate the GATT contract
independently of app-specific code.

## Objective

Confirm that the **Bot Simulator** (peripheral / GATT server) correctly implements
the protocol defined in `lib/shared/ble_protocol.dart` end-to-end:

1. **Discover and connect** — the simulator advertises as "CuteBot" and accepts an
   open-link GATT session (no bonding required).
2. **Audio out (bot → phone)** — mic audio streams over `cb070002` notifications
   while hold-to-talk is active, with correct utterance start/end framing.
3. **Control in (phone → bot)** — writes to `cb070004` drive LED color, wiggle,
   beep, and battery queries.
4. **Telemetry out (bot → phone)** — battery and status responses arrive on
   `cb070005` notifications.
5. **Audio in (phone → bot)** — writes to `cb070003` play back on the simulator
   speaker.

Passing all six test cases below unblocks M1: building the Companion app as the
BLE central and running the bandwidth gate (sustained duplex audio at real-time
with acceptable latency).

## What you are testing

| Plane | Direction | Characteristic | Purpose |
|-------|-----------|----------------|---------|
| Audio | Bot → phone | `cb070002` (notify) | Mic stream while hold-to-talk is active |
| Audio | Phone → bot | `cb070003` (write w/o response) | Speaker playback |
| Control | Phone → bot | `cb070004` (write) | LED, wiggle, beep, get_battery |
| Telemetry | Bot → phone | `cb070005` (notify + read) | Battery and status responses |

Full UUIDs live in `lib/shared/ble_protocol.dart`.

## Prerequisites

- **Two physical Android phones** (minSdk 29 / Android 10). BLE does not work on
  emulators.
- **[nRF Connect](https://play.google.com/store/apps/details?id=no.nordicsemi.android.mcp)**
  installed on phone #1 (the test client).
- Cute Bot APK or `flutter run` on phone #2 (the bot simulator).

### What NOT to use

| Wrong approach | Why it fails |
|----------------|--------------|
| Android Settings → Bluetooth → Pair | Classic pairing ≠ BLE GATT session. No characteristics are subscribed and no protocol frames are exchanged. |
| Cute Bot → **Companion** mode | Placeholder until M1. It does not scan or connect. |
| System pairing dialogs | M0 uses an **open link** (no bonding required). Pairing is optional and does not replace nRF Connect. |

## Setup

### Phone #2 — Bot Simulator

1. Open Cute Bot → **Bot Simulator**.
2. Confirm the Link card shows:
   - **Radio: poweredOn** (green)
   - **Advertising "CuteBot"** (green)
3. Leave this screen open for the whole test.

### Phone #1 — nRF Connect

1. Open nRF Connect → **SCAN**.
2. Tap **CONNECT** on **CuteBot** / **CUTEBOT**.
3. Open the **CLIENT** tab (you should see `CONNECTED · NOT BONDED`).

## nRF Connect walkthrough

### Step 1 — Request MTU

Audio frames are **168 bytes**. At the default MTU of 23 they are silently dropped.

1. Tap **⋮** (top right).
2. Tap **Request MTU**.
3. Enter **517** → OK.

After a central connects, the simulator Link card may show the negotiated MTU.

### Step 2 — Enable notifications

Expand service `cb070001-4bd9-4f22-9e15-8c2a51d1f27e`.

For each NOTIFY characteristic, tap the **three-down-arrows** icon on the right
(the notification subscribe button). Do **not** use the single **↓** on descriptors —
that only reads a value.

| Characteristic | UUID suffix | Action |
|----------------|-------------|--------|
| Audio from bot | `…0002` | Enable notifications |
| Telemetry | `…0005` | Enable notifications |

**Success signal:** On the simulator, **Audio subscribers** changes from `0` to `1`,
and the bottom button changes from *"Waiting for an audio subscriber…"* to
**Hold to talk**.

### Step 3 — Write commands

Tap the **↑** (upload) icon on the characteristic you want to write to.

In the **Write value** dialog:

1. Stay on the **NEW** tab.
2. Set type to **BYTE ARRAY**.
3. Enter the hex bytes in **New value** (spaces are fine).
4. Tap **SEND**.

Example LED command in the field:

```text
02 00 00 00 01 FF 00 80 01
```

If spaced input is rejected, try without spaces: `0200000001FF008001`.

> **Tip:** Tap **SAVE** and name a command (e.g. `set_led_purple`) to reuse it
> from the **LOAD** tab.

## Test cases

Run these in order. Each test lists the characteristic, hex payload, and what to
look for on the simulator.

### 1. Mic → phone (audio notify)

| | |
|---|---|
| **Characteristic** | `cb070002` (notifications must be enabled) |
| **Action** | On the simulator, **hold** **Hold to talk** |
| **Expected — nRF Connect** | Continuous hex notifications on `…0002` while held |
| **Expected — simulator** | **Mic out** frame count increases; Activity may log streaming |
| **Release** | Notifications stop; last frame header flag byte is `0x02` (end of utterance) |

### 2. LED color

| | |
|---|---|
| **Characteristic** | `cb070004` |
| **Payload** | `02 00 00 00 01 FF 00 80 01` |
| **Expected** | LED box turns purple; Activity: `set_led rgb(255,0,128) solid` |

### 3. Wiggle

| | |
|---|---|
| **Characteristic** | `cb070004` |
| **Payload** | `02 00 01 00 02` |
| **Expected** | LED box rotates briefly; Activity: `wiggle` |

### 4. Beep

| | |
|---|---|
| **Characteristic** | `cb070004` |
| **Payload** | `02 00 02 00 03 01` |
| **Expected** | Simulator plays a beep; Activity: `play_sound beep` |

### 5. Battery telemetry

| | |
|---|---|
| **Characteristic** | Write `cb070004`, read response on `cb070005` |
| **Payload** | `02 00 03 00 04` |
| **Expected** | Notification on `…0005`; Activity: `get_battery -> 87%` (simulated value) |

### 6. Phone → speaker (audio write)

| | |
|---|---|
| **Characteristic** | `cb070003` (not `…0004`) |
| **Payload** | `01 03 00 00 00 00 00 00 41 44` |
| **Expected** | Short click from simulator speaker; Activity: `Utterance played: 1 frames, 0 lost`; **Speaker in** count increments |

## Pass criteria

M0 passes when **all six** test cases succeed:

- [ ] Mic streams over `cb070002` while hold-to-talk is active
- [ ] LED changes color via control write
- [ ] Wiggle animates the LED box
- [ ] Beep plays
- [ ] Battery telemetry returns on `cb070005`
- [ ] Audio write to `cb070003` plays on the simulator speaker

A successful run looks similar to this Activity log on the simulator:

```text
Advertising as CuteBot
<device-id> connected
set_led rgb(255,0,128) solid
wiggle
play_sound beep
get_battery -> 87%
Utterance played: 1 frames, 0 lost
```

## Troubleshooting

### "Nothing happens" after connecting

You are likely using system Bluetooth pairing instead of nRF Connect GATT. Open
nRF Connect, connect to CuteBot, enable notifications on `…0002`, then retry.

### Talk button says "Waiting for an audio subscriber…"

Notifications are not enabled on `cb070002`. Tap the **three-arrows** icon on that
characteristic in nRF Connect.

### No audio hex stream while holding talk

- Confirm **Audio subscribers: 1** on the simulator.
- Confirm MTU was requested (517). Without MTU ≥ 171, audio frames are dropped
  silently.

### `Malformed frame dropped (frame too short: 0 < 4)`

An empty write was sent (SEND tapped with no bytes). Harmless — enter the hex
payload before sending.

### Pairing dialogs on both phones

Optional for M0. You can tap **Pair** on both sides, but the real work happens
inside nRF Connect after GATT connects. Bonding is not required for the open-link
simulator phase.

## Debugging

View app logs from a connected dev machine:

```bash
adb logcat | grep CuteBot
```

## Reference — GATT map

| UUID | Short name | Properties | M0 role |
|------|------------|------------|---------|
| `cb070001-…` | Service | — | Cute Bot service |
| `cb070002-…` | audioFromBot | NOTIFY | Mic stream out |
| `cb070003-…` | audioToBot | WRITE, WRITE NO RESPONSE | Speaker in |
| `cb070004-…` | control | WRITE | Commands (LED, wiggle, beep, battery) |
| `cb070005-…` | telemetry | NOTIFY, READ | Status responses |

## After M0

Once all tests pass, M0 is complete. M1 builds the **Companion** app as the BLE
central so nRF Connect is no longer needed, and runs the **bandwidth gate** test
(sustained ADPCM audio at real-time with acceptable latency).
