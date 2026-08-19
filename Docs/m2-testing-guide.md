# M2 human-bar testing guide — the service must not die (and when it does, it must come back)

M2's claim: the bot lives in a foreground service, not in the app UI. The
human bar from the brief:

1. App swiped out of recents → **bot still responds**.
2. App force-killed (`adb shell am kill`) → service comes back on its own and
   the bot recovers to responding **without opening the UI**.
3. Phone rebooted → service comes back.

## Setup

- Phone #2: `flutter run` → **Bot Simulator** (as in M1).
- Phone #1: **Companion**. First launch walks permissions in this order:
  notifications (Android 13+), Bluetooth, then the battery-optimization
  exemption dialog — **accept it**; a restricted app fails this whole
  milestone by OEM design, not by bug.
- Wait for: Link "Connected", Brain "Warming up…" → "Ready". During warm-up
  the simulator's LED box breathes blue — that's the recovery/warming state
  you'll be looking for later.
- Baseline check: hold-to-talk on the simulator, speak ~2 s, release. Within
  a couple of seconds the LED blinks pink or flashes green + chirp (FakeBrain
  responding) and the transcript in the companion UI gains a `(voice, X s)`
  line and a bot line.

Debugging without a debugger: `adb logcat | grep CuteBot` on phone #1. The
service heartbeats a snapshot every 5 s; brain and link transitions are all
logged.

## Test 1 — swipe from recents

1. Note the transcript contents.
2. Swipe the companion app out of recents. The notification ("Cute Bot —
   bot connected · brain ready") must stay.
3. Speak into the simulator. **Pass:** the bot reacts (LED + chirp) with the
   UI dead. The FakeBrain's spoken-duration reply also proves audio actually
   crossed: check the transcript after reopening.
4. Reopen the app → Companion. It must *attach* (no permission dialogs, no
   service restart): transcript intact, "Replayed N entries" unchanged.

## Test 2 — force kill

```
adb shell am kill com.cutebot.cute_bot        # polite kill (background only)
# if the polite kill is a no-op because the service holds foreground state:
adb shell am force-stop com.cutebot.cute_bot  # the sledgehammer — see note
```

1. `am kill` while the screen shows the app is *not* in the foreground.
   START_STICKY + `allowAutoRestart` should bring the service back within
   seconds — watch `logcat` for `service starting (starter: system)`.
2. On restart the bot shows **breathing blue** (warming) while the brain
   re-warms and the transcript is reloaded from storage ("Replayed N" in the
   UI should now equal the line count from before the kill).
3. Speak. **Pass:** response happens with the UI never opened after the kill.

Note: `force-stop` also disables the app's alarms/receivers until the next
manual launch — Android treats it as "the user said stop". A service that
does **not** come back after `force-stop` is expected OS behavior, not an M2
failure. `am kill` (or letting the low-memory killer do it naturally —
open a dozen heavy apps) is the honest test.

## Test 3 — reboot

1. With the service running, reboot phone #1. Do not open the app.
2. After boot settles (give OEMs a minute), check for the Cute Bot
   notification, or `adb shell dumpsys activity services | grep cutebot`.
3. Speak into the simulator once it reconnects. **Pass:** bot responds.
4. **If the service did not start:** note the device/OEM. Android 12+
   background-start restrictions or an OEM battery manager blocked the
   BOOT_COMPLETED path. That's the known gap in the README — the tappable-
   notification fallback gets built if any test device hits this.

## Test 4 — the rest of the failure matrix (quick passes)

- **Bluetooth off/on:** toggle BT on phone #1. Link card → "Bluetooth is
  off", then reconnects on its own when BT returns. No app interaction.
- **Doze:** screen off, phone still, 10+ minutes (or
  `adb shell dumpsys deviceidle force-idle`). Speak. The BLE connection is
  doze-exempt while the FGS runs; response should still happen.
- **Transcript clear + kill:** Clear transcript in the UI, `am kill`,
  reopen — "Replayed 0 entries". Persistence works in both directions.
- **One-phone variant:** everything above minus the simulator, using the
  **Fake utterance** button before the kill and checking "Replayed N" after.
  Useful when only one phone is handy; it exercises brain + transcript but
  not the BLE path.

## What the agent bar already covered (no need to re-test)

77 unit tests: protocol + codec + transport (M0/M1), and new in M2 —
transcript persistence round-trip through a fresh store (the kill survival
path), FakeBrain contract (warm-up gating, streamed deltas, terminal events,
tool calls), BrainSession serialization (turns never run concurrently) and
recovery bookkeeping, and the UI↔service IPC codec including malformed-input
tolerance.
