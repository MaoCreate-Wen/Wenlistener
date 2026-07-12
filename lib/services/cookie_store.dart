import 'dart:io';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:path_provider/path_provider.dart';

import 'netease_crypto.dart';
import 'netease_endpoints.dart';

/// Wraps a [CookieJar] with a small synchronous cache so `csrf` / `MUSIC_U`
/// can be read inline when building weapi payloads, while the jar persists
/// auth cookies across launches (and is shared with dio's CookieManager).
///
/// The jar is the single source of truth: dio's `CookieManager` auto-persists
/// every response's `Set-Cookie` into it, so the synchronous [_cache] is always
/// re-derived from the jar (see [reload]) rather than from a fragile manual
/// parse. This is what makes `MUSIC_U` / `__csrf` reliably reach the cache after
/// a real QR login (code 803).
class CookieStore {
  final CookieJar jar;
  final Map<String, String> _cache = <String, String>{};

  CookieStore({required this.jar});

  static final Uri _origin = Uri.parse(NeteaseEndpoints.base);

  /// Builds a persistent store under the app support dir.
  static Future<CookieStore> create() async {
    final Directory dir = await getApplicationSupportDirectory();
    final PersistCookieJar jar = PersistCookieJar(
      ignoreExpires: true,
      storage: FileStorage('${dir.path}/.netease_cookies'),
    );
    final CookieStore store = CookieStore(jar: jar);
    await store.reload();
    return store;
  }

  /// Clears the synchronous cache and re-derives it from the jar — the source of
  /// truth, populated by dio's [CookieManager] (and by [saveFromSetCookie]).
  /// Call on relaunch (persisted jar) or after a login round-trip to surface
  /// `MUSIC_U` / `__csrf` into the cache.
  Future<void> reload() async {
    _cache.clear();
    try {
      final List<Cookie> cookies = await jar.loadForRequest(_origin);
      for (final Cookie c in cookies) {
        _cache[c.name] = c.value;
      }
    } catch (_) {
      // No persisted cookies yet / in-memory jar.
    }
  }

  String? get musicU => _cache['MUSIC_U'];
  String? get csrf => _cache['__csrf'];
  bool get isLoggedIn => (musicU ?? '').isNotEmpty;

  /// Returns a stable `sDeviceId`, seeding one into the jar on first use so
  /// dio's [CookieManager] auto-attaches it to every music.163.com request
  /// (mirrors the Python `cookies=dict(base_cookies)` carrying sDeviceId). The
  /// QR-login chainId (`v1_<sDeviceId>_web_login_<ms>`) embeds this id so the
  /// phone scan and the polling client correlate. Persisted via the jar, so the
  /// same device id survives relaunches.
  Future<String> ensureDeviceId() async {
    final String? existing = _cache['sDeviceId'];
    if (existing != null && existing.isNotEmpty) return existing;
    final String id = 'YD-${NeteaseCrypto.randomBase62(32)}';
    await jar.saveFromResponse(
      _origin,
      <Cookie>[
        Cookie('sDeviceId', id)
          ..domain = '.music.163.com'
          ..path = '/',
      ],
    );
    // Jar = source of truth → re-derive the synchronous cache so subsequent
    // calls (and `csrf`/`musicU` reads) see the freshly-seeded sDeviceId.
    await reload();
    return id;
  }

  /// Persists Set-Cookie header values (used after QR auth, code 803) and
  /// refreshes the synchronous cache FROM THE JAR.
  ///
  /// dio's [CookieManager] already saves the same `Set-Cookie` headers into the
  /// jar during response handling, so even when [Cookie.fromSetCookieValue]
  /// fails to parse an entry the cookie still lands in the jar; the trailing
  /// [reload] then re-derives the cache from it. The cache therefore reflects
  /// whatever the jar holds (always `MUSIC_U`, plus `__csrf` when NetEase sets
  /// it), never just the brittle manual parse.
  Future<void> saveFromSetCookie(List<String> setCookies) async {
    final List<Cookie> cookies = <Cookie>[];
    for (final String raw in setCookies) {
      try {
        cookies.add(Cookie.fromSetCookieValue(raw));
      } catch (_) {
        // Skip malformed Set-Cookie entries; dio's CookieManager already
        // captured them in the jar, and reload() below picks them up.
      }
    }
    if (cookies.isNotEmpty) {
      await jar.saveFromResponse(_origin, cookies);
    }
    // Jar = source of truth → re-derive the synchronous cache from it.
    await reload();
  }

  /// A full snapshot of the jar's cookies (name→value) — used by the
  /// multi-account manager to save a whole login for later restore.
  Future<Map<String, String>> snapshot() async {
    await reload();
    return Map<String, String>.from(_cache);
  }

  /// Replaces the jar with a prior [snapshot] (the account switch): clears, writes
  /// the cookies back under `.music.163.com`, then re-derives the cache.
  Future<void> restore(Map<String, String> cookies) async {
    await jar.deleteAll();
    _cache.clear();
    final List<Cookie> list = <Cookie>[
      for (final MapEntry<String, String> e in cookies.entries)
        Cookie(e.key, e.value)
          ..domain = '.music.163.com'
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
