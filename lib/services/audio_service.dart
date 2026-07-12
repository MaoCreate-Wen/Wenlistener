import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:just_audio/just_audio.dart';

import '../models/play_url.dart';
import '../models/song.dart';
import 'music_api.dart';
import 'playback_store.dart';
import 'resolving_audio_source.dart';

enum RepeatMode { off, all, one }

/// Immutable view of the player state, emitted on [AudioService.snapshots].
class PlaybackSnapshot {
  final bool playing;
  final bool buffering;
  final Duration position;
  final Duration duration;
  final int? index;

  const PlaybackSnapshot({
    this.playing = false,
    this.buffering = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.index,
  });
}

/// just_audio wrapper that owns the queue. The whole queue is fed to the player
/// as a [ConcatenatingAudioSource] of [ResolvingAudioSource] children, so
/// just_audio (and the audio_service notification) see a real multi-item
/// sequence — that
/// is what lights up the notification's previous/next controls and drives native
/// auto-advance, repeat-all wrap, and shuffle. Each child resolves its play URL
/// lazily (at play time) via [MusicApi.songUrl] (Migu or Netease).
class AudioService with WidgetsBindingObserver {
  final MusicApi api;
  final PlaybackStore? _store;

  final AudioPlayer _player;

  final StreamController<PlaybackSnapshot> _snapshots =
      StreamController<PlaybackSnapshot>.broadcast();
  final StreamController<int?> _indexController =
      StreamController<int?>.broadcast();
  final StreamController<String?> _errors =
      StreamController<String?>.broadcast();

  List<Song> _queue = <Song>[];
  int? _currentIndex;
  RepeatMode _repeatMode = RepeatMode.off;
  bool _shuffle = false;

  /// Preferred audio quality, set from the persisted setting (see
  /// [SettingsProvider]). Applies to tracks resolved AFTER a change (already-
  /// resolved URLs keep their quality until the next play / queue rebuild). Each
  /// backend maps it: Netease degrades from here, QQ picks FLAC/320/128 by it,
  /// Kugou/Migu ignore it.
  AudioLevel audioLevel = AudioLevel.exhigh;

  /// Consecutive unresolvable/unloadable tracks while skipping forward to a
  /// playable one. Reset on any successful load ([ProcessingState.ready]); once
  /// it reaches the queue length the whole queue is unplayable, so we surface
  /// [unplayableMessage] and stop instead of skipping forever. This is the
  /// tight-loop guard for the native skip chain (which wraps under repeat-all).
  int _consecutiveErrors = 0;

  /// Restore position stashed by [restore]; consumed (and cleared) on the first
  /// real [play] so a cold-started session does **zero** network until the user
  /// presses play. While set, it also stands in for the (unloaded) player
  /// position in [position] / [_push] and flags that a restore is still pending.
  Duration? _pendingStartPosition;

  /// Wall-clock of the last throttled persist from the position stream.
  int _lastPersistMs = 0;

  AudioService({
    required this.api,
    required AudioPlayer player,
    PlaybackStore? store,
  })  : _player = player,
        _store = store;

  Stream<PlaybackSnapshot> get snapshots => _snapshots.stream;
  Stream<int?> get currentIndexStream => _indexController.stream;

  /// Transient, user-facing playback errors (null clears the current one).
  /// Emitted when nothing in the queue can be resolved/loaded.
  Stream<String?> get errors => _errors.stream;
  int? get currentIndex => _currentIndex;

  // --- state mirrors consumed by PlayerProvider's restore-seeding ----------
  List<Song> get queue => List<Song>.unmodifiable(_queue);
  RepeatMode get repeatMode => _repeatMode;
  bool get shuffleEnabled => _shuffle;

  /// The pending restore position before the first load, else the live decoder
  /// position.
  Duration get position => _pendingStartPosition ?? _player.position;

  /// Message surfaced when no track in the queue can be resolved/loaded.
  static const String unplayableMessage = '无法播放（可能需要会员或登录）';

