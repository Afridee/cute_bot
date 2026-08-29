# Companion first-run setup

The prompt the Companion setup wizard is implemented against. The existing
Companion page stays the debug panel. Setup sits **in front of it** and only
unlocks it when the blocking essentials are true.

```
Open Companion
  → blocking essentials true? → Companion debug panel
  → else → Welcome → Notifications → Bluetooth
       → start service (model download in parallel)
       → Battery unrestricted → Notification access
       → Autostart / Recents (vivo/iQOO only; skip later)
       → Link bot to Android (skip later)
       → Wait for brain ready
       → Teach it how you sound (skip later)
       → debug panel
```

## Why this exists

The Companion page used to dump everything at once. Permissions fired in
`CompanionController.start` (notifications, BLE, ask-once battery). Model
download was a progress bar on the Brain card. CDM linking was an optional
button. Autostart lived on the vivo-only `OemGuidancePage`, shown after a
kill.

A first-run user could reach Control / Transcript / Fake utterance before
Bluetooth, keep-alive, or the model were actually ready. Setup forces the
essentials **in order**, then gets out of the way.

## Gating rules

**Block** (cannot leave the step; cannot open the debug panel):

- Notification permission (Android 13+)
- Bluetooth permission, and Bluetooth on
- Battery unrestricted (`isIgnoringBatteryOptimizations`)
- Notification access (the listener — keep-alive + phone alerts)
- Brain ready (model downloaded and loaded; omitted when
  `CUTEBOT_FAKE_BRAIN=true`)

**Skip later** (explicit button; remembered for this install; does not
re-block):

- OEM autostart / Recents lock (vivo/iQOO only)
- CDM “Link bot to Android”
- Voice enroll (“Teach it how you sound”)

**Not a step:** BLE connection to a live bot. Scan/connect stays automatic
once the service is up. The bot may be off or in another room.

**Re-entry:** every Companion open re-checks the blocking list from live
state. If the user later revokes BLE, battery exemption, or Notification
access, or the model is missing, they land on the first failed blocking
step. Welcome is first-run only (`setupWelcomeSeen`). Skipped-later items
stay skipped. Clear app data resets everything.

**Parallel download:** start the foreground service as soon as notification
+ Bluetooth permissions are granted (and the radio is on), so the ~2.6 GB
model can download while the user does battery, Notification access, OEM,
and CDM. The model step is a wait screen if warm-up is still running.

Completeness is **derived** from live checks + the skip flags. There is no
`setupComplete` flag.

## Step order and copy

Tone: same as the keep-alive page — short, explains why, no marketing. One
primary action per step. Back is allowed; Next / Continue is disabled until
the step is satisfied (or they tap skip later).

### 0. Welcome

**Title:** Before the bot can live here

**Body:** Cute Bot thinks on this phone, not in the robot. These steps let
it talk over Bluetooth, keep the brain warm, and come back if Android kills
the app.

**Primary:** Continue

Shown once per install, only while setup is incomplete.

### 1. Notifications — block

**Title:** Show that the bot is running

**Body:** Android hides background apps unless we can show a quiet
notification. That notification is how you know Cute Bot is still alive. It
never buzzes.

**Primary:** Allow notifications

**Done when:** `POST_NOTIFICATIONS` granted, or API < 33 (step omitted).

**Denied:** Stay here. Secondary: Open app settings.

### 2. Bluetooth — block

**Title:** Talk to the bot

**Body:** The robot has no brain of its own. Bluetooth is the only link.

**Primary:** Allow Bluetooth

**Done when:** BLE authorized **and** Bluetooth is on.

**Denied / off:** Stay here. If permission is granted but radio is off,
change the primary to Turn on Bluetooth.

This is also the first moment the service is allowed to start.

### 3. Battery unrestricted — block

**Title:** Don’t let Android starve it

**Body:** Battery savers kill the companion even when it is in the
foreground-service list. Allow unrestricted background use.

**Primary:** Allow background

**Done when:** `FlutterForegroundTask.isIgnoringBatteryOptimizations` is
true.

Battery is no longer ask-once-and-forget. Refusal keeps the user on this
step.

### 4. Notification access — block

**Title:** Bring the bot back after a kill

**Body:** Some phones force-stop apps, including a swipe from Recents.
Notification access is how Android itself restarts Cute Bot. It also lets
the bot blink and chirp when your phone gets an alert. Cute Bot never reads
the text — only that something arrived.

**Primary:** Open Notification access settings

**Done when:** `OemCare.diagnostics().notificationAccessGranted` is true
(refresh on resume).

Required for everyone, not only vivo after a death.

