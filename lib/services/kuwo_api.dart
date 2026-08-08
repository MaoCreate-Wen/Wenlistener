import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/album.dart';
import '../models/artist.dart';
import '../models/lyric_line.dart';
import '../models/play_url.dart';
import '../models/playlist.dart';
import '../models/search_result.dart';
import '../models/song.dart';
import 'music_api.dart';
import 'kuwo_cookie_store.dart';

/// Kuwo (酷我音乐) music backend. Anonymous search and lyrics work without login;
/// full-quality play URLs from `anti.s` are only reliable with a signed-in
/// `userid` + `websid` (anonymous calls may return a ~180 KB stub MP3).
class KuwoApi implements MusicApi {
  static const String _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
  static const String _referer = 'https://www.kuwo.cn/';

  late final Dio _dio;
  final KuwoCookieStore _cookies;

  /// Fired (once the session is confirmed expired) when a LOGGED-IN play request
  /// resolves to Kuwo's ~180KB placeholder stub instead of the real stream —
  /// the platform's only "session no longer authorized" signal (it returns no
  /// error code, just a trial file). The auth layer clears the session so the
  /// UI re-prompts login. Kuwo issues no refresh token → re-login is required.
  void Function()? onSessionExpired;

  // Real tracks are multi-MB; the unauthorized stub is ~180KB. A resolved URL
  // whose Content-Length is below this (but present) is treated as the stub.
  static const int _stubMaxBytes = 400 * 1024;

