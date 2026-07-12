import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';

/// Passive [audio_service] handler that mirrors a shared just_audio
/// [AudioPlayer] into the system media notification / lock screen, and forwards
/// notification button taps back to that same player.
///
/// This replaces `just_audio_background`, which hardcoded a `stop` notification
/// control (not config-removable) and defaulted the notification small-icon to
/// the colourful launcher mipmap. Here the controls are exactly
/// **previous · play/pause · next** — no stop, no like/heart action — and the
/// small icon is set by the [AudioServiceConfig] the orchestrator passes to
/// [AudioService.init] (`drawable/ic_stat_music`).
///
/// The handler is **passive**: playback, the queue, repeat/shuffle and all
/// state stay owned by the app's `AudioService` (which drives the same
/// [AudioPlayer]). This handler only reflects the player's streams outward into
/// the notification and relays taps inward — it never owns or rebuilds the
/// queue itself. It is constructed by `main.dart` via
/// `AudioService.init(builder: () => WenAudioHandler(player))`, with `player`
/// created before init.
class WenAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  WenAudioHandler(this._player) {
    // playbackEventStream covers position / buffered / processing / index;
    // playerStateStream covers the play/pause toggle (which doesn't always emit
    // a new playback event) — both refresh the whole notification state. The
    // onError no-op keeps unresolvable-track errors from escaping here; the
    // app's AudioService owns the skip-to-next recovery.
    _subs.add(_player.playbackEventStream
        .listen((_) => _broadcastState(), onError: (Object _) {}));
    _subs.add(_player.playerStateStream.listen((_) => _broadcastState()));

    // Mirror the queue: every source already carries a [MediaItem] tag (set in
    // AudioService._mediaItem), so the notification queue is just those tags.
    _subs.add(_player.sequenceStream.listen((List<IndexedAudioSource>? seq) {
      if (_disposed || seq == null) return;
      queue.add(seq.map((s) => s.tag as MediaItem).toList());
    }));

    // Patch the current item's decoder duration: streamed / 302 mp3 sources
    // often start with a null duration, filled in once decoded.
    _subs.add(_player.currentIndexStream.listen((_) => _broadcastMediaItem()));
    _subs.add(_player.durationStream.listen((_) => _broadcastMediaItem()));
  }

  final AudioPlayer _player;
  final List<StreamSubscription<dynamic>> _subs =
      <StreamSubscription<dynamic>>[];
  bool _disposed = false;

  // --- outward mirroring ----------------------------------------------------

  /// Reflects the live player state into the notification with exactly the
  /// three transport controls: previous · play/pause · next. No stop control,
  /// no custom (like) action.
  void _broadcastState() {
    if (_disposed) return;
    final bool playing = _player.playing;
    playbackState.add(PlaybackState(
      controls: <MediaControl>[
        MediaControl.skipToPrevious,
        if (playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const <MediaAction>{
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const <int>[0, 1, 2],
      processingState: _mapProcessingState(_player.processingState),
      playing: playing,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
      queueIndex: _player.currentIndex,
    ));
  }

  /// Publishes the current track's [MediaItem], patched with the decoder
  /// duration once it's known (falls back to the tag's own duration).
  void _broadcastMediaItem() {
    if (_disposed) return;
    final MediaItem? tag = _currentTag;
    if (tag == null) return;
    mediaItem.add(tag.copyWith(duration: _player.duration ?? tag.duration));
  }

  /// The [MediaItem] tag of the source at the player's current index, if any.
  MediaItem? get _currentTag {
    final List<IndexedAudioSource>? seq = _player.sequence;
    final int? i = _player.currentIndex;
    if (seq == null || i == null || i < 0 || i >= seq.length) return null;
    final Object? tag = seq[i].tag;
    return tag is MediaItem ? tag : null;
  }

  static AudioProcessingState _mapProcessingState(ProcessingState state) {
    switch (state) {
      case ProcessingState.idle:
        return AudioProcessingState.idle;
      case ProcessingState.loading:
        return AudioProcessingState.loading;
      case ProcessingState.buffering:
        return AudioProcessingState.buffering;
      case ProcessingState.ready:
        return AudioProcessingState.ready;
      case ProcessingState.completed:
        return AudioProcessingState.completed;
    }
  }

  static LoopMode _loopModeFor(AudioServiceRepeatMode mode) {
    switch (mode) {
      case AudioServiceRepeatMode.one:
        return LoopMode.one;
      case AudioServiceRepeatMode.all:
      case AudioServiceRepeatMode.group:
        return LoopMode.all;
      case AudioServiceRepeatMode.none:
        return LoopMode.off;
    }
  }

  // --- inward button taps (delegate to the shared player) -------------------

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> skipToNext() => _player.seekToNext();

  @override
  Future<void> skipToPrevious() => _player.seekToPrevious();

  @override
  Future<void> skipToQueueItem(int index) =>
      _player.seek(Duration.zero, index: index);

  /// No stop button is shown; a defensive stop maps to a pause so a stray
  /// system stop never tears the shared player down.
  @override
  Future<void> stop() => _player.pause();

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) =>
      _player.setLoopMode(_loopModeFor(repeatMode));

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) =>
      _player.setShuffleModeEnabled(shuffleMode != AudioServiceShuffleMode.none);

  /// Cancels the stream mirrors so callbacks no-op after disposal. The shared
  /// [AudioPlayer] is owned by the app's AudioService and is NOT disposed here.
  Future<void> dispose() async {
    _disposed = true;
    for (final StreamSubscription<dynamic> s in _subs) {
      await s.cancel();
    }
    _subs.clear();
  }
}