### 5. Autostart and Recents — skip later, vivo/iQOO only

**Title:** Allow autostart on this phone

**Body:** vivo and iQOO also need Autostart on, and the Cute Bot card
locked in Recents. Android does not tell us whether you did this — continue
after you have, or skip for now.

Numbered instructions (reuse the keep-alive wording):

1. Leave with Home, not a swipe.
2. Lock Cute Bot in Recents.
3. Settings → Apps → Cute Bot → Autostart (or i Manager → Autostart
   manager).
4. Settings → Battery → Background power consumption → Cute Bot → allow
   high.

**Primary:** I did this

**Secondary:** I’ll do this later

**Done when:** user taps either button. We cannot verify autostart. Persist
`oemKeepAliveAcknowledged` or `oemKeepAliveSkipped`.

Omit this step on other OEMs. `OemGuidancePage` stays as the after-death
fallback if they skipped.

No new settings deep link for Autostart.

### 6. Link bot to Android — skip later

**Title:** Link the bot to Android

**Body:** Link once so Android notices the bot when it comes into range and
starts the companion — even if the app is dead. Turn on the bot (or the Bot
Simulator) and keep it nearby.

**Primary:** Link bot to Android (existing CDM chooser)

**Secondary:** I’ll do this later

**Done when:** `companionLink.state.associated`, or user skips. Persist
`cdmSkipped`.

If they skip, the existing “Link bot to Android” button on the debug panel
remains.

### 7. Brain ready — block

**Title:** Download the brain

**Body:** About 2.6 GB, once, stays on this phone. Use Wi-Fi. First time
takes several minutes. After that, restarts only reload.

**UI:** progress percent from `ServiceSnapshot.downloadPercent`; then
“Loading…” while `brainState == warming`; error + Retry if `brainError` is
set.

**Done when:** `brainState` is `ready`, `thinking`, or `responding`.

**FakeBrain:** this step is omitted.

If the download already finished during steps 3–6, the step is already
satisfied and the wizard continues to voice enroll.

### 8. Teach it how you sound — skip later

**Title:** Teach it how you sound

**Body:** The bot’s ears turn your words into text. Your voice may come
out wrong. Say these lines so pause and timers still work. Use the robot
or Bot Simulator. Skip if the bot isn’t here.

Zipformer (the on-device ASR) mangles some speakers so “Pause the timer”
lands as `WAS THE TEMPER`. This step records those substitutions and
overlays them on the fast-intent matcher. No Gemma. Alignment is
deterministic. The overlay only keeps substitutions seen in at least
two takes.

**UI:** 11 prompted lines, 5 successful transcripts each (empty / silence
does not count). The line to say is the display type (one break). Line
counter `03 / 11` as a Space Mono label; takes as a 5-segment bar. Last
ASR line under HEARD in data type. Skip this line after 3 successes.
Speak into the bot or Bot Simulator — same Zipformer as live commands.
No phone primary: speaking is hold-to-talk on the robot. If nothing is
connected, status is `[WAITING]`. While receiving: `[LISTENING]`. Silence:
`[MISSED]`.

**Secondary:** I’ll do this later.

**Tertiary:** Skip this line (after 3 takes).

**Done when:** overlay is saved, or user skips. Persist
`voiceEnrollSkipped` on skip. Overlay JSON is `fast_intent_overlay_v1` on
the same KeyValueStore as the transcript. Skipping later does not wipe an
existing overlay.

Unfinished (never skipped, no overlay) re-shows on the next Companion
open. Re-enroll from the debug panel overwrites the overlay.

**FakeBrain:** keep this step — Sherpa still warms; enrollment does not
need Gemma.

Not a BLE-connection gate for the rest of setup: skip is always available.

### Unlock

Open the existing `CompanionPage` debug panel. No redesign. Skipped CDM
still shows the Android-link card. Skipped OEM still shows Keep-alive tips
on vivo/iQOO.

## Persistence keys

- `oemGuidanceShown` — keep for the death-triggered page; do not treat it
  as setup complete.
- `setupWelcomeSeen` — first-run only; re-entry skips Welcome.
- `oemKeepAliveAcknowledged` / `oemKeepAliveSkipped`
- `cdmSkipped`
- `voiceEnrollSkipped`
- `fast_intent_overlay_v1` — enrolled fast-intent phrases/slots (JSON)
- No `setupComplete` flag.

## Out of scope

- Pretty Companion UI, persona, TTS
- Changing Mode Select (Bot Simulator vs Companion)
- Detecting OEM autostart (impossible without vendor APIs)
- Requiring a live BLE connection before unlock
- iOS
- New packages
