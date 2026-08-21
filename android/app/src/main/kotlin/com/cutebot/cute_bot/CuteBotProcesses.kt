// Process-name helpers for the split :listener / default-process layout.
//
// CuteBotNotificationListenerService runs in `:listener` so vivo's Recents
// swipe (which kills the task's process) can leave the system-bound listener
// alive. Everything else — the Flutter UI, the bot FGS, WorkManager — stays
// in the default process. Application.onCreate runs in both.

package com.cutebot.cute_bot

import android.app.ActivityManager
import android.app.Application
import android.content.Context

internal object CuteBotProcesses {
    const val LISTENER_SUFFIX = ":listener"

    fun name(): String = Application.getProcessName()

    fun isListenerProcess(): Boolean = name().endsWith(LISTENER_SUFFIX)

    /** True if the NLS is actually running (bound) in `:listener`. */
    fun isListenerServiceRunning(context: Context): Boolean {
        val manager =
            context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        @Suppress("DEPRECATION")
        return manager.getRunningServices(Int.MAX_VALUE)
            .any {
                it.service.className ==
                    CuteBotNotificationListenerService::class.java.name
            }
    }
}