  Future<void> init() async {
    WidgetsBinding.instance.addObserver(this);
    _player.playerStateStream.listen((_) => _push());
    _player.positionStream.listen((_) => _push());
    _player.durationStream.listen((_) => _push());

    // The native queue index is the single source of truth for "current track
    // changed" — it fires for in-app prev/next, notification prev/next, and
    // automatic advance alike, driving the UI and PlayerProvider's lyric/palette
    // load (via _indexController → _onIndexChanged → _maybeLoadExtras).
    _player.currentIndexStream.listen((int? i) {
      if (i == null || i == _currentIndex) return;
      if (i < 0 || i >= _queue.length) return;
      _currentIndex = i;
      _indexController.add(i);
      _push();
      unawaited(_persist());
    });

    // A successful load clears the skip-error counter and any stale error banner.
    _player.processingStateStream.listen((ProcessingState state) {
      if (state == ProcessingState.ready) {
        _consecutiveErrors = 0;
        _errors.add(null);
      }
    });

    // A ResolvingAudioSource that can't resolve a URL (VIP / login-gated) throws
    // from request(); just_audio surfaces it as a player error here. Skip to the
    // next playable track, bounded by [_consecutiveErrors].
    _player.playbackEventStream.listen((_) {}, onError: (Object e) {
      debugPrint('AudioService: playback error: $e');
      // Defer the skip out of the playbackEventStream broadcast: calling
      // seekToNext() synchronously inside onError re-enters this same stream
      // and throws "Cannot fire new event. Controller is already firing an
      // event" (the storm seen on a queue switch). A microtask runs the
      // recovery after the current broadcast settles.
      scheduleMicrotask(() => unawaited(_onPlayerError()));
    });
  }

  void _push() {
    final ProcessingState ps = _player.processingState;
    _snapshots.add(PlaybackSnapshot(
      playing: _player.playing,
      buffering:
          ps == ProcessingState.loading || ps == ProcessingState.buffering,
      // While a restore is pending the player hasn't loaded yet, so stand in
      // with the saved position rather than the player's 0.
      position: _pendingStartPosition ?? _player.position,
      duration: _effectiveDuration,
      index: _currentIndex,
    ));
    _maybePersistThrottled();
  }

  /// The decoder duration when the source reports one, else the dt-derived
  /// [Song.duration] fallback — streamed/302 mp3 sources frequently leave
  /// `_player.duration` null, which would otherwise pin the scrubber at zero.
  Duration get _effectiveDuration {
    final Duration d = _player.duration ?? Duration.zero;
    if (d.inMilliseconds > 0) return d;
    final Duration songDuration = _currentSong?.duration ?? Duration.zero;
    return songDuration.inMilliseconds > 0 ? songDuration : d;
  }

  Song? get _currentSong {
    final int? i = _currentIndex;
    if (i == null || i < 0 || i >= _queue.length) return null;
    return _queue[i];
  }

  Future<void> setQueue(List<Song> songs, {int initialIndex = 0}) async {
    _pendingStartPosition = null; // a fresh queue supersedes any restore.
    _queue = List<Song>.of(songs);
    if (_queue.isEmpty) {
      _currentIndex = null;
      _indexController.add(null);
      await _player.stop();
      _push();
      return;
    }
    _consecutiveErrors = 0;
    await _setConcat(initialIndex.clamp(0, _queue.length - 1), autoPlay: true);
  }

  /// Restores a persisted [session] for cold start: rebuilds the queue / index /
  /// repeat / shuffle and stashes the saved position. The queue source is set
  /// with `preload: false`, so **no network and no playback** happen until the
  /// first [play] / [togglePlay] — `request()` is not called on any child yet.
  /// `initialIndex` / `initialPosition` make that first play resume the right
  /// track at the saved spot without a second load. We emit the index and one
  /// paused snapshot so the mini player shows the restored track immediately.
  Future<void> restore(PlaybackSession session) async {
    if (session.queue.isEmpty) return;
    _queue = List<Song>.of(session.queue);
    _currentIndex = session.currentIndex.clamp(0, _queue.length - 1);
    _repeatMode = RepeatMode
        .values[session.repeatIndex.clamp(0, RepeatMode.values.length - 1)];
    _shuffle = session.shuffle;
    _pendingStartPosition = Duration(milliseconds: session.positionMs);
    _consecutiveErrors = 0;

    await _player.setAudioSource(
      _buildConcat(),
      initialIndex: _currentIndex!,
      initialPosition: _pendingStartPosition!,
      preload: false, // defer request()/network to the first play.
    );
    await _player.setLoopMode(_loopModeFor(_repeatMode));
    await _player.setShuffleModeEnabled(_shuffle);

    _indexController.add(_currentIndex);
    _snapshots.add(PlaybackSnapshot(
      playing: false,
      position: _pendingStartPosition!,
      duration: _currentSong?.duration ?? Duration.zero,
      index: _currentIndex,
    ));
  }

  /// Builds the whole queue as a lazily-resolved [ConcatenatingAudioSource].
  /// `useLazyPreparation` (default true) keeps non-current children unprepared
  /// until just before they're needed, so URLs resolve at play time and never
  /// expire while still in the queue. Every child carries its [MediaItem] tag —
  /// WenAudioHandler mirrors these tags into the audio_service notification
  /// queue (and its prev/next controls).
  ConcatenatingAudioSource _buildConcat() => ConcatenatingAudioSource(
        children: <AudioSource>[
          for (final Song s in _queue)
            ResolvingAudioSource(
              song: s,
              resolve: (Song x) =>
                  api.songUrl(x, level: audioLevel).then((u) => u?.url),
              tag: _mediaItem(s),
            ),
        ],
      );

