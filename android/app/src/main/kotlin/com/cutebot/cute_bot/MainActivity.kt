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

        // Scheduled once per install (KEEP policy); survives reboots via
        // WorkManager, so it exists even when the app is never reopened.
        ServiceWatchdog.ensureScheduled(applicationContext)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (companionLink?.handleActivityResult(requestCode, resultCode, data) == true) {
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }
}
