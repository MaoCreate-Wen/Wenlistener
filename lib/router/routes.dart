import 'package:flutter/widgets.dart';

/// Navigator key for the root navigator (full-screen routes / overlays that cover
/// the desktop shell — player, lyrics, playlist detail, login, accounts).
final GlobalKey<NavigatorState> rootNavigatorKey =
    GlobalKey<NavigatorState>(debugLabel: 'root');

/// Frozen route paths, names and sidebar indices for the desktop client.
///
/// The persistent shell hosts four branches (首页 / 搜索 / 音乐库 / 设置) behind the
/// left sidebar; everything else is a full-screen route pushed on
/// [rootNavigatorKey]. Page agents reference these constants — do NOT inline
/// string paths.
class Routes {
  Routes._();

  // --- shell branch paths ---------------------------------------------------
  static const String home = '/';
  static const String search = '/search';
  static const String library = '/library';
  static const String settings = '/settings';

  // --- full-screen (root navigator) paths -----------------------------------
  static const String player = '/player';
  static const String lyrics = '/lyrics';
  static const String accounts = '/accounts';

  /// Backend playlist detail. `:id` is the integer playlist id; the active source
  /// resolves it (`LibraryProvider.loadPlaylist`).
  static const String playlist = '/playlist/:id';

  /// Local ("共同歌单") playlist detail. `:id` is an opaque `lp_…` STRING id, kept
  /// distinct from the backend [playlist] route above.
  static const String localPlaylist = '/local/:id';

  /// Per-source login. `:source` ∈ { netease, qq, kugou, kuwo }. Netease/Kugou/QQ
  /// render a QR panel; Kuwo renders a password form.
  static const String login = '/login/:source';

  // --- path builders --------------------------------------------------------
  static String playlistPath(int id) => '/playlist/$id';
  static String localPlaylistPath(String id) => '/local/$id';
  static String loginPath(String source) => '/login/$source';

  // --- route names ----------------------------------------------------------
  static const String nHome = 'home';
  static const String nSearch = 'search';
  static const String nLibrary = 'library';
  static const String nSettings = 'settings';
  static const String nPlayer = 'player';
  static const String nLyrics = 'lyrics';
  static const String nAccounts = 'accounts';
  static const String nPlaylist = 'playlist';
  static const String nLocalPlaylist = 'localPlaylist';
  static const String nLogin = 'login';

  // --- sidebar nav order ----------------------------------------------------
  static const int navHome = 0;
  static const int navSearch = 1;
  static const int navLibrary = 2;
  static const int navSettings = 3;
}
