// Process-start bookkeeping that must run before any other component.
// Application.onCreate runs in BOTH the default process and :listener.
//
// 1. Observe an unexpected service death BEFORE anything can hide it. After
//    an OEM cleaner force-stop (iQOO Neo 10), the next app launch revives
//    the foreground service within ~100 ms of process start —
//    flutter_foreground_task's own restart path, upstream of both our
//    watchdog and the Dart side — after which the wanted-but-dead evidence
//    is gone. Application.onCreate completes first, so the sticky marker
//    gets written first. Safe in both processes: a freshly started process
//    has an empty SharedPreferences cache, so the disk read is accurate,
//    and the marker is a sticky true.
//
// 2. Heal the notification-listener bind. vivo's cleaner kill severs the
//    system's listener bind and never re-establishes it on its own, and
//    requestRebind() is a no-op on that OEM (measured on V2425A / iQOO
//    Neo 10). requestRebindIfNeeded waits out an in-flight bind, then
//    flips a dummy component so PACKAGE_CHANGED makes
//    NotificationManagerService rebind us. Never disable the listener
//    itself — on vivo that revokes Notification access. In the default
//    process this is a no-op while :listener is already bound, so an FGS
//    restart after swipe does not poke a live bind.

package com.cutebot.cute_bot

import android.app.Application
import android.util.Log
import androidx.work.Configuration

class CuteBotApplication : Application(), Configuration.Provider {
    override fun onCreate() {
        super.onCreate()
        Log.i(TAG, "onCreate process=${CuteBotProcesses.name()}")
        BotServiceStarter.checkUnexpectedDeath(this)
        CuteBotNotificationListenerService.requestRebindIfNeeded(this)
        // Re-arm after boot / any process start. The alarm that survives a
        // cleaner SIGKILL is the one that was set *before* the kill.
        KeepAliveAlarm.sync(this)
    }

    // Workers stay in the default process. :listener must not open
    // WorkManager's shared DB (SQLite lock / duplicate init).
    override val workManagerConfiguration: Configuration
        get() = Configuration.Builder()
            .setDefaultProcessName(packageName)
            .build()

    companion object {
        private const val TAG = "CuteBot/App"
    }
}
