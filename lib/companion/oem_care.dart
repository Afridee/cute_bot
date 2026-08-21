// Dart face of OemCareHandler.kt: who made this phone, did the service die
// behind our back, and is our notification listener enabled?
//
// Why this exists: on the iQOO Neo 10, vivo's cleaner FORCE-STOPS the app
// (ApplicationExitInfo: "stop ... due to single-cleaner") — even swiping the
// app from Recents does it, and a locked Recents card does not stop an
// individual swipe. A force-stopped app is beyond every resurrection path we
// own — sticky FGS restart, the watchdog, CDM presence — until something
// EXTERNAL re-enters the process. The one external path that works is
// Notification access: system_server persistently binds an enabled
// NotificationListenerService and re-binds it after the kill, restarting our
// process, whereupon the listener revives the foreground service (verified:
// this is exactly how Nothing X survives the same cleaner). The vivo settings
// (autostart, background power, Recents lock) remain useful hardening, so
// the guidance page teaches both — notification access first.

import 'package:flutter/services.dart';

import '../shared/log.dart';

const String _tag = 'OemCare';

final class OemDiagnostics {
  const OemDiagnostics({
    required this.manufacturer,
    required this.brand,
    required this.serviceDiedUnexpectedly,
    required this.notificationAccessGranted,
  });

  final String manufacturer;
  final String brand;

  /// The service was at some point observed dead while it should have been
  /// running — the signature of an OEM cleaner force-stop. Sticky on the
  /// native side (BotServiceStarter.checkUnexpectedDeath): the watchdog can
  /// revive the service before the UI looks, so a live check would miss.
  final bool serviceDiedUnexpectedly;

  /// Our CuteBotNotificationListenerService is enabled in the system's
  /// Notification access settings — which both powers "phone alerts on bot"
  /// and makes the OS re-bind (and thus revive) us after cleaner kills.
  final bool notificationAccessGranted;

  /// OEMs whose stock cleaner force-stops backgrounded apps, defeating a
  /// foreground service outright. Only the vivo family (vivo/iQOO) is listed
  /// because that is what the guidance page's steps are written for.
  bool get isAggressiveOem {
    final m = manufacturer.toLowerCase();
    final b = brand.toLowerCase();
    return m == 'vivo' || b == 'vivo' || b == 'iqoo';
  }
}

abstract final class OemCare {
  static const MethodChannel _channel =
      MethodChannel('com.cutebot.cute_bot/oem_care');

  /// Null on any failure (e.g. non-Android platforms — iOS is unsupported
  /// by design, but don't crash the companion bring-up over diagnostics).
  static Future<OemDiagnostics?> diagnostics() async {
    try {
      final raw =
          await _channel.invokeMethod<Map<Object?, Object?>>('getDiagnostics');
      if (raw == null) return null;
      return OemDiagnostics(
        manufacturer: raw['manufacturer'] as String? ?? '',
        brand: raw['brand'] as String? ?? '',
        serviceDiedUnexpectedly: raw['unexpectedDeath'] == true,
        notificationAccessGranted: raw['notificationAccess'] == true,
      );
    } catch (e) {
      Log.w(_tag, 'diagnostics failed: $e');
      return null;
    }
  }

  /// Opens the system Notification access screen (app-specific detail page
  /// where the OS supports it). Returns false if no settings screen opened.
  static Future<bool> openNotificationAccessSettings() async {
    try {
      return await _channel
              .invokeMethod<bool>('openNotificationAccessSettings') ??
          false;
    } catch (e) {
      Log.w(_tag, 'openNotificationAccessSettings failed: $e');
      return false;
    }
  }
}
