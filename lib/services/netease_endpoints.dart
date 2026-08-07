/// weapi endpoint paths (all POST under [base]).
class NeteaseEndpoints {
  NeteaseEndpoints._();

  static const String base = 'https://music.163.com';

  // `/weapi/cloudsearch/get/web` now returns risk-control code 50000005 for
  // anonymous callers; `/weapi/cloudsearch/pc` serves the same rich shape
  // (al.picUrl, ar[], dt, privilege) and still works without login.
  static const String search = '/weapi/cloudsearch/pc';
  static const String songDetail = '/weapi/v3/song/detail';
  static const String songUrl = '/weapi/song/enhance/player/url/v1';
  static const String downloadUrl = '/weapi/song/enhance/download/url';
  static const String qrUnikey = '/weapi/login/qrcode/unikey';
  static const String qrLogin = '/weapi/login/qrcode/client/login';
  // Silent session renewal: the jar's MUSIC_R_T (refresh token) minted by the
  // 803 QR login is carried automatically by the CookieManager; a 200 here
  // Set-Cookies a fresh MUSIC_U, extending the session without a re-scan.
  static const String tokenRefresh = '/weapi/login/token/refresh';
  static const String lyric = '/weapi/song/lyric';
  static const String account = '/weapi/w/nuser/account/get';
  static const String personalized = '/weapi/personalized/playlist';
  static const String playlistDetail = '/weapi/v6/playlist/detail';
  static const String userPlaylist = '/weapi/user/playlist';
  static const String recommendResource =
      '/weapi/discovery/recommend/resource';
  static const String recommendSongs = '/weapi/v1/discovery/recommend/songs';

  // Playlist management (weapi).
  static const String playlistCreate = '/weapi/playlist/create';
  static const String playlistDelete = '/weapi/playlist/delete';
  static const String playlistTracks = '/weapi/playlist/manipulate/tracks';
  static const String playlistSubscribe = '/weapi/playlist/subscribe';

  // eapi (desktop) word-by-word YRC lyric — absolute URL on the desktop
  // interface host. [eapiLyricPath] (the path WITHOUT the `/eapi` prefix) is
  // what gets folded into the eapi signature.
  static const String eapiLyricUrl =
      'https://interface.music.163.com/eapi/song/lyric/v1';
  static const String eapiLyricPath = '/api/song/lyric/v1';

  /// Headers the desktop eapi endpoint expects. The LOWERCASE `user-agent` key
  /// is deliberate: [WeapiInterceptor] injects its default browser UA via
  /// `putIfAbsent('user-agent', …)`, so a same-cased key already present wins —
  /// the eapi endpoint wants the NeteaseMusicDesktop UA, not the browser one.
  static const Map<String, String> eapiHeaders = <String, String>{
    'user-agent':
        'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Safari/537.36 Chrome/91.0.4472.164 NeteaseMusicDesktop/3.1.13.204183',
    'MConfig-Info':
        '{"IuRPVVmc3WWul9fT":{"version":966656,"appver":"3.1.13.204183"}}',
  };
}
