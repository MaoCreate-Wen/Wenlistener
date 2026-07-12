import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart' hide RepeatMode;

import '../models/lyric_line.dart';
import '../models/song.dart';
import '../services/artwork_palette.dart';
import '../services/audio_service.dart';
import '../services/music_api.dart';
import '../theme/app_colors.dart';

/// Page-facing playback state. Subscribes to [AudioService.snapshots]; on each
/// song change it fetches lyrics and extracts the dynamic palette, and it
/// derives [activeLyricIndex] from the live position.
class PlayerProvider extends ChangeNotifier {
  final AudioService audio;
  final MusicApi api;
  final ArtworkPalette palette;

  /// Optional low-frequency (bass) volume signal supplied by the orchestrator in
  /// main(); plumbed through to the lyrics page's NeonFlowBackground so the flow
  /// can pulse to the beat. This provider only stores and re-exposes it.
  final ValueListenable<double>? _lowFreqVolume;

  late final StreamSubscription<PlaybackSnapshot> _snapshotSub;
  late final StreamSubscription<int?> _indexSub;
  late final StreamSubscription<String?> _errorSub;

  PlayerProvider({
    required this.audio,
    required this.api,
    required this.palette,
    ValueListenable<double>? lowFreqVolume,
  }) : _lowFreqVolume = lowFreqVolume {
    _snapshotSub = audio.snapshots.listen(_onSnapshot);
    _indexSub = audio.currentIndexStream.listen(_onIndexChanged);
    _errorSub = audio.errors.listen(_onPlaybackError);
    // Seed from the already-restored AudioService (built before this provider in
    // main()) so a restored, paused session shows in the mini player at once.
    // The restore emits on broadcast streams before we subscribe, so those
    // emissions are missed — hence the manual seed.
    _queue = audio.queue;
    _currentIndex = audio.currentIndex;
    _repeatMode = audio.repeatMode;
    _shuffle = audio.shuffleEnabled;
    _position = audio.position;
    // That missed index emission also means _onIndexChanged never fired for the
    // restored track, so its lyrics + palette would otherwise stay blank until
    // the first play. Kick the load once now — lyric fetch + artwork palette
    // only, no songUrl/audio, so cold start stays network-light. Deferred to a
    // microtask so the load's notifyListeners runs after construction; the
    // _extrasSongId dedupe makes the first-play index re-emit a harmless no-op.
    scheduleMicrotask(() => unawaited(_maybeLoadExtras(currentSong)));
  }

  List<Song> _queue = <Song>[];
  int? _currentIndex;
  bool _playing = false;
  bool _buffering = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  RepeatMode _repeatMode = RepeatMode.off;
  bool _shuffle = false;
  double _volume = 1.0;
  String? _playbackError;

  Color _dynamicAccent = AppColors.accentPlay;
  Gradient _dynamicGradient = PaletteResult.fallback.gradient;
  List<Color> _paletteColors = const <Color>[];

  // The home/shell background wash is decided **once** — from the first track
  // whose palette resolves this session — then frozen, so the feed doesn't
  // re-tint on every song change. [dynamicGradient] still tracks live for any
  // surface that wants the current track's colours.
  Gradient _washGradient = PaletteResult.fallback.gradient;
  bool _washLocked = false;

  Lyrics _lyrics = Lyrics.empty;
  bool _lyricsLoading = false;
  int _activeLyricIndex = -1;

  // Lyric-load robustness. [_lyricRequest] is a per-load token so a stale/late
  // load (the same song id can load twice on A→B→A) can't clobber a fresh one;
  // [_lyricsSettled] marks a *definitive* result (real lyrics, or a clean "this
  // track has none") so a transient fetch failure is never shown as "No lyrics";
  // [_lyricRetries] bounds the self-healing retry.
  int _lyricRequest = 0;
  bool _lyricsSettled = false;
  int _lyricRetries = 0;

  final Set<int> _liked = <int>{};
  int? _extrasSongId;
  Timer? _paletteDebounce;

  // --- getters -------------------------------------------------------------
  List<Song> get queue => _queue;
  int? get currentIndex => _currentIndex;
  Song? get currentSong =>
      (_currentIndex != null && _currentIndex! >= 0 && _currentIndex! < _queue.length)
          ? _queue[_currentIndex!]
          : null;
  bool get hasSong => currentSong != null;
  bool get isPlaying => _playing;
  bool get isBuffering => _buffering;
  Duration get position => _position;

  /// Effective track length. Streamed sources (Migu 302→CDN mp3, some Netease
  /// URLs) often don't report a decoder duration, leaving the audio duration at
  /// zero; fall back to the dt-derived [Song.duration] so the scrubber and
  /// remaining-time labels still advance from t=0.
  Duration get duration {
    if (_duration.inMilliseconds > 0) return _duration;
    final Duration songDuration = currentSong?.duration ?? Duration.zero;
    return songDuration.inMilliseconds > 0 ? songDuration : _duration;
  }

