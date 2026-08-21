// Notification listener: the strongest keep-alive anchor we have on
// vivo/iQOO, plus the input for the "phone alerts on bot" feature.
//
// Keep-alive: once the user grants Notification access, system_server holds
// a persistent bind to this service. When the OEM cleaner kills the process
// ("single-cleaner" on the iQOO Neo 10 — it kills even a live FGS on swipe),
// the system re-binds the listener, which restarts our process, and
// onListenerConnected() revives the foreground service through the shared
// BotServiceStarter path. This is exactly how Nothing X survives the same
// cleaner (its NothingNotificationService is in enabled_notification_listeners
// and system_server rebinds it after every kill). Not a hack: the honest
// product reason for the access is the alert relay below.
//
// Alerts: qualifying phone notifications (WhatsApp, calls, ...) are forwarded
// as a tiny "phoneAlert" event into the service isolate over the plugin's own
// task-data channel (ForegroundService.sendData — same pipe the UI commands
// use, no second IPC stack). The service isolate decides whether/how to
// actuate the bot; if the service is not running, sendData is a no-op and the
// event is simply dropped, which is fine — the ensureRunning call above is
// the part that matters for survival.

package com.cutebot.cute_bot

import android.app.Notification
import android.app.NotificationManager
import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import androidx.core.app.NotificationManagerCompat
import com.pravera.flutter_foreground_task.service.ForegroundService

class CuteBotNotificationListenerService : NotificationListenerService() {

    companion object {
        private const val TAG = "CuteBot/NotifListener"

        /** Re-check the FGS at most this often from posted-notification spam. */
        private const val ENSURE_GAP_MS = 10_000L

        /** At most one alert forwarded per this window (BLE spam guard #1;
         *  the service isolate applies its own actuation debounce too). */
        private const val ALERT_GAP_MS = 3_000L

        /** Live system bind held right now (per process — which is exactly
         *  the scope [requestRebindIfNeeded] needs). */
        @Volatile
        private var connected = false

        /** A dummy-component poke is in flight. */
        @Volatile
        private var healing = false

        private val healHandler = Handler(Looper.getMainLooper())
        private val healToken = Any()

        /** Wait for an in-flight system bind before poking PackageManager. */
        private const val HEAL_INITIAL_DELAY_MS = 600L

        /** Gap between enabling and disabling the dummy poke so NMS sees
         *  two PACKAGE_CHANGED events (a same-ms toggle can coalesce). */
        private const val HEAL_COMPONENT_GAP_MS = 300L

        /** Retries after the first poke, if still unbound. */
        private val HEAL_RETRY_DELAYS_MS = longArrayOf(1_800L, 4_000L)

        /** Is our listener in the user's enabled_notification_listeners? */
        fun isEnabled(context: Context): Boolean =
            NotificationManagerCompat.getEnabledListenerPackages(context)
                .contains(context.packageName)

        fun componentName(context: Context): ComponentName =
            ComponentName(context, CuteBotNotificationListenerService::class.java)

        /**
         * Restore the system's bind to this listener after a kill.
         *
         * Measured on vivo/iQOO: the cleaner severs the bind and never
         * re-establishes it, and [requestRebind] alone is a no-op. AOSP
         * rebinds enabled listeners on PACKAGE_CHANGED for this package,
         * so we flip a dummy component ([ListenerBindPoke]) — never this
         * listener, because disabling it on vivo revokes Notification
         * access. Wait briefly first so we don't interrupt a bind that
         * is already in flight (grant, boot, package update).
         *
         * Called on every process start (CuteBotApplication) and after
         * [onListenerDisconnected]. No-op when already bound or when
         * access is not granted.
         */
        fun requestRebindIfNeeded(context: Context) {
            if (connected || healing) return
            if (!isEnabled(context)) return
            val app = context.applicationContext
            // Recover if a previous poke left this listener disabled.
            ensureListenerEnabled(app)
            healing = true
            healHandler.removeCallbacksAndMessages(healToken)
            Log.i(TAG, "listener enabled but not bound; scheduling bind heal")
            postHeal(HEAL_INITIAL_DELAY_MS) { healBind(app, attempt = 0) }
        }

        private fun postHeal(delayMs: Long, action: () -> Unit) {
            healHandler.postDelayed(action, healToken, delayMs)
        }

        private fun finishHealing() {
            healing = false
            healHandler.removeCallbacksAndMessages(healToken)
        }

        private fun ensureListenerEnabled(context: Context) {
            try {
                context.packageManager.setComponentEnabledSetting(
                    componentName(context),
                    PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
                    PackageManager.DONT_KILL_APP,
                )
            } catch (e: Exception) {
                Log.w(TAG, "listener enable failed: ${e.message}")
            }
        }

        private fun setPokeEnabled(context: Context, enabled: Boolean) {
            val state = if (enabled) {
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED
            } else {
                PackageManager.COMPONENT_ENABLED_STATE_DISABLED
            }
            try {
                context.packageManager.setComponentEnabledSetting(
                    ComponentName(context, ListenerBindPoke::class.java),
                    state,
                    PackageManager.DONT_KILL_APP,
                )
            } catch (e: Exception) {
                Log.w(TAG, "bind poke failed: ${e.message}")
            }
        }

        private fun healBind(context: Context, attempt: Int) {
            if (connected) {
                finishHealing()
                return
            }

            Log.i(TAG, "healing listener bind (attempt ${attempt + 1})")
            // Flip dummy receiver: PACKAGE_CHANGED → NMS rebindServices.
            setPokeEnabled(context, true)

            postHeal(HEAL_COMPONENT_GAP_MS) {
                setPokeEnabled(context, false)
                if (connected) {
                    finishHealing()
                    return@postHeal
                }
                try {
                    requestRebind(componentName(context))
                } catch (e: Exception) {
                    Log.w(TAG, "requestRebind failed: ${e.message}")
                }
                val next = attempt + 1
                if (next < HEAL_RETRY_DELAYS_MS.size + 1) {
                    postHeal(HEAL_RETRY_DELAYS_MS[next - 1]) {
                        healBind(context, next)
                    }
                } else {
                    healing = false
                    if (!connected) {
                        Log.w(TAG, "listener still unbound after bind heal")
                    }
                }
            }
        }
    }

