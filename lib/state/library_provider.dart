import 'package:flutter/foundation.dart';

import '../models/home_section.dart';
import '../models/playlist.dart';
import '../models/song.dart';
import '../services/music_api_router.dart';

/// Backs the home / discovery feed and caches playlist details by id. Listens to
/// the [MusicApiRouter] so switching backend reloads the feed: Migu shows a
/// hot-songs grid (no playlist plaza), Netease shows recommended playlists +
/// songs.
class LibraryProvider extends ChangeNotifier {
  final MusicApiRouter api;

  LibraryProvider({required this.api}) {
    api.addListener(_onSourceChanged);
  }

  bool _homeLoading = false;
  bool _homeError = false;
  List<HomeSection> _homeSections = <HomeSection>[];

  // The active source the home feed was last (re)loaded for. The home feed
  // (每日推荐/推荐歌单/推荐歌曲) depends ONLY on the active source, so it must reload
  // when the source changes — but NOT on the many other `router.refresh()` auth
  // events (登录/登出/切账号/签到) that fire our listener without changing the source.
  // Those used to re-fetch the identical 每日推荐 every time. Tracked here so
  // [_onSourceChanged] can dedupe by source. `null` = never loaded.
  MusicSource? _homeSource;

  final Map<int, Playlist> _playlists = <int, Playlist>{};
  // Albums keep a SEPARATE cache from playlists: an albumid and a listid/special_id
  // can collide numerically, and `/album/:id` vs `/playlist/:id` are distinct.
  final Map<int, Playlist> _albums = <int, Playlist>{};
  final Set<int> _loadingPlaylists = <int>{};

  List<Playlist> _userPlaylists = const <Playlist>[];
  bool _userPlaylistsLoading = false;

  // Memoized split of [_userPlaylists] by the `subscribed` flag (NetEase returns
  // one combined list, created first with 我喜欢的音乐 at index 0). Held as FIELDS
  // — not getters that re-filter on each call — so `context.select` identity
  // equality holds and sections don't rebuild on every unrelated notify (Dart
  // List.== is identity). Recomputed in [loadUserPlaylists]; reset wherever
  // [_userPlaylists] is reset.
  List<Playlist> _created = const <Playlist>[];
  List<Playlist> _collected = const <Playlist>[];

  bool get homeLoading => _homeLoading;
  bool get homeError => _homeError;
  List<HomeSection> get homeSections => _homeSections;

  /// The signed-in user's own playlists (Netease real; Migu has none → []).
  /// Source of truth — `.first` stays 我喜欢的音乐 (relied on elsewhere).
  List<Playlist> get userPlaylists => _userPlaylists;
  bool get userPlaylistsLoading => _userPlaylistsLoading;

  /// User-CREATED playlists (`subscribed == false`); 我喜欢的音乐 at index 0.
  List<Playlist> get createdPlaylists => _created;

  /// COLLECTED / subscribed playlists (`subscribed == true`).
  List<Playlist> get collectedPlaylists => _collected;

  void _onSourceChanged() {
    // Reload the home feed ONLY when the active source actually changed, or when
    // we still have no feed for it (e.g. a login just populated an account whose
    // feed was empty). This is the fix for "很多无关的操作都会触发刷新": 签到, logging
    // into / switching a NON-active source's account, and other `router.refresh()`
    // callers fire this listener without changing the active source, and used to
    // re-fetch the identical 每日推荐 each time. Now they leave the home feed alone.
    // Explicit user reload (源切换 / 重试「还原」按钮) still calls [loadHome] directly.
    if (api.source != _homeSource || (_homeSections.isEmpty && !_homeLoading)) {
      _homeSections = <HomeSection>[];
      loadHome();
    }
    // 我的歌单 / 收藏 are a NETEASE-account feature routed to Netease regardless of
    // the active source (see MusicApiRouter) — reload them on EVERY refresh so
    // switching the playback source to 咪咕/酷狗 never hides the signed-in user's
    // playlists (the "网易云歌单消失了" bug). `userPlaylists()` returns [] when not
    // signed in, and the Library section is gated on the login state anyway, so
    // this is a no-op when logged out. `force` bypasses the in-flight guard.
    loadUserPlaylists(force: true);
  }

  Future<void> loadHome() async {
    // Record the source this (re)load is for so [_onSourceChanged] dedupes any
    // subsequent same-source refresh. Set eagerly (before the await) so a burst
    // of startup refresh() events collapses to a single load.
    _homeSource = api.source;
    _homeLoading = true;
    _homeError = false;
    notifyListeners();
    try {
      // Daily recommends are Netease-only (signed in); Migu/anon return [] and
      // we fall back to the personalized plaza + a hot-songs grid.
      final List<Song> daily = await api.dailyRecommendSongs(limit: 12);
      final List<Playlist> dailyPlaylists =
          await api.dailyRecommendPlaylists(limit: 12);
      final List<Playlist> personal =
          await api.personalizedPlaylists(limit: 12);
      final List<Song> recommended = await api.recommendedSongs(limit: 8);

      // Prefer the "为你推荐" daily playlists; fall back to the personalized
      // plaza when daily ones aren't available (Migu / not signed in).
      final List<Playlist> carousel =
          dailyPlaylists.isNotEmpty ? dailyPlaylists : personal;

      final List<HomeSection> sections = <HomeSection>[
        if (daily.isNotEmpty)
          HomeSection(
            title: '每日推荐',
            kind: HomeSectionKind.dailySongs,
            songs: daily,
            subtitle: '根据你的口味生成',
          ),
        if (carousel.isNotEmpty)
          HomeSection(
            title: '推荐歌单',
            kind: HomeSectionKind.playlistCarousel,
            playlists: carousel,
          ),
        // Only surface the hot-songs grid when there's no daily feed, so a
        // signed-in user doesn't get two song grids stacked together.
        if (daily.isEmpty && recommended.isNotEmpty)
          HomeSection(
            title: '推荐歌曲',
            kind: HomeSectionKind.recommendedGrid,
            songs: recommended,
          ),
      ];
      _homeSections = sections;
      // Empty is a valid "no feed" state (e.g. a backend with no recommends),
      // not an error — the page shows a friendly prompt rather than a failure.
      _homeError = false;
    } catch (e) {
      debugPrint('LibraryProvider.loadHome failed: $e');
      _homeError = true;
      _homeSections = <HomeSection>[];
    } finally {
      _homeLoading = false;
      notifyListeners();
    }
  }

