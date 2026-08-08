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

  /// Pristine (pre-shuffle) queue order, captured when the queue is set. App-
  /// layer shuffle permutes [_queue] for playback while this preserves the order
  /// to restore when shuffle is turned back off. (A cold-start [restore] can't
  /// persist the pristine order separately — see [PlaybackSession] — so it seeds
  /// this from the restored play order; turning shuffle off on a disk-resumed
  /// session therefore reshuffles from that order rather than un-shuffling to a
  /// true original. Within a live session it holds the real insertion order.)
  List<Song> _originalOrder = <Song>[];

  int? _currentIndex;
  RepeatMode _repeatMode = RepeatMode.off;

  /// Whether shuffle is on. This is the app's OWN flag, deliberately independent
  /// of just_audio's `shuffleModeEnabled`: shuffle is done in the app layer (we
  /// physically reorder [_queue] and keep native shuffle OFF — see [setShuffle]),
  /// so just_audio's flag stays false and is never trusted here.
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

  /// Fallback snapshot heartbeat. Re-emits a snapshot from the live player state
  /// so playing/index/duration changes can't be missed while the native
  /// positionStream is quiet. It is a PURE READ of `_player.position`, so it can
  /// never un-freeze a stalled position: that getter stops interpolating while
  /// processingState != ready, and just_audio's own positionStream already polls
  /// the identical getter at ≤200ms (it only looks dead because its .distinct()
  /// swallows the repeated frozen value). Unfreezing is
  /// [_wakePositionStreamAfterIndexChange]'s job, not this ticker's.
  Timer? _positionTicker;

  /// Wall-clock of the last [_push]. Lets the ticker stay quiet while the native
  /// positionStream is still delivering (no double-push in steady playback).
  int _lastPushMs = 0;

  /// Monotonic generation for the position-wake observer. Every track change
  /// bumps it; an in-flight [_wakePositionStreamAfterIndexChange] bails the
  /// instant a newer change supersedes its generation, so a burst of rapid skips
  /// or queue taps leaves at most one live observer instead of one idle timer
  /// chain per tap.
  int _wakeGen = 0;

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
      // After a native transition just_audio's cached processingState can land
      // on a non-ready value, and nothing ever corrects it: just_audio_windows
      // broadcasts state from only four sites (PlaybackStateChanged,
      // CurrentItemChanged, seekToItem, seekToPosition) with no periodic
      // broadcast, so a stale mid-transition event is simply the LAST one.
      // just_audio's `position` getter only wall-clock-interpolates while
      // ready, so it then returns a frozen constant that the pure-read
      // heartbeat can only re-push (and PlayerProvider dedupes away). Only a
      // real seek forces a fresh broadcast. This is the SHARED track-change
      // path — next/previous, tray, error-skip and native auto-advance all land
      // here — so it is where the wake belongs. The observer is index-less and
      // only fires on a CONFIRMED stall, so it can't re-load the source or race
      // the in-flight seekToNext/seekToPrevious (the indexed seek that once
      // broke 'next' is not what this does).
      unawaited(_wakePositionStreamAfterIndexChange(i, ++_wakeGen));
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

    // Fallback position heartbeat — MF withholds positionStream after a native
    // track transition (next/previous/auto-advance), which would freeze the
    // scrubber + lyric sweep until a real seek. This pure-read poll of the
    // wall-clock-interpolated position getter re-arms the UI WITHOUT any seek, so
    // it can't disturb a transition. It stays quiet (the 220ms coalesce guard)
    // whenever the native positionStream is still delivering.
    _positionTicker = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!_player.playing) return; // paused: nothing to advance
      if (_pendingStartPosition != null) return; // pre-restore: position is a stand-in
      final int now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastPushMs < 220) return; // positionStream still live → don't double-push
      _push();
    });
  }

  void _push() {
    _lastPushMs = DateTime.now().millisecondsSinceEpoch;
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
    _originalOrder = List<Song>.of(songs); // pristine order for un-shuffle.
    if (_originalOrder.isEmpty) {
      _queue = <Song>[];
      _currentIndex = null;
      _indexController.add(null);
      await _player.stop();
      _push();
      return;
    }
    _consecutiveErrors = 0;
    // App-layer shuffle: native shuffle is unreliable on just_audio_windows (see
    // [setShuffle] for why), so the queue is PHYSICALLY reordered and native
    // shuffle is kept off. With shuffle on, the tapped track leads and the rest
    // follow in a random order; native linear auto-advance then walks that
    // shuffled order — every advance path sees the same single order.
    await _player.setShuffleModeEnabled(false);
    final int idx = initialIndex.clamp(0, _originalOrder.length - 1);
    if (_shuffle) {
      _queue = _shuffledOrder(_originalOrder, _originalOrder[idx]);
      await _setConcat(0, autoPlay: true); // the chosen track is at the front.
    } else {
      _queue = List<Song>.of(_originalOrder);
      await _setConcat(idx, autoPlay: true);
    }
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
    // The persisted queue is the PLAY order (already shuffled if shuffle was on),
    // so resume it verbatim and seed the pristine mirror from it — app-layer
    // shuffle keeps native shuffle off, so linear auto-advance replays this exact
    // order. (The pre-shuffle order isn't persisted; see [_originalOrder].)
    _queue = List<Song>.of(session.queue);
    _originalOrder = List<Song>.of(session.queue);
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
    // Native shuffle stays OFF regardless of [_shuffle]: shuffle lives in the
    // play-order of [_queue] (see [setShuffle]). Enabling native shuffle here
    // would re-introduce the MF desync that stalls playback after a few tracks.
    await _player.setShuffleModeEnabled(false);

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
    // Redundant with the currentIndexStream listener (the seek above emits the
    // index change, which starts an observer of its own) but kept deliberately:
    // this is the one path confirmed working today, and dropping it would change
    // it. Harmless — the listener's observer starts first, this ++_wakeGen
    // supersedes it, and the earlier one bails on the generation check, leaving
    // exactly one live observer anchored to `target` and at most one seek.
    unawaited(_wakePositionStreamAfterIndexChange(target, ++_wakeGen));
  }

  /// Re-arms the position display after a track change — ANY path.
  ///
  /// just_audio_windows (Media Foundation) broadcasts playback state from only
  /// four sites — PlaybackStateChanged, CurrentItemChanged, seekToItem and
  /// seekToPosition — with no periodic broadcast and no Dart-side correction. So
  /// when a broadcast lands mid-transition carrying a non-ready processingState,
  /// that stale event is simply the LAST one: nothing fixes it while playback
  /// continues. just_audio's `position` getter only wall-clock-interpolates while
  /// processingState == ready and otherwise returns a frozen constant, which the
  /// pure-read heartbeat can only re-push (deduped by PlayerProvider) — so the
  /// scrubber + lyric sweep freeze. Only a real seek re-enters the plugin and
  /// forces a fresh broadcast, by which point the state recomputes as ready.
  ///
  /// Observes for ~480ms and, ONLY if the position is confirmed stuck while
  /// playing, issues exactly one zero-displacement, index-less seek. A target
  /// that keeps interpolating is left untouched (no seek at all). Index-less is
  /// what makes this safe on the shared path: the plugin calls seekToItem — i.e.
  /// MediaPlaybackList.MoveTo, a real source RE-LOAD — only when the seek carries
  /// an index, so this can neither re-load the source nor race an in-flight
  /// seekToNext/seekToPrevious. (The original fix seeked WITH an index; that is
  /// what broke 'next' and got it reverted. Do not re-narrow this to jumpTo: the
  /// paths without a wake are exactly the ones that freeze.)
  Future<void> _wakePositionStreamAfterIndexChange(int target, int gen) async {
    Duration last = _player.position;
    for (int i = 0; i < 4; i++) {
      // ~480ms observation window (4 × 120ms).
      await Future<void>.delayed(const Duration(milliseconds: 120));
      if (gen != _wakeGen) return; // a newer track change superseded this one.
      if (_currentIndex != target) return; // next/previous/auto-advance moved on.
      if (_pendingStartPosition != null) return; // a cold-start restore took over.
      if (!_player.playing) return; // paused: nothing to advance.
      final Duration pos = _player.position;
      if (pos > last) return; // interpolation is live → the heartbeat has it.
      last = pos;
    }
    // Still frozen while playing → the MF cold-jump stall. One zero-displacement,
    // index-less real seek forces MF to re-broadcast (ready + updateTime = now),
    // re-arming the interpolation the pure-read heartbeat relies on.
    if (gen != _wakeGen) return;
    if (_currentIndex != target) return;
    if (_pendingStartPosition != null) return;
    if (!_player.playing) return;
    await _player.seek(_player.position);
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

  /// Toggles shuffle. Implemented in the APP LAYER — the play queue is
  /// physically reordered and just_audio's native shuffle is kept permanently
  /// OFF — because native shuffle is unreliable on just_audio_windows (Media
  /// Foundation), which is what left playback stuck after ~3 shuffled songs:
  ///   * the MF plugin hardcodes `getShuffleMode()` to "none", and it broadcasts
  ///     that on every state change, which flaps just_audio's shuffleModeEnabled
  ///     flag back to false moments after we enable it — so hasNext / nextIndex /
  ///     effectiveIndices (and therefore seekToNext and the [_onPlayerError]
  ///     skip) flip between the shuffled and the linear order turn to turn;
  ///   * native `ShuffleEnabled(true)` still auto-advances the WinRT
  ///     MediaPlaybackList in its OWN private random order, which the plugin only
  ///     ever reports back as a CurrentItemIndex — so after a few auto-advances
  ///     the Dart index model and the native list have desynced, and the
  ///     position-wake / error-skip recovery then act on a stale index and stall;
  ///   * the plugin's SetShuffledItems reorder is a broken permutation anyway.
  /// Reordering ourselves collapses all of that to ONE order that native linear
  /// auto-advance, seekToNext/Previous, hasNext and currentIndexStream all agree
  /// on, so the desync can't happen. The current track keeps playing — pulled to
  /// the front on enable, or returned to its pristine slot on disable — and only
  /// that one track reloads (from its current position) as the source rebuilds.
  Future<void> setShuffle(bool enabled) async {
    if (_shuffle == enabled) return;
    _shuffle = enabled;
    // Never use native shuffle; keep it forced off (it may have been left on by
    // a prior build, and its state survives setAudioSource on this backend).
    await _player.setShuffleModeEnabled(false);
    if (_queue.isEmpty) {
      unawaited(_persist());
      return;
    }
    // A shuffle toggle rebuilds the queue into a fresh play order, exactly like
    // [setQueue] — so reset the skip-error guard too. Otherwise a non-zero count
    // left over from an earlier VIP/unresolvable skip is carried into the newly
    // reordered (and possibly shorter, once shuffle drops a leading track to the
    // back) queue, where it can hit `_consecutiveErrors >= _queue.length` after
    // just a couple of hops and surface [unplayableMessage] / pause — the "stuck
    // after a few shuffled songs" stall. A real successful load still clears it
    // via the processingState listener; this just removes the stale carry-over.
    _consecutiveErrors = 0;
    final Song? current = _currentSong;
    final List<Song> base =
        _originalOrder.isEmpty ? List<Song>.of(_queue) : _originalOrder;
    _queue = enabled ? _shuffledOrder(base, current) : List<Song>.of(base);
    final int found =
        current == null ? -1 : _indexOfIdentity(_queue, current);
    // Rebuild the source at the current track's new slot, preserving play state
    // and position (reuses the setQueue path, so the MF autoplay/seek quirks are
    // handled identically). Only the current track reloads.
    await _setConcat(found < 0 ? 0 : found,
        autoPlay: _player.playing, startAt: _player.position);
    unawaited(_persist());
  }

  /// A random permutation of [source] with [keep] (the track that must keep
  /// playing) pulled to the front, so enabling shuffle never cuts to a different
  /// song. [keep] is matched by identity — it is the live queue element — so any
  /// duplicate song elsewhere in the queue is unaffected.
  List<Song> _shuffledOrder(List<Song> source, Song? keep) {
    final List<Song> rest = <Song>[];
    Song? head;
    for (final Song s in source) {
      if (keep != null && head == null && identical(s, keep)) {
        head = s;
      } else {
        rest.add(s);
      }
    }
    rest.shuffle();
    return <Song>[if (head != null) head, ...rest];
  }

  /// Index of [song] in [list] by identity (the queue holds the same [Song]
  /// instances across a reorder, so identity is exact even with duplicate ids),
  /// falling back to value equality, else -1.
  int _indexOfIdentity(List<Song> list, Song song) {
    for (int i = 0; i < list.length; i++) {
      if (identical(list[i], song)) return i;
    }
    return list.indexOf(song);
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
    _positionTicker?.cancel();
    await _snapshots.close();
    await _indexController.close();
    await _errors.close();
    await _player.dispose();
  }
}
