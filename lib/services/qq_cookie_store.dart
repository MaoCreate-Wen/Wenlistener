import 'dart:convert';
import 'dart:io';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:path_provider/path_provider.dart';

/// Persistent cookie jar for QQ Music (`.qq.com`, which also covers the login
/// domains `ptlogin2.qq.com` / `graph.qq.com` / `open.weixin.qq.com`). Mirrors the
/// Netease [CookieStore]: the jar is the source of truth (dio's `CookieManager`
/// auto-persists every `Set-Cookie`), and a small synchronous [_cache] is
/// re-derived from it so the guest `guid`/`uin` can be read inline when building
/// a request body.
///
/// QQ needs a login for EVERYTHING (even search returns an empty list without a
/// valid session cookie), so [isLoggedIn] gates the whole source: it's true once
/// the login redirect chain has landed a `qm_keyst` / `qqmusic_key` session key.
class QqCookieStore {
  final CookieJar jar;
  final Map<String, String> _cache = <String, String>{};

  QqCookieStore({required this.jar});

  static final Uri _origin = Uri.parse('https://y.qq.com/');

  static Future<QqCookieStore> create() async {
    final Directory dir = await getApplicationSupportDirectory();
    final PersistCookieJar jar = PersistCookieJar(
      ignoreExpires: true,
      storage: FileStorage('${dir.path}/.qq_cookies'),
    );
    final QqCookieStore store = QqCookieStore(jar: jar);
    await store.reload();
    return store;
  }

  /// Re-derives the synchronous cache from the jar (the source of truth). Call on
  /// relaunch and after a login round-trip so `qm_keyst`/`pgv_pvid`/`wxuin` surface.
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

  /// `guid` for the vkey request — QQ's `pgv_pvid` device cookie. When absent
  /// (our login never lands one), derive a STABLE 16-digit id from the uin. The
  /// CDN 403s the obvious `10000` placeholder on the resolved stream URL, so a
  /// realistic-looking, deterministic guid is used instead (same value every
  /// request, as the vkey signature is bound to it).
  String get guid {
    final String v = _cache['pgv_pvid'] ?? '';
    if (v.isNotEmpty) return v;
    final String u = uin;
    if (u != '0' && RegExp(r'^\d+$').hasMatch(u)) {
      return '${u}0000000000000000'.substring(0, 16);
    }
    return '1000000000000000';
  }

  /// `uin` for `comm` / the vkey request (WeChat login sets `wxuin`, QQ sets `uin`).
  String get uin => _cache['wxuin'] ?? _cache['uin'] ?? '0';

  /// QQ-Connect tokens landed by [saveLoginCookies] from the QQLogin exchange —
  /// the QQ **Android** backend feeds these to `GetSession` to obtain its own
  /// `authst` session ticket (see [QqAndroidApi.getSession]). Empty when logged out.
  String get accessToken => _cache['psrf_qqaccess_token'] ?? '';
  String get openid => _cache['psrf_qqopenid'] ?? '';

  /// The session key that proves a completed login. Search/play only work when
  /// this is present.
  bool get isLoggedIn =>
      (_cache['qm_keyst'] ?? _cache['qqmusic_key'] ?? '').isNotEmpty;

  /// `1`=WeChat, `2`=QQ (set by the site after login); null before login.
  String? get loginType => _cache['tmeLoginType'];

