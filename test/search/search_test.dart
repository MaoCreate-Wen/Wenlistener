import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:wenlistener/models/artist.dart';
import 'package:wenlistener/models/search_result.dart';
import 'package:wenlistener/models/song.dart';
import 'package:wenlistener/pages/search/search_page.dart';
import 'package:wenlistener/pages/search/search_results_page.dart';
import 'package:wenlistener/pages/search/widgets/search_field.dart';
import 'package:wenlistener/pages/search/widgets/search_skeleton.dart';
import 'package:wenlistener/pages/search/widgets/search_tab_chips.dart';
import 'package:wenlistener/router/routes.dart';
import 'package:wenlistener/services/cookie_store.dart';
import 'package:wenlistener/services/music_api_router.dart';
import 'package:wenlistener/services/netease_api.dart';
import 'package:wenlistener/services/netease_crypto.dart';
import 'package:wenlistener/state/player_provider.dart';
import 'package:wenlistener/state/search_provider.dart';
import 'package:wenlistener/theme/app_theme.dart';
import 'package:wenlistener/widgets/skeleton_box.dart';
import 'package:wenlistener/widgets/song_tile.dart';

/// Canned song results with no artwork URLs, so [SongTile]/[ArtworkImage] render
/// a static placeholder (no infinite shimmer) and tests can `pumpAndSettle`.
SearchResult _songResult() => SearchResult(
      type: SearchType.song,
      songs: <Song>[
        for (int i = 0; i < 5; i++)
          Song(
            id: 1000 + i,
            name: 'Result Song $i',
            artists: <Artist>[Artist(id: i, name: 'Artist $i')],
            duration: const Duration(seconds: 200),
            fee: 0,
            playable: true,
          ),
      ],
      total: 50,
      hasMore: true,
    );

/// Deterministic stand-in for [SearchProvider]: overrides the page-facing state
/// getters and records calls, never touching the network. The required `api` is
/// a parked instance (an in-memory cookie jar), never invoked.
class _StubSearchProvider extends SearchProvider {
  _StubSearchProvider() : super(api: _parkedRouter());

  /// A router whose backends are never invoked (the stub overrides every
  /// page-facing method); it just satisfies the [SearchProvider] constructor.
  static MusicApiRouter _parkedRouter() {
    final NeteaseApi parked = NeteaseApi(
      dio: Dio(),
      crypto: const NeteaseCrypto(),
      cookies: CookieStore(jar: CookieJar()),
    );
    return MusicApiRouter(migu: parked, netease: parked, kugou: parked);
  }

  SearchType _type = SearchType.song;
  String _query = '';
  SearchResult _result = SearchResult.empty();
  bool _loading = false;
  bool _loadingMore = false;
  bool _error = false;
  final List<String> _history = <String>[];

  int setTypeCalls = 0;
  int searchCalls = 0;
  int loadMoreCalls = 0;
  SearchType? lastTypeSet;

  @override
  SearchType get activeType => _type;
  @override
  String get query => _query;
  @override
  SearchResult get result => _result;
  @override
  bool get isLoading => _loading;
  @override
  bool get isLoadingMore => _loadingMore;
  @override
  bool get hasError => _error;
  @override
  bool get hasMore => _result.hasMore;
  @override
  List<String> get history => List<String>.unmodifiable(_history);

  void emit({
    SearchType? type,
    String? query,
    SearchResult? result,
    bool? loading,
    bool? loadingMore,
    bool? error,
    List<String>? history,
  }) {
    if (type != null) _type = type;
    if (query != null) _query = query;
    if (result != null) _result = result;
    if (loading != null) _loading = loading;
    if (loadingMore != null) _loadingMore = loadingMore;
    if (error != null) _error = error;
    if (history != null) {
      _history
        ..clear()
        ..addAll(history);
    }
    notifyListeners();
  }

  @override
  void setQuery(String q) {
    _query = q;
    notifyListeners();
  }

  @override
  void setType(SearchType type) {
    setTypeCalls++;
    lastTypeSet = type;
    _type = type;
    notifyListeners();
  }

  @override
  Future<void> search([String? q]) async {
    searchCalls++;
    if (q != null) _query = q;
    _loading = false;
    _result = _songResult();
    notifyListeners();
  }

  @override
  Future<void> loadMore() async {
    loadMoreCalls++;
  }

  @override
  void clearHistory() {
    _history.clear();
    notifyListeners();
  }
}

/// Minimal [PlayerProvider] used only for the `isActive`/`playQueue` reads of the
/// results page. Everything else is forwarded to [noSuchMethod] (and unused).
class _FakePlayerProvider extends ChangeNotifier implements PlayerProvider {
  _FakePlayerProvider({Song? current}) : _current = current;

  final Song? _current;
  final List<List<Song>> playQueueCalls = <List<Song>>[];