  double get progress {
    final int total = duration.inMilliseconds;
    return total <= 0
        ? 0.0
        : (_position.inMilliseconds / total).clamp(0.0, 1.0);
  }
  RepeatMode get repeatMode => _repeatMode;
  bool get shuffleEnabled => _shuffle;
  double get volume => _volume;
  Color get dynamicAccent => _dynamicAccent;
  Gradient get dynamicGradient => _dynamicGradient;

  /// Frozen background wash for the home/shell — decided once (see [_washGradient]).
  Gradient get washGradient => _washGradient;
  List<Color> get paletteColors => _paletteColors;
  Lyrics get lyrics => _lyrics;
  bool get lyricsLoading => _lyricsLoading;

  /// True once the current track's lyrics have a *definitive* result (fetched
  /// lyrics, or a clean "this track has none"). While false, a transient failure
  /// is being retried and the view should keep a spinner rather than show the
  /// "No lyrics" empty state.
  bool get lyricsSettled => _lyricsSettled;
  int get activeLyricIndex => _activeLyricIndex;
  bool get isLiked => currentSong != null && _liked.contains(currentSong!.id);

  /// Optional bass / low-frequency volume signal supplied at construction; the
  /// lyrics page forwards it to its NeonFlowBackground. Null when no FFT source
  /// is wired.
  ValueListenable<double>? get lowFreqVolume => _lowFreqVolume;

  /// Transient, user-facing message when a track/queue can't be played (VIP /
  /// login required). The UI surfaces it then calls [clearPlaybackError]; it is
  /// also cleared automatically on the next successful load.
  String? get playbackError => _playbackError;

  // --- commands ------------------------------------------------------------
  Future<void> playSong(Song song, {List<Song>? queue, int index = 0}) async {
    if (queue != null && queue.isNotEmpty) {
      await playQueue(queue, index: index);
    } else {
      await playQueue(<Song>[song]);
    }
  }

  Future<void> playQueue(List<Song> songs, {int index = 0}) async {
    if (songs.isEmpty) return;
    _queue = List<Song>.of(songs);
    _currentIndex = index.clamp(0, _queue.length - 1);
    notifyListeners();
    await audio.setQueue(songs, initialIndex: index);
  }

  Future<void> togglePlay() => audio.togglePlay();
  Future<void> next() => audio.next();
  Future<void> previous() => audio.previous();
  Future<void> seek(Duration position) => audio.seek(position);

  /// Re-attempts a lyric fetch for the current track when there are no lines on
  /// screen and none is in flight — e.g. the user re-opened /lyrics or returned
  /// from the background after an earlier transient failure. No-op once lyrics
  /// are present or a load is already running.
  void retryLyrics() {
    final Song? song = currentSong;
    // Only when we have no lyrics, none is loading, and the result isn't already
    // definitive (a genuine instrumental stays empty; an exhausted-retry failure
    // re-fetches on the next track change instead of on every re-open).
    if (song == null ||
        _lyricsSettled ||
        _lyrics.lines.isNotEmpty ||
        _lyricsLoading) {
      return;
    }
    _lyricRetries = 0;
    unawaited(_loadLyrics(song));
  }

  /// Jumps to an existing [index] in the current queue without rebuilding the
  /// audio source (no re-resolve / reload flash) — see [AudioService.jumpTo].
  /// Optimistically advances the highlight + now-playing so the UI reacts on
  /// tap; the native index stream still drives [_onIndexChanged] (lyrics /
  /// palette) once the seek lands.
  Future<void> jumpTo(int index) async {
    if (index < 0 || index >= _queue.length) return;
    if (_currentIndex != index) {
      _currentIndex = index;
      notifyListeners();
    }
    await audio.jumpTo(index);
  }

  Future<void> cycleRepeat() async {
    _repeatMode = RepeatMode.values[(_repeatMode.index + 1) % RepeatMode.values.length];
    await audio.setRepeatMode(_repeatMode);
    notifyListeners();
  }

  Future<void> toggleShuffle() async {
    _shuffle = !_shuffle;
    await audio.setShuffle(_shuffle);
    notifyListeners();
  }

  void toggleLike() {
    final Song? song = currentSong;
    if (song == null) return;
    setLiked(song, !_liked.contains(song.id));
  }

  /// Whether a *specific* [song] is liked (not necessarily the current one).
  bool isLikedSong(Song song) => _liked.contains(song.id);

  /// Sets the liked flag for a *specific* [song]. Used by the player's like
  /// action so an optimistic flip and its on-failure revert both target the
  /// captured song even if the queue auto-advanced during the network
  /// round-trip (otherwise the revert would flip whatever is current now).
  void setLiked(Song song, bool liked) {
    final bool changed = liked ? _liked.add(song.id) : _liked.remove(song.id);
    if (changed) notifyListeners();
  }

  /// Seeds the liked set from ids already in the user's liked playlist, so the
  /// heart lights for songs liked in a previous session — the in-memory [_liked]
  /// otherwise starts empty each launch. Merges (never clears) and notifies only
  /// when something new lands, which also re-syncs the notification heart via the
  /// app's notification bridge. Wired from app.dart once the liked playlist's
  /// tracks are known.
  void markLiked(Iterable<int> ids) {
    bool changed = false;
    for (final int id in ids) {
      if (_liked.add(id)) changed = true;
    }
    if (changed) notifyListeners();
  }

