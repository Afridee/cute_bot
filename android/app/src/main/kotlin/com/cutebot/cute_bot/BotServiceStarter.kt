// The one native path that (re)starts the bot's foreground service, shared
// by every background wake-up source (CDM device presence, the watchdog
// worker). Deliberately reuses flutter_foreground_task's own persisted
// service status and restart action instead of keeping a second
// "should be running" flag: the plugin already writes API_STOP on a
// deliberate user stop and a start action otherwise, and its own boot /
// restart receivers consult exactly this state. One source of truth.
//
// Android 12+ honesty (M2.5): starting a foreground
// service from the background only succeeds under an exemption (CDM device
// presence callback, battery-optimization exemption, ...). When the OS
// rejects the start, we post a normal tappable notification instead of
// failing silently.

package com.cutebot.cute_bot

import android.app.ActivityManager
import android.app.ForegroundServiceStartNotAllowedException
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.pravera.flutter_foreground_task.models.ForegroundServiceAction
import com.pravera.flutter_foreground_task.models.ForegroundServiceStatus
import com.pravera.flutter_foreground_task.service.ForegroundService

/** What [BotServiceStarter.ensureRunning] decided to do. */
enum class StartDecision {
    /** The user never started the bot, or explicitly stopped it. Do nothing. */
    NOT_WANTED,

    /** The service is already up. Do nothing. */
    ALREADY_RUNNING,

    /** The service should be running but is not: start it. */
    START,
}

object BotServiceStarter {
    private const val TAG = "CuteBot/BotServiceStarter"

    /**
     * Must match the channel the Dart side configures in
     * CompanionController._initService. Created here too (idempotently, with
     * the same LOW importance) because the fallback notification can fire
     * before the service ever created it on this install.
     */
    private const val CHANNEL_ID = "cute_bot_service"
    private const val CHANNEL_NAME = "Cute Bot"
    private const val REOPEN_NOTIFICATION_ID = 1008

    /** Sticky "the service died behind our back" marker (see below). */
    private const val CARE_PREFS = "oem_care"
    private const val KEY_UNEXPECTED_DEATH = "unexpectedDeathObserved"

    /**
     * The watchdog / presence decision, kept pure for unit tests.
     *
     * [lastAction] is flutter_foreground_task's persisted service action
     * (null when the service was never started on this install — the plugin
     * treats null as API_STOP, and so do we).
     */
    @JvmStatic
    fun decide(lastAction: String?, isRunning: Boolean): StartDecision {
        val stopped = lastAction == null || lastAction == ForegroundServiceAction.API_STOP
        return when {
            stopped -> StartDecision.NOT_WANTED
            isRunning -> StartDecision.ALREADY_RUNNING
            else -> StartDecision.START
        }
    }

    /**
     * The decision [ensureRunning] would make right now, without acting on
     * it. [StartDecision.START] means the service died behind our back
     * (OEM cleaner force-stop, crash, ...).
     */
    fun currentDecision(context: Context): StartDecision {
        val lastAction = ForegroundServiceStatus.getData(context).action
        return decide(lastAction, isBotServiceRunning(context))
    }

    /**
     * True if the service was EVER observed dead while it should have been
     * running — the signature of an OEM cleaner force-stop (seen on the
     * iQOO Neo 10). Sticky on purpose: after a force-stop the watchdog can
     * revive the service seconds after the app process comes back, i.e.
     * before the UI gets a chance to look, so a live wanted-but-dead check
     * would race it and miss. Both [ensureRunning] and this method record
     * the observation; the Dart side keeps its own ask-once flag for the
     * guidance page, so this marker is never cleared.
     */
    fun checkUnexpectedDeath(context: Context): Boolean {
        if (currentDecision(context) == StartDecision.START) {
            recordUnexpectedDeath(context)
            return true
        }
        return context.getSharedPreferences(CARE_PREFS, Context.MODE_PRIVATE)
            .getBoolean(KEY_UNEXPECTED_DEATH, false)
    }

    private fun recordUnexpectedDeath(context: Context) {
        Log.w(TAG, "service found dead while it should be running; recorded")
        context.getSharedPreferences(CARE_PREFS, Context.MODE_PRIVATE)
            .edit().putBoolean(KEY_UNEXPECTED_DEATH, true).apply()
    }

    /**
     * Restarts the bot service if (and only if) it should be running but is
     * not. Returns the decision that was made; a rejected start posts the
     * reopen notification and still returns [StartDecision.START].
     */
    fun ensureRunning(context: Context, reason: String): StartDecision {
        val lastAction = ForegroundServiceStatus.getData(context).action
        val decision = decide(lastAction, isBotServiceRunning(context))
        Log.i(TAG, "ensureRunning($reason): action=$lastAction -> $decision")
        if (decision != StartDecision.START) return decision

        // We are about to resurrect a service that something else killed —
        // remember that for the keep-alive guidance, since our restart hides
        // the evidence from the UI's own launch-time check.
        recordUnexpectedDeath(context)

        try {
            // Same start path as the plugin's own RestartReceiver: mark the
            // persisted status RESTART and start the service; it reloads its
            // stored callback/notification options from SharedPreferences.
            ForegroundServiceStatus.setData(context, ForegroundServiceAction.RESTART)
            ContextCompat.startForegroundService(
                context, Intent(context, ForegroundService::class.java))
            Log.i(TAG, "ensureRunning($reason): service start requested")
        } catch (e: Exception) {
            val blocked = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                e is ForegroundServiceStartNotAllowedException
            Log.e(TAG, "ensureRunning($reason): start failed (blocked=$blocked)", e)
            postReopenNotification(context)
        }
        return decision
    }

    /**
     * Same check the plugin's RestartReceiver uses. getRunningServices is
     * deprecated for inspecting *other* apps but still returns our own
     * services, and unlike the plugin's in-process StateFlow it works from a
     * freshly spawned process.
     */
    private fun isBotServiceRunning(context: Context): Boolean {
        val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        @Suppress("DEPRECATION")
        return manager.getRunningServices(Int.MAX_VALUE)
            .any { it.service.className == ForegroundService::class.java.name }
    }

    /** Normal (non-ongoing) "reopen the app" notification. Never silent failure. */
    private fun postReopenNotification(context: Context) {
        val manager =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, CHANNEL_NAME, NotificationManager.IMPORTANCE_LOW))

        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
        val contentIntent = launch?.let {
            PendingIntent.getActivity(
                context, 0, it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        }

        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(context.applicationInfo.icon)
            .setContentTitle("Cute Bot stopped")
            .setContentText("Android blocked the background restart. Tap to bring the bot back.")
            .setContentIntent(contentIntent)
            .setAutoCancel(true)
            .build()
        try {
            manager.notify(REOPEN_NOTIFICATION_ID, notification)
        } catch (e: SecurityException) {
            // POST_NOTIFICATIONS revoked: nothing more we can do from here.
            Log.e(TAG, "reopen notification rejected", e)
        }
    }
}
