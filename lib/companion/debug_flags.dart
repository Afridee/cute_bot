/// Companion debug switches. Flip these and rebuild — they are not
/// persisted. Runtime toggles (where they exist) still override for the
/// current service lifetime.

/// Play bot-mic audio on the companion speaker as it arrives (M1 uplink
/// debug). Off by default — talking to the bot otherwise echoes on the
/// phone. Flip this, or the Audio → Live toggle, when diagnosing the
/// BLE receive path.
const bool kLiveMonitorDefault = false;
