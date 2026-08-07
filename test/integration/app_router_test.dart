import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';
import 'package:wenlistener/models/artist.dart';
import 'package:wenlistener/models/home_section.dart';
import 'package:wenlistener/models/local_playlist.dart';
import 'package:wenlistener/models/lyric_line.dart';
import 'package:wenlistener/models/playlist.dart';
import 'package:wenlistener/models/song.dart';
import 'package:wenlistener/pages/home/home_page.dart';
import 'package:wenlistener/pages/library/library_page.dart';
import 'package:wenlistener/pages/lyrics/lyrics_page.dart';
import 'package:wenlistener/pages/player/player_page.dart';
import 'package:wenlistener/pages/playlist/playlist_page.dart';
import 'package:wenlistener/pages/search/search_page.dart';
import 'package:wenlistener/router/app_router.dart';
import 'package:wenlistener/router/routes.dart';
import 'package:wenlistener/services/fft_service.dart';
import 'package:wenlistener/services/migu_api.dart';
import 'package:wenlistener/services/music_api_router.dart';
import 'package:wenlistener/services/netease_api.dart';
import 'package:wenlistener/services/settings_store.dart';
import 'package:wenlistener/shell/bottom_nav_bar.dart';
import 'package:wenlistener/state/auth_provider.dart';
import 'package:wenlistener/state/library_provider.dart';
import 'package:wenlistener/state/local_playlist_provider.dart';
import 'package:wenlistener/state/player_provider.dart';
import 'package:wenlistener/state/search_provider.dart';
import 'package:wenlistener/state/settings_provider.dart';
import 'package:wenlistener/theme/app_colors.dart';
import 'package:wenlistener/theme/app_theme.dart';

/// Three canned tracks with no artwork URLs (so [ArtworkImage] renders a static
/// placeholder rather than an endless shimmer, keeping pumps deterministic).
List<Song> _tracks() => <Song>[
      for (int i = 0; i < 3; i++)
        Song(
          id: 100 + i,
          name: 'Track $i',
          artists: <Artist>[Artist(id: i, name: 'Artist $i')],
          duration: Duration(seconds: 180 + i),
          fee: 0,
          playable: true,
        ),
    ];

/// A [PlayerProvider] stand-in that supplies only the page-/shell-facing reads
/// (no audio stack) and records [playQueue] calls. Everything else routes to
/// [noSuchMethod] (and is never touched by the mounted routes).
class _StubPlayerProvider extends ChangeNotifier implements PlayerProvider {
  static const Gradient _gradient = LinearGradient(
    colors: <Color>[AppColors.seed, AppColors.seedDeep],
  );

  final List<List<Song>> playQueueCalls = <List<Song>>[];
  final List<int> playQueueIndexes = <int>[];

  @override
  bool get hasSong => false;
  @override
  Song? get currentSong => null;
  @override
  Color get dynamicAccent => AppColors.accentPlay;
  @override
  Gradient get dynamicGradient => _gradient;
  @override
  Gradient get washGradient => _gradient;
  @override
  List<Color> get paletteColors => const <Color>[];
  @override
  Lyrics get lyrics => Lyrics.empty;
  @override
  bool get lyricsLoading => false;
  @override
  int get activeLyricIndex => -1;
  @override
  bool get lyricsSettled => true;
  @override
  bool get isPlaying => false;
  @override
  bool get isBuffering => false;
  @override
  Duration get position => Duration.zero;
  @override
  Duration get duration => Duration.zero;
  @override
  List<Song> get queue => const <Song>[];

  @override
  String? get playbackError => null;

  @override
  void clearPlaybackError() {}

  @override
  void retryLyrics() {}

