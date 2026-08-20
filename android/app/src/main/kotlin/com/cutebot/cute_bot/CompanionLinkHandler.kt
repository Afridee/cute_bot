// CompanionDeviceManager association plumbing (M2.5),
// exposed to Dart over the "com.cutebot.cute_bot/companion_link"
// MethodChannel. Lives Activity-side because the CDM chooser is an
// IntentSender that must be launched with startIntentSenderForResult.
//
// Methods:
//   getState      -> current association/observation state (also re-arms
//                    presence observation, which is harmlessly idempotent)
//   associate     -> launch the CDM chooser filtered to the bot service
//                    UUID; on confirm: bond + observe presence
//   disassociate  -> stop observing + remove all associations
//
// API gating: association works from API 26 (so our whole 29+ range);
// presence observation (startObservingDevicePresence + BotPresenceService)
// is API 31+. On 29–30 association still succeeds and the state map says
// presenceSupported=false — the wake-on-approach feature is simply absent.

package com.cutebot.cute_bot

import android.app.Activity
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.companion.AssociationInfo
import android.companion.AssociationRequest
import android.companion.BluetoothLeDeviceFilter
import android.companion.CompanionDeviceManager
import android.content.Context
import android.content.Intent
import android.content.IntentSender
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class CompanionLinkHandler(private val activity: Activity) :
    MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL_NAME = "com.cutebot.cute_bot/companion_link"
        private const val TAG = "CuteBot/CompanionLink"
        private const val REQUEST_CODE_ASSOCIATE = 0xB07

        /** Must stay in sync with BotUuids.service in lib/shared/ble_protocol.dart. */
        private const val BOT_SERVICE_UUID = "cb070001-4bd9-4f22-9e15-8c2a51d1f27e"
    }

    private val manager: CompanionDeviceManager? =
        activity.getSystemService(Context.COMPANION_DEVICE_SERVICE)
            as? CompanionDeviceManager

    /** Completes when the chooser round-trip finishes. */
    private var pendingAssociate: MethodChannel.Result? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getState" -> {
                ensureObservingIfAssociated()
                result.success(stateMap())
            }
            "associate" -> associate(result)
            "disassociate" -> disassociate(result)
            else -> result.notImplemented()
        }
    }

    // --- state ---

    private fun stateMap(): Map<String, Any?> {
        val addresses = associatedAddresses()
        return mapOf(
            "presenceSupported" to (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S),
            "associated" to addresses.isNotEmpty(),
            "addresses" to addresses,
            "bondState" to addresses.firstOrNull()?.let { bondStateLabel(it) },
        )
    }

    private fun associatedAddresses(): List<String> {
        val manager = manager ?: return emptyList()
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                manager.myAssociations.mapNotNull { it.deviceMacAddress?.toString() }
            } else {
                @Suppress("DEPRECATION")
                manager.associations.toList()
            }
        } catch (e: Exception) {
            Log.e(TAG, "reading associations failed", e)
            emptyList()
        }
    }

    private fun bondStateLabel(address: String): String? {
        return try {
            when (remoteDevice(address)?.bondState) {
                BluetoothDevice.BOND_BONDED -> "bonded"
                BluetoothDevice.BOND_BONDING -> "bonding"
                BluetoothDevice.BOND_NONE -> "none"
                else -> null
            }
        } catch (e: SecurityException) {
            null // BLUETOOTH_CONNECT not granted yet; state is display-only
        }
    }

    private fun remoteDevice(address: String): BluetoothDevice? {
        val adapter =
            (activity.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)
                ?.adapter ?: return null
        return try {
            adapter.getRemoteDevice(address.uppercase())
        } catch (e: IllegalArgumentException) {
            null
        }
    }

    // --- associate ---

    private fun associate(result: MethodChannel.Result) {
        val manager = manager
        if (manager == null) {
            result.error("unsupported", "CompanionDeviceManager unavailable", null)
            return
        }
        if (pendingAssociate != null) {
            result.error("busy", "Association already in progress", null)
            return
        }

        val filter = BluetoothLeDeviceFilter.Builder()
            .setScanFilter(
                ScanFilter.Builder()
                    .setServiceUuid(ParcelUuid.fromString(BOT_SERVICE_UUID))
                    .build())
            .build()
        val request = AssociationRequest.Builder()
            .addDeviceFilter(filter)
            .setSingleDevice(true)
            .build()

        pendingAssociate = result
        // The Handler overload is deprecated on API 33+ but is the only one
        // that exists below 33; the replacement Executor overload adds
        // nothing for us.
        @Suppress("DEPRECATION")
        manager.associate(request, object : CompanionDeviceManager.Callback() {
            // On API 33+ onAssociationPending's default implementation
            // delegates here, so this one override covers 29 through current.
            @Deprecated("Deprecated in API 33")
            override fun onDeviceFound(intentSender: IntentSender) {
                try {
                    activity.startIntentSenderForResult(
                        intentSender, REQUEST_CODE_ASSOCIATE, null, 0, 0, 0)
                } catch (e: Exception) {
                    Log.e(TAG, "launching CDM chooser failed", e)
                    finishAssociate { it.error("chooser", e.message, null) }
                }
            }

            override fun onFailure(error: CharSequence?) {
                Log.e(TAG, "association failed: $error")
                finishAssociate { it.error("associate", error?.toString(), null) }
            }
        }, Handler(Looper.getMainLooper()))
    }

    /** MainActivity forwards onActivityResult here. Returns true if consumed. */
    fun handleActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CODE_ASSOCIATE) return false

        if (resultCode != Activity.RESULT_OK) {
            Log.i(TAG, "association chooser canceled")
            finishAssociate { it.success(stateMap() + mapOf("canceled" to true)) }
            return true
        }

        val device = extractDevice(data)
        if (device == null) {
            Log.e(TAG, "chooser returned OK but no device extra")
            finishAssociate { it.error("associate", "No device in chooser result", null) }
            return true
        }

        Log.i(TAG, "associated with ${device.address}")

        // Pairing/bonding decision (a) from the brief: bond at association
        // time so the phone holds the IRK and CDM presence tracking can
        // resolve the bot's rotating random address. Recorded in
        // lib/shared/ble_protocol.dart.
        try {
            if (device.bondState == BluetoothDevice.BOND_NONE) {
                val started = device.createBond()
                Log.i(TAG, "createBond started=$started")
            }
        } catch (e: SecurityException) {
            Log.e(TAG, "createBond rejected (BLUETOOTH_CONNECT missing?)", e)
        }

        startObserving(device.address)
        finishAssociate { it.success(stateMap()) }
        return true
    }

    private fun extractDevice(data: Intent?): BluetoothDevice? {
        if (data == null) return null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val info = data.getParcelableExtra(
                CompanionDeviceManager.EXTRA_ASSOCIATION, AssociationInfo::class.java)
            val address = info?.deviceMacAddress?.toString() ?: return null
            return remoteDevice(address)
        }
        // Pre-33: EXTRA_DEVICE is a ScanResult for BLE filters (may be a
        // BluetoothDevice for classic ones — handle both).
        @Suppress("DEPRECATION")
        return when (val extra =
            data.getParcelableExtra<android.os.Parcelable>(CompanionDeviceManager.EXTRA_DEVICE)) {
            is ScanResult -> extra.device
            is BluetoothDevice -> extra
            else -> null
        }
    }

    private fun finishAssociate(complete: (MethodChannel.Result) -> Unit) {
        val pending = pendingAssociate ?: return
        pendingAssociate = null
        complete(pending)
    }

    // --- presence observation (API 31+) ---

    private fun startObserving(address: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            Log.i(TAG, "presence observation unsupported below API 31; skipping")
            return
        }
        try {
            @Suppress("DEPRECATION") // String overload; replacement is API 36+
            manager?.startObservingDevicePresence(address)
            Log.i(TAG, "observing device presence for $address")
        } catch (e: Exception) {
            // e.g. DeviceNotAssociatedException; log, feature degrades.
            Log.e(TAG, "startObservingDevicePresence failed", e)
        }
    }

    /**
     * Re-arms observation for every association. Called from getState on
     * each app open: registration normally persists, but re-registering is
     * idempotent and covers package-update edge cases.
     */
    private fun ensureObservingIfAssociated() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
        for (address in associatedAddresses()) {
            startObserving(address)
        }
    }

    // --- disassociate ---

    private fun disassociate(result: MethodChannel.Result) {
        val manager = manager
        if (manager == null) {
            result.error("unsupported", "CompanionDeviceManager unavailable", null)
            return
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                for (info in manager.myAssociations) {
                    stopObserving(info.deviceMacAddress?.toString())
                    manager.disassociate(info.id)
                }
            } else {
                @Suppress("DEPRECATION")
                for (address in manager.associations.toList()) {
                    stopObserving(address)
                    @Suppress("DEPRECATION")
                    manager.disassociate(address)
                }
            }
            // Note: the bond itself is not removed — Android has no public
            // API for that. The user can forget the device in Bluetooth
            // settings; a stale bond is harmless to us.
            result.success(stateMap())
        } catch (e: Exception) {
            Log.e(TAG, "disassociate failed", e)
            result.error("disassociate", e.message, null)
        }
    }

    private fun stopObserving(address: String?) {
        if (address == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
        try {
            @Suppress("DEPRECATION")
            manager?.stopObservingDevicePresence(address)
        } catch (e: Exception) {
            Log.w(TAG, "stopObservingDevicePresence failed: ${e.message}")
        }
    }
}
