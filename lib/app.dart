import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'shell/desktop_window_frame.dart';
import 'shell/fullscreen_controller.dart';
import 'shell/nav_history.dart';
import 'state/auth_provider.dart';
import 'state/kugou_auth_provider.dart';
import 'state/kuwo_auth_provider.dart';
import 'state/library_provider.dart';
import 'state/local_playlist_provider.dart';
import 'state/player_provider.dart';
import 'state/qq_auth_provider.dart';
import 'state/search_provider.dart';
import 'state/settings_provider.dart';
import 'theme/app_theme.dart';

/// Root widget for the **desktop** client. Services are built in `main()` and
/// injected here (same 15-arg wiring as mobile — the reused logic layer is
/// identical). The four backends are multiplexed by [MusicApiRouter]; the
/// page-facing providers (+ the services they wrap) are exposed via
/// [MultiProvider]. The desktop-only difference from mobile is the
/// `MaterialApp.router` `builder:` — it pins the frameless [DesktopWindowFrame]
/// (custom title bar + window controls) above every route.
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
        // Plain services via Provider.value (UI reads, never rebuilds on them).
        Provider<CookieStore>.value(value: cookieStore),
        Provider<Dio>.value(value: dio),
        Provider<NeteaseCrypto>.value(value: crypto),
        Provider<NeteaseApi>.value(value: neteaseApi),
        Provider<QqApi>.value(value: qqApi),
        Provider<AudioService>.value(value: audio),
        Provider<ArtworkPalette>.value(value: palette),
        Provider<FftService>.value(value: fft),
        // The router is a ChangeNotifier so the source switcher rebuilds on flip.
        ChangeNotifierProvider<MusicApiRouter>.value(value: musicApi),
        ChangeNotifierProvider<SettingsProvider>.value(value: settings),
        // Browser-style ◀ ▶ history for the desktop top bar, driven by the
        // go_router location. Created once against the app's single router.
        ChangeNotifierProvider<NavHistory>(
          create: (_) => NavHistory(AppRouter.router),
        ),
        // Page-facing providers.
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
        // Local "共同歌单" — cross-source on-device playlists; self-contained.
        ChangeNotifierProvider<LocalPlaylistProvider>(
          create: (_) => LocalPlaylistProvider(
            store: LocalPlaylistStore(),
            scanner: const LocalMusicScanner(),
          ),
        ),
        // Auth — the lazy flags are load-bearing (see DESKTOP_WIRING §3).
        // Netease: eager so a restored session validates at startup.
        ChangeNotifierProvider<AuthProvider>(
          lazy: false,
          create: (_) => AuthProvider(
            api: neteaseApi,
            cookies: cookieStore,
            router: musicApi,
          ),
        ),
        // Kugou: eager so the persisted active account is re-installed into
        // KugouApi at startup (else a Kugou track played before the accounts page
        // is opened would resolve anonymously despite a saved login).
        ChangeNotifierProvider<KugouAuthProvider>(
          lazy: false,
          create: (_) => KugouAuthProvider(
            api: kugouApi,
            store: KugouAccountStore(),
            router: musicApi,
          ),
        ),
        // QQ: eager so a restored session validates at startup (QQ needs a login
        // for everything, so this gates the whole source).
        ChangeNotifierProvider<QqAuthProvider>(
          lazy: false,
          create: (_) => QqAuthProvider(
            api: qqApi,
            cookies: qqCookies,
            router: musicApi,
          ),
        ),
        // Kuwo: password login — no startup credential push, so lazy is fine.
        ChangeNotifierProvider<KuwoAuthProvider>(
          create: (_) => KuwoAuthProvider(
            api: kuwoApi,
            cookies: kuwoCookies,
            router: musicApi,
          ),
        ),
      ],
      // Seed the in-app liked hearts from the user's liked playlist — needs both
      // PlayerProvider + LibraryProvider, so it sits just below the MultiProvider.
      child: _LikedSeeder(
        child: MaterialApp.router(
          title: 'WenListener',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark(),
          routerConfig: AppRouter.router,
          // Desktop-only: pin the custom frameless title bar above every route
          // (shell AND pushed full-screen routes) so window controls stay
          // reachable. Pure pass-through on non-Windows. The fullscreen key
          // scope sits above the frame so F11 / Esc work on every route.
          builder: (BuildContext context, Widget? child) => _FullscreenKeyScope(
            child: DesktopWindowFrame(child: child ?? const SizedBox.shrink()),
          ),
        ),
      ),
    );
  }
}

/// App-wide 沉浸全屏 key handling, mounted in `MaterialApp.router`'s `builder:`
/// so it covers every route (shell branches AND pushed player/lyrics surfaces).
///
///  - **F11** toggles fullscreen from anywhere — the handler is registered on
///    [HardwareKeyboard], which runs *before* focus dispatch, so F11 works even
///    while the search `TextField` owns focus (a focus-chain `Shortcuts` would
///    be preempted there and would also go dead when nothing holds focus).
///  - **Esc** exits fullscreen, but ONLY while fullscreen is active — otherwise
///    the event is left alone (returns false) so dialogs/menus still close.
class _FullscreenKeyScope extends StatefulWidget {
  final Widget child;
  const _FullscreenKeyScope({required this.child});

  @override
  State<_FullscreenKeyScope> createState() => _FullscreenKeyScopeState();
}

class _FullscreenKeyScopeState extends State<_FullscreenKeyScope> {
  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (event.logicalKey == LogicalKeyboardKey.f11) {
      unawaited(FullscreenController.toggle());
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape &&
        FullscreenController.isFullscreen.value) {
      unawaited(FullscreenController.setFullscreen(false));
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Seeds [PlayerProvider]'s liked set from the user's "liked" playlist so songs
/// liked in a previous session show a filled in-app heart. Copied verbatim from
/// the mobile app — it only touches [LibraryProvider] + [PlayerProvider] (no
/// Android-specific bits).
class _LikedSeeder extends StatefulWidget {
  final Widget child;
  const _LikedSeeder({required this.child});

  @override
  State<_LikedSeeder> createState() => _LikedSeederState();
}

class _LikedSeederState extends State<_LikedSeeder> {
  LibraryProvider? _library;
  PlayerProvider? _player;

  /// One-shot guard so the liked playlist's tracks are fetched only once per
  /// login; reset on sign-out so a later/other login re-seeds.
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

    // Restored login may already have populated the playlists — seed now if so.
    _onLibraryChanged();
  }

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
