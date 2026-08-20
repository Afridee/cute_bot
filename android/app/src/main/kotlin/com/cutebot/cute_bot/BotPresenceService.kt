// CompanionDeviceManager device-presence hook (M2.5).
//
// After the user associates the bot (CompanionLinkHandler) and we call
// startObservingDevicePresence, Android itself scans for the bonded device
// and binds this service when it comes into BLE range — even if our process
// is dead. That bind runs our process at foreground importance, which is
// what makes the foreground-service start below legal on Android 12+.
//
// API gating: CompanionDeviceService and presence observation exist on
// API 31+ only. On API 29–30 this class is never bound (we never call
// startObservingDevicePresence there), so the feature is simply absent —
// no crash, per the brief.
//
// Presence tracking is identity-based, which is why association bonds the
// device (see the pairing note in lib/shared/ble_protocol.dart): bonding
// gives the phone the bot's IRK, so the rotating random address still
// resolves to the associated identity.

package com.cutebot.cute_bot

import android.companion.CompanionDeviceService
import android.os.Build
import android.util.Log
import androidx.annotation.RequiresApi

@RequiresApi(Build.VERSION_CODES.S)
class BotPresenceService : CompanionDeviceService() {
    private companion object {
        const val TAG = "CuteBot/BotPresence"
    }

    // The String overload is deprecated on API 33+, but the AssociationInfo
    // overload's default implementation delegates to it, so overriding just
    // this one covers API 31 through current.
    @Deprecated("Deprecated in API 33; still the cross-version entry point")
    override fun onDeviceAppeared(address: String) {
        Log.i(TAG, "bot appeared ($address)")
        BotServiceStarter.ensureRunning(applicationContext, "cdm-appeared")
    }

    @Deprecated("Deprecated in API 33; still the cross-version entry point")
    override fun onDeviceDisappeared(address: String) {
        // Nothing to do: if the service is alive its own BLE reconnect loop
        // handles drops, and if it is dead there is nothing to stop.
        Log.i(TAG, "bot disappeared ($address)")
    }
}
