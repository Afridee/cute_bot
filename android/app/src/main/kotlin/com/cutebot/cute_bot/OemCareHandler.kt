// Diagnostics + one action for the Dart side's OEM keep-alive guidance
// (observed on the iQOO Neo 10: vivo's cleaner FORCE-STOPS the app —
// ApplicationExitInfo says "due to single-cleaner" — which blocks every
// self-resurrection path until something external re-enters the process.
// The one external path that works is the notification listener: with
// Notification access granted, system_server re-binds
// CuteBotNotificationListenerService after the kill and the FGS revives).
//
// Methods:
//   getDiagnostics -> {
//     manufacturer:       Build.MANUFACTURER   (e.g. "vivo")
//     brand:              Build.BRAND          (e.g. "iQOO")
//     unexpectedDeath:    the service was at some point observed dead while
//                         it should have been running (sticky — see
//                         BotServiceStarter.checkUnexpectedDeath for why a
//                         live check would race the watchdog and miss).
//     notificationAccess: our listener is in enabled_notification_listeners.
//   }
//   openNotificationAccessSettings -> deep-links to the system Notification
//     access screen (app-specific detail page on API 30+). Returns true if
//     a settings screen was opened.
//
// Deliberately does NOT act on the restart decision — CompanionController
// .start() owns the restart path.

package com.cutebot.cute_bot

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class OemCareHandler(private val context: Context) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL_NAME = "com.cutebot.cute_bot/oem_care"
        private const val TAG = "CuteBot/OemCare"
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getDiagnostics" -> result.success(
                mapOf(
                    "manufacturer" to Build.MANUFACTURER,
                    "brand" to Build.BRAND,
                    "unexpectedDeath" to BotServiceStarter.checkUnexpectedDeath(context),
                    "notificationAccess" to
                        CuteBotNotificationListenerService.isEnabled(context),
                ))
            "openNotificationAccessSettings" ->
                result.success(openNotificationAccessSettings())
            "openBluetoothSettings" -> result.success(openBluetoothSettings())
            "openAppSettings" -> result.success(openAppSettings())
            else -> result.notImplemented()
        }
    }

    /**
     * App-specific listener detail page where it exists (API 30+), the
     * all-listeners screen otherwise. NEW_TASK because we hold an
     * application context, not the Activity.
     */
    private fun openNotificationAccessSettings(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val detail = Intent(Settings.ACTION_NOTIFICATION_LISTENER_DETAIL_SETTINGS)
                .putExtra(
                    Settings.EXTRA_NOTIFICATION_LISTENER_COMPONENT_NAME,
                    CuteBotNotificationListenerService.componentName(context)
                        .flattenToString())
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            try {
                context.startActivity(detail)
                return true
            } catch (e: ActivityNotFoundException) {
                Log.w(TAG, "detail listener settings missing; falling back")
            }
        }
        return try {
            context.startActivity(
                Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            true
        } catch (e: ActivityNotFoundException) {
            Log.e(TAG, "no notification listener settings screen on this device")
            false
        }
    }

    private fun openBluetoothSettings(): Boolean {
        val flags = Intent.FLAG_ACTIVITY_NEW_TASK
        return try {
            context.startActivity(Intent(Settings.ACTION_BLUETOOTH_SETTINGS).addFlags(flags))
            true
        } catch (e: ActivityNotFoundException) {
            Log.w(TAG, "Bluetooth settings missing; falling back to app settings")
            openAppSettings()
        }
    }

    private fun openAppSettings(): Boolean {
        return try {
            context.startActivity(
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                    .setData(Uri.fromParts("package", context.packageName, null))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            true
        } catch (e: ActivityNotFoundException) {
            Log.e(TAG, "no application details settings on this device")
            false
        }
    }
}
