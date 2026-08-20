// Dart side of the CompanionDeviceManager association (M2.5). Thin
// wrapper over the "companion_link" MethodChannel implemented in
// CompanionLinkHandler.kt — the native side owns all CDM logic; this class
// only holds UI-facing state.
//
// Why this exists (topology recap): our phone is the BLE *central*, so a
// dead app means nobody initiates the connection — ACL broadcast receivers
// can't wake us the way they wake Nothing X. The Android-sanctioned answer
// for centrals is a CDM association: after the user links the bot once,
// Android itself watches for it (API 31+) and binds BotPresenceService when
// it comes into range, resurrecting the foreground service even from a dead
// process. Association also grants the CDM exemption for starting an FGS
// from the background on Android 12+.
//
// UI-isolate only: the chooser needs an Activity, so none of this is
// callable from the service isolate (same constraint as BLE authorize()).

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../shared/log.dart';

const String _tag = 'CompanionDeviceLink';

/// Association/observation state as reported by the native side.
final class CompanionLinkState {
  const CompanionLinkState({
    required this.presenceSupported,
    required this.associated,
    required this.addresses,
    this.bondState,
  });

  /// False on API 29–30: association works, wake-on-approach does not.
  final bool presenceSupported;
  final bool associated;
  final List<String> addresses;

  /// "bonded" / "bonding" / "none", or null when unknown.
  final String? bondState;

  static CompanionLinkState fromMap(Object? raw) {
    if (raw is! Map) return const CompanionLinkState.unknown();
    return CompanionLinkState(
      presenceSupported: raw['presenceSupported'] == true,
      associated: raw['associated'] == true,
      addresses: [
        if (raw['addresses'] is List)
          for (final a in raw['addresses'] as List)
            if (a is String) a,
      ],
      bondState: raw['bondState'] is String ? raw['bondState'] as String : null,
    );
  }

  const CompanionLinkState.unknown()
      : presenceSupported = false,
        associated = false,
        addresses = const [],
        bondState = null;
}

final class CompanionDeviceLink extends ChangeNotifier {
  static const MethodChannel _channel =
      MethodChannel('com.cutebot.cute_bot/companion_link');

  CompanionLinkState state = const CompanionLinkState.unknown();

  /// True while the CDM chooser is up.
  bool associating = false;

  String? lastError;

  /// Reads current state; also re-arms presence observation natively.
  Future<void> refresh() async {
    try {
      final raw = await _channel.invokeMethod<Object>('getState');
      state = CompanionLinkState.fromMap(raw);
      lastError = null;
    } on PlatformException catch (e) {
      lastError = e.message ?? e.code;
      Log.e(_tag, 'getState failed', e);
    } on MissingPluginException {
      // Non-Android host (tests); feature simply absent.
      state = const CompanionLinkState.unknown();
    }
    notifyListeners();
  }

  /// Launches the CDM chooser. Resolves when the user confirms or cancels.
  Future<void> associate() async {
    if (associating) return;
    associating = true;
    lastError = null;
    notifyListeners();
    try {
      final raw = await _channel.invokeMethod<Object>('associate');
      state = CompanionLinkState.fromMap(raw);
      if (raw is Map && raw['canceled'] == true) {
        Log.i(_tag, 'association canceled by user');
      } else {
        Log.i(_tag, 'associated: ${state.addresses}');
      }
    } on PlatformException catch (e) {
      lastError = e.message ?? e.code;
      Log.e(_tag, 'associate failed', e);
    } finally {
      associating = false;
      notifyListeners();
    }
  }

  Future<void> disassociate() async {
    try {
      final raw = await _channel.invokeMethod<Object>('disassociate');
      state = CompanionLinkState.fromMap(raw);
      lastError = null;
      Log.i(_tag, 'association removed');
    } on PlatformException catch (e) {
      lastError = e.message ?? e.code;
      Log.e(_tag, 'disassociate failed', e);
    }
    notifyListeners();
  }
}
