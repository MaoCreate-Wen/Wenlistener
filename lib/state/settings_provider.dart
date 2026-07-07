import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/play_url.dart';
import '../models/song.dart';
import '../services/audio_service.dart';
import '../services/music_api_router.dart';
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
  })  : _router = router,
        _store = store,
        _audio = audio,
        _source = source,
        _rhythmEnabled = rhythmEnabled,
        _audioQuality = audioQuality {
    _audio?.audioLevel = audioQuality; // apply the restored preference at startup
  }

  final MusicApiRouter _router;
  final SettingsStore _store;
  final AudioService? _audio;
  MusicSource _source;
  bool _rhythmEnabled;
  AudioLevel _audioQuality;

  MusicSource get source => _source;

  /// Whether the lyrics-page background reacts to the music. When off, the mesh
  /// still flows gently but never pulses with the beat, and the lyrics page does
  /// not start the FFT (so it never asks for / holds the microphone).
  bool get rhythmEnabled => _rhythmEnabled;

  /// Preferred playback audio quality. Pushed into [AudioService] so newly-
  /// resolved tracks fetch this level (already-playing/cached URLs keep theirs).
  AudioLevel get audioQuality => _audioQuality;

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

  Future<void> _persist() => _store.save(
        source: _source,
        rhythmEnabled: _rhythmEnabled,
        audioQuality: _audioQuality,
      );
}
