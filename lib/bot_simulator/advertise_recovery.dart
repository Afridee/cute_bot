/// How the peripheral recovers connectable advertising after a central drops.
///
/// Android stops connectable ads the moment a central attaches, and a single
/// `startAdvertising` on the disconnect callback often fails while the ACL
/// (and a bonded ghost connection) is still tearing down. Toggling Bluetooth
/// works because it closes the GATT server and republishes. This policy is
/// that recovery, without the user: retry ads with backoff, then rebuild
/// the GATT database the same way a radio cycle does.
library;

/// Consecutive failed advertise attempts before we tear down and republish
/// GATT services ([AdvertiseRecoveryAction.republishServices]).
const int kAdvertiseFailuresBeforeRepublish = 3;

/// First wait after a disconnect, before the stack has finished teardown.
const Duration kAdvertiseResumeDelay = Duration(milliseconds: 400);

/// Cap on the exponential backoff between advertise retries.
const Duration kAdvertiseMaxBackoff = Duration(seconds: 8);

/// If ads claim to be running after a drop but nobody attaches, cycle
/// them. Long enough that a companion mid-scan is not interrupted; short
/// enough that a ghost GATT session is rebuilt before the FGS returns.
const Duration kIdleAdvertiseRefresh = Duration(seconds: 45);

enum AdvertiseRecoveryAction {
  /// `stopAdvertising` + `startAdvertising` only.
  retryAdvertise,

  /// `removeAllServices` + re-add + advertise. Same effect as a BT toggle.
  republishServices,
}

/// Delay before advertise attempt [failedAttempts] (0 = first try after drop).
Duration advertiseRetryDelay(int failedAttempts) {
  final shift = failedAttempts.clamp(0, 5);
  final millis = kAdvertiseResumeDelay.inMilliseconds * (1 << shift);
  if (millis > kAdvertiseMaxBackoff.inMilliseconds) {
    return kAdvertiseMaxBackoff;
  }
  return Duration(milliseconds: millis);
}

/// After [kAdvertiseFailuresBeforeRepublish] misses, rebuild the GATT server
/// instead of only poking the advertiser. Repeats every N failures so a
/// wedged radio cannot stay dark until the user toggles Bluetooth.
AdvertiseRecoveryAction advertiseRecoveryAction(int failedAttempts) {
  if (failedAttempts > 0 &&
      failedAttempts % kAdvertiseFailuresBeforeRepublish == 0) {
    return AdvertiseRecoveryAction.republishServices;
  }
  return AdvertiseRecoveryAction.retryAdvertise;
}