    private var lastEnsureAt = 0L
    private var lastAlertAt = 0L

    override fun onListenerConnected() {
        // Fires on grant, on boot, after our component poke, and — when the
        // OEM actually rebinds — right after a cleaner kill.
        Log.i(TAG, "listener connected")
        connected = true
        finishHealing()
        lastEnsureAt = SystemClock.elapsedRealtime()
        BotServiceStarter.ensureRunning(applicationContext, "notification-listener")
    }

    override fun onListenerDisconnected() {
        Log.w(TAG, "listener disconnected")
        connected = false
        requestRebindIfNeeded(applicationContext)
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        // Keep-alive check first, independent of alert filtering: any posted
        // notification is a chance to notice the FGS is gone. Debounced —
        // ensureRunning walks getRunningServices, no need to do that per post.
        val now = SystemClock.elapsedRealtime()
        if (now - lastEnsureAt >= ENSURE_GAP_MS) {
            lastEnsureAt = now
            BotServiceStarter.ensureRunning(applicationContext, "notification-posted")
        }

        if (!qualifiesAsAlert(sbn)) return
        if (now - lastAlertAt < ALERT_GAP_MS) return
        lastAlertAt = now

        Log.i(TAG, "phone alert: ${sbn.packageName} (${sbn.notification.category})")
        // Same map schema as UiCommand in lib/companion/service/service_ipc.dart.
        ForegroundService.sendData(
            mapOf(
                "cmd" to "phoneAlert",
                "pkg" to sbn.packageName,
                "category" to (sbn.notification.category ?: ""),
            ))
    }

    /**
     * Aggressive spam filter: only human-relevant, newly-alerting
     * notifications should reach the bot. Content is never read — package
     * and category are all that crosses to the Dart side.
     */
    private fun qualifiesAsAlert(sbn: StatusBarNotification): Boolean {
        // Our own notifications (FGS "cute_bot_service" id 1007, reopen 1008).
        if (sbn.packageName == packageName) return false
        // Ongoing = FGS notifications, media sessions, downloads — not alerts.
        if (sbn.isOngoing) return false
        val flags = sbn.notification.flags
        if (flags and Notification.FLAG_GROUP_SUMMARY != 0) return false
        if (flags and Notification.FLAG_FOREGROUND_SERVICE != 0) return false
        // Silent/minimized channels: below DEFAULT never makes a sound on the
        // phone, so it should not make the bot chirp either.
        try {
            val ranking = Ranking()
            if (currentRanking.getRanking(sbn.key, ranking) &&
                ranking.importance < NotificationManager.IMPORTANCE_DEFAULT
            ) {
                return false
            }
        } catch (e: Exception) {
            // Ranking unavailable (listener mid-disconnect): let it through
            // rather than silently eating real alerts.
            Log.w(TAG, "ranking lookup failed: ${e.message}")
        }
        return true
    }
}
