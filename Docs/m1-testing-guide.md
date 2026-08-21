# M1 Human-Bar Testing Guide — the Bandwidth Gate

> **Status:** M1 agent bar is complete and M2+ is in the tree. This guide
> is still the bandwidth-gate procedure (two phones, Companion +
> Simulator). Current product status: `README.md`.

## Purpose

M1 built the Companion app as the BLE central: scan, auto-connect, MTU
negotiation, chunk framing/reassembly, reconnect backoff, prioritized control
writes. The **agent bar** (framing + codec unit tests, including loss/reorder
cases) is complete — 50 tests pass.

This guide is the **human bar**, and it doubles as **the bandwidth gate**:
the decision point for whether BLE notifications can carry real-time duplex
audio at acceptable quality. If the gate fails, we stop and discuss the
Bluetooth Classic / A2DP fallback *before* starting M2 — that decision
reopens the audio plane of the protocol (codec, sample rate, chunk sizing),
which is exactly why the audio plane is not frozen yet.

nRF Connect is no longer needed: both roles are now in the app.

## Pass criteria (from the brief)

1. **Connection resilience** — two phones hold a connection across a walk
   out of the room and back.
2. **Byte-identical delivery** — a spoken utterance arrives at the companion
   intact enough to play back byte-identical (checksums match on both
   screens, 0 lost).
3. **Real-time rate** — audio sustains **≥ 1.0× real time** with transport
   latency under **~300 ms**. Byte-identical alone is not enough: a stream
   that arrives intact at 0.3× real time **fails** this milestone.

## Setup

- Phone #2 (the "bot"): open Cute Bot → **Bot Simulator**. Confirm
  *Radio: poweredOn* and *Advertising "CuteBot"*.
- Phone #1 (the brain): open Cute Bot → **Companion**. It scans, connects,
  and configures on its own — no manual pairing, no nRF Connect.

**Success signal:** the companion Link card shows **Connected** and
**MTU ≥ 171** (Android 14+ phones typically negotiate 517 automatically).
The simulator shows *Audio subscribers: 1* and the MTU it granted. If MTU
shows below 171, the companion can still *send* audio (its chunker shrinks
frames to fit) but the simulator's fixed 168-byte frames will not arrive —
report that MTU value.

## Test 1 — Utterance delivery + the rate number

1. On the simulator, **hold "Hold to talk"** and speak a sentence
   (aim for 5–10 seconds), then release.
2. If **Live** is on (default), you should hear it on the companion *as you
   speak* — the lag you perceive is the transport latency. It should feel
   like a walkie-talkie, well under half a second.
3. When you release, the companion's **Audio from bot** card shows the gate
   readout:
   - **N.NNx real time** — green at ≥ 1.0, red below. This is the number
     that passes or fails M1.
   - **kbps** — payload throughput (ADPCM needs ~66 kbps sustained).
   - **worst frame gap** — the largest stall between frames; a proxy for
     the jitter buffer the real product would need. Values beyond ~300 ms
     mean audible dropouts even if the average rate is fine.
   - **frames / lost / dup / stale · crc** — delivery quality.

### Byte-identical check

After each utterance, compare:

- Simulator Activity: `Utterance sent: N frames, crc XXXXXXXX`
- Companion Activity: `Utterance: N frames, 0 lost … crc XXXXXXXX`

Same frame count, 0 lost, same crc ⇒ byte-identical delivery. Tap
**Replay** to hear the reassembled audio again.

Run this at least three times: phones side by side, phones a few meters
apart, and phones in different rooms. Note the rate each time.

## Test 2 — Duplex: audio back to the bot

1. After receiving an utterance, tap **Echo to bot** on the companion.
2. The utterance plays from the simulator's speaker, and the simulator
   Activity logs `Utterance played: N frames, M lost`.
3. The companion logs `Echo sent: … (N.NNx RT)` — the phone→bot half of
   the duplex question. Report this number too. Note: echo uses
   write-without-response as fast as the stack allows; the simulator
   buffers, so playback quality matters more than the raw rate here.

## Test 3 — Control priority under audio load

1. Start a long hold-to-talk on the simulator and keep holding.
2. While audio is streaming, tap LED colors / **Wiggle** / **Beep** on the
   companion.
3. The LED box should react **immediately** (the control queue jumps ahead
   of audio) and the companion logs `set_led … · acked in N ms`. Report a
   typical ack time — this is also a decent proxy for link RTT, as is the
   `Battery … RTT` number from the **Battery** button.

## Test 4 — Connection resilience (walk test)

1. With both phones connected, take the companion phone for a walk out of
   the room / down the hall until the link drops.
   - Companion shows **Reconnecting (attempt N)** with growing backoff.
   - Simulator shows the disconnect in its Activity log.
2. Walk back. The companion should reconnect **on its own** — no taps —
   and land back at **Connected** with a fresh MTU. Hold-to-talk must work
   again immediately.
3. Also try: toggle Bluetooth off and on, on the companion phone. Same
   expectation: automatic recovery once the radio returns.

## What to report back

- Typical **× real time** rate and **worst frame gap** for Test 1, at the
  three distances.
- Whether checksums matched (and loss counts if not).
- The echo rate from Test 2.
- Control ack / battery RTT times from Test 3 under audio load.
- Whether reconnect recovered without intervention in Test 4.

**Gate decision:** if the rate holds ≥ 1.0× with tolerable gaps at
conversational distance, the audio plane (ADPCM, 16 kHz, 20 ms blocks)
freezes and M2 begins. If not, we stop and take up the Bluetooth Classic /
A2DP fallback question with these numbers in hand.

## Troubleshooting

- **Companion stuck on "Scanning for bot…"** — confirm the simulator is
  advertising; Android scan filters occasionally miss 128-bit service UUIDs
  in crowded RF, move the phones closer for initial discovery.
- **Connected but no audio arrives** — check the simulator granted
  MTU ≥ 171 (Link card). Below that, the simulator's fixed-size frames
  exceed the notification payload and are dropped (logged as notify
  failures in `adb logcat | grep CuteBot`).
- **Choppy live audio but a good final rate** — look at *worst frame gap*:
  Android BLE connection-interval renegotiation causes periodic stalls;
  a jitter buffer (M2+) absorbs these, but note the number.
- **Permission denied banner** — grant Nearby Devices (Android 12+) or
  Location (Android 10/11) permission and reopen Companion mode.