  /// Loads the signed-in user's own playlists via [MusicApiRouter.userPlaylists].
  /// Guards against concurrent calls; on error keeps an empty list (the page
  /// degrades to its empty state) and logs the cause.
  ///
  /// Pass [force] to bypass the in-flight guard — a post-mutation refresh (after
  /// create/delete/collect/add/remove) must not be swallowed just because a load
  /// is already running.
  Future<void> loadUserPlaylists({bool force = false}) async {
    if (_userPlaylistsLoading && !force) return;
    _userPlaylistsLoading = true;
    notifyListeners();
    try {
      _userPlaylists = await api.userPlaylists();
      _created = _userPlaylists.where((p) => !p.subscribed).toList();
      _collected = _userPlaylists.where((p) => p.subscribed).toList();
    } catch (e) {
      debugPrint('LibraryProvider.loadUserPlaylists failed: $e');
      _userPlaylists = const <Playlist>[];
      _created = const <Playlist>[];
      _collected = const <Playlist>[];
    } finally {
      _userPlaylistsLoading = false;
      notifyListeners();
    }
  }

  bool isPlaylistLoading(int id) => _loadingPlaylists.contains(id);

  /// The currently-selected UI source (used when forking a playlist "导入到本地歌单"
  /// so the local copy records which backend it came from, for later re-sync).
  MusicSource get source => api.source;

  Playlist? playlist(int id) => _playlists[id];

  /// Fetches a playlist FRESH from a specific backend, bypassing the id cache —
  /// for re-syncing a local "共同歌单" against its remote source (which must reflect
  /// the upstream's current tracks, not a stale cached copy).
  Future<Playlist> fetchPlaylistFresh(MusicSource source, int id) =>
      api.playlistDetailFrom(source, id);

  Future<Playlist> loadPlaylist(int id) async {
    final Playlist? cached = _playlists[id];
    if (cached != null) return cached;
    _loadingPlaylists.add(id);
    notifyListeners();
    try {
      final Playlist pl = await api.playlistDetail(id);
      _playlists[id] = pl;
      return pl;
    } finally {
      _loadingPlaylists.remove(id);
      notifyListeners();
    }
  }

  /// Album detail incl. tracks (route `/album/:id`). Cached in [_albums], keyed by
  /// albumid — a separate id space from playlists. Only kugougn resolves it for
  /// real; other backends return an empty album.
  Future<Playlist> loadAlbum(int id) async {
    final Playlist? cached = _albums[id];
    if (cached != null) return cached;
    _loadingPlaylists.add(id);
    notifyListeners();
    try {
      final Playlist a = await api.albumDetail(id);
      _albums[id] = a;
      return a;
    } finally {
      _loadingPlaylists.remove(id);
      notifyListeners();
    }
  }

  // --- playlist mutations (NetEase only) -----------------------------------

  /// Adds [song] to the playlist [playlistId].
  ///
  /// PLAYER-agent FROZEN contract: returns a plain `Future<void>` and THROWS on
  /// failure (no internal catch) so the caller can surface the error. On success
  /// it invalidates the cached detail and force-refreshes the user playlists.
  Future<void> addSongToPlaylist(int playlistId, Song song) async {
    await api.addTracksToPlaylist(playlistId, <int>[song.id]);
    _playlists.remove(playlistId);
    await loadUserPlaylists(force: true);
  }

  /// Removes [song] from the playlist [playlistId]. Throws on failure.
  Future<void> removeSongFromPlaylist(int playlistId, Song song) async {
    await api.removeTracksFromPlaylist(playlistId, <int>[song.id]);
    _playlists.remove(playlistId);
    await loadUserPlaylists(force: true);
  }

  /// Creates a playlist named [name] and returns its id. Throws on failure;
  /// force-refreshes the user playlists on success.
  Future<int> createUserPlaylist(String name) async {
    final int id = await api.createPlaylist(name);
    await loadUserPlaylists(force: true);
    return id;
  }

  /// Deletes the playlist [id]. Throws on failure; drops the cached detail and
  /// force-refreshes the user playlists on success.
  Future<void> deleteUserPlaylist(int id) async {
    await api.deletePlaylist(id);
    _playlists.remove(id);
    await loadUserPlaylists(force: true);
  }

  /// Subscribes ([collect] true) / unsubscribes a playlist [id]. Throws on
  /// failure; drops the cached detail and force-refreshes the user playlists on
  /// success.
  Future<void> collectPlaylist(int id, bool collect) async {
    await api.collectPlaylist(id, collect);
    _playlists.remove(id);
    await loadUserPlaylists(force: true);
  }

  @override
  void dispose() {
    api.removeListener(_onSourceChanged);
    super.dispose();
  }
}
