import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/lyric_line.dart';
import '../models/play_url.dart';
import '../models/playlist.dart';
import '../models/search_result.dart';
import '../models/song.dart';
import 'kuwo_api.dart';
import 'local_music_api.dart';
import 'music_api.dart';
import 'resource_cache.dart';

/// Multiplexes the music backends behind one [MusicApi]. The UI [source]
/// (persisted; default Netease) selects the backend for **search / feeds /
/// playlist management** ([active]); [setSource]/[toggle] flip it and notify
/// listeners so those feeds refresh.
///
/// **Play / lyric dispatch PER-SONG**, by [Song.source] — not the active UI
/// source — so a mixed-source local playlist (网易 / 咪咕 / 酷狗 in one list) plays
/// and shows lyrics end to end no matter which source is currently selected.
class MusicApiRouter extends ChangeNotifier implements MusicApi {
  final MusicApi migu;
  final MusicApi netease;
  final MusicApi kugou;

  /// 酷狗概念版 (FreeListen/Lite Android) — a separate source from web [kugou].
  final MusicApi kugougn;

  /// QQ 音乐（安卓客户端）— an INDEPENDENT source from the web QQ that occupies the
  /// [migu] slot; its own qqcn_* session.
  final MusicApi qqcn;
  final MusicApi kuwo;

  /// Backend for user-imported on-device files ([MusicSource.local]).
  final MusicApi local;
  MusicSource _source;

  MusicApiRouter({
    required this.migu,
    required this.netease,
    required this.kugou,
    required this.kugougn,
    required this.qqcn,
    MusicApi? kuwo,
    this.local = const LocalMusicApi(),
    MusicSource initial = MusicSource.netease,
  })  : kuwo = kuwo ?? KuwoApi(),
        _source = initial;

  MusicSource get source => _source;

  MusicApi _backendFor(MusicSource source) {
    switch (source) {
      case MusicSource.migu:
        return migu;
      case MusicSource.netease:
        return netease;
      case MusicSource.kugou:
        return kugou;
      case MusicSource.kugougn:
        return kugougn;
      case MusicSource.qqcn:
        return qqcn;
      case MusicSource.kuwo:
        return this.kuwo;
      case MusicSource.local:
        return local;
    }
  }

  /// Backend for the currently-selected UI source (search / feeds / playlist
  /// management route here); play/lyric instead dispatch per-song.
  MusicApi get active => _backendFor(_source);

  bool get isMigu => _source == MusicSource.migu;

  void setSource(MusicSource source) {
    if (_source == source) return;
    _source = source;
    notifyListeners();
  }

  void toggle() =>
      setSource(_source == MusicSource.migu ? MusicSource.netease : MusicSource.migu);

  /// Forces a listener refresh WITHOUT changing the source — used on login/logout
  /// so the feeds (home + user playlists) reload against the new auth state even
  /// when the source is unchanged. With the source now a user setting defaulting
  /// to Netease, a login no longer flips it, so `setSource` would be a no-op and
  /// [LibraryProvider] would never reload; this is the explicit trigger instead.
  void refresh() => notifyListeners();

  @override
  Future<SearchResult> search({
    required String keyword,
    SearchType type = SearchType.song,
    int limit = 30,
    int offset = 0,
  }) =>
      active.search(keyword: keyword, type: type, limit: limit, offset: offset);

  // Per-SONG dispatch (NOT the active source): route to the backend that OWNS the
  // track so a mixed-source local playlist plays / lyrics end to end. Single-source
  // queues are unaffected (song.source == active source there anyway).
  @override
  Future<PlayUrl?> songUrl(Song song, {AudioLevel level = AudioLevel.exhigh}) =>
      _backendFor(song.source).songUrl(song, level: level);

  @override
  Future<Lyrics> lyric(Song song) async {
    // Local files carry their own sidecar .lrc — never disk-cache those (the
    // path IS the identity and re-reading is free).
    if (song.source == MusicSource.local) {
      return _backendFor(song.source).lyric(song);
    }
    // Transparent disk read-through (keyed `source-id`). Semantics preserved
    // EXACTLY for the caller (`PlayerProvider`'s transient-failure retry):
    //  * backend throws → this still throws (nothing cached, retry/backoff intact);
    //  * successful EMPTY result (instrumental) → returned but NOT cached, so a
    //    later fetch can still re-confirm;
    //  * only successful, non-empty lyrics are written (fire-and-forget).
    final Lyrics? cached =
        await ResourceCache.instance.readLyrics(song.source, song.id);
    if (cached != null) return cached;
    final Lyrics fresh = await _backendFor(song.source).lyric(song);
    if (fresh.lines.isNotEmpty) {
      unawaited(ResourceCache.instance.writeLyrics(song.source, song.id, fresh));
    }
    return fresh;
  }

  @override
  Future<List<Playlist>> personalizedPlaylists({int limit = 12}) =>
      active.personalizedPlaylists(limit: limit);

  @override
  Future<List<Song>> recommendedSongs({int limit = 8}) =>
      active.recommendedSongs(limit: limit);

  // Playlists (歌单) display + open BY SOURCE (per user request 「歌单的切换按音源展示」):
  // `userPlaylists` / `playlistDetail` / the writes all follow the ACTIVE source, so
  // switching to 网易/QQ/酷狗 shows that source's 我的歌单 and opens/likes them with
  // the same backend. Listing and opening therefore stay consistent (both use
  // `active`), so no per-playlist source tagging is needed. 咪咕/酷狗 with no
  // playlist API just return []/throw (an empty library section).
  @override
  Future<Playlist> playlistDetail(int id) => active.playlistDetail(id);

  // Album detail dispatches to the ACTIVE source — a searched album is opened
  // while browsing that source, so active == the album's source. Sources without
  // album support return an empty Playlist.
  @override
  Future<Playlist> albumDetail(int id) => active.albumDetail(id);

  /// Fetches a playlist from a SPECIFIC backend (not the active source) — used to
  /// re-sync a local "共同歌单" against the remote it was forked from, regardless of
  /// which source the UI is currently on.
  Future<Playlist> playlistDetailFrom(MusicSource source, int id) =>
      _backendFor(source).playlistDetail(id);

  @override
  Future<List<Playlist>> userPlaylists({int limit = 30, int offset = 0}) =>
      active.userPlaylists(limit: limit, offset: offset);

  @override
  Future<List<Song>> dailyRecommendSongs({int limit = 30}) =>
      active.dailyRecommendSongs(limit: limit);

  @override
  Future<List<Playlist>> dailyRecommendPlaylists({int limit = 30}) =>
      active.dailyRecommendPlaylists(limit: limit);

  // Playlist writes follow the active source too (see the note above).
  @override
  Future<int> createPlaylist(String name, {int privacy = 0}) =>
      active.createPlaylist(name, privacy: privacy);

  @override
  Future<void> deletePlaylist(int pid) => active.deletePlaylist(pid);

  @override
  Future<void> addTracksToPlaylist(int pid, List<int> ids) =>
      active.addTracksToPlaylist(pid, ids);

  @override
  Future<void> removeTracksFromPlaylist(int pid, List<int> ids) =>
      active.removeTracksFromPlaylist(pid, ids);

  @override
  Future<void> collectPlaylist(int id, bool collect) =>
      active.collectPlaylist(id, collect);
}
