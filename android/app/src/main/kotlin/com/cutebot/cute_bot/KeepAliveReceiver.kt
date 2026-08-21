// Repeating wake while the bot should be running — the Nothing X trick.
//
// vivo's Recents cleaner SIGKILLs the UID (LOW_MEMORY / single-cleaner)
// without onDestroy, so flutter_foreground_task's one-shot RestartReceiver
// alarm is never armed. A clock already in AlarmManager survives that kill
// (it does not survive a package FORCE_STOP). Each fire re-arms, pokes the
// listener bind, and asks BotServiceStarter to bring the FGS back.

package com.cutebot.cute_bot

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.SystemClock
import android.util.Log

class KeepAliveReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent?) {
        Log.i(TAG, "alarm fired")
        val app = context.applicationContext
        if (BotServiceStarter.currentDecision(app) == StartDecision.NOT_WANTED) {
            KeepAliveAlarm.cancel(app)
            return
        }
        KeepAliveAlarm.schedule(app)
        CuteBotNotificationListenerService.requestRebindIfNeeded(app)
        BotServiceStarter.ensureRunning(app, "keep-alive-alarm")
    }

    companion object {
        private const val TAG = "CuteBot/KeepAlive"
    }
}

object KeepAliveAlarm {
    private const val TAG = "CuteBot/KeepAlive"
    private const val REQUEST_CODE = 7101
    private const val INTERVAL_MS = 60_000L

    /** Arm if the bot is wanted, cancel if the user stopped it. */
    fun sync(context: Context) {
        if (BotServiceStarter.currentDecision(context) == StartDecision.NOT_WANTED) {
            cancel(context)
        } else {
            schedule(context)
        }
    }

    fun schedule(context: Context) {
        val app = context.applicationContext
        val am = app.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val operation = pendingIntent(app)
        val trigger = SystemClock.elapsedRealtime() + INTERVAL_MS
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                if (canExact(am)) {
                    am.setExactAndAllowWhileIdle(
                        AlarmManager.ELAPSED_REALTIME_WAKEUP, trigger, operation)
                } else {
                    am.setAndAllowWhileIdle(
                        AlarmManager.ELAPSED_REALTIME_WAKEUP, trigger, operation)
                }
            } else {
                am.set(AlarmManager.ELAPSED_REALTIME_WAKEUP, trigger, operation)
            }
            Log.i(TAG, "scheduled in ${INTERVAL_MS}ms exact=${canExact(am)}")
        } catch (e: SecurityException) {
            try {
                am.setAndAllowWhileIdle(
                    AlarmManager.ELAPSED_REALTIME_WAKEUP, trigger, operation)
                Log.i(TAG, "scheduled inexact fallback in ${INTERVAL_MS}ms")
            } catch (e2: Exception) {
                Log.w(TAG, "schedule failed: ${e2.message}")
            }
        } catch (e: Exception) {
            Log.w(TAG, "schedule failed: ${e.message}")
        }
    }

    fun cancel(context: Context) {
        val app = context.applicationContext
        val am = app.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        am.cancel(pendingIntent(app))
        Log.i(TAG, "cancelled")
    }

    private fun canExact(am: AlarmManager): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        return try {
            am.canScheduleExactAlarms()
        } catch (e: Exception) {
            false
        }
    }

    private fun pendingIntent(context: Context): PendingIntent {
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        return PendingIntent.getBroadcast(
            context, REQUEST_CODE, Intent(context, KeepAliveReceiver::class.java), flags)
    }
}
