import 'dart:convert';
import 'dart:io';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:path_provider/path_provider.dart';

/// Persistent store for QQ Music's **Android** auth session.
///
/// Two kinds of state share the one [CookieJar]:
///  1. Ordinary HTTP cookies from the ptlogin OAuth walk (`ptlogin2.qq.com` /
///     `graph.qq.com`: `qrsig`, `p_skey`, `uin`, …) — auto-persisted by dio's
///     `CookieManager` during login.
///  2. The Android session fields returned by `QQConnectLogin.QQLogin` +
///     `music.getSession.GetSession` (`uid` / `sid` / `authst` / `qq` /
///     `psrf_qqaccess_token` / `psrf_qqopenid`) — these arrive as JSON, NOT
///     `Set-Cookie`, so [saveSession] writes them into the jar by hand (under
///     `.qq.com`) so they persist, snapshot, and restore exactly like the rest.
///
/// `authst` is the QQ Music session key (the Android equivalent of the web
/// `qm_keyst`); its presence is what [isLoggedIn] gates the whole source on. A
/// small synchronous [_cache] is re-derived from the jar so the comm can be built
/// inline when signing a request.
class QqcnCookieStore {
  final CookieJar jar;
  final Map<String, String> _cache = <String, String>{};

  QqcnCookieStore({required this.jar});

  static final Uri _origin = Uri.parse('https://y.qq.com/');

  // Fixed device/app fingerprint (from the verified Android capture — see
  // spider/QQmusic_Android tools). guid for the vkey request is [udid].
  static const String udid = '00000000640d1edc000000000033c587';
  static const String _appVersion = '20070008';
  static const String qimei36 = '088970b982ef722711218ff510001bf1a702';

  static Future<QqcnCookieStore> create() async {
    final Directory dir = await getApplicationSupportDirectory();
    final PersistCookieJar jar = PersistCookieJar(
      ignoreExpires: true,
      // INDEPENDENT jar dir — must NOT collide with the web-QQ (`migu` slot)
      // `.qq_cookies`, or the two QQ sources overwrite each other's session.
      storage: FileStorage('${dir.path}/.qqcn_cookies'),
    );
    final QqcnCookieStore store = QqcnCookieStore(jar: jar);
    await store.reload();
    return store;
  }

  /// Re-derives the synchronous cache from the jar (the source of truth). Call on
  /// relaunch and after a login round-trip so `authst`/`uid`/`qq` surface.
  Future<void> reload() async {
    _cache.clear();
    try {
      final List<Cookie> cookies = await jar.loadForRequest(_origin);
      for (final Cookie c in cookies) {
        _cache[c.name] = c.value;
      }
    } catch (_) {
      // No persisted cookies yet.
    }
  }

  String? operator [](String name) => _cache[name];

  /// QQ Music internal uid (numeric — `comm.uid`, and `uin=` in the resolved
  /// stream URL). Distinct from [qq] (the login QQ number).
  String get uid => _cache['uid'] ?? '0';

  /// The login QQ number (`comm.qq`, and the vkey request's `uin` param).
  String get qq => _cache['qq'] ?? '0';

  /// The QQ Music session key. Search/play only work when this is present, so it
  /// is the definitive logged-in signal.
  String get authst => _cache['authst'] ?? '';

  bool get isLoggedIn => authst.isNotEmpty;

  /// Nickname — the real `nick` from the QQLogin response (stored base64), else
  /// null (the UI then shows a generic label).
  String? get nickname {
    final String? real = _decodeB64(_cache['qm_nick_b64']);
    return (real != null && real.isNotEmpty) ? real : null;
  }

  /// Avatar — the real `logo` from the QQLogin response (stored base64), else the
  /// public QQ avatar derived from the numeric [qq].
  String? get avatarUrl {
    final String? real = _decodeB64(_cache['qm_logo_b64']);
    if (real != null && real.startsWith('http')) return real;
    final String u = qq;
    if (u == '0' || !RegExp(r'^\d+$').hasMatch(u)) return null;
    return 'https://q1.qlogo.cn/g?b=qq&nk=$u&s=100';
  }

  /// The anonymous device `comm` (uid `0` + the fixed fingerprint, no session
  /// fields). This is what the scan-login calls
  /// (`CreateQRCode`/`GetQRCodeStatus`/`QRCodeLogin`) must send — an EMPTY `{}`
  /// comm makes the server reject the QR with `104610 "not in cts-white-list"`
  /// (verified live): it needs `ct`/`cv`/`chid`/`tmeAppID` device identity even
  /// pre-login. The mask uid is still `0`, so the crypto envelope is unchanged.
  Map<String, dynamic> loginComm() => <String, dynamic>{
        'uid': '0',
        'udid': udid,
        'OpenUDID': udid,
        'ct': '11',
        'cv': _appVersion,
        'v': _appVersion,
        'chid': '73387',
        'os_ver': '14',
        'aid': '8c54b1e0c50ad8cd',
        'phonetype': '22021211RC',
        'QIMEI36': qimei36,
        'tmeAppID': 'qqmusic',
        'nettype': '1030',
        'gzip': '1',
      };

