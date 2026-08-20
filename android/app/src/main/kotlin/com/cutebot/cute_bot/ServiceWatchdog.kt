// Watchdog safety net (M2.5): a periodic WorkManager job
// that restarts the foreground service if it should be running but is not.
// "Should be running" comes from flutter_foreground_task's persisted status
// via BotServiceStarter — this file only does the scheduling.
//
// WorkManager survives process death and reboot, so once scheduled (on the
// first app open, kept forever) the watchdog exists even if the user never
// opens the app again. The ~15-minute period is WorkManager's minimum for
// periodic work, which is exactly the cadence the brief asks for.

package com.cutebot.cute_bot

import android.content.Context
import android.util.Log
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import java.util.concurrent.TimeUnit

object ServiceWatchdog {
    private const val TAG = "CuteBot/ServiceWatchdog"
    private const val UNIQUE_NAME = "cute_bot_service_watchdog"

    fun ensureScheduled(context: Context) {
        val request =
            PeriodicWorkRequestBuilder<WatchdogWorker>(15, TimeUnit.MINUTES).build()
        // KEEP: never resets the period timer on app open; the job is
        // scheduled once per install and left alone.
        WorkManager.getInstance(context).enqueueUniquePeriodicWork(
            UNIQUE_NAME, ExistingPeriodicWorkPolicy.KEEP, request)
        Log.i(TAG, "watchdog scheduled (period 15 min, policy KEEP)")
    }
}

class WatchdogWorker(context: Context, params: WorkerParameters) :
    Worker(context, params) {

    override fun doWork(): Result {
        BotServiceStarter.ensureRunning(applicationContext, "watchdog")
        // Always success: a blocked start already posted the fallback
        // notification, and retrying sooner than the next period would
        // just hit the same restriction.
        return Result.success()
    }
}