  /// Nickname — the real `nick` from the QQLogin response (stored base64 by
  /// [saveLoginCookies]), falling back to the hex-encoded `ptnick_<uin>` cookie.
  String? get nickname {
    final String? real = _decodeB64(_cache['qm_nick_b64']);
    if (real != null && real.isNotEmpty) return real;
    for (final MapEntry<String, String> e in _cache.entries) {
      if (e.key.startsWith('ptnick_')) {
        final String? n = _decodeHexNick(e.value);
        if (n != null) return n;
      }
    }
    return null;
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

  static String? _decodeHexNick(String v) {
    if (v.isEmpty || v.length.isOdd) return null;
    try {
      final List<int> bytes = <int>[];
      for (int i = 0; i < v.length; i += 2) {
        bytes.add(int.parse(v.substring(i, i + 2), radix: 16));
      }
      final String s = utf8.decode(bytes, allowMalformed: true).trim();
      // '#include' is QQ's placeholder for an unset/absent nickname.
      return (s.isEmpty || s == '#include') ? null : s;
    } catch (_) {
      return null;
    }
  }

  /// Avatar — the real `logo` from the QQLogin response (stored base64), else the
  /// public QQ avatar derived from a numeric QQ [uin] (WeChat `wxuin` isn't a QQ
  /// number → null → the UI shows a generic glyph).
  String? get avatarUrl {
    final String? real = _decodeB64(_cache['qm_logo_b64']);
    if (real != null && real.startsWith('http')) return real;
    final String u = uin;
    if (u == '0' || !RegExp(r'^\d+$').hasMatch(u)) return null;
    return 'https://q1.qlogo.cn/g?b=qq&nk=$u&s=100';
  }

  /// Loads all cookies visible to [uri] as a name→value map (used during the
  /// OAuth handoff to read `p_skey`/`ui` from `graph.qq.com` and `qqmusic_key`
  /// from `y.qq.com`, which the y.qq.com-only [_cache] wouldn't surface).
  Future<Map<String, String>> loadFor(Uri uri) async {
    final Map<String, String> out = <String, String>{};
    try {
      for (final Cookie c in await jar.loadForRequest(uri)) {
        out[c.name] = c.value;
      }
    } catch (_) {}
    return out;
  }

  /// Persists the music-session cookies carried in the `QQLogin`/`WXLogin`
  /// response body (they arrive as JSON `data`, NOT `Set-Cookie`, so the
  /// CookieManager can't auto-store them). `musickey` → `qm_keyst`+`qqmusic_key`
  /// is the one [isLoggedIn] checks. Mirrors qq_qr_login.py `set_music_login_cookies`.
  Future<void> saveLoginCookies(Map<String, dynamic> data) async {
    final List<Cookie> cookies = <Cookie>[];
    void add(String name, String? value) {
      if (value == null || value.isEmpty) return;
      cookies.add(Cookie(name, value)
        ..domain = '.qq.com'
        ..path = '/');
    }

    const Map<String, String> mapping = <String, String>{
      'openid': 'psrf_qqopenid',
      'access_token': 'psrf_qqaccess_token',
      'refresh_token': 'psrf_qqrefresh_token',
      'unionid': 'psrf_qqunionid',
      'expired_at': 'psrf_access_token_expiresAt',
      'musickeyCreateTime': 'psrf_musickey_createtime',
      'musicid': 'uin',
    };
    mapping.forEach((String src, String target) {
      if (data[src] != null) add(target, data[src].toString());
    });
    final String musickey = data['musickey']?.toString() ?? '';
    if (musickey.isNotEmpty) {
      add('qqmusic_key', musickey);
      add('qm_keyst', musickey);
    }
    // The QQLogin/WXLogin response also carries the real nickname + avatar — keep
    // them (base64, so URLs/unicode stay cookie-safe) for accountProfile.
    final String nick = data['nick']?.toString() ?? '';
    if (nick.isNotEmpty) add('qm_nick_b64', _encodeB64(nick));
    final String logo = data['logo']?.toString() ?? '';
    if (logo.startsWith('http')) add('qm_logo_b64', _encodeB64(logo));
    if (cookies.isNotEmpty) {
      await jar.saveFromResponse(_origin, cookies);
    }
    await reload();
  }

  /// A full snapshot of the jar's cookies (name→value) — the multi-account
  /// manager saves this whole login for later restore.
  Future<Map<String, String>> snapshot() async {
    await reload();
    return Map<String, String>.from(_cache);
  }

  /// Replaces the jar with a prior [snapshot] (the account switch): clears, writes
  /// the cookies back under `.qq.com`, then re-derives the cache.
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
}
