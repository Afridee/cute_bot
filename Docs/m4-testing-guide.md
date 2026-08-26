# M4 / M5 human-bar test — tools, timers, TTS

Agent bar: unit tests pass for timer persistence, battery tool results,
sentence splitting, WAV parse/resample, and BLE utterance framing.
This page is the **two-phone** check.

You need the same setup as M3: companion (8GB+, Gemma warm) and
simulator. FakeBrain (`--dart-define=CUTEBOT_FAKE_BRAIN=true`) still
exercises TTS over BLE (a beep scaled to the canned reply) and
`set_timer` / `get_battery` via FakeBrain's tool-call path — useful
when you do not want to wait on the model.

## TTS (the mouth)

1. Hold-to-talk on the simulator, say a short sentence, release.
2. Companion streams a caption (still there as a subtitle).
3. Simulator **speaker** plays the reply (not the companion phone
   speaker). Simulator state goes **speaking** for the BLE utterance
   then back to idle.
4. Logcat on the companion:

   ```
   adb logcat | grep -E 'GemmaBrain|ReplySpeaker|BotService'
   ```

   Write down `ttf` (GemmaBrain) and `ReplySpeaker: first audio Xms`.
   Product budget is end-of-speech → first audio out of the bot
   speaker ≤ 2 s warm on E2B (3.5 s ceiling). That is roughly ttf +
   first-sentence synth + first BLE write.

Half-duplex: while the simulator is playing the reply, holding
**Hold to talk** should not start a new companion turn. Companion
drops inbound mic frames while `ReplySpeaker` is speaking.

## Battery into the brain

Ask "how much battery do you have?" The spoken reply should include
the simulator's faked percent (87), not a shrug. Logcat should show
`tool get_battery` and a telemetry line `Battery 87%`.

## Timer that survives a kill

1. Ask "set a timer for one minute, tea" (or FakeBrain: it will not
   call `set_timer` on its own — use Gemma for this step).
2. Companion activity log: `timer … armed`.
3. Force-stop or swipe-kill the companion (`Docs/m2.5-testing-guide.md`).
   After the service is back and the brain is **Ready**, the timer
   must still fire — you should hear an announcement, not silence.
   Due-on-restore timers fire as soon as warm-up finishes.

## What success looks like

- Spoken reply comes out of the **simulator** speaker.
- `get_battery` returns a real percent in the spoken follow-up.
- A 1-minute timer announces after a service restart.
- Captions still appear (subtitle). Phone speaker stays quiet.