  /// Sets the concatenating queue source at [index] and (optionally) plays it.
  /// Shared by [setQueue]. A load failure of the initial item surfaces via
  /// [playbackEventStream] and is recovered by [_onPlayerError] (skip forward),
  /// so the await is guarded to avoid an uncaught exception escaping setQueue.
  Future<void> _setConcat(int index,
      {required bool autoPlay, Duration startAt = Duration.zero}) async {
    _currentIndex = index; // set first so the index-stream listener dedupes.
    try {
      await _player.setAudioSource(
        _buildConcat(),
        initialIndex: index,
        initialPosition: startAt,
        // just_audio_windows (Media Foundation) fix: when we're about to
        // autoplay, DON'T preload here. A play() issued right after a fully
        // preloaded source is silently dropped on Windows — the queue loads but
        // sits paused (the "must press the mini-player play button" bug). With
        // preload:false the following play() drives load+play as one coordinated
        // native request (the same path the restore→play flow uses), so audio
        // begins immediately and `playing` reflects true. Non-autoplay callers
        // (none today, but e.g. building a paused queue) keep eager preload.
        preload: !autoPlay,
      );
      // just_audio_windows (Media Foundation) IGNORES the ConcatenatingAudioSource
      // `initialIndex` on the autoplay (preload:false) path — the following play()
      // starts the sequence at item 0 regardless of which row was tapped (the
      // "always plays the first song" bug). Force the queue to the requested item
      // explicitly, exactly as jumpTo() does for an in-place row tap. Safe because
      // `_currentIndex` is already `index`, so the currentIndexStream listener
      // dedupes this seek's index event; we still emit it below for the lyric /
      // palette load. This targets the same index the source was built at, so the
      // eager-preload branch treats it as a no-op re-seek to position `startAt`.
      await _player.seek(startAt, index: index);
    } catch (e) {
      // The failing item re-surfaces via playbackEventStream → _onPlayerError,
      // which skips to the next playable track; nothing more to do here.
      debugPrint('AudioService: setAudioSource failed: $e');
    }
    _indexController.add(index);
    // Explicitly start playback so a queue built via setQueue/playQueue begins
    // at once (see the preload note above). play() is a no-op if already
    // playing, and sets `playing` true synchronously so the snapshot is correct.
    if (autoPlay) await _player.play();
    _push();
    unawaited(_persist());
  }

  LoopMode _loopModeFor(RepeatMode mode) {
    switch (mode) {
      case RepeatMode.one:
        return LoopMode.one;
      case RepeatMode.all:
        return LoopMode.all;
      case RepeatMode.off:
        return LoopMode.off;
    }
  }

  /// Builds the background [MediaItem] tag carried by every queue source.
  /// WenAudioHandler derives the notification (title / art) from these tags;
  /// every source must carry one.
  MediaItem _mediaItem(Song song) => MediaItem(
        id: song.id.toString(),
        title: song.name,
        artist: song.artistNames,
        album: song.album?.name,
        duration: song.duration,
        artUri: (song.artworkUrl != null && song.artworkUrl!.isNotEmpty)
            ? Uri.tryParse(song.artworkUrl!)
            : null,
      );

  Future<void> play() async {
    // First play after a cold-start restore: the source was set with
    // preload:false and an initialPosition, so play() loads and resumes at the
    // saved position with no second load. Consume the pending marker so the live
    // decoder position takes over the display (the player already reports the
    // saved position via the initialPosition broadcast, so no visible jump).
    final bool wasPendingRestore = _pendingStartPosition != null;
    _pendingStartPosition = null;
    await _player.play();
    // The restored index was emitted at restore time, before PlayerProvider
    // subscribed, and loading doesn't "change" it — so re-emit it now to trigger
    // the lazy lyrics/palette load (_onIndexChanged → _maybeLoadExtras).
    if (wasPendingRestore && _currentIndex != null) {
      _indexController.add(_currentIndex);
    }
  }

  Future<void> pause() async {
    await _player.pause();
    unawaited(_persist());
  }

  Future<void> togglePlay() {
    if (_pendingStartPosition != null && _currentIndex != null) {
      return play(); // deferred restore-load + play.
    }
    return _player.playing ? pause() : _player.play();
  }

  Future<void> seek(Duration position, {int? index}) async {
    // Before the first play of a restored session the queue source isn't loaded
    // yet; a real seek would discard just_audio's deferred initial position, so
    // ignore scrubbing until playback has started (matches the prior behaviour).
    if (_pendingStartPosition != null) return;
    if (index != null && index != _currentIndex) {
      await _player.seek(position, index: index);
    } else {
      await _player.seek(position);
    }
  }

