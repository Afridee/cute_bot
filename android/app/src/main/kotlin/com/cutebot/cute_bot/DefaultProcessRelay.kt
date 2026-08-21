// Cross-process hop from `:listener` into the default process.
//
// ForegroundService.sendData and flutter_foreground_task's SharedPreferences
// are in-process: calling them from `:listener` is a silent no-op (sendData)
// or a stale-cache race (lastAction). This receiver is declared *without*
// android:process, so it runs next to the FGS. Explicit + exported=false.

package com.cutebot.cute_bot

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import com.pravera.flutter_foreground_task.service.ForegroundService

class DefaultProcessRelay : BroadcastReceiver() {

    companion object {
        private const val TAG = "CuteBot/DefaultRelay"

        private const val ACTION_ENSURE = "com.cutebot.cute_bot.ENSURE_RUNNING"
        private const val ACTION_PHONE_ALERT = "com.cutebot.cute_bot.PHONE_ALERT"
        private const val EXTRA_REASON = "reason"
        private const val EXTRA_PKG = "pkg"
        private const val EXTRA_CATEGORY = "category"

        fun requestEnsureRunning(context: Context, reason: String) {
            context.sendBroadcast(
                Intent(context, DefaultProcessRelay::class.java)
                    .setAction(ACTION_ENSURE)
                    .putExtra(EXTRA_REASON, reason)
                    .setPackage(context.packageName)
                    .addFlags(Intent.FLAG_RECEIVER_FOREGROUND),
            )
        }

        fun sendPhoneAlert(context: Context, packageName: String, category: String) {
            if (!CuteBotProcesses.isListenerProcess()) {
                deliverPhoneAlert(packageName, category)
                return
            }
            context.sendBroadcast(
                Intent(context, DefaultProcessRelay::class.java)
                    .setAction(ACTION_PHONE_ALERT)
                    .putExtra(EXTRA_PKG, packageName)
                    .putExtra(EXTRA_CATEGORY, category)
                    .setPackage(context.packageName)
                    .addFlags(Intent.FLAG_RECEIVER_FOREGROUND),
            )
        }

        internal fun deliverPhoneAlert(packageName: String, category: String) {
            ForegroundService.sendData(
                mapOf(
                    "cmd" to "phoneAlert",
                    "pkg" to packageName,
                    "category" to category,
                ),
            )
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            ACTION_ENSURE -> {
                val reason = intent.getStringExtra(EXTRA_REASON) ?: "default-relay"
                Log.i(TAG, "ensureRunning hop: $reason")
                BotServiceStarter.ensureRunning(context, reason)
            }
            ACTION_PHONE_ALERT -> {
                deliverPhoneAlert(
                    intent.getStringExtra(EXTRA_PKG) ?: "",
                    intent.getStringExtra(EXTRA_CATEGORY) ?: "",
                )
            }
        }
    }
}
