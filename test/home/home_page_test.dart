import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';
import 'package:wenlistener/models/artist.dart';
import 'package:wenlistener/models/home_section.dart';
import 'package:wenlistener/models/playlist.dart';
import 'package:wenlistener/models/song.dart';
import 'package:wenlistener/pages/home/home_page.dart';
import 'package:wenlistener/pages/home/widgets/carousel_section.dart';
import 'package:wenlistener/pages/home/widgets/recommended_grid.dart';
import 'package:wenlistener/pages/home/widgets/greeting_header.dart';
import 'package:wenlistener/services/migu_api.dart';
import 'package:wenlistener/services/music_api_router.dart';
import 'package:wenlistener/services/settings_store.dart';
import 'package:wenlistener/state/library_provider.dart';
import 'package:wenlistener/state/player_provider.dart';
import 'package:wenlistener/state/settings_provider.dart';
import 'package:wenlistener/theme/app_colors.dart';
import 'package:wenlistener/theme/app_theme.dart';
import 'package:wenlistener/widgets/skeleton_box.dart';

/// A lightweight [LibraryProvider] stub: it exposes controllable home state and
/// counts [loadHome] invocations, so the page can be driven without any network
/// or real [NeteaseApi]. Unimplemented members route to [noSuchMethod].
class _FakeLibraryProvider extends ChangeNotifier implements LibraryProvider {
  _FakeLibraryProvider({
    bool loading = false,
    bool error = false,
    List<HomeSection> sections = const <HomeSection>[],
  })  : _loading = loading,
        _error = error,
        _sections = sections;

  bool _loading;
  bool _error;
  List<HomeSection> _sections;
  int loadHomeCalls = 0;

  @override
  bool get homeLoading => _loading;

  @override
  bool get homeError => _error;

  @override
  List<HomeSection> get homeSections => _sections;

  @override
  Future<void> loadHome() async {
    loadHomeCalls++;
  }

