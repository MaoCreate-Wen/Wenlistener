import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../animation/neon_flow_background.dart';
import '../pages/home/home_page.dart';
import '../pages/library/library_page.dart';
import '../pages/library/local_playlist_detail_page.dart';
import '../pages/lyrics/lyrics_page.dart';
import '../pages/player/player_page.dart';
import '../pages/playlist/playlist_detail_page.dart';
import '../pages/search/search_page.dart';
import '../shell/app_shell.dart';
import '../state/player_provider.dart';
import '../widgets/artwork_image.dart';
import 'routes.dart';

/// Desktop route table.
///
/// A [StatefulShellRoute.indexedStack] hosts the three persistent branches
/// (首页 / 搜索 / 音乐库) inside [AppShell] so the left sidebar, top bar and docked
/// mini-player survive navigation between them. The full-screen routes (player,
/// lyrics, playlist / local-playlist detail) are pushed on [rootNavigatorKey] so
/// they cover the shell — with a slide-up sheet transition for the player/lyrics.
/// 账号管理 / 设置 / 登录 are now dialogs (see `showAccountsDialog` /
/// `showSettingsDialog` / `showLoginDialog`), not routes.
class AppRouter {
  AppRouter._();

  /// Slide-up (push) / slide-down (pop) transition for the sheet-like full-screen
  /// routes. Decelerates in (`easeOutCubic`), leaves promptly (`easeInCubic`).
  ///
  /// SLIDE ONLY — no page-wide fade. A `FadeTransition` over this whole opaque,
  /// multi-RepaintBoundary page forced a full-window group `saveLayer` (≈14.7MB
  /// at 1440p) for the entire push AND pop, and made every nested offscreen
  /// (mesh blit + per-line lyric blurs) re-composite through that group buffer —
  /// a major contributor to the ~500MB open/close working-set spikes. The page
  /// is `opaque:true` with its own always-painted mesh/wash background, so it
  /// covers the surface beneath as it slides (no black flash / 闪屏), and the
  /// shared-element cover Hero (`'album_art'`) flies ABOVE the page regardless of
  /// the fade. The slide begins only part-way (0.12 down) so the flight isn't
  /// fighting a full-height translation; the same reverses on pop.
  static Widget _sheetTransition(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final CurvedAnimation curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(0, 0.12),
        end: Offset.zero,
      ).animate(curved),
      child: child,
    );
  }

  static CustomTransitionPage<void> _sheetPage(
    GoRouterState state,
    Widget child,
  ) =>
      CustomTransitionPage<void>(
        key: state.pageKey,
        opaque: true,
        barrierColor: Colors.transparent,
        // Matched push/pop windows give the Hero cover flight room to settle at
        // both ends; the flight duration tracks this route transition. Shortened
        // 420/380 → 300/240: the player open/close is a frequent op and both
        // pages raster concurrently for the whole window (+ the mesh field's
        // per-frame offscreen churns through it), so a tighter window directly
        // cuts the transition's memory high-water and CPU cost; easeOutCubic@300
        // still reads as a deliberate sheet.
        transitionDuration: const Duration(milliseconds: 300),
        reverseTransitionDuration: const Duration(milliseconds: 240),
        transitionsBuilder: _sheetTransition,
        child: child,
      );

  static final GoRouter router = GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: Routes.home,
    routes: <RouteBase>[
      StatefulShellRoute.indexedStack(
        builder: (
          BuildContext context,
          GoRouterState state,
          StatefulNavigationShell navigationShell,
        ) =>
            _MeshPrewarmer(child: AppShell(navigationShell: navigationShell)),
        branches: <StatefulShellBranch>[
          // Branch 0 — Home.
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: Routes.home,
                name: Routes.nHome,
                builder: (BuildContext context, GoRouterState state) =>
                    const HomePage(),
              ),
            ],
          ),
          // Branch 1 — Search.
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: Routes.search,
                name: Routes.nSearch,
                builder: (BuildContext context, GoRouterState state) =>
                    const SearchPage(),
              ),
            ],
          ),
          // Branch 2 — Library.
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: Routes.library,
                name: Routes.nLibrary,
                builder: (BuildContext context, GoRouterState state) =>
                    const LibraryPage(),
              ),
            ],
          ),
        ],
      ),

      // --- full-screen routes (over the shell) -----------------------------
      GoRoute(
        path: Routes.player,
        name: Routes.nPlayer,
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (BuildContext context, GoRouterState state) =>
            _sheetPage(state, const PlayerPage()),
      ),
      GoRoute(
        path: Routes.lyrics,
        name: Routes.nLyrics,
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (BuildContext context, GoRouterState state) =>
            _sheetPage(state, const LyricsPage()),
      ),
      GoRoute(
        path: Routes.playlist, // '/playlist/:id'
        name: Routes.nPlaylist,
        parentNavigatorKey: rootNavigatorKey,
        builder: (BuildContext context, GoRouterState state) =>
            PlaylistDetailPage(
          playlistId: int.tryParse(state.pathParameters['id'] ?? '') ?? 0,
        ),
      ),
      GoRoute(
        path: Routes.album, // '/album/:id' — reuses PlaylistDetailPage(isAlbum:true)
        name: Routes.nAlbum,
        parentNavigatorKey: rootNavigatorKey,
        builder: (BuildContext context, GoRouterState state) =>
            PlaylistDetailPage(
          playlistId: int.tryParse(state.pathParameters['id'] ?? '') ?? 0,
          isAlbum: true,
        ),
      ),
      GoRoute(
        path: Routes.localPlaylist, // '/local/:id'
        name: Routes.nLocalPlaylist,
        parentNavigatorKey: rootNavigatorKey,
        builder: (BuildContext context, GoRouterState state) =>
            LocalPlaylistDetailPage(
          playlistId: state.pathParameters['id'] ?? '',
        ),
      ),
    ],
  );
}

