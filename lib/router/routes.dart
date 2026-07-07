import 'package:flutter/widgets.dart';

/// Navigator key for the root navigator (top-level routes / overlays).
final GlobalKey<NavigatorState> rootNavigatorKey =
    GlobalKey<NavigatorState>(debugLabel: 'root');

/// Route paths, names and tab indices. FROZEN — every stream references these.
class Routes {
  Routes._();

  // Paths.
  static const String home = '/';
  static const String search = '/search';

  /// Sub-route (relative) path under [search].
  static const String searchResults = 'results';
  static const String library = '/library';
  static const String player = '/player';
  static const String lyrics = '/lyrics';
  static const String login = '/login';

  /// Kugou (酷狗) QR login — separate from the Netease [login] above.
  static const String kugouLogin = '/login/kugou';

  /// QQ Music scan login (微信 / QQ).
  static const String qqLogin = '/login/qq';
  /// Kuwo (酷我) password+captcha login.
  static const String kuwoLogin = '/login/kuwo';
  static const String nKuwoLogin = 'kuwoLogin';

  static const String profile = '/profile';

  /// Multi-account manager (网易 + 酷狗).
  static const String accounts = '/accounts';
  static const String settings = '/settings';
  static const String playlist = '/playlist/:id';

  /// Local ("共同歌单") playlist detail. Its id is an opaque `lp_…` STRING (not an
  /// int), kept distinct from the backend [playlist] route above.
  static const String localPlaylist = '/local/:id';

  static String playlistPath(int id) => '/playlist/$id';

  static String localPlaylistPath(String id) => '/local/$id';

  // Names.
  static const String nHome = 'home';
  static const String nSearch = 'search';
  static const String nSearchResults = 'searchResults';
  static const String nLibrary = 'library';
  static const String nPlayer = 'player';
  static const String nLyrics = 'lyrics';
  static const String nLogin = 'login';
  static const String nKugouLogin = 'kugouLogin';
  static const String nQqLogin = 'qqLogin';
  static const String nProfile = 'profile';
  static const String nAccounts = 'accounts';
  static const String nSettings = 'settings';
  static const String nPlaylist = 'playlist';
  static const String nLocalPlaylist = 'localPlaylist';

  // Bottom-nav tab order.
  static const int tabHome = 0;
  static const int tabSearch = 1;
  static const int tabLibrary = 2;
}
