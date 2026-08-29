/// Persisted [FastIntentOverlay] (ASR enrollment).
///
/// Same [KeyValueStore] as the transcript and timers. Load once at service
/// start; reload after enrollment save. Missing key = today's matcher.
library;

import '../brain/fast_intent_overlay.dart';
import '../brain/transcript.dart';

final class FastIntentStore {
  FastIntentStore(this._store);

  static const String storageKey = 'fast_intent_overlay_v1';

  final KeyValueStore _store;
  FastIntentOverlay? _overlay;

  FastIntentOverlay? get overlay => _overlay;

  bool get hasOverlay => _overlay != null;

  Future<FastIntentOverlay?> load() async {
    final raw = await _store.read(storageKey);
    _overlay = FastIntentOverlay.decode(raw);
    return _overlay;
  }

  Future<void> save(FastIntentOverlay overlay) async {
    _overlay = overlay;
    await _store.write(storageKey, overlay.encode());
  }

  Future<void> clear() async {
    _overlay = null;
    await _store.remove(storageKey);
  }
}