  Future<void> setVolume(double value) async {
    _volume = value.clamp(0.0, 1.0);
    await audio.setVolume(_volume);
    notifyListeners();
  }

  /// Clears the current [playbackError] (call after surfacing it to the user).
  void clearPlaybackError() {
    if (_playbackError == null) return;
    _playbackError = null;
    notifyListeners();
  }

  void _onPlaybackError(String? message) {
    if (_playbackError == message) return;
    _playbackError = message;
    notifyListeners();
  }

  // --- stream handlers -----------------------------------------------------
  void _onSnapshot(PlaybackSnapshot s) {
    bool changed = false;
    if (_playing != s.playing) {
      _playing = s.playing;
      changed = true;
    }
    if (_buffering != s.buffering) {
      _buffering = s.buffering;
      changed = true;
    }
    if (_position != s.position) {
      _position = s.position;
      changed = true;
    }
    if (_duration != s.duration) {
      _duration = s.duration;
      changed = true;
    }
    final int newActive = _lyrics.indexAt(_position);
    if (newActive != _activeLyricIndex) {
      _activeLyricIndex = newActive;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  void _onIndexChanged(int? index) {
    // No notifyListeners() here: the on-tap path (jumpTo) already optimistically
    // set _currentIndex and notified, and every other index move (auto-advance,
    // next/previous) is accompanied by a PlaybackSnapshot whose _onSnapshot
    // notify carries the new index to the UI. Notifying again here would be a
    // duplicate that re-renders the page a second time on every track change.
    _currentIndex = index;
    _maybeLoadExtras(currentSong);
  }

  Future<void> _maybeLoadExtras(Song? song) async {
    if (song == null) return;
    if (song.id == _extrasSongId) return;
    _extrasSongId = song.id;
    _activeLyricIndex = -1;
    _lyricsSettled = false;
    _lyricRetries = 0;
    unawaited(_loadLyrics(song));
    // Debounce the palette extract (~150ms): a fast run of queue switches would
    // otherwise kick off an artwork decode + colour-quantize per song. Coalesce
    // to the last switch; the _extrasSongId guard inside _loadPalette still drops
    // any result that is no longer current when the decode finishes.
    _paletteDebounce?.cancel();
    _paletteDebounce = Timer(
      const Duration(milliseconds: 150),
      () => unawaited(_loadPalette(song)),
    );
  }

  Future<void> _loadLyrics(Song song) async {
    final int req = ++_lyricRequest;
    // Keep the current lyrics on screen across a song-to-song switch and swap in
    // the new ones with a single notify when they arrive (AMLL replaces lines in
    // place, never flashing a spinner). Only enter the loading state — which the
    // view renders as a full-screen spinner — on a first-ever load, when there
    // are no lyrics to show yet.
    if (_lyrics.lines.isEmpty) {
      _lyricsLoading = true;
      notifyListeners();
    }
    try {
      final Lyrics lyrics = await api.lyric(song);
      // Drop a stale/superseded result (track changed, or a newer load started).
      if (req != _lyricRequest || song.id != _extrasSongId) return;
      _lyrics = lyrics; // definitive — may legitimately be empty (instrumental)
      _lyricsSettled = true;
      _lyricsLoading = false;
      _activeLyricIndex = _lyrics.indexAt(_position);
      notifyListeners();
    } catch (e) {
      debugPrint('PlayerProvider lyric load failed: $e');
      if (req != _lyricRequest || song.id != _extrasSongId) return;
      if (_lyricRetries < 3) {
        // A transient fetch failure is NOT "no lyrics": don't cache empty and
        // don't settle — leave any prior lines up, drop the spinner, and retry
        // with backoff so one network blip doesn't stick as "No lyrics".
        _lyricRetries++;
        final int attempt = _lyricRetries;
        _lyricsLoading = false;
        notifyListeners();
        Future<void>.delayed(Duration(milliseconds: 500 * attempt), () {
          if (req == _lyricRequest &&
              song.id == _extrasSongId &&
              !_lyricsSettled) {
            unawaited(_loadLyrics(song));
          }
        });
      } else {
        // Retries exhausted → give up and settle empty so the view shows the
        // "No lyrics" state instead of spinning forever.
        _lyrics = Lyrics.empty;
        _lyricsSettled = true;
        _lyricsLoading = false;
        _activeLyricIndex = -1;
        notifyListeners();
      }
    }
  }

  Future<void> _loadPalette(Song song) async {
    final PaletteResult result = await palette.extract(song.artworkUrl);
    if (song.id != _extrasSongId) return;
    _dynamicAccent = result.accent;
    _dynamicGradient = result.gradient;
    _paletteColors = result.colors;
    // Lock the home wash to the first track's palette, then never re-tint it.
    if (!_washLocked) {
      _washGradient = result.gradient;
      _washLocked = true;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _snapshotSub.cancel();
    _indexSub.cancel();
    _errorSub.cancel();
    _paletteDebounce?.cancel();
    super.dispose();
  }
}