  @override
  Future<void> playQueue(List<Song> songs, {int index = 0}) async {
    playQueueCalls.add(songs);
    playQueueIndexes.add(index);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// A [LibraryProvider] stand-in: empty home feed, and [loadPlaylist] returns a
/// canned playlist (recording the requested id) instead of hitting the network.
class _StubLibraryProvider extends ChangeNotifier implements LibraryProvider {
  _StubLibraryProvider({List<Song> tracks = const <Song>[]}) : _tracks = tracks;

  final List<Song> _tracks;
  final Map<int, Playlist> _cache = <int, Playlist>{};
  int? lastLoadedId;
  int loadPlaylistCalls = 0;

  @override
  List<HomeSection> get homeSections => const <HomeSection>[];
  @override
  bool get homeLoading => false;
  @override
  bool get homeError => false;

  @override
  Future<void> loadHome() async {}

  @override
  bool isPlaylistLoading(int id) => false;

  @override
  Playlist? playlist(int id) => _cache[id];

  @override
  Future<Playlist> loadPlaylist(int id) async {
    loadPlaylistCalls++;
    lastLoadedId = id;
    final Playlist pl = Playlist(
      id: id,
      name: 'Test Playlist',
      creatorName: 'Tester',
      trackCount: _tracks.length,
      tracks: _tracks,
    );
    _cache[id] = pl;
    notifyListeners();
    return pl;
  }

  @override
  List<Playlist> get userPlaylists => const <Playlist>[];

  @override
  bool get userPlaylistsLoading => false;

  @override
  Future<void> loadUserPlaylists({bool force = false}) async {}

  @override
  List<Playlist> get createdPlaylists => const <Playlist>[];

  @override
  List<Playlist> get collectedPlaylists => const <Playlist>[];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// A [AuthProvider] stand-in exposing a controllable [isLoggedIn].
class _StubAuthProvider extends ChangeNotifier implements AuthProvider {
  _StubAuthProvider({bool loggedIn = false}) : _loggedIn = loggedIn;

  bool _loggedIn;

  @override
  bool get isLoggedIn => _loggedIn;

  // No profile fetched in the stub → the account card renders its "Signed in"
  // fallback (nickname unknown) which this test asserts on.
  @override
  NeteaseAccount? get account => null;

  @override
  Future<void> logout() async {
    _loggedIn = false;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// A [SearchProvider] stand-in supplying just the empty history the search
/// landing reads.
class _StubSearchProvider extends ChangeNotifier implements SearchProvider {
  @override
  List<String> get history => const <String>[];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// A [LocalPlaylistProvider] stand-in supplying the empty local-playlist list the
/// Library section (and the player's add-to-local sheet) read.
class _StubLocalPlaylistProvider extends ChangeNotifier
    implements LocalPlaylistProvider {
  @override
  List<LocalPlaylist> get playlists => const <LocalPlaylist>[];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

Future<void> _pumpApp(
  WidgetTester tester, {
  required _StubLibraryProvider library,
  required _StubPlayerProvider player,
  required _StubAuthProvider auth,
  required _StubSearchProvider search,
}) async {
  await tester.pumpWidget(
    MultiProvider(
      providers: <SingleChildWidget>[
        ChangeNotifierProvider<MusicApiRouter>.value(
          value: MusicApiRouter(migu: MiguApi(), netease: MiguApi(), kugou: MiguApi(), kugougn: MiguApi(), qqcn: MiguApi()),
        ),
        ChangeNotifierProvider<PlayerProvider>.value(value: player),
        ChangeNotifierProvider<LibraryProvider>.value(value: library),
        ChangeNotifierProvider<AuthProvider>.value(value: auth),
        ChangeNotifierProvider<SearchProvider>.value(value: search),
        ChangeNotifierProvider<LocalPlaylistProvider>.value(
          value: _StubLocalPlaylistProvider(),
        ),
        // LyricsPage reads FftService in initState (to start/stop the visualizer).
        // A bare instance is fine in tests — start() catches the missing platform
        // channel and no-ops.
        Provider<FftService>.value(value: FftService()),
        ChangeNotifierProvider<SettingsProvider>(
          create: (_) => SettingsProvider(
            router: MusicApiRouter(migu: MiguApi(), netease: MiguApi(), kugou: MiguApi(), kugougn: MiguApi(), qqcn: MiguApi()),
            store: SettingsStore(),
            source: MusicSource.netease,
            rhythmEnabled: false,
          ),
        ),
      ],
      child: MaterialApp.router(
        theme: AppTheme.dark(),
        routerConfig: AppRouter.router,
      ),
    ),
  );
  // Run the post-frame callback (HomePage.initState -> loadHome). Do NOT settle:
  // skeleton shimmers + the art background animate forever.
  await tester.pump();
}

Widget _wrapPage(
  Widget page, {
  required _StubPlayerProvider player,
  _StubLibraryProvider? library,
  _StubAuthProvider? auth,
}) {
  return MultiProvider(
    providers: <SingleChildWidget>[
      ChangeNotifierProvider<PlayerProvider>.value(value: player),
      ChangeNotifierProvider<LocalPlaylistProvider>.value(
        value: _StubLocalPlaylistProvider(),
      ),
      if (library != null)
        ChangeNotifierProvider<LibraryProvider>.value(value: library),
      if (auth != null)
        ChangeNotifierProvider<AuthProvider>.value(value: auth),
      // LibraryPage reads the current source; Netease keeps it on the AuthProvider
      // path (QQ/Kugou providers are only read on their own source).
      ChangeNotifierProvider<SettingsProvider>(
        create: (_) => SettingsProvider(
          router: MusicApiRouter(
              migu: MiguApi(), netease: MiguApi(), kugou: MiguApi(), kugougn: MiguApi(), qqcn: MiguApi()),
          store: SettingsStore(),
          source: MusicSource.netease,
          rhythmEnabled: false,
        ),
      ),
    ],
    child: MaterialApp(theme: AppTheme.dark(), home: page),
  );
}

void main() {
  testWidgets(
      'AppRouter renders the three nav tabs and the full-screen routes',
      (WidgetTester tester) async {
    final _StubLibraryProvider library =
        _StubLibraryProvider(tracks: _tracks());
    final _StubPlayerProvider player = _StubPlayerProvider();
    final _StubAuthProvider auth = _StubAuthProvider();
    final _StubSearchProvider search = _StubSearchProvider();

    await _pumpApp(
      tester,
      library: library,
      player: player,
      auth: auth,
      search: search,
    );

    // Home tab is live, with the three-tab glass bottom nav beneath it.
    expect(find.byType(HomePage), findsOneWidget);
    expect(find.byType(AppBottomNav), findsOneWidget);
    final Finder nav = find.byType(AppBottomNav);
    expect(find.descendant(of: nav, matching: find.text('Home')),
        findsOneWidget);
    expect(find.descendant(of: nav, matching: find.text('Search')),
        findsOneWidget);
    expect(find.descendant(of: nav, matching: find.text('Library')),
        findsOneWidget);

    // Tab → Search.
    await tester.tap(find.descendant(of: nav, matching: find.text('Search')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byType(SearchPage), findsOneWidget);

    // Tab → Library (logged out → login CTA).
    await tester.tap(find.descendant(of: nav, matching: find.text('Library')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byType(LibraryPage), findsOneWidget);

    // Tab → Home.
    await tester.tap(find.descendant(of: nav, matching: find.text('Home')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byType(HomePage), findsOneWidget);

    // Push /playlist/123 (top-level route) → PlaylistPage.
    AppRouter.router.push(Routes.playlistPath(123));
    await tester.pump();
    await tester.pump(); // loadPlaylist future resolves + notifyListeners
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byType(PlaylistPage), findsOneWidget);
    expect(library.lastLoadedId, 123);
    AppRouter.router.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    // Push /player → PlayerPage.
    AppRouter.router.push(Routes.player);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byType(PlayerPage), findsOneWidget);
    AppRouter.router.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    // /lyrics is now integrated into PlayerPage (no separate route).
    // Pushing Routes.lyrics redirects to /player.
    AppRouter.router.push(Routes.lyrics);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byType(PlayerPage), findsOneWidget);
    AppRouter.router.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  });

  testWidgets('PlaylistPage lists tracks and plays the queue on tap',
      (WidgetTester tester) async {
    final List<Song> tracks = _tracks();
    final _StubLibraryProvider library = _StubLibraryProvider(tracks: tracks);
    final _StubPlayerProvider player = _StubPlayerProvider();

    await tester.pumpWidget(
      _wrapPage(
        const PlaylistPage(playlistId: 7),
        player: player,
        library: library,
      ),
    );
    await tester.pump(); // post-frame _load
    await tester.pump(); // loadPlaylist resolves + notifyListeners
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.byType(PlaylistPage), findsOneWidget);
    expect(library.lastLoadedId, 7);
    expect(find.text('Track 0'), findsOneWidget);

    await tester.tap(find.text('Track 1'));
    await tester.pump();

    expect(player.playQueueCalls, hasLength(1));
    expect(player.playQueueCalls.first, hasLength(3));
    expect(player.playQueueIndexes.first, 1);
  });

  testWidgets('LibraryPage shows the scan-to-log-in CTA when logged out',
      (WidgetTester tester) async {
    final _StubPlayerProvider player = _StubPlayerProvider();
    final _StubAuthProvider auth = _StubAuthProvider(loggedIn: false);

    await tester.pumpWidget(
      _wrapPage(const LibraryPage(), player: player, auth: auth),
    );
    await tester.pump();

    expect(find.text('Library'), findsOneWidget);
    expect(find.text('登录网易云'), findsOneWidget);
  });

  testWidgets('LibraryPage shows the account row when logged in',
      (WidgetTester tester) async {
    final _StubPlayerProvider player = _StubPlayerProvider();
    final _StubAuthProvider auth = _StubAuthProvider(loggedIn: true);

    await tester.pumpWidget(
      _wrapPage(
        const LibraryPage(),
        player: player,
        auth: auth,
        library: _StubLibraryProvider(),
      ),
    );
    await tester.pump();

    expect(find.text('网易云用户'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '退出'), findsOneWidget);
  });
}
