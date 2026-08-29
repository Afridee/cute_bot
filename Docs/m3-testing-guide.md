# M3 human-bar test — GemmaBrain

Agent bar (this milestone's report): the app builds, unit tests pass,
Gemma 4 is wired behind `BotBrain` in the service isolate. This page is
the **on-phone** check: native audio in, a real reply, latency numbers.

You need the companion phone (8GB+ RAM, arm64, Android 11+) and enough
storage for a **~2.6 GB** model download on first launch. Wi-Fi. The bot
simulator phone is the same as M1/M2.

## First launch (model download)

1. `fvm flutter run` on the companion phone. Pick **Companion**.
2. A first-run wizard walks notifications, Bluetooth, battery,
   Notification access, optional CDM link, then the brain download
   (copy and gating: `Docs/companion-setup.md`). The service starts
   after Bluetooth so the model can download during the later steps.
   FakeBrain (`--dart-define=CUTEBOT_FAKE_BRAIN=true`) skips the
   download wait. The debug panel only opens after the blocking steps.
3. Once the panel is unlocked, the Brain card shows **Gemma 4 E2B**
   and, if warm-up is still running, a download percentage. First
   warm-up is **minutes** (download) plus **tens of seconds** (model
   load). Breathing-blue LEDs on the bot mean warming; utterances
   during this window are dropped.
4. When the card says **Ready**, the model is in memory. Subsequent
   service restarts skip the download and only pay load + chat-create.

The file lives on device after that. `--dart-define=HUGGINGFACE_TOKEN=…`
is only needed if Hugging Face starts gating the litert-community
bundle; it is ungated as of Aug 2026.

### Warm-up fails with "Model may be invalid"

`Failed to create engine. Model may be invalid` is the Dart wrapper.
Native `engine_create` returning in ~150 ms (not tens of seconds) means
the runtime rejected the file or the accelerator, not that it loaded
2.6 GB. Check, in order:

1. **File size.** The bundle is **~2.59 GB**. A Hugging Face HTML page
   or a truncated download will still be marked "installed":

   ```
   adb shell run-as com.cutebot.cute_bot ls -l app_flutter/gemma-4-E2B-it.litertlm
   ```

   If it is not ~2.5–2.6 GB, delete it and re-warm:

   ```
   adb shell run-as com.cutebot.cute_bot rm app_flutter/gemma-4-E2B-it.litertlm
   ```

   Then restart the service so it re-downloads. Do not trust a 100%
   progress bar if the size is wrong.

2. **Native reason.** flutter_gemma does not redirect LiteRT stderr on
   Android. The real error is in logcat under `tflite` / `litert`:

   ```
   adb logcat | grep -E 'tflite|litert|LiteRtLm|GemmaBrain'
   ```

3. **Rebuild after the vndksupport / CPU-audio fix.** GPU OpenCL on
   Android 12+ needs `libvndksupport.so` in the app manifest; the audio
   encoder must not be pinned to GPU or the CPU text fallback never
   actually drops GPU.

### Spoken turn fails with miniaudio error -10

`Failed to initialize miniaudio decoder, error code: -10` then
`Failed to start streaming (code: 2)` means LiteRT-LM got audio bytes
it could not sniff as a file. The clip must be a PCM WAV (RIFF header),
not raw PCM16. Rebuild after the WAV wrap in `pcm16.dart` if you are
still on the raw-samples path. Confirm logcat shows
`GemmaBrain: submit wav N bytes` (N = 44 + samples×2).

## Spoken turn

1. Hold-to-talk on the simulator, say something short ("hey little
   robot, how are you?"), release.
2. Companion Brain card should move **Thinking → Responding → Ready**.
3. Response text streams in. The bot chirps at response start (M2
   expression) and may change LED color if the model called `set_led`.
4. Read the latency line under the reply:

   `submit Xms · ttf Yms · decode Zms · total Tms · gpu`

   - **ttf** = end of the utterance (when `respond()` started) to the
     first token. This is the M3 stand-in for the product budget
     (end-of-speech → first audio out ≤ 2 s on E2B, 3.5 s ceiling).
     TTS + BLE playback are M5, so spoken audio out of the bot speaker
     is **not** in this number yet.
   - Same line is in logcat: `adb logcat | grep GemmaBrain`.

A **Fake utterance** button still exists; it feeds silence. Prefer a
real spoken clip — silence is a hostile input for a native-audio model.

## What success looks like

- A spoken utterance produces a short, on-topic reply (not FakeBrain's
  canned "I heard you talk for N seconds").
- `ttf` is logged every turn. Write the number down; it is the M3
  budget check.
- A tool call (`set_led` / `wiggle` / `play_sound`) visibly moves the
  simulator. `get_battery` in the spoken follow-up, `set_timer`
  kill-survival, and TTS out of the bot speaker are the M4/M5 human
  bar — **passed**; procedure: `Docs/m4-testing-guide.md`.

## Kill / recovery (still M2's contract, now with a real model)

Swipe the companion out of recents. Speak again. The bot should still
respond (service isolate owns the model). Force-stop / reboot still
follow the M2.5 keep-alive paths; after resurrection the brain will
**re-warm** (load + chat-create, no re-download). Live turns and
post-restart turns both clear history and seed the last 16 bot
transcript lines as text, then submit the current utterance as WAV.

## Fallback

If you need the M2 canned brain without downloading the model:

```
fvm flutter run --dart-define=CUTEBOT_FAKE_BRAIN=true
```
