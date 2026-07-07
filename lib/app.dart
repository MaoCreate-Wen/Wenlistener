import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';

import 'models/playlist.dart';
import 'models/song.dart';
import 'router/app_router.dart';
import 'services/artwork_palette.dart';
import 'services/audio_service.dart';
import 'services/cookie_store.dart';
import 'services/fft_service.dart';
import 'services/kugou_account_store.dart';
import 'services/kugou_api.dart';
import 'services/kuwo_api.dart';
import 'services/kuwo_cookie_store.dart';
import 'services/local_music_scanner.dart';
import 'services/local_playlist_store.dart';
import 'services/music_api_router.dart';
import 'services/netease_api.dart';
import 'services/netease_crypto.dart';
import 'services/qq_api.dart';
import 'services/qq_cookie_store.dart';
import 'state/auth_provider.dart';
import 'state/kugou_auth_provider.dart';
import 'state/kuwo_auth_provider.dart';
import 'state/library_provider.dart';
import 'state/local_playlist_provider.dart';
import 'state/qq_auth_provider.dart';
import 'state/player_provider.dart';
import 'state/search_provider.dart';
import 'state/settings_provider.dart';
import 'theme/app_theme.dart';

/// Root widget. Services are built in `main()` and injected here. The two
/// backends (Migu + Netease) are multiplexed by [MusicApiRouter] (default Migu);
/// the four page-facing providers (+ the services they wrap) are exposed via
/// [MultiProvider].
class WenListenerApp extends StatelessWidget {
  final CookieStore cookieStore;
  final Dio dio;
  final NeteaseCrypto crypto;
  final NeteaseApi neteaseApi;
  final QqApi qqApi;
  final QqCookieStore qqCookies;
  final KugouApi kugouApi;
  final KuwoApi kuwoApi;
  final KuwoCookieStore kuwoCookies;
  final MusicApiRouter musicApi;
  final AudioService audio;
  final ArtworkPalette palette;
  final FftService fft;
  final SettingsProvider settings;

  const WenListenerApp({
    super.key,
    required this.cookieStore,
    required this.dio,
    required this.crypto,
    required this.neteaseApi,
    required this.qqApi,
    required this.qqCookies,
    required this.kugouApi,
    required this.kuwoApi,
    required this.kuwoCookies,
    required this.musicApi,
    required this.audio,
    required this.palette,
    required this.fft,
    required this.settings,
  });

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: <SingleChildWidget>[
        Provider<CookieStore>.value(value: cookieStore),
        Provider<Dio>.value(value: dio),
        Provider<NeteaseCrypto>.value(value: crypto),
        Provider<NeteaseApi>.value(value: neteaseApi),
        Provider<QqApi>.value(value: qqApi),
        Provider<AudioService>.value(value: audio),
        Provider<ArtworkPalette>.value(value: palette),
        Provider<FftService>.value(value: fft),
        // The router is a ChangeNotifier so the UI source switcher rebuilds when
        // the active backend flips.
        ChangeNotifierProvider<MusicApiRouter>.value(value: musicApi),
        ChangeNotifierProvider<SettingsProvider>.value(value: settings),
        ChangeNotifierProvider<PlayerProvider>(
          create: (_) => PlayerProvider(
            audio: audio,
            api: musicApi,
            palette: palette,
            lowFreqVolume: fft.lowFreqVolume,
          ),
        ),
        ChangeNotifierProvider<SearchProvider>(
          create: (_) => SearchProvider(api: musicApi),
        ),
        ChangeNotifierProvider<LibraryProvider>(
          create: (_) => LibraryProvider(api: musicApi),
        ),
        // Local "共同歌单" — cross-source, on-device playlists. Self-contained
        // (only needs its own on-device store), so it's created here rather than
        // threaded through the app constructor.
        ChangeNotifierProvider<LocalPlaylistProvider>(
          create: (_) => LocalPlaylistProvider(
            store: LocalPlaylistStore(),
            scanner: const LocalMusicScanner(),
          ),
        ),
        ChangeNotifierProvider<AuthProvider>(
          // Eager (not lazy): AuthProvider must construct at startup so it can
          // validate a *restored* session against the server even when the user
          // lands on the Home tab and never opens Library/login (the only places
          // that read it). While lazy, the stale-session check never ran, leaving
          // an expired MUSIC_U trusted forever (每日推荐/我的歌单/逐字歌词 all fail).
          lazy: false,
          create: (_) => AuthProvider(
            api: neteaseApi,
            cookies: cookieStore,
            router: musicApi,
          ),
        ),
        // Kugou multi-account manager. Eager (not lazy) so the persisted active
        // account is re-installed into KugouApi at startup — otherwise a Kugou
        // track played before the accounts page is ever opened would resolve
        // anonymously (null → skip) despite a saved login.
        ChangeNotifierProvider<KugouAuthProvider>(
          lazy: false,
          create: (_) => KugouAuthProvider(
            api: kugouApi,
            store: KugouAccountStore(),
            router: musicApi,
          ),
        ),
        // QQ Music login (replaces Migu). Eager so a restored session validates at
        // startup; QQ needs a login for everything, so this gates the whole source.
        ChangeNotifierProvider<QqAuthProvider>(
          lazy: false,
          create: (_) => QqAuthProvider(
            api: qqApi,
            cookies: qqCookies,
            router: musicApi,
          ),
        ),
        // Kuwo (酷我) password login. Lazy is fine — it doesn't need to
        // pre-install any credentials at startup.
        ChangeNotifierProvider<KuwoAuthProvider>(
          create: (_) => KuwoAuthProvider(
            api: kuwoApi,
            cookies: kuwoCookies,
            router: musicApi,
          ),
        ),
      ],
      // Seed the in-app liked hearts from the user's liked playlist — needs both
      // PlayerProvider + LibraryProvider, so it sits here just below the
      // MultiProvider, wrapping the router.
      child: _LikedSeeder(
        child: MaterialApp.router(
          title: 'WenListener',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark(),
          routerConfig: AppRouter.router,
        ),
      ),
    );
  }
}

