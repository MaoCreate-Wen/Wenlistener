import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/play_url.dart';
import '../models/song.dart';
import '../services/audio_service.dart';
import '../services/music_api_router.dart';
import '../services/resource_cache.dart';
import '../services/settings_store.dart';

/// User settings (the music [source] and the lyrics-page background 律动 toggle),
/// persisted via [SettingsStore].
///
/// The [setSource] setter drives the live [MusicApiRouter] AND persists, so the
/// settings switcher and the runtime backend never diverge (the router stays the
/// single runtime source of truth; this only owns the *persisted preference* and
/// mirrors it in). Built in `main.dart` from the loaded [SettingsData].
class SettingsProvider extends ChangeNotifier {
  SettingsProvider({
    required MusicApiRouter router,
    required SettingsStore store,
    required MusicSource source,
    required bool rhythmEnabled,
    AudioService? audio,
    AudioLevel audioQuality = AudioLevel.exhigh,
    CloseBehavior closeBehavior = CloseBehavior.minimizeToTray,
    int? cacheMaxBytes,
  })  : _router = router,
        _store = store,
        _audio = audio,
        _source = source,
        _rhythmEnabled = rhythmEnabled,
        _audioQuality = audioQuality,
        _closeBehavior = closeBehavior,
        _cacheMaxBytes = cacheMaxBytes ?? kCacheMaxBytesDefault {
    _audio?.audioLevel = audioQuality; // apply the restored preference at startup
    // Push the (restored or default) cache budget into the live cache. When the
    // caller didn't thread the persisted value through (main constructs this
    // provider field-by-field), restore it here from the store — one extra tiny
    // settings.json read at startup, and main.dart needs no new wiring.
    ResourceCache.instance.maxBytes = _cacheMaxBytes;
    if (cacheMaxBytes == null) unawaited(_restoreCacheMaxBytes());
  }

  final MusicApiRouter _router;
  final SettingsStore _store;
  final AudioService? _audio;
  MusicSource _source;
  bool _rhythmEnabled;
  AudioLevel _audioQuality;
  CloseBehavior _closeBehavior;
  int _cacheMaxBytes;

  MusicSource get source => _source;

  /// Whether the lyrics-page background reacts to the music. When off, the mesh
  /// still flows gently but never pulses with the beat, and the lyrics page does
  /// not start the FFT (so it never asks for / holds the microphone).
  bool get rhythmEnabled => _rhythmEnabled;

  /// Preferred playback audio quality. Pushed into [AudioService] so newly-
  /// resolved tracks fetch this level (already-playing/cached URLs keep theirs).
  AudioLevel get audioQuality => _audioQuality;

  /// What the window ✕ does (直接退出 / 最小化到托盘). Read live by the tray
  /// controller's `onWindowClose` — no restart needed after changing it.
  CloseBehavior get closeBehavior => _closeBehavior;

  /// Disk-cache budget (bytes) for covers/lyrics — mirrored into
  /// [ResourceCache.maxBytes] so eviction reacts immediately.
  int get cacheMaxBytes => _cacheMaxBytes;

  void setSource(MusicSource s) {
    if (_source == s) return;
    _source = s;
    _router.setSource(s); // live backend switch (reloads feeds via its listeners)
    notifyListeners();
    unawaited(_persist());
  }

  void setRhythmEnabled(bool v) {
    if (_rhythmEnabled == v) return;
    _rhythmEnabled = v;
    notifyListeners();
    unawaited(_persist());
  }

  void setAudioQuality(AudioLevel q) {
    if (_audioQuality == q) return;
    _audioQuality = q;
    _audio?.audioLevel = q; // takes effect on the next track resolved
    notifyListeners();
    unawaited(_persist());
  }

  void setCloseBehavior(CloseBehavior b) {
    if (_closeBehavior == b) return;
    _closeBehavior = b;
    notifyListeners();
    unawaited(_persist());
  }

  void setCacheMaxBytes(int bytes) {
    if (bytes <= 0 || _cacheMaxBytes == bytes) return;
    _cacheMaxBytes = bytes;
    ResourceCache.instance.maxBytes = bytes; // live: schedules an LRU pass
    notifyListeners();
    unawaited(_persist());
  }

  /// Startup restore of the persisted cache budget (ctor got no explicit value —
  /// see the ctor comment). Runs once, milliseconds after construction.
  Future<void> _restoreCacheMaxBytes() async {
    final SettingsData data = await _store.load();
    if (data.cacheMaxBytes == _cacheMaxBytes) return;
    _cacheMaxBytes = data.cacheMaxBytes;
    ResourceCache.instance.maxBytes = data.cacheMaxBytes;
    notifyListeners();
  }

  Future<void> _persist() => _store.save(
        source: _source,
        rhythmEnabled: _rhythmEnabled,
        audioQuality: _audioQuality,
        closeBehavior: _closeBehavior,
        cacheMaxBytes: _cacheMaxBytes,
      );
}