  @override
  Song? get currentSong => _current;

  @override
  Future<void> playQueue(List<Song> songs, {int index = 0}) async {
    playQueueCalls.add(songs);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

Widget _wrapResults(_StubSearchProvider search, _FakePlayerProvider player) {
  return MultiProvider(
    providers: <ChangeNotifierProvider<ChangeNotifier>>[
      ChangeNotifierProvider<SearchProvider>.value(value: search),
      ChangeNotifierProvider<PlayerProvider>.value(value: player),
    ],
    child: MaterialApp(
      theme: AppTheme.dark(),
      home: const SearchResultsPage(),
    ),
  );
}

void main() {
  testWidgets('SearchPage renders the field and recent searches',
      (WidgetTester tester) async {
    final _StubSearchProvider stub = _StubSearchProvider()
      ..emit(history: <String>['lofi beats', 'jay chou']);

    await tester.pumpWidget(
      MultiProvider(
        providers: <ChangeNotifierProvider<ChangeNotifier>>[
          ChangeNotifierProvider<SearchProvider>.value(value: stub),
          ChangeNotifierProvider<MusicApiRouter>.value(value: stub.api),
        ],
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const SearchPage(),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(SearchField), findsOneWidget);
    expect(find.text('Search'), findsOneWidget);
    expect(find.text('Recent searches'), findsOneWidget);
    expect(find.text('lofi beats'), findsOneWidget);
    expect(find.text('jay chou'), findsOneWidget);
  });

  testWidgets('SearchResultsPage renders a SongTile list and chips switch type',
      (WidgetTester tester) async {
    final _StubSearchProvider stub = _StubSearchProvider()
      ..emit(query: 'test', result: _songResult(), loading: false);
    final _FakePlayerProvider player = _FakePlayerProvider();

    await tester.pumpWidget(_wrapResults(stub, player));
    await tester.pump();

    expect(find.byType(SearchTabChips), findsOneWidget);
    expect(find.byType(SongTile), findsWidgets);
    expect(find.text('Result Song 0'), findsOneWidget);
    expect(find.text('Songs'), findsOneWidget);
    expect(find.text('Albums'), findsOneWidget);

    await tester.tap(find.text('Albums'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(stub.setTypeCalls, 1);
    expect(stub.lastTypeSet, SearchType.album);
    expect(stub.activeType, SearchType.album);
  });

  testWidgets('SearchResultsPage shows the skeleton while loading',
      (WidgetTester tester) async {
    final _StubSearchProvider stub = _StubSearchProvider()
      ..emit(query: 'test', loading: true, result: SearchResult.empty());
    final _FakePlayerProvider player = _FakePlayerProvider();

    await tester.pumpWidget(_wrapResults(stub, player));
    // Single frame only: the skeleton shimmer animates forever, so do not settle.
    await tester.pump();

    expect(find.byType(SearchSkeleton), findsOneWidget);
    expect(find.byType(SkeletonBox), findsWidgets);
  });

  testWidgets('Tapping a song starts playback through PlayerProvider',
      (WidgetTester tester) async {
    final _StubSearchProvider stub = _StubSearchProvider()
      ..emit(query: 'test', result: _songResult(), loading: false);
    final _FakePlayerProvider player = _FakePlayerProvider();

    await tester.pumpWidget(_wrapResults(stub, player));
    await tester.pump();

    await tester.tap(find.text('Result Song 1'));
    await tester.pump();

    expect(player.playQueueCalls, hasLength(1));
    expect(player.playQueueCalls.first, hasLength(5));
  });

  testWidgets('Submitting a query seeds the provider and navigates to results',
      (WidgetTester tester) async {
    final _StubSearchProvider stub = _StubSearchProvider();
    final _FakePlayerProvider player = _FakePlayerProvider();

    final GoRouter router = GoRouter(
      initialLocation: Routes.search,
      routes: <RouteBase>[
        GoRoute(
          path: Routes.search,
          builder: (BuildContext context, GoRouterState state) =>
              const SearchPage(),
          routes: <RouteBase>[
            GoRoute(
              path: Routes.searchResults,
              builder: (BuildContext context, GoRouterState state) =>
                  const SearchResultsPage(),
            ),
          ],
        ),
      ],
    );

    await tester.pumpWidget(
      MultiProvider(
        providers: <ChangeNotifierProvider<ChangeNotifier>>[
          ChangeNotifierProvider<SearchProvider>.value(value: stub),
          ChangeNotifierProvider<MusicApiRouter>.value(value: stub.api),
          ChangeNotifierProvider<PlayerProvider>.value(value: player),
        ],
        child: MaterialApp.router(
          theme: AppTheme.dark(),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(SearchPage), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'hello');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(stub.searchCalls, greaterThanOrEqualTo(1));
    expect(find.byType(SearchResultsPage), findsOneWidget);
  });
}