/// Seeds [PlayerProvider]'s liked set from the user's "liked" playlist so songs
/// liked in a previous session show a filled in-app heart. Needs both
/// [LibraryProvider] (to fetch the liked playlist's tracks) and [PlayerProvider]
/// (to seed them via [PlayerProvider.markLiked]). Sits just below the
/// [MultiProvider], wrapping the router. The in-app like button
/// ([PlayerProvider.toggleLike] / [PlayerProvider.setLiked]) is independent of
/// this and untouched.
class _LikedSeeder extends StatefulWidget {
  final Widget child;
  const _LikedSeeder({required this.child});

  @override
  State<_LikedSeeder> createState() => _LikedSeederState();
}

class _LikedSeederState extends State<_LikedSeeder> {
  LibraryProvider? _library;
  PlayerProvider? _player;

  /// One-shot guard so the liked playlist's tracks are fetched (to seed the
  /// hearts) only once per login; reset on sign-out so a later/other login
  /// re-seeds. See [_onLibraryChanged].
  bool _likedSeeded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    final LibraryProvider library = context.read<LibraryProvider>();
    if (!identical(library, _library)) {
      _library?.removeListener(_onLibraryChanged);
      _library = library..addListener(_onLibraryChanged);
    }

    _player = context.read<PlayerProvider>();

    // The user's playlists may already be populated by the time we wire up
    // (restored login) — seed the liked hearts now if so.
    _onLibraryChanged();
  }

  /// Seeds [PlayerProvider]'s liked set from the user's liked playlist so songs
  /// already liked in a previous session show a filled in-app heart. The liked
  /// playlist is the first user playlist (Netease's "我喜欢的音乐"); its full track
  /// list is fetched once, lazily, the first time the playlists are known. Resets
  /// on sign-out (userPlaylists empties) so a later login re-seeds.
  void _onLibraryChanged() {
    final LibraryProvider? library = _library;
    final PlayerProvider? player = _player;
    if (library == null || player == null) return;
    if (library.userPlaylists.isEmpty) {
      _likedSeeded = false; // signed out / not loaded — allow a later re-seed.
      return;
    }
    if (_likedSeeded) return;
    _likedSeeded = true; // set before the await so we fetch exactly once.
    final int likedId = library.userPlaylists.first.id;
    unawaited(_seedLikedFromPlaylist(likedId, library, player));
  }

  Future<void> _seedLikedFromPlaylist(
      int likedId, LibraryProvider library, PlayerProvider player) async {
    try {
      final Playlist liked = await library.loadPlaylist(likedId);
      player.markLiked(liked.tracks.map((Song s) => s.id));
    } catch (e) {
      debugPrint('seed liked hearts failed: $e');
      _likedSeeded = false; // let the next library change retry.
    }
  }

  @override
  void dispose() {
    _library?.removeListener(_onLibraryChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
