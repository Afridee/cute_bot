package com.cutebot.cute_bot

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var companionLink: CompanionLinkHandler? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val handler = CompanionLinkHandler(this)
        companionLink = handler
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CompanionLinkHandler.CHANNEL_NAME,
        ).setMethodCallHandler(handler)

        // OEM keep-alive diagnostics (manufacturer + should-be-running check).
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            OemCareHandler.CHANNEL_NAME,
        ).setMethodCallHandler(OemCareHandler(applicationContext))

        // Scheduled once per install (KEEP policy); survives reboots via
        // WorkManager, so it exists even when the app is never reopened.
        ServiceWatchdog.ensureScheduled(applicationContext)

        // Any app open revives a wanted-but-dead service — including a
        // launch that stops at mode select and never reaches the Companion
        // page (whose controller was previously the only start path).
        // Cheap no-op when the service is running or was deliberately
        // stopped; always legal here because the activity is foreground.
        BotServiceStarter.ensureRunning(applicationContext, "app-open")
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (companionLink?.handleActivityResult(requestCode, resultCode, data) == true) {
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }
}