  /// Jumps to an existing queue [index] in place — a lightweight alternative to
  /// rebuilding the source via [setQueue]. Uses the player's native
  /// seek-to-index so already-resolved children stay resolved and there is no
  /// re-resolve / reload flash. Mirrors [seek]'s cold-start guard (realise a
  /// pending restore first), then ensures playback is running so a tapped queue
  /// row actually plays. The native index change drives [currentIndexStream] →
  /// PlayerProvider's lyric/palette load, exactly like [next]/[previous].
  Future<void> jumpTo(int index) async {
    if (_queue.isEmpty) return;
    final int target = index.clamp(0, _queue.length - 1);
    // No-op fast path: tapping the already-current row shouldn't re-seek or
    // re-resolve the track (which flashes the player); just make sure it's
    // playing. Skipped while a cold-start restore is still pending — that case
    // is realised through the restore-aware play() below.
    if (target == _currentIndex && _pendingStartPosition == null) {
      if (!_player.playing) await _player.play();
      return;
    }
    // Pending cold-start restore: the source was set with preload:false, so it
    // isn't loaded yet. Realise it (loads + plays at the restored index) before
    // seeking elsewhere, mirroring how next()/previous() handle the same guard.
    if (_pendingStartPosition != null) {
      await play();
    }
    await _player.seek(Duration.zero, index: target);
    // A tapped queue item should start playing even if we were paused.
    if (!_player.playing) await _player.play();
  }

  Future<void> next() async {
    if (_queue.isEmpty || _currentIndex == null) return;
    // Pending cold-start restore: the source isn't loaded — realise + play it.
    if (_pendingStartPosition != null) {
      await play();
      return;
    }
    // Native skip; wraps under LoopMode.all, no-op past the end under off.
    await _player.seekToNext();
  }

  Future<void> previous() async {
    if (_queue.isEmpty || _currentIndex == null) return;
    if (_pendingStartPosition != null) {
      await play();
      return;
    }
    // Skip to the previous track. (No "restart current if >3s" heuristic — the
    // 上一首 button is meant to move back a track; the old guard made the common
    // case, any track played >3s, always restart the current song instead.)
    // Wraps under LoopMode.all; a no-op before the start under repeat-off.
    await _player.seekToPrevious();
  }

  Future<void> setRepeatMode(RepeatMode mode) async {
    _repeatMode = mode;
    // off / all / one all loop natively now — repeat-all wraps via LoopMode.all.
    await _player.setLoopMode(_loopModeFor(mode));
    unawaited(_persist());
  }

  Future<void> setShuffle(bool enabled) async {
    _shuffle = enabled;
    await _player.setShuffleModeEnabled(enabled);
    unawaited(_persist());
  }

  Future<void> setVolume(double volume) =>
      _player.setVolume(volume.clamp(0.0, 1.0));

  /// Handles a player error from an unresolvable/unloadable track: skip forward
  /// to the next one. Bounded by [_consecutiveErrors] so a fully-unplayable
  /// queue surfaces [unplayableMessage] and stops rather than looping forever.
  Future<void> _onPlayerError() async {
    if (_queue.isEmpty) return;
    _consecutiveErrors++;
    // Give up and surface the message when the whole queue failed in a row, OR
    // when there's nowhere left to advance ([hasNext] already accounts for the
    // loop mode, so a mid-queue tail of unplayable tracks under repeat-off won't
    // stall silently on the last one).
    if (_consecutiveErrors >= _queue.length || !_player.hasNext) {
      _consecutiveErrors = 0;
      _errors.add(unplayableMessage);
      await _player.pause();
      return;
    }
    // A successful load resets the counter via the processingState listener.
    await _player.seekToNext();
  }

  // --- persistence ---------------------------------------------------------

  /// Persists the current session (no-op without a store or with no track). The
  /// session is built synchronously from the live state, so callers may fire it
  /// unawaited.
  Future<void> _persist() async {
    final PlaybackStore? store = _store;
    if (store == null) return;
    if (_queue.isEmpty || _currentIndex == null) return;
    await store.save(PlaybackSession(
      queue: List<Song>.of(_queue),
      currentIndex: _currentIndex!,
      positionMs: position.inMilliseconds,
      repeatIndex: _repeatMode.index,
      shuffle: _shuffle,
    ));
  }

  /// Persists at most once per 5s from the high-frequency position stream.
  void _maybePersistThrottled() {
    if (_store == null) return;
    final int now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastPersistMs < 5000) return;
    _lastPersistMs = now;
    unawaited(_persist());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      unawaited(_persist());
    }
  }

  Future<void> dispose() async {
    WidgetsBinding.instance.removeObserver(this);
    await _snapshots.close();
    await _indexController.close();
    await _errors.close();
    await _player.dispose();
  }
}