  /// Builds the full `comm` block for a `musics.fcg` (search / vkey / lyric-adjacent)
  /// request: the fixed device fingerprint plus the persisted session fields. When
  /// logged out only the anonymous fields are present (uid `0`, no `authst`).
  Map<String, dynamic> sessionComm() {
    final Map<String, dynamic> comm = loginComm();
    comm['uid'] = uid; // real internal uid once logged in, else stays '0'
    if (isLoggedIn) {
      comm['sid'] = _cache['sid'] ?? '';
      comm['authst'] = authst;
      // int（非字符串）以对齐已验证可用的 android_auth.json 抓包；认证 vkey 等
      // 调用若被网关按 int 严格解析，字符串会污染会话身份 → 播放取 vkey 失败。
      comm['tmeLoginType'] = 2;
      comm['tmeLoginMethod'] = 3;
      comm['qq'] = qq;
      final String at = _cache['psrf_qqaccess_token'] ?? '';
      final String oid = _cache['psrf_qqopenid'] ?? '';
      if (at.isNotEmpty) comm['psrf_qqaccess_token'] = at;
      if (oid.isNotEmpty) comm['psrf_qqopenid'] = oid;
    }
    return comm;
  }

  /// Persists the Android session fields returned by the login exchange /
  /// GetSession. Written to the jar as `.qq.com` cookies (so snapshot/restore and
  /// the multi-account manager treat them uniformly), then the cache is refreshed.
  Future<void> saveSession(
    Map<String, dynamic> fields, {
    String? nick,
    String? logo,
  }) async {
    final List<Cookie> cookies = <Cookie>[];
    void add(String name, String? value) {
      if (value == null || value.isEmpty) return;
      cookies.add(Cookie(name, value)
        ..domain = '.qq.com'
        ..path = '/');
    }

    for (final String k in const <String>[
      'uid',
      'sid',
      'authst',
      'qq',
      'psrf_qqaccess_token',
      'psrf_qqopenid',
      'psrf_access_token_expiresAt',
    ]) {
      final dynamic v = fields[k];
      if (v != null) add(k, v.toString());
    }
    if (nick != null && nick.isNotEmpty) add('qm_nick_b64', _encodeB64(nick));
    if (logo != null && logo.startsWith('http')) {
      add('qm_logo_b64', _encodeB64(logo));
    }
    if (cookies.isNotEmpty) {
      await jar.saveFromResponse(_origin, cookies);
    }
    await reload();
  }

  /// Loads all cookies visible to [uri] as a name→value map (used during the OAuth
  /// handoff to read `p_skey`/`ui` from `graph.qq.com`, which the y.qq.com-scoped
  /// [_cache] wouldn't surface).
  Future<Map<String, String>> loadFor(Uri uri) async {
    final Map<String, String> out = <String, String>{};
    try {
      for (final Cookie c in await jar.loadForRequest(uri)) {
        out[c.name] = c.value;
      }
    } catch (_) {}
    return out;
  }

  /// A full snapshot of the jar's cookies (name→value) — the multi-account manager
  /// saves this whole login for later restore.
  Future<Map<String, String>> snapshot() async {
    await reload();
    return Map<String, String>.from(_cache);
  }

  /// Replaces the jar with a prior [snapshot] (the account switch).
  Future<void> restore(Map<String, String> cookies) async {
    await jar.deleteAll();
    _cache.clear();
    final List<Cookie> list = <Cookie>[
      for (final MapEntry<String, String> e in cookies.entries)
        Cookie(e.key, e.value)
          ..domain = '.qq.com'
          ..path = '/',
    ];
    if (list.isNotEmpty) await jar.saveFromResponse(_origin, list);
    await reload();
  }

  Future<void> clear() async {
    await jar.deleteAll();
    _cache.clear();
  }

  static String? _decodeB64(String? s) {
    if (s == null || s.isEmpty) return null;
    try {
      final int pad = (4 - s.length % 4) % 4;
      return utf8.decode(base64Url.decode(s + ('=' * pad)), allowMalformed: true);
    } catch (_) {
      return null;
    }
  }

  static String _encodeB64(String s) =>
      base64Url.encode(utf8.encode(s)).replaceAll('=', '');
}
