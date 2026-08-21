// Dummy receiver whose only job is to flip enabled/disabled so
// PackageManager broadcasts PACKAGE_CHANGED for this app. AOSP
// ManagedServices.onPackagesChanged then rebinds enabled notification
// listeners. We poke THIS component, never the listener itself:
// disabling CuteBotNotificationListenerService on vivo drops the user
// from enabled_notification_listeners (measured on V2425A).

package com.cutebot.cute_bot

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class ListenerBindPoke : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {}
}