  void update({
    bool? loading,
    bool? error,
    List<HomeSection>? sections,
  }) {
    if (loading != null) _loading = loading;
    if (error != null) _error = error;
    if (sections != null) _sections = sections;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// A [PlayerProvider] stub that only supplies what [AppScaffold] /
/// [RecommendedGrid] read, avoiding the real audio stack (just_audio).
class _FakePlayerProvider extends ChangeNotifier implements PlayerProvider {
  static const Gradient _gradient = LinearGradient(
    colors: <Color>[AppColors.seed, AppColors.seedDeep],
  );

  @override
  Gradient get dynamicGradient => _gradient;

  @override
  Gradient get washGradient => _gradient;

  @override
  Color get dynamicAccent => AppColors.accentPlay;

  @override
  bool get hasSong => false;

  List<Song>? lastQueue;
  int? lastIndex;

  @override
  Future<void> playQueue(List<Song> songs, {int index = 0}) async {
    lastQueue = songs;
    lastIndex = index;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

Future<void> _pumpHome(
  WidgetTester tester, {
  required _FakeLibraryProvider library,
  _FakePlayerProvider? player,
}) async {
  await tester.pumpWidget(
    MultiProvider(
      providers: <SingleChildWidget>[
        ChangeNotifierProvider<MusicApiRouter>.value(
          value: MusicApiRouter(
              migu: MiguApi(), netease: MiguApi(), kugou: MiguApi(), kugougn: MiguApi(), qqcn: MiguApi()),
        ),
        ChangeNotifierProvider<PlayerProvider>.value(
          value: player ?? _FakePlayerProvider(),
        ),
        ChangeNotifierProvider<LibraryProvider>.value(value: library),
        // HomePage reads the current source (Netease here → the QQ login gate is
        // skipped, so no QqAuthProvider is needed).
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
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: const HomePage(),
      ),
    ),
  );
  // Run the post-frame callback (initState -> loadHome) without settling the
  // forever-repeating skeleton animation.
  await tester.pump();
}

void main() {
  testWidgets('renders a loading skeleton while the first load is in flight',
      (WidgetTester tester) async {
    final _FakeLibraryProvider library = _FakeLibraryProvider(loading: true);

    await _pumpHome(tester, library: library);

    expect(find.byType(HomePage), findsOneWidget);
    expect(find.byType(GreetingHeader), findsOneWidget);
    expect(find.byType(SkeletonBox), findsWidgets);
  });

  testWidgets('renders the playlist carousel sections once loaded',
      (WidgetTester tester) async {
    final _FakeLibraryProvider library = _FakeLibraryProvider(
      sections: const <HomeSection>[
        HomeSection(
          title: '推荐歌单',
          kind: HomeSectionKind.playlistCarousel,
          playlists: <Playlist>[
            Playlist(id: 1, name: '夜间单曲', trackCount: 5),
            Playlist(id: 2, name: '通勤电台', trackCount: 8),
          ],
        ),
      ],
    );

    await _pumpHome(tester, library: library);

    expect(find.byType(CarouselSection), findsOneWidget);
    expect(find.text('推荐歌单'), findsOneWidget);
    expect(find.text('夜间单曲'), findsOneWidget);
    expect(find.byType(GreetingHeader), findsOneWidget);
  });

  testWidgets('renders the daily-songs section with title, subtitle and reason',
      (WidgetTester tester) async {
    const List<Song> songs = <Song>[
      Song(
        id: 20,
        name: '七里香',
        artists: <Artist>[Artist(id: 1, name: '周杰伦')],
        duration: Duration(seconds: 300),
        fee: 0,
        playable: true,
        reason: '因为你常听 周杰伦',
      ),
    ];
    final _FakeLibraryProvider library = _FakeLibraryProvider(
      sections: const <HomeSection>[
        HomeSection(
          title: '每日推荐',
          kind: HomeSectionKind.dailySongs,
          songs: songs,
          subtitle: '根据你的口味生成',
        ),
      ],
    );

    await _pumpHome(tester, library: library);

    // The daily-songs kind reuses RecommendedGrid and surfaces the title, the
    // section subtitle and the per-song recommend reason.
    expect(find.byType(RecommendedGrid), findsOneWidget);
    expect(find.text('每日推荐'), findsOneWidget);
    expect(find.text('根据你的口味生成'), findsOneWidget);
    expect(find.text('七里香'), findsOneWidget);
    expect(find.text('因为你常听 周杰伦'), findsOneWidget);
  });

  testWidgets('calls loadHome on init and shows the empty state when blank',
      (WidgetTester tester) async {
    final _FakeLibraryProvider library = _FakeLibraryProvider();

    await _pumpHome(tester, library: library);

    expect(library.loadHomeCalls, 1);
    expect(find.text('暂时没有推荐内容'), findsOneWidget);
    expect(find.byType(GreetingHeader), findsOneWidget);
  });

  testWidgets('shows a retry affordance on error', (WidgetTester tester) async {
    final _FakeLibraryProvider library = _FakeLibraryProvider(error: true);

    await _pumpHome(tester, library: library);

    expect(find.text('加载失败'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '重试'), findsOneWidget);
  });

  testWidgets('recommended grid plays the queue when a song is tapped',
      (WidgetTester tester) async {
    const List<Song> songs = <Song>[
      Song(
        id: 10,
        name: '夜曲',
        artists: <Artist>[Artist(id: 1, name: '周杰伦')],
        duration: Duration(seconds: 200),
        fee: 0,
        playable: true,
      ),
      Song(
        id: 11,
        name: '晴天',
        artists: <Artist>[Artist(id: 1, name: '周杰伦')],
        duration: Duration(seconds: 210),
        fee: 0,
        playable: true,
      ),
    ];
    final _FakePlayerProvider player = _FakePlayerProvider();
    final _FakeLibraryProvider library = _FakeLibraryProvider(
      sections: const <HomeSection>[
        HomeSection(
          title: '推荐单曲',
          kind: HomeSectionKind.recommendedGrid,
          songs: songs,
        ),
      ],
    );

    await _pumpHome(tester, library: library, player: player);

    expect(find.byType(RecommendedGrid), findsOneWidget);
    expect(find.text('晴天'), findsOneWidget);

    await tester.tap(find.text('晴天'));
    await tester.pump();

    expect(player.lastIndex, 1);
    expect(player.lastQueue, isNotNull);
    expect(player.lastQueue!.length, 2);
  });

  testWidgets('greetingForHour maps the day into buckets',
      (WidgetTester tester) async {
    expect(GreetingHeader.greetingForHour(8), '早上好');
    expect(GreetingHeader.greetingForHour(12), '中午好');
    expect(GreetingHeader.greetingForHour(15), '下午好');
    expect(GreetingHeader.greetingForHour(20), '晚上好');
    expect(GreetingHeader.greetingForHour(2), '夜深了');
  });
}
