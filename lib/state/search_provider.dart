import 'package:flutter/foundation.dart';

import '../models/album.dart';
import '../models/artist.dart';
import '../models/playlist.dart';
import '../models/search_result.dart';
import '../models/song.dart';
import '../services/music_api_router.dart';

/// Drives the search page: query, active [SearchType], paginated [result],
/// and recent-query [history]. Listens to the [MusicApiRouter] so switching the
/// backend (Migu ⇄ Netease) clears stale results.
class SearchProvider extends ChangeNotifier {
  final MusicApiRouter api;

  SearchProvider({required this.api}) {
    api.addListener(_onSourceChanged);
  }

  void _onSourceChanged() => reset();

  @override
  void dispose() {
    api.removeListener(_onSourceChanged);
    super.dispose();
  }

  static const int _pageSize = 30;
  static const int _historyLimit = 12;

  String _query = '';
  SearchType _activeType = SearchType.song;
  SearchResult _result = SearchResult.empty();
  bool _isLoading = false;
  bool _isLoadingMore = false;
  bool _hasError = false;
  int _offset = 0;
  // Per-request token: a newer search / type-switch / reset supersedes an older
  // in-flight request, so a slow first search can never clobber a faster later
  // one's result — nor reset its loading flag, the stale-result / stuck-spinner
  // race behind the "search page stops working until restart" symptom.
  int _searchRequest = 0;
  final List<String> _history = <String>[];

  String get query => _query;
  SearchType get activeType => _activeType;
  SearchResult get result => _result;
  bool get isLoading => _isLoading;
  bool get isLoadingMore => _isLoadingMore;
  bool get hasError => _hasError;
  bool get hasMore => _result.hasMore;
  List<String> get history => List<String>.unmodifiable(_history);

  void setQuery(String q) {
    _query = q;
    notifyListeners();
  }

  void setType(SearchType type) {
    if (_activeType == type) return;
    _activeType = type;
    notifyListeners();
    if (_query.trim().isNotEmpty) {
      search();
    }
  }

  Future<void> search([String? q]) async {
    final String keyword = (q ?? _query).trim();
    if (keyword.isEmpty) return;
    final int req = ++_searchRequest;
    _query = keyword;
    _offset = 0;
    _isLoading = true;
    _hasError = false;
    notifyListeners();
    _addHistory(keyword);
    try {
      final SearchResult r = await api.search(
        keyword: keyword,
        type: _activeType,
        limit: _pageSize,
        offset: 0,
      );
      if (req != _searchRequest) return; // superseded by a newer search / reset
      _result = r;
    } catch (e) {
      if (req != _searchRequest) return;
      debugPrint('SearchProvider.search failed: $e');
      _hasError = true;
      _result = SearchResult.empty(_activeType);
    } finally {
      // Only the LATEST request owns the loading flag — a superseded one leaves it
      // to the newer search (which set it true) so the spinner tracks the real one.
      if (req == _searchRequest) {
        _isLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> loadMore() async {
    if (_isLoading || _isLoadingMore || !hasMore || _query.trim().isEmpty) {
      return;
    }
    final int req = _searchRequest;
    _isLoadingMore = true;
    notifyListeners();
    final int nextOffset = _offset + _pageSize;
    try {
      final SearchResult page = await api.search(
        keyword: _query,
        type: _activeType,
        limit: _pageSize,
        offset: nextOffset,
      );
      if (req != _searchRequest) return; // a new search / reset superseded this
      _offset = nextOffset;
      _result = _merge(_result, page);
    } catch (e) {
      if (req != _searchRequest) return;
      debugPrint('SearchProvider.loadMore failed: $e');
      _hasError = true;
    } finally {
      // Always clear the more-flag so it can never stick; notify only when current.
      _isLoadingMore = false;
      if (req == _searchRequest) notifyListeners();
    }
  }

  void clearHistory() {
    _history.clear();
    notifyListeners();
  }

  void reset() {
    _searchRequest++; // invalidate any in-flight search / loadMore
    _query = '';
    _result = SearchResult.empty(_activeType);
    _offset = 0;
    _isLoading = false;
    _isLoadingMore = false;
    _hasError = false;
    notifyListeners();
  }

  void _addHistory(String keyword) {
    _history.remove(keyword);
    _history.insert(0, keyword);
    if (_history.length > _historyLimit) {
      _history.removeRange(_historyLimit, _history.length);
    }
  }

  SearchResult _merge(SearchResult a, SearchResult b) {
    // Cross-page DEDUPE by id: kugougn's mixed search returns overlapping preview
    // rows across cursors, so a naive concat would surface duplicate cards. Keep
    // first occurrence (LinkedHashSet-style via a seen set).
    List<T> dedup<T>(List<T> x, List<T> y, int Function(T) idOf) {
      final Set<int> seen = <int>{};
      final List<T> out = <T>[];
      for (final T e in <T>[...x, ...y]) {
        if (seen.add(idOf(e))) out.add(e);
      }
      return out;
    }

    final List<Song> songs = dedup<Song>(a.songs, b.songs, (Song s) => s.id);
    final List<Album> albums =
        dedup<Album>(a.albums, b.albums, (Album x) => x.id);
    // Artists carry no stable numeric id here — keep the simple concat.
    final List<Artist> artists = <Artist>[...a.artists, ...b.artists];
    final List<Playlist> playlists =
        dedup<Playlist>(a.playlists, b.playlists, (Playlist p) => p.id);
    final int total = b.total != 0 ? b.total : a.total;
    final int prevLoaded =
        a.songs.length + a.albums.length + a.artists.length + a.playlists.length;
    final int loaded =
        songs.length + albums.length + artists.length + playlists.length;
    return SearchResult(
      type: a.type,
      songs: songs,
      albums: albums,
      artists: artists,
      playlists: playlists,
      total: total,
      // Termination guard: if a page adds nothing NEW after dedupe (loaded didn't
      // grow), stop — else `total > loaded` stays true forever → infinite paging
      // spinner. Only keep paging while this page actually contributed rows.
      hasMore: total > loaded && loaded > prevLoaded,
    );
  }
}