  KuwoApi({KuwoCookieStore? cookieStore})
      : _cookies = cookieStore ?? KuwoCookieStore() {
    _dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 20),
      headers: <String, String>{
        'User-Agent': _ua,
        'Referer': _referer,
      },
    ));
    // Eagerly load persisted cookies.
    _cookies.load();
  }

  Map<String, String> get _headers => <String, String>{
        'Cookie': _cookies.cookieHeader,
        'Referer': _referer,
      };

  // ─── Search ───────────────────────────────────────────────────────────────

  @override
  Future<SearchResult> search({
    required String keyword,
    SearchType type = SearchType.song,
    int limit = 30,
    int offset = 0,
  }) async {
    if (type != SearchType.song && type != SearchType.comprehensive) {
      return SearchResult.empty(type);
    }
    final int page = (limit > 0) ? (offset ~/ limit) : 0;
    try {
      final Response<String> resp = await _dio.get<String>(
        'https://www.kuwo.cn/search/searchMusicBykeyWord',
        queryParameters: <String, dynamic>{
          'all': keyword,
          'pn': page,
          'rn': limit,
          'ft': 'music',
          'encoding': 'utf8',
          'rformat': 'json',
        },
        options: Options(headers: _headers, responseType: ResponseType.plain),
      );
      final dynamic body = jsonDecode(resp.data ?? '{}');
      final dynamic list =
          (body is Map ? body['data'] : null) is Map
              ? (body['data'] as Map)['list']
              : null;
      if (list is! List) return SearchResult.empty(type);
      final List<Song> songs = list
          .whereType<Map>()
          .map((dynamic e) => _songFromRow(Map<String, dynamic>.from(e)))
          .where((Song s) => s.id != 0 && s.name.isNotEmpty)
          .toList();
      return SearchResult(
        type: SearchType.song,
        songs: songs,
        total: songs.length,
        hasMore: songs.length >= limit,
      );
    } on DioException catch (e) {
      throw Exception('Kuwo search failed: ${e.message}');
    }
  }

  Song _songFromRow(Map<String, dynamic> row) {
    final int rid = _int(row['rid']);
    final String name = _str(row['name'] ?? row['music_name']);
    final String artistName = _str(row['artist'] ?? row['artistName']);
    // duration is in SECONDS for Kuwo (unlike Netease which uses milliseconds)
    final int durationSec = _int(row['duration'] ?? row['songTimeMinutes']);
    final String pic = _str(row['pic'] ?? row['albumpic'] ?? row['pic120']);
    final String albumName = _str(row['album'] ?? row['albumName']);

    return Song(
      id: rid,
      name: name,
      artists: artistName.isNotEmpty
          ? <Artist>[Artist(id: 0, name: artistName)]
          : const <Artist>[],
      album: Album(
        id: 0,
        name: albumName.isNotEmpty ? albumName : name,
        picUrl: pic.isNotEmpty ? _httpsUrl(pic) : null,
      ),
      duration: Duration(seconds: durationSec),
      fee: 0,
      playable: true,
      source: MusicSource.kuwo,
      ref: <String, String>{'rid': rid.toString()},
    );
  }

  // ─── Song URL ─────────────────────────────────────────────────────────────

  @override
  Future<PlayUrl?> songUrl(Song song,
      {AudioLevel level = AudioLevel.exhigh}) async {
    final String rid = song.ref['rid'] ?? song.id.toString();
    if (rid.isEmpty || rid == '0') return null;
    try {
      final Response<String> resp = await _dio.get<String>(
        'https://antiserver.kuwo.cn/anti.s',
        queryParameters: <String, dynamic>{
          'type': 'convert_url3',
          'rid': 'MUSIC_$rid',
          'format': 'mp3',
          'response': 'url',
        },
        options: Options(
          headers: _headers,
          responseType: ResponseType.plain,
          followRedirects: true,
        ),
      );
      final String url = (resp.data ?? '').trim();
      if (url.isEmpty || !url.startsWith('http')) return null;
      // If we're logged in, verify (in the background, non-blocking) that the
      // resolved stream is a real track and not the unauthorized stub — an
      // expired websid still resolves a *valid-looking* URL that points at the
      // ~180KB placeholder. Playback isn't delayed; a stale session is caught
      // and cleared so the login prompt reappears.
      if (_cookies.isLoggedIn) {
        unawaited(_probeStub(url));
      }
      return PlayUrl(
        id: song.id,
        url: url,
        br: 128000,
        type: 'mp3',
        size: 0,
        level: AudioLevel.standard,
      );
    } on DioException catch (e) {
      // Transport error is transient — never treat it as a session expiry.
      debugPrint('KuwoApi.songUrl failed for rid=$rid: ${e.message}');
      return null;
    }
  }

  /// Background HEAD probe: if the resolved stream's Content-Length is present
  /// and below [_stubMaxBytes], it's Kuwo's unauthorized placeholder → fire
  /// [onSessionExpired]. A missing/oversized Content-Length or any error is
  /// treated as "can't tell / real track" and does NOT log the user out.
  Future<void> _probeStub(String url) async {
    try {
      final Response<void> head = await _dio.head<void>(
        url,
        options: Options(headers: _headers),
      );
      final int? len =
          int.tryParse(head.headers.value(Headers.contentLengthHeader) ?? '');
      if (len != null && len > 0 && len < _stubMaxBytes) {
        onSessionExpired?.call();
      }
    } catch (_) {
      // Ignore — probing must never cause a false logout.
    }
  }

  // ─── Lyrics ───────────────────────────────────────────────────────────────

  @override
  Future<Lyrics> lyric(Song song) async {
    final String rid = song.ref['rid'] ?? song.id.toString();
    if (rid.isEmpty || rid == '0') return Lyrics.empty;
    try {
      final Response<String> resp = await _dio.get<String>(
        'https://m.kuwo.cn/newh5/singles/songinfoandlrc',
        queryParameters: <String, dynamic>{'musicId': rid},
        options: Options(headers: _headers, responseType: ResponseType.plain),
      );
      final dynamic body = jsonDecode(resp.data ?? '{}');
      final dynamic lrcList =
          (body is Map ? body['data'] : null) is Map
              ? (body['data'] as Map)['lrclist']
              : null;
      if (lrcList is! List || lrcList.isEmpty) return Lyrics.empty;
      // Build a plain LRC string from lrclist[].{time, lineLyric}
      final StringBuffer lrc = StringBuffer();
      for (final dynamic item in lrcList) {
        if (item is! Map) continue;
        final double timeSec =
            _double((item as Map)['time'] ?? 0);
        final String text = _str(item['lineLyric']);
        final int mm = (timeSec ~/ 60);
        final double ss = timeSec - mm * 60;
        lrc.writeln('[${mm.toString().padLeft(2, '0')}:${ss.toStringAsFixed(2).padLeft(5, '0')}]$text');
      }
      return Lyrics.parse(lrc: lrc.toString());
    } on DioException catch (e) {
      debugPrint('KuwoApi.lyric failed for rid=$rid: ${e.message}');
      throw e; // rethrow so PlayerProvider can retry
    }
  }

  // ─── Feeds ────────────────────────────────────────────────────────────────

  @override
  Future<List<Playlist>> personalizedPlaylists({int limit = 12}) async {
    // Hot chart (bangId 16 = 热歌榜) as a "playlist" stand-in.
    return const <Playlist>[];
  }

  @override
  Future<List<Song>> recommendedSongs({int limit = 8}) async {
    try {
      final SearchResult r =
          await search(keyword: '热门', type: SearchType.song, limit: limit);
      return r.songs.take(limit).toList();
    } catch (_) {
      return const <Song>[];
    }
  }

  // ─── Playlist ─────────────────────────────────────────────────────────────

  @override
  Future<Playlist> albumDetail(int id) async =>
      Playlist(id: id, name: '专辑', tracks: const <Song>[]);

  @override
  Future<Playlist> playlistDetail(int id) async {
    try {
      final Response<String> resp = await _dio.get<String>(
        'https://nplserver.kuwo.cn/pl.svc',
        queryParameters: <String, dynamic>{
          'op': 'getlistinfo',
          'pid': id,
          'pn': 0,
          'rn': 300,
          'encode': 'utf-8',
          'keyset': 'pl2012',
          'identity': 'kuwo',
        },
        options: Options(headers: _headers, responseType: ResponseType.plain),
      );
      final dynamic body = jsonDecode(resp.data ?? '{}');
      final dynamic ml = body is Map ? body['musiclist'] : null;
      final List<Song> tracks = <Song>[];
      if (ml is List) {
        for (final dynamic e in ml) {
          if (e is Map) {
            tracks.add(_songFromRow(Map<String, dynamic>.from(e)));
          }
        }
      }
      final String name = body is Map ? _str(body['name'] ?? '') : '';
      final String cover = body is Map ? _str(body['img'] ?? '') : '';
      return Playlist(
        id: id,
        name: name,
        coverUrl: cover.isNotEmpty ? _httpsUrl(cover) : null,
        tracks: tracks,
        trackCount: tracks.length,
      );
    } on DioException catch (e) {
      throw Exception('KuwoApi.playlistDetail failed: ${e.message}');
    }
  }

  @override
  Future<List<Playlist>> userPlaylists({int limit = 30, int offset = 0}) async {
    if (!_cookies.isLoggedIn) return const <Playlist>[];
    try {
      final Response<String> resp = await _dio.get<String>(
        'https://nplserver.kuwo.cn/pl.svc',
        queryParameters: <String, dynamic>{
          'op': 'getuserlist',
          'uid': _cookies.userid,
          'sid': _cookies.websid,
          'pn': (limit > 0) ? (offset ~/ limit) : 0,
          'rn': limit,
          'encode': 'utf-8',
          'keyset': 'pl2012',
          'identity': 'kuwo',
        },
        options: Options(headers: _headers, responseType: ResponseType.plain),
      );
      final dynamic body = jsonDecode(resp.data ?? '{}');
      final dynamic list = body is Map ? body['list'] : null;
      if (list is! List) return const <Playlist>[];
      return list
          .whereType<Map>()
          .map((dynamic e) {
            final Map<String, dynamic> m =
                Map<String, dynamic>.from(e as Map);
            return Playlist(
              id: _int(m['id'] ?? m['pid']),
              name: _str(m['name']),
              coverUrl: _emptyNull(_str(m['img'])),
              trackCount: _int(m['nums']),
            );
          })
          .where((Playlist p) => p.id != 0)
          .toList();
    } on DioException {
      return const <Playlist>[];
    }
  }

  @override
  Future<List<Song>> dailyRecommendSongs({int limit = 30}) =>
      recommendedSongs(limit: limit);

  @override
  Future<List<Playlist>> dailyRecommendPlaylists({int limit = 30}) =>
      personalizedPlaylists(limit: limit);

  // ─── Playlist writes (unsupported) ────────────────────────────────────────

  @override
  Future<int> createPlaylist(String name, {int privacy = 0}) =>
      throw UnsupportedError('KuwoApi: createPlaylist not supported');

  @override
  Future<void> deletePlaylist(int pid) =>
      throw UnsupportedError('KuwoApi: deletePlaylist not supported');

  @override
  Future<void> addTracksToPlaylist(int pid, List<int> ids) =>
      throw UnsupportedError('KuwoApi: addTracksToPlaylist not supported');

  @override
  Future<void> removeTracksFromPlaylist(int pid, List<int> ids) =>
      throw UnsupportedError('KuwoApi: removeTracksFromPlaylist not supported');

  @override
  Future<void> collectPlaylist(int id, bool collect) =>
      throw UnsupportedError('KuwoApi: collectPlaylist not supported');

  // ─── Login ────────────────────────────────────────────────────────────────

  /// Fetches a captcha image for the password-login flow.
  /// Returns `{imgBase64: '...', token: '...'}` or throws.
  Future<Map<String, String>> getCaptcha() async {
    final Response<String> resp = await _dio.get<String>(
      'https://www.kuwo.cn/api/common/captcha/getcode',
      options: Options(
        headers: _headers,
        responseType: ResponseType.plain,
      ),
    );
    final dynamic body = jsonDecode(resp.data ?? '{}');
    if (body is! Map || body['code'] != 200) {
      throw Exception('Kuwo getCaptcha failed: ${body['msg'] ?? resp.data}');
    }
    final dynamic d = body['data'];
    return <String, String>{
      'imgBase64': (d is Map ? d['img'] as String? : null) ?? '',
      'token': (d is Map ? d['token'] as String? : null) ?? '',
    };
  }

  /// Password login. On success, cookies are saved to [_cookies].
  /// [username] is the Kuwo username (email/phone/user ID).
  Future<bool> login({
    required String username,
    required String password,
    required String verifyCode,
    required String verifyCodeToken,
  }) async {
    final Response<String> resp = await _dio.post<String>(
      'https://wapi.kuwo.cn/api/www/login/loginByKw',
      data: <String, dynamic>{
        'uname': username,
        'pwd': password,
        'verifyCode': verifyCode,
        'verifyCodeToken': verifyCodeToken,
        'reqId': _reqId(),
      },
      options: Options(
        contentType: 'application/json;charset=UTF-8',
        headers: _headers,
        responseType: ResponseType.plain,
      ),
    );
    final dynamic body = jsonDecode(resp.data ?? '{}');
    if (body is! Map || body['code'] != 200) {
      throw Exception(
          'Kuwo login failed: ${body['msg'] ?? 'code=${body['code']}'}');
    }
    final dynamic d = body['data'];
    if (d is Map) {
      final Map<String, String> cookies = <String, String>{};
      final dynamic uid = d['userid'] ?? d['userId'];
      final dynamic sid = d['websid'] ?? d['sid'];
      if (uid != null) cookies['userid'] = uid.toString();
      if (sid != null) cookies['websid'] = sid.toString();
      await _cookies.saveLoginCookies(cookies);
      return _cookies.isLoggedIn;
    }
    return false;
  }

  Future<void> logout() async => _cookies.clear();

  static String _reqId() {
    final int ms = DateTime.now().millisecondsSinceEpoch;
    return 'wenlistener_$ms';
  }

  static int _int(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }

  static double _double(dynamic v) {
    if (v is double) return v;
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? 0.0;
    return 0.0;
  }

  static String _str(dynamic v) => v is String ? v : '';

  static String? _emptyNull(String s) => s.isEmpty ? null : s;

  static String _httpsUrl(String url) {
    if (url.startsWith('http://')) {
      return 'https://${url.substring(7)}';
    }
    return url;
  }
}
