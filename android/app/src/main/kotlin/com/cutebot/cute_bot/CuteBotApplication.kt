// Process-start bookkeeping that must run before any other component:
//
// 1. Observe an unexpected service death BEFORE anything can hide it. After
//    an OEM cleaner force-stop (iQOO Neo 10), the next app launch revives
//    the foreground service within ~100 ms of process start —
//    flutter_foreground_task's own restart path, upstream of both our
//    watchdog and the Dart side — after which the wanted-but-dead evidence
//    is gone. Application.onCreate completes first, so the sticky marker
//    gets written first.
//
// 2. Heal the notification-listener bind. vivo's cleaner kill severs the
//    system's listener bind and never re-establishes it on its own, and
//    requestRebind() is a no-op on that OEM (measured on V2425A / iQOO
//    Neo 10). requestRebindIfNeeded waits out an in-flight bind, then
//    flips a dummy component so PACKAGE_CHANGED makes
//    NotificationManagerService rebind us. Never disable the listener
//    itself — on vivo that revokes Notification access.

package com.cutebot.cute_bot

import android.app.Application

class CuteBotApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        BotServiceStarter.checkUnexpectedDeath(this)
        CuteBotNotificationListenerService.requestRebindIfNeeded(this)
    }
}
