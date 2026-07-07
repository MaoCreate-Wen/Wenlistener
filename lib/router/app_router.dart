import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../pages/accounts/accounts_page.dart';
import '../pages/home/home_page.dart';
import '../pages/library/library_page.dart';
import '../pages/local_playlist/local_playlist_page.dart';
import '../pages/login/kugou_qr_login_page.dart';
import '../pages/login/kuwo_login_page.dart';
import '../pages/login/qq_qr_login_page.dart';
import '../pages/login/qr_login_page.dart';
import '../pages/lyrics/lyrics_page.dart';
import '../pages/player/player_page.dart';
import '../pages/playlist/playlist_page.dart';
import '../pages/profile/profile_page.dart';
import '../pages/search/search_page.dart';
import '../pages/settings/settings_page.dart';
import '../pages/search/search_results_page.dart';
import '../shell/home_shell.dart';
import 'routes.dart';

/// The real application route table (replaces the foundation bootstrap).
///
/// A [StatefulShellRoute.indexedStack] hosts the three persistent tabs
/// (Home / Search / Library) inside [HomeShell], so the glass bottom-nav and the
/// always-mounted mini-player survive tab switches. The full-screen routes
/// (player, lyrics, login, playlist) are pushed onto [rootNavigatorKey] so they
/// cover the shell — the mini-player hides behind them.
class AppRouter {
  AppRouter._();

  /// Shared push/pop slide for the drag-to-dismiss sheets (`/player`, `/lyrics`):
  /// up from the bottom on push, back down on pop.
  ///
  /// The push decelerates into place (`easeOutCubic`). The pop uses an **ease-IN**
  /// `reverseCurve` so it LEAVES promptly. A plain `easeOutCubic` keyed to the
  /// (reversing) `animation` crawls through the first half of the pop — the page
  /// barely moves until ~½-way, then rushes the last third — which reads as an
  /// obvious "过半时等待零点几秒" mid-dismiss dwell. The ease-in reverse removes it.
  static Widget _sheetTransition(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(0, 1),
        end: Offset.zero,
      ).animate(CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      )),
      child: child,
    );
  }

  /// "Route-jump + Hero" for `/lyrics`: the page itself does NOT slide or fade — it
  /// appears/leaves instantly while the shared `album_art` Hero provides ALL the
  /// motion (cover flies player→header on push, header→player on pop). No slide =
  /// no "从下往上/从上往下" complaint; no fade = no momentary solid-bg flash. The
  /// ONLY slide on this page is the grabber's own DismissibleSheet drag (→ home).
  static Widget _heroOnlyTransition(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) =>
      child;


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
            HomeShell(navigationShell: navigationShell),
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
          // Branch 1 — Search (with the pushed results child route).
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: Routes.search,
                name: Routes.nSearch,
                builder: (BuildContext context, GoRouterState state) =>
                    const SearchPage(),
                routes: <RouteBase>[
                  GoRoute(
                    path: Routes.searchResults, // '/search/results'
                    name: Routes.nSearchResults,
                    builder: (BuildContext context, GoRouterState state) =>
                        const SearchResultsPage(),
                  ),
                ],
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

      // --- full-screen routes (over the shell) ------------------------------
      // The player is a drag-to-dismiss sheet: it slides up over the shell on push.
      // EXIT (back button, grabber tap, over-threshold fling) pops the route, which
      // triggers the 300ms reverse slide and flies the shared `album_art` Hero back
      // into the mini-player. `opaque: true` prevents the shell from painting through
      // the player during the internal lyrics-mode animation, eliminating the brief
      // background flash when the album cover taps to open lyrics.
      GoRoute(
        path: Routes.player,
        name: Routes.nPlayer,
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (BuildContext context, GoRouterState state) =>
            CustomTransitionPage<void>(
          key: state.pageKey,
          opaque: true,
          barrierColor: Colors.transparent,
          transitionDuration: const Duration(milliseconds: 340),
          reverseTransitionDuration: const Duration(milliseconds: 300),
          transitionsBuilder: _sheetTransition,
          child: const PlayerPage(),
        ),
      ),
      // /lyrics is now handled INSIDE the player page (integrated lyrics panel).
      // This stub keeps old pushes of Routes.lyrics from crashing — it just
      // redirects to /player.
      GoRoute(
        path: Routes.lyrics,
        name: Routes.nLyrics,
        parentNavigatorKey: rootNavigatorKey,
        redirect: (_, __) => Routes.player,
      ),
      GoRoute(
        path: Routes.login,
        name: Routes.nLogin,
        parentNavigatorKey: rootNavigatorKey,
        builder: (BuildContext context, GoRouterState state) =>
            const QrLoginPage(),
      ),
      GoRoute(
        path: Routes.kugouLogin, // '/login/kugou'
        name: Routes.nKugouLogin,
        parentNavigatorKey: rootNavigatorKey,
        builder: (BuildContext context, GoRouterState state) =>
            const KugouQrLoginPage(),
      ),
      GoRoute(
        path: Routes.kuwoLogin, // '/login/kuwo'
        name: Routes.nKuwoLogin,
        parentNavigatorKey: rootNavigatorKey,
        builder: (BuildContext context, GoRouterState state) =>
            const KuwoLoginPage(),
      ),
      GoRoute(
        path: Routes.qqLogin, // '/login/qq'
        name: Routes.nQqLogin,
        parentNavigatorKey: rootNavigatorKey,
        builder: (BuildContext context, GoRouterState state) =>
            const QqQrLoginPage(),
      ),
      GoRoute(
        path: Routes.profile,
        name: Routes.nProfile,
        parentNavigatorKey: rootNavigatorKey,
        builder: (BuildContext context, GoRouterState state) =>
            const ProfilePage(),
      ),
      GoRoute(
        path: Routes.accounts,
        name: Routes.nAccounts,
        parentNavigatorKey: rootNavigatorKey,
        builder: (BuildContext context, GoRouterState state) =>
            const AccountsPage(),
      ),
      GoRoute(
        path: Routes.settings,
        name: Routes.nSettings,
        parentNavigatorKey: rootNavigatorKey,
        builder: (BuildContext context, GoRouterState state) =>
            const SettingsPage(),
      ),
      GoRoute(
        path: Routes.playlist, // '/playlist/:id'
        name: Routes.nPlaylist,
        parentNavigatorKey: rootNavigatorKey,
        builder: (BuildContext context, GoRouterState state) => PlaylistPage(
          playlistId: int.tryParse(state.pathParameters['id'] ?? '') ?? 0,
        ),
      ),
      GoRoute(
        path: Routes.localPlaylist, // '/local/:id'
        name: Routes.nLocalPlaylist,
        parentNavigatorKey: rootNavigatorKey,
        builder: (BuildContext context, GoRouterState state) =>
            LocalPlaylistPage(
          playlistId: state.pathParameters['id'] ?? '',
        ),
      ),
    ],
  );
}