/// Always-mounted (wraps [AppShell]) warm-up hook for the now-playing mesh
/// field: whenever the current song's artwork changes it asks
/// [NeonFlowBackground.prewarm] to decode + grade the cover into the shared
/// mesh-texture cache ahead of time. Opening `/player` or `/lyrics` then hits
/// the cache and paints the REAL field from the push's first frame — without
/// this, the first open of a track cross-faded the bright palette wash through
/// the route transition (the desktop 闪屏; the same lesson as the mobile app's
/// "background always-mount" fix, at the cost of one cached 32² texture
/// instead of a permanently mounted live field).
class _MeshPrewarmer extends StatelessWidget {
  final Widget child;

  const _MeshPrewarmer({required this.child});

  @override
  Widget build(BuildContext context) {
    // Rebuilds only when the artwork URL changes (field-level select) or the
    // window size does (MediaQuery.sizeOf). The actual work is deferred to
    // after the frame so build stays pure; prewarm itself dedupes cache hits
    // and in-flight builds, and precacheImage is a no-op map hit once decoded.
    final String? url = context
        .select<PlayerProvider, String?>((p) => p.currentSong?.artworkUrl);
    if (url != null && url.isNotEmpty) {
      final List<Color> colors = context.read<PlayerProvider>().paletteColors;
      // The `/player` Hero-flight rider: decode the cover at its DESTINATION
      // display resolution ahead of the push. The flight shuttle and the
      // settled `_Cover` resolve this exact ResizeImage key (same formula +
      // 64px bucketing in [ArtworkImage.cachePxFor]), so the 420ms flight
      // never kicks off a full cover decode mid-transition — that decode was
      // the black skeleton visibly flying on every first open.
      final int coverPx = ArtworkImage.cachePxFor(
        PlayerPage.coverSizeFor(MediaQuery.sizeOf(context)),
        MediaQuery.devicePixelRatioOf(context),
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        NeonFlowBackground.prewarm(url, colors);
        if (!context.mounted) return;
        precacheImage(ArtworkImage.providerFor(url, coverPx), context);
      });
    }
    return child;
  }
}
