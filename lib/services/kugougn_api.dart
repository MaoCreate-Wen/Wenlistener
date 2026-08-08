import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';

import '../models/album.dart';
import '../models/artist.dart';
import '../models/kugougn_account.dart';
import '../models/lyric_line.dart';
import '../models/play_url.dart';
import '../models/playlist.dart';
import '../models/search_result.dart';
import '../models/song.dart';
import 'kugougn_crypto.dart';
import 'kugougn_lyric_crypto.dart';
import 'music_api.dart';

class KugougnApiException implements Exception {
  final String message;
  KugougnApiException(this.message);
  @override
  String toString() => 'KugougnApiException: $message';
}

/// Outcome of a [KugougnApi.signInDaily] run — the free-VIP items claimed today,
/// those skipped (already received / not active), and any that errored. Mirrors
/// the reference `daily_signin()` result shape.
class KugougnSignInResult {
  final List<String> claimed;
  final List<String> skipped;
  final List<String> errors;
  const KugougnSignInResult({
    this.claimed = const <String>[],
    this.skipped = const <String>[],
    this.errors = const <String>[],
  });

  bool get anyClaimed => claimed.isNotEmpty;

  /// A short, user-facing summary line for a toast / status label.
  String get message {
    if (claimed.isNotEmpty) return '已领取：${claimed.join('、')}';
    if (errors.isNotEmpty) return '签到失败：${errors.first}';
    return '今日已签到，暂无可领取的 VIP';
  }
}

/// Kugougn 概念版 (FreeListen / Lite Android) backend — a pure-algorithm port of
/// `Code/spider/kugougn/kugou_client.py`. Unlike the old web JSONP endpoints,
/// this speaks the real App protocol: MD5 `signature`, dynamic `KG-RF`/`KG-THash`
/// headers, an RSA+AES secu layer for login, and the libj.so `t1`/`t2` device
/// tokens reproduced natively ([KugougnCrypto]). Endpoints:
///  - search: `gateway.kugou.com/complexsearch/v3/search/mixed`
///            (`platform:AndroidFilter`) — `data.lists[]` carries `FileHash` +
///            numeric `MixSongID`/`Audioid` (the play id) + album/cover.
///  - play:   `get_res_privilege/lite` (POST) → `trackercdn/v1/user_verify`
///            (auth/open_time) → `gateway.kugou.com/v5/url` (signed, keyed by
///            `gen_v5_url_key`) → walk the response for the mp3 url. Needs a login
///            for full tracks; anonymous degrades to null → skip-to-next.
///  - lyric:  `lyrics.kugou.com/v1/search` (by hash) → `/download?fmt=lrc` → LRC.
///  - login:  phone + SMS — [sendMobileCode] (`/v8/send_mobile_code/`) then
///            [loginByVerifyCode] (`/v7/login_by_verifycode/`). RSA(`pk`) + AES
///            (`params`) + `t1`/`t2`/`gen_time_key`; the response `data`
///            (plaintext or secu-AES) yields userid + token.
class KugougnApi implements MusicApi {
  final Dio _dio;
  final KugougnCrypto _c = KugougnCrypto();

  /// The active signed-in account (null = anonymous). Installed by
  /// [KugougnAuthProvider] via [setAccount]; its `token`+`userid` are folded into
  /// every signed request, unlocking full-track playback.
  KugougnAccount? _account;

  /// Fired when a LOGGED-IN request comes back with a token-invalid signal — the
  /// auth layer drops that account so the login prompt reappears. Never fired for
  /// the anonymous case or a transient transport error.
  void Function(String userId)? onSessionExpired;

  void setAccount(KugougnAccount? account) => _account = account;
  KugougnAccount? get account => _account;

  String get _token => _account?.token ?? '';
  String get _userid => _account?.userId ?? '0';

  /// KG-FAKE header value: the userid when logged in, else "0".
  String get _headerUserId =>
      (_account?.isValid ?? false) ? _account!.userId : '0';

  /// `vip_status` for signed search/feed requests — '1' when the active account
  /// is VIP, else '0' (mirrors the reference `DeviceCreds.VIP_STATUS`, derived in
  /// `apply_login_data` from vip_type/svip_level). 概念版's mixed search gates the
  /// per-row VIP-song privilege on this flag; hardcoding '0' made every VIP track
  /// come back locked for a logged-in VIP user — the "sign for VIP" bug.
  String get _vipStatus => (_account?.isVip ?? false) ? '1' : '0';

  KugougnApi({Dio? dio}) : _dio = dio ?? _buildDio();

  /// Builds the HTTP client with **autoUncompress disabled**. Like the reference
  /// client (urllib), this hands us the RAW body — [_inflateBytes] then handles
  /// gzip/deflate. With autoUncompress ON, dio's `ResponseType.bytes` returns an
  /// EMPTY body for a gzipped response (the lyrics.kugou.com case: 0 bytes → no
  /// candidates → no lyrics).
  static Dio _buildDio() {
    final Dio d = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 20),
    ));
    d.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () => HttpClient()..autoUncompress = false,
    );
    return d;
  }

  // Kugougn auth error codes that mean "token invalid / re-login" (best-effort).
  // 20010/20020/20003 = the token itself is dead (drop the account). 30020 is
  // NOT here on purpose: it means "no play right / VIP-gated" — a LOGGED-IN free
  // account hits it on VIP tracks, and treating it as expiry would log the user
  // out the instant they play a VIP song (a login→logout loop). Leave it as a
  // per-track "no url", not a session kill.
  static const Set<int> _authErrorCodes = <int>{20010, 20020, 20003};

  // listid → (global_collection_id, 歌单原作者 userid); filled by [userPlaylists].
  // playlistDetail needs the gcid + owner to call pubsongs/get_other_list_file_nofilt
  // (the real "playlist songs" endpoint) — a listid is NOT a get_special_detail id.
  final Map<int, ({String gcid, int ownerId})> _kgnListRef =
      <int, ({String gcid, int ownerId})>{};

  // ===== endpoints =========================================================
  static const String _searchUrl =
      'https://gateway.kugou.com/complexsearch/v3/search/mixed';
  static const String _privilegeUrl =
      'https://gateway.kugou.com/goodsmstore/v1/get_res_privilege/lite';
  static const String _userVerifyUrl =
      'http://trackercdn.kugou.com/v1/user_verify';
  static const String _v5UrlUrl = 'https://gateway.kugou.com/v5/url';
  // Lyrics are a PUBLIC endpoint (same as classic Kugou) — the `/search`
  // (not `/v1/search`) + `man=yes&client=pc&hash` form, no auth headers.
  static const String _lyricSearchUrl = 'https://lyrics.kugou.com/search';
  static const String _lyricDownloadUrl = 'https://lyrics.kugou.com/download';
  static const String _sendCodeUrl =
      'https://loginserviceretry.kugou.com/v8/send_mobile_code/';
  static const String _loginUrl =
      'http://login.user.kugou.com/v7/login_by_verifycode/';

  // ===== common param builders =============================================

  String _nowSec() =>
      (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
  int _nowMs() => DateTime.now().millisecondsSinceEpoch;

  Map<String, String> _commonParams() => <String, String>{
        'dfid': KugougnCrypto.dfid,
        'appid': KugougnCrypto.appId,
        'mid': KugougnCrypto.mid,
        'uuid': KugougnCrypto.uuid,
        'clientver': KugougnCrypto.clientVer,
        'clienttime': _nowSec(),
      };

  Map<String, String> _signBase() => <String, String>{
        'userid': _userid,
        'token': _token,
        'appid': KugougnCrypto.appId,
        'clientver': KugougnCrypto.clientVer,
        'clienttime': _nowSec(),
        'mid': KugougnCrypto.mid,
        'uuid': KugougnCrypto.uuid,
        'dfid': KugougnCrypto.dfid,
      };

  // ===== low-level HTTP (gzip-aware, KG-* headers) =========================

  Future<Uint8List> _get(
    String url,
    Map<String, String> params, {
    String ua = 'ChannelTodayFeatured-wifi',
    Map<String, String>? extraHeaders,
  }) async {
    final Map<String, String> headers = _c.buildHeaders(
      ua,
      rfVersion: _c.kgRfVersionForUrl(url),
      userIdFake: _headerUserId,
    );
    if (extraHeaders != null) headers.addAll(extraHeaders);
    final Response<dynamic> resp = await _dio.get<dynamic>(
      url,
      queryParameters: params,
      options: Options(responseType: ResponseType.bytes, headers: headers),
    );
    return _bytes(resp.data);
  }

  Future<Uint8List> _post(
    String url,
    Map<String, String> query,
    String body, {
    String ua = 'ChannelTodayFeatured-wifi',
    String contentType = 'application/json',
    Map<String, String>? extraHeaders,
  }) async {
    final Map<String, String> headers = _c.buildHeaders(
      ua,
      rfVersion: _c.kgRfVersionForUrl(url),
      userIdFake: _headerUserId,
    );
    if (extraHeaders != null) headers.addAll(extraHeaders);
    final Response<dynamic> resp = await _dio.post<dynamic>(
      url,
      queryParameters: query,
      data: body,
      options: Options(
        responseType: ResponseType.bytes,
        contentType: contentType,
        headers: headers,
      ),
    );
    return _bytes(resp.data);
  }

  /// Normalizes a dio bytes payload, gunzipping when the raw body is still gzip
  /// (dart:io usually auto-decompresses; this is a belt-and-braces fallback that
  /// mirrors the reference `_decode_response`).
  Uint8List _bytes(dynamic raw) {
    Uint8List b;
    if (raw is Uint8List) {
      b = raw;
    } else if (raw is List<int>) {
      b = Uint8List.fromList(raw);
    } else if (raw is String) {
      b = Uint8List.fromList(utf8.encode(raw));
    } else {
      return Uint8List(0);
    }
    if (b.length >= 2 && b[0] == 0x1f && b[1] == 0x8b) {
      b = Uint8List.fromList(GZipCodec().decode(b));
    }
    return b;
  }

  /// Inflate a gzip/deflate body the transport left compressed; no-op for plain
  /// text. Some kugou hosts (notably lyrics.kugou.com) return a compressed body
  /// that dio's transport did not transparently inflate.
  static Uint8List _inflateBytes(Uint8List b) {
    try {
      if (b.length >= 2 && b[0] == 0x1f && b[1] == 0x8b) {
        return Uint8List.fromList(gzip.decode(b));
      }
      if (b.length >= 2 &&
          b[0] == 0x78 &&
          (b[1] == 0x01 || b[1] == 0x9c || b[1] == 0xda)) {
        return Uint8List.fromList(ZLibCodec().decode(b));
      }
    } catch (_) {}
    return b;
  }

  Map<String, dynamic> _json(Uint8List bytes) {
    if (bytes.isEmpty) return <String, dynamic>{};
    try {
      final dynamic d =
          jsonDecode(utf8.decode(_inflateBytes(bytes), allowMalformed: true));
      if (d is Map) return Map<String, dynamic>.from(d);
    } catch (_) {}
    return <String, dynamic>{};
  }

  // ===== search ============================================================

  /// One signed mixed-search request for [cursor]. Returns the typed `data.lists`
  /// sections + the raw `data` map (`_section` slices a section out; `data` feeds
  /// the song deep-walk fallback). Empty tuple on a non-Map body.
  Future<(List<dynamic>, Map<String, dynamic>)> _mixedFetch(
      String keyword, int cursor) async {
    final Map<String, String> p = _commonParams();
    p.addAll(<String, String>{
      'keyword': keyword,
      'platform': 'AndroidFilter',
      'tag': 'em',
      'area_code': '1',
      'iscorrection': '1',
      'cursor': cursor.toString(),
      'apiver': '22',
      'osversion': KugougnCrypto.osVersion,
      'userid': _userid,
      'ability': '1',
      'vip_status': _vipStatus,
      'token': _token,
      'user_labels': '',
      'page_id': KugougnCrypto.pageId,
      'ppage_id': KugougnCrypto.ppageId,
    });
    p['signature'] = _c.sign(p);
    final Map<String, dynamic> body = _json(await _get(_searchUrl, p));
    final dynamic data = body['data'];
    if (data is! Map) return (const <dynamic>[], <String, dynamic>{});
    final Map<String, dynamic> d = Map<String, dynamic>.from(data);
    final List<dynamic> sections =
        (d['lists'] is List) ? d['lists'] as List<dynamic> : const <dynamic>[];
    return (sections, d);
  }

  /// BARE GET (no KG-* headers, standard UA) + JSON decode — for the classic
  /// public `mobilecdn.kugou.com` endpoints, which return `{}` when hit with the
  /// concept app's KG-* headers. Empty map on any failure.
  Future<Map<String, dynamic>> _bareJson(String url, Map<String, String> q,
      {bool log = false}) async {
    final Dio bare = Dio(BaseOptions(
      responseType: ResponseType.bytes,
      headers: <String, String>{
        'User-Agent':
            'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Mobile',
      },
    ));
    try {
      final Response<dynamic> r = await bare.get<dynamic>(url, queryParameters: q);
      final Uint8List raw = _bytes(_bytesOf(r.data));
      final String text = utf8.decode(raw, allowMalformed: true);
      if (log) {
        debugPrint('KGN bareGet $url raw[${text.length}]='
            '${text.substring(0, text.length.clamp(0, 400))}');
      }
      final dynamic j = jsonDecode(text);
      return j is Map ? Map<String, dynamic>.from(j) : <String, dynamic>{};
    } catch (e) {
      debugPrint('KGN bareGet $url failed: $e');
      return <String, dynamic>{};
    }
  }

  /// Dedicated album search (`mobilecdn/api/v3/search/album`, public, no sign) —
  /// real `page`/`pagesize` paging, unlike the mixed 3-row preview. `data.info[]`
  /// carries albumid/albumname/imgurl/singer.
  Future<SearchResult> _searchAlbums(
      String keyword, int limit, int offset) async {
    final int pageSize = limit <= 0 ? 30 : limit;
    final int page = (limit <= 0) ? 1 : (offset ~/ limit) + 1;
    final Map<String, dynamic> resp = await _bareJson(
      'http://mobilecdn.kugou.com/api/v3/search/album',
      <String, String>{
        'version': '9108',
        'keyword': keyword,
        'pagesize': pageSize.toString(),
        'page': page.toString(),
        'plat': '0',
        'area_code': '1',
        'iscorrection': '1',
      },
    );
    final Map<String, dynamic> data = _obj(resp['data']);
    final int total = _int(data['total']);
    final dynamic rows = data['info'] ?? data['lists'] ?? data['list'];
    final List<Album> albums = <Album>[];
    final Set<int> seen = <int>{};
    if (rows is List) {
      for (final dynamic e in rows) {
        if (e is! Map) continue;
        final Album? a = _parseAlbum(Map<String, dynamic>.from(e));
        if (a != null && a.id != 0 && seen.add(a.id)) albums.add(a);
      }
    }
    return SearchResult(
      type: SearchType.album,
      albums: albums,
      total: total > 0 ? total : albums.length,
      hasMore: total > 0 ? (offset + albums.length) < total : false,
    );
  }

  @override
  Future<SearchResult> search({
    required String keyword,
    SearchType type = SearchType.song,
    int limit = 30,
    int offset = 0,
  }) async {
    // kugougn mixed 无独立「歌手」分区（歌手只内嵌在 album 行里），歌词非搜索类型。
    if (type == SearchType.artist || type == SearchType.lyric) {
      return SearchResult.empty(type);
    }
    try {
      // 专辑走【专用】公开搜索端点：mixed 的 album 分区只有 3 条固定预览，cursor 只翻
      // 歌曲不翻专辑（实测 cursor>0 的 album 分区为空）。dedicated 端支持真正的
      // page/pagesize 分页 → 数量正常 + loadMore 可续。
      if (type == SearchType.album) {
        return await _searchAlbums(keyword, limit, offset);
      }

      final int cursor = (limit <= 0) ? 0 : (offset ~/ limit);
      final (List<dynamic> sections, Map<String, dynamic> d) =
          await _mixedFetch(keyword, cursor);

      switch (type) {
        case SearchType.album:
          return SearchResult.empty(type); // handled above (dedicated endpoint)
        case SearchType.playlist:
          // 歌单仍走 mixed 的 collect 分区（它带 gid+suid → playlistDetail 能用已验证
          // 的 get_other_list_file_nofilt 取曲目；换端点会丢这两个键、详情又打不开）。
          final (List<dynamic> rows0, int total) = _section(sections, 'collect');
          final List<Playlist> playlists = _parsePlaylists(rows0);
          return SearchResult(
            type: type,
            playlists: playlists,
            total: total > 0 ? total : playlists.length,
            hasMore: false,
          );
        case SearchType.comprehensive:
          final (List<dynamic> songRows, int songTotal) =
              _section(sections, 'song');
          final (List<dynamic> albumRows, _) = _section(sections, 'album');
          final (List<dynamic> collectRows, _) = _section(sections, 'collect');
          final List<Song> songs = _parseSongs(songRows, d);
          return SearchResult(
            type: SearchType.comprehensive,
            songs: songs,
            albums: _parseAlbums(albumRows),
            playlists: _parsePlaylists(collectRows),
            total: songTotal > 0 ? songTotal : songs.length,
            hasMore: songTotal > 0
                ? (offset + songs.length) < songTotal
                : songs.length >= limit,
          );
        default: // SearchType.song
          final (List<dynamic> songRows, int songTotal) =
              _section(sections, 'song');
          final List<Song> songs = _parseSongs(songRows, d);
          return SearchResult(
            type: SearchType.song,
            songs: songs,
            total: songTotal > 0 ? songTotal : songs.length,
            hasMore: songTotal > 0
                ? (offset + songs.length) < songTotal
                : songs.length >= limit,
          );
      }
    } on DioException catch (e) {
      throw KugougnApiException(e.message ?? 'Kugougn search failed');
    }
  }

  /// Picks the `type == sectionType` section out of the mixed `data.lists[]`,
  /// returning its nested rows + declared total.
  (List<dynamic>, int) _section(List<dynamic> sections, String sectionType) {
    for (final dynamic s in sections) {
      if (s is! Map) continue;
      if (_str(s['type']) != sectionType) continue;
      final dynamic inner = s['lists'];
      return (inner is List ? inner : const <dynamic>[], _int(s['total']));
    }
    return (const <dynamic>[], 0);
  }

  List<Song> _parseSongs(List<dynamic> rows, Map<String, dynamic> data) {
    final List<Song> songs = <Song>[];
    final Set<int> seen = <int>{};
    for (final dynamic e in rows) {
      if (e is! Map) continue;
      final Song? s = _parseSong(Map<String, dynamic>.from(e));
      if (s != null && seen.add(s.id)) songs.add(s);
    }
    // Fallback: if the 'song' section shape shifts, deep-walk `data` for any
    // object carrying a FileHash + numeric id so songs never zero out silently.
    if (songs.isEmpty) {
      for (final Map<String, dynamic> m in _walkMaps(data)) {
        final Song? s = _parseSong(m);
        if (s != null && seen.add(s.id)) songs.add(s);
      }
    }
    return songs;
  }

  List<Album> _parseAlbums(List<dynamic> rows) {
    final List<Album> out = <Album>[];
    final Set<int> seen = <int>{};
    for (final dynamic e in rows) {
      if (e is! Map) continue;
      final Album? a = _parseAlbum(Map<String, dynamic>.from(e));
      if (a != null && a.id != 0 && seen.add(a.id)) out.add(a);
    }
    return out;
  }

  /// album section row → [Album] (albumid/albumname/img). Singer info isn't
  /// carried by [Album], so it's dropped (parity with the Netease album parse).
  Album? _parseAlbum(Map<String, dynamic> raw) {
    final int id =
        _int(_firstOf(raw, const <String>['albumid', 'AlbumID', 'album_id']));
    final String name = _stripTags(
        _firstOf(raw, const <String>['albumname', 'AlbumName', 'title']));
    if (id == 0 && name.isEmpty) return null;
    // dedicated 搜索行封面在 `imgurl`，常带 `{size}` 占位符；替换成实际尺寸。
    final String cover = _firstOf(raw,
            const <String>['img', 'imgurl', 'sizable_cover', 'cover', 'pic'])
        .replaceAll('{size}', '240');
    return Album(id: id, name: name, picUrl: _httpsPic(cover));
  }

  List<Playlist> _parsePlaylists(List<dynamic> rows) {
    final List<Playlist> out = <Playlist>[];
    final Set<int> seen = <int>{};
    for (final dynamic e in rows) {
      if (e is! Map) continue;
      final Playlist? pl = _parsePlaylist(Map<String, dynamic>.from(e));
      if (pl != null && pl.id != 0 && seen.add(pl.id)) out.add(pl);
    }
    return out;
  }

  /// collect section (歌单) row → [Playlist].
  Playlist? _parsePlaylist(Map<String, dynamic> raw) {
    final int id = _int(
        _firstOf(raw, const <String>['specialid', 'SpecialId', 'special_id']));
    final String name = _stripTags(
        _firstOf(raw, const <String>['specialname', 'SpecialName', 'title']));
    if (id == 0 && name.isEmpty) return null;
    // 搜索来的公开歌单行带 `gid`(=global_collection_id) + `suid`(=原作者 userid)。
    // 把它们按 specialid 存进 _kgnListRef，这样点开时 playlistDetail 能用【已验证】的
    // get_other_list_file_nofilt 取曲目（专为「他人歌单」设计），绕开坏的 get_special_detail。
    final String gid = _str(raw['gid'] ?? raw['global_collection_id']);
    final int owner = _int(raw['suid'] ?? raw['list_create_userid']);
    if (id != 0 && gid.isNotEmpty && gid != '0' && owner != 0) {
      _kgnListRef[id] = (gcid: gid, ownerId: owner);
    }
    return Playlist(
      id: id,
      name: name,
      coverUrl: _httpsPic(
          _firstOf(raw, const <String>['img', 'flexible_cover', 'cover'])),
      creatorName: _nullIfEmpty(
          _stripTags(_firstOf(raw, const <String>['nickname', 'username']))),
      description: _nullIfEmpty(
          _stripTags(_firstOf(raw, const <String>['intro', 'tag_str']))),
      trackCount: _int(_firstOf(raw, const <String>['song_count', 'songcount'])),
      // total_play_count is the cumulative count; play_count is period-only.
      playCount: _int(_firstOf(
          raw, const <String>['total_play_count', 'play_count', 'playcount'])),
    );
  }

  static String? _nullIfEmpty(String s) => s.isEmpty ? null : s;

  /// Builds a [Song] from a mixed-search `lists[]` row. A row is playable only if
  /// it has both a `FileHash` and a NUMERIC audio id (`MixSongID`/`Audioid`) —
  /// the encoded `EMixSongID` is a web id, unusable by the Android privilege/url
  /// flow, so it is intentionally not accepted as the id.
  Song? _parseSong(Map<String, dynamic> raw) {
    final String hash = _firstOf(raw, const <String>[
      'FileHash',
      'file_hash',
      'fileHash',
      'Hash',
      'hash',
      'SQFileHash',
      'HQFileHash',
    ]).toUpperCase();
    if (hash.isEmpty) return null;

    final String audioId = _firstNumeric(raw, const <String>[
      'MixSongID',
      'mixsongid',
      'MixSongId',
      'Audioid',
      'audioid',
      'AudioId',
      'audio_id',
      'album_audio_id',
      'AlbumAudioId',
    ]);
    if (audioId.isEmpty) return null;

    String fileName =
        _stripTags(_firstOf(raw, const <String>['FileName', 'filename']));
    String title = _stripTags(_firstOf(
        raw, const <String>['SongName', 'songname', 'OriSongName', 'FileName']));
    // 云歌单 (pubsongs/get_other_list_file_nofilt) 行只带 `name` = "歌手 - 歌名"，
    // 没有 SongName/FileName（App 也原样读 `name`，不解密）。这不是加密：之前歌名
    // 塌成 FileHash 是因为这些字段全缺、回落到 hash。仅当 SongName/FileName 全缺
    // （=云歌单形状）才兜底读 `name`，普通搜索/推荐行行为不变。
    if (title.isEmpty || fileName.isEmpty) {
      final String combined = _stripTags(_firstOf(raw, const <String>['name']));
      if (combined.isNotEmpty) {
        if (fileName.isEmpty) fileName = combined;
        if (title.isEmpty) {
          final int sep = combined.indexOf(' - ');
          title = sep >= 0 ? combined.substring(sep + 3).trim() : combined;
        }
      }
    }
    final String singer = _singerOf(raw);
    final String albumName =
        _stripTags(_firstOf(raw, const <String>['AlbumName', 'album_name']));
    final String albumId =
        _firstOf(raw, const <String>['AlbumID', 'album_id', 'AlbumId']);
    final String cover = _cover(raw);

    final List<Artist> artists = <Artist>[];
    for (final String part in singer.split(RegExp(r'[、/&]'))) {
      final String t = part.trim();
      if (t.isNotEmpty) artists.add(Artist(id: 0, name: t));
    }
    if (artists.isEmpty && singer.isNotEmpty) {
      artists.add(Artist(id: 0, name: singer));
    }

    Album? album;
    if (albumName.isNotEmpty || cover.isNotEmpty) {
      album = Album(
        id: int.tryParse(albumId) ?? 0,
        name: albumName,
        picUrl: cover.isEmpty ? null : cover,
      );
    }

    final int durSec = _int(_firstOf(raw, const <String>[
      'Duration', 'duration', 'TimeLength', 'timelen',
      'time_length', 'timelength', // 每日推荐 everyday_song_recommend 用 time_length（秒）
    ]));

    return Song(
      id: _stableId(hash, audioId),
      name: title.isEmpty ? (fileName.isEmpty ? hash : fileName) : title,
      artists: artists,
      album: album,
      duration: Duration(seconds: durSec),
      fee: 0,
      playable: true,
      source: MusicSource.kugougn,
      ref: <String, String>{
        'hash': hash,
        'albumAudioId': audioId,
        if (albumId.isNotEmpty) 'albumId': albumId,
        if (cover.isNotEmpty) 'cover': cover,
        if (fileName.isNotEmpty) 'fileName': fileName,
        if (albumName.isNotEmpty) 'albumName': albumName,
      },
    );
  }

  // ===== play url ==========================================================

  @override
  Future<PlayUrl?> songUrl(Song song,
      {AudioLevel level = AudioLevel.exhigh}) async {
    // The 概念版 App (and the reference client) key the whole play chain off the
    // LOWERCASE FileHash: `gen_v5_url_key` = md5(hash+secret+appid+mid+userid) and
    // the `hash` query param are both lowercase in the captured v5/url request
    // (API.md). Both the search parser and Song.fromKugouJson upper-case it, so we
    // must lower-case here or the `key` mismatches → v5/url yields no url.
    final String hash = (song.ref['hash'] ?? '').toLowerCase();
    final String audioId = song.ref['albumAudioId'] ?? '';
    if (hash.isEmpty || audioId.isEmpty) return null;

    // 概念版 has NO anonymous play path: `user_verify` signs the stream `auth` by
    // userid/token, so an anonymous jar yields an empty url for every track. Bail
    // early when logged out — otherwise each queued song fires privilege +
    // user_verify + v5/url (×2 for the 128k retry) only to fail. The empty return
    // surfaces AudioService's "需要会员或登录" unplayable message.
    if (!(_account?.isValid ?? false)) return null;

    final String quality = _qualityFor(level);
    try {
      String url = await _resolvePlayUrl(song, hash, audioId, quality);
      // Fall back to the always-free 128k tier when a higher tier yields nothing
      // (VIP-gated / no entitlement) so a playable copy still surfaces.
      if (url.isEmpty && quality != '128') {
        url = await _resolvePlayUrl(song, hash, audioId, '128');
      }
      if (url.isEmpty) return null;
      return PlayUrl(
        id: song.id,
        url: url,
        br: _brFor(quality),
        type: quality == 'flac' ? 'flac' : 'mp3',
        size: 0,
        level: level,
      );
    } on DioException {
      return null;
    }
  }

  /// Full privilege → user_verify → v5/url resolve for one quality tier. Returns
  /// the mp3/flac url, or '' when not entitled. Fires [onSessionExpired] when a
  /// logged-in call reports a token-invalid code.
  Future<String> _resolvePlayUrl(
      Song song, String hash, String audioId, String quality) async {
    final int sec = int.parse(_nowSec());
    final String pageId = song.ref['pageId'] ?? KugougnCrypto.pageId;
    final String ppageId = KugougnCrypto.ppageId;
    final String albumId = song.ref['albumId'] ?? '';
    final String name = song.ref['fileName'] ??
        (song.artistNames.isEmpty
            ? song.name
            : '${song.artistNames} - ${song.name}');

    // 1) Register the play + fetch the initial tracker (best-effort).
    Map<String, dynamic> priv = <String, dynamic>{};
    try {
      priv = await _getPrivilege(
          hash, audioId, albumId, name, pageId, ppageId, quality);
      if (_account != null && _isAuthError(priv)) {
        onSessionExpired?.call(_account!.userId);
      }
    } catch (_) {
      // A blocked/locked privilege call must not abort the URL attempt.
    }
    final Map<String, dynamic> tracker0 = _findTracker(priv);
    String moduleId = _str(tracker0['module_id']);
    if (moduleId.isEmpty) moduleId = '51';

    // 2) user_verify → fresh auth / open_time / module_id.
    final Map<String, String> uv = <String, String>{
      'dfid': KugougnCrypto.dfid,
      'module_id': moduleId,
      'appid': KugougnCrypto.appId,
      'mid': KugougnCrypto.mid,
      'clientver': KugougnCrypto.clientVer,
      'clienttime': sec.toString(),
      'uuid': KugougnCrypto.uuid,
      'userid': _userid,
      'token': _token,
    };
    uv['signature'] = _c.sign(uv);
    final Map<String, dynamic> verify =
        _json(await _get(_userVerifyUrl, uv, ua: 'FreeListen-wifi'));
    if (_account != null && _isAuthError(verify)) {
      onSessionExpired?.call(_account!.userId);
    }
    final Map<String, dynamic> auth = _obj(verify['data']);
    final String authorization =
        _str(auth['authorization']).isNotEmpty ? _str(auth['authorization']) : _str(auth['auth']);
    final String openTime = _str(auth['open_time']);
    String vModuleId = _str(auth['module_id']);
    if (vModuleId.isEmpty) vModuleId = '51';

    // 3) v5/url — signed, keyed by gen_v5_url_key, with the t2 KG-DEVID header.
    final String vipType = (_account?.vipType ?? 0).toString();
    final Map<String, String> params = <String, String>{
      'album_id': albumId,
      'userid': _userid,
      'area_code': '1',
      'module': '',
      'hash': hash,
      'appid': KugougnCrypto.appId,
      'ssa_flag': 'is_fromtrack',
      'version': KugougnCrypto.clientVer,
      'open_time': openTime,
      'vipType': vipType,
      'ptype': vipType,
      'token': _token,
      'page_id': pageId,
      'auth': authorization,
      'mtype': '0',
      'quality': quality,
      'album_audio_id': audioId,
      'behavior': 'play',
      'pid': '411',
      'module_id': vModuleId,
      'clienttime': sec.toString(),
      'cmd': '26',
      'uuid': KugougnCrypto.uuid,
      'ppage_id': ppageId,
      'mid': KugougnCrypto.mid,
      'dfid': KugougnCrypto.dfid,
      'clientver': KugougnCrypto.clientVer,
      'pidversion': KugougnCrypto.trackerPidVersion,
      'key': _c.genV5UrlKey(hash, _userid),
    };
    params['signature'] = _c.sign(params);

    final int machineTs = _nowMs();
    final Map<String, dynamic> urlResp = _json(await _get(
      _v5UrlUrl,
      params,
      ua: 'NetMusic-wifi',
      extraHeaders: <String, String>{
        'KG-DEVID': _c.genT2(machineTs),
        'KG-CLIENTTIMEMS': machineTs.toString(),
        'KG-AI-OP': '{"a":"1;1","b":"0;0;0;0"}',
        'x-router': 'trackercdn.kugou.com',
      },
    ));
    if (_account != null && _isAuthError(urlResp)) {
      onSessionExpired?.call(_account!.userId);
    }
    return _findPlayUrl(urlResp);
  }

  Future<Map<String, dynamic>> _getPrivilege(String hash, String audioId,
      String albumId, String name, String pageId, String ppageId,
      String quality) async {
    final Map<String, dynamic> resource = <String, dynamic>{
      'source': <String, dynamic>{
        'page_id': int.tryParse(pageId) ?? 0,
        'ppage_id': ppageId,
      },
      'behavior': 'play',
      'clientver': int.parse(KugougnCrypto.clientVer),
      'vip': 0,
      'resource': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 0,
          'type': 'audio',
          'hash': hash,
          'name': name,
          'album_id': albumId.isEmpty ? '0' : albumId,
          'album_audio_id': int.tryParse(audioId) ?? 0,
          'page_id': int.tryParse(pageId) ?? 0,
          'ppage_id': ppageId,
        },
      ],
      'token': _token,
      'user_attr0': 8,
      'relate': 0,
      'need_hash_offset': 1,
      'userid': int.tryParse(_userid) ?? 0,
      'need_userinfo': 1,
      'area_code': '1',
      'appid': int.parse(KugougnCrypto.appId),
      'quality': quality,
      'qualities': const <String>['128', '320', 'flac', 'high', 'viper_tape'],
    };
    return _json(await _post(
      _privilegeUrl,
      const <String, String>{},
      jsonEncode(resource),
      ua: 'mediastore-wifi',
      contentType: 'application/x-www-form-urlencoded',
    ));
  }

  /// Walks the privilege response for the first object carrying an `auth`(+`open_time`)
  /// or `authorization`(+`open_time`) tracker block.
  Map<String, dynamic> _findTracker(dynamic value) {
    for (final Map<String, dynamic> item in _walkMaps(value)) {
      if (item['open_time'] == null) continue;
      if (item['auth'] != null) return item;
      if (item['authorization'] != null) {
        return <String, dynamic>{
          'auth': item['authorization'],
          'open_time': item['open_time'],
          'module_id': item['module_id'] ?? 51,
        };
      }
    }
    return <String, dynamic>{};
  }

  /// Walks a response for a direct http(s) stream url under url/play_url/…keys.
  String _findPlayUrl(dynamic value) {
    for (final Map<String, dynamic> item in _walkMaps(value)) {
      for (final String key in const <String>[
        'url',
        'play_url',
        'playUrl',
        'file_url',
      ]) {
        final dynamic v = item[key];
        if (v is String && (v.startsWith('http://') || v.startsWith('https://'))) {
          return v;
        }
        if (v is List) {
          for (final dynamic e in v) {
            if (e is String &&
                (e.startsWith('http://') || e.startsWith('https://'))) {
              return e;
            }
          }
        }
      }
    }
    return '';
  }

  // ===== lyric =============================================================

  @override
  Future<Lyrics> lyric(Song song) async {
    // lyrics.kugou.com is a PUBLIC endpoint. The classic-Kugou form works: no
    // auth, no KG-* headers — just `ver/man=yes/client=pc/hash` (UPPERCASE hash).
    // The Android `/v1/search` auth path (userid/token + KG-* headers + man=y)
    // gets a 200-with-empty-body rejection — that was the "no lyrics" bug.
    final String hash = (song.ref['hash'] ?? '').toUpperCase();
    if (hash.isEmpty) return Lyrics.empty;
    try {
      // 1) Find a candidate by file hash (public, unauthenticated).
      final Response<dynamic> sr = await _dio.get<dynamic>(
        _lyricSearchUrl,
        queryParameters: <String, dynamic>{
          'ver': 1,
          'man': 'yes',
          'client': 'pc',
          'hash': hash,
        },
        options: Options(responseType: ResponseType.bytes),
      );
      final Map<String, dynamic> sm = _json(_bytes(sr.data));
      final dynamic candidates = sm['candidates'];
      if (candidates is! List || candidates.isEmpty) return Lyrics.empty;
      final Map<String, dynamic> best =
          Map<String, dynamic>.from(candidates.first as Map);
      final String id = _str(best['id']);
      final String accesskey = _str(best['accesskey']);
      if (id.isEmpty || accesskey.isEmpty) return Lyrics.empty;

      // 2) 逐字 KRC（增强，best-effort）：download fmt=krc → {content: base64(加密KRC)}
      //    → kugouDecryptKrc（去 krc1 头 + XOR + zlib）→ _krcToKlyric 转绝对 klyric。
      String klyric = '';
      try {
        final Response<dynamic> kd = await _dio.get<dynamic>(
          _lyricDownloadUrl,
          queryParameters: <String, dynamic>{
            'ver': 1,
            'client': 'pc',
            'id': id,
            'accesskey': accesskey,
            'fmt': 'krc',
            'charset': 'utf8',
          },
          options: Options(responseType: ResponseType.bytes),
        );
        final Map<String, dynamic> km = _json(_bytes(kd.data));
        final String krc = kugouDecryptKrc(_str(km['content'])) ?? '';
        if (krc.isNotEmpty) klyric = _krcToKlyric(krc);
      } catch (e) {
        debugPrint('Kugougn KRC unavailable: $e');
      }
      if (klyric.trim().isNotEmpty) {
        final Lyrics ly = Lyrics.parse(klyric: klyric);
        if (ly.lines.isNotEmpty) return ly;
      }

      // 3) 回退：plain LRC (fmt=lrc → {content: base64(LRC)}).
      final Response<dynamic> dl = await _dio.get<dynamic>(
        _lyricDownloadUrl,
        queryParameters: <String, dynamic>{
          'ver': 1,
          'client': 'pc',
          'id': id,
          'accesskey': accesskey,
          'fmt': 'lrc',
          'charset': 'utf8',
        },
        options: Options(responseType: ResponseType.bytes),
      );
      final String lrc = _decodeLyric(_bytes(dl.data));
      if (lrc.trim().isEmpty) return Lyrics.empty;
      return Lyrics.parse(lrc: lrc);
    } on DioException {
      // Transient transport failure — surface it so PlayerProvider retries
      // instead of caching "no lyrics".
      rethrow;
    }
  }

  /// KRC(`<相对偏移,字长,0>字`，偏移相对行首) → klyric(`(绝对起,字长)字`) 供
  /// _parseKlyric。行头 `[行起,行长]` 保留、元数据行([ti:]/[ar:]等) 跳过；把相对偏移
  /// 加上行首 → 绝对毫秒（走 _parseKlyric 的绝对分支，避免相对启发式的边界误判）。
  String _krcToKlyric(String krc) {
    final StringBuffer out = StringBuffer();
    final RegExp head = RegExp(r'^\[(\d+),(\d+)\](.*)$');
    final RegExp word = RegExp(r'<(\d+),(\d+)(?:,\d+)?>([^<\r\n]*)');
    for (final String rawLine in krc.split('\n')) {
      final Match? h = head.firstMatch(rawLine.trimRight());
      if (h == null) continue;
      final int ls = int.parse(h.group(1)!);
      out.write('[${h.group(1)},${h.group(2)}]');
      for (final Match m in word.allMatches(h.group(3)!)) {
        out.write('(${ls + int.parse(m.group(1)!)},${m.group(2)})${m.group(3) ?? ''}');
      }
      out.write('\n');
    }
    return out.toString();
  }

  /// The `/download` payload may be a JSON envelope (`{content: base64}`), a bare
  /// base64 LRC, or raw LRC text — decode all three.
  String _decodeLyric(Uint8List rawIn) {
    final String text = utf8.decode(_inflateBytes(rawIn), allowMalformed: true);
    // JSON envelope with a base64 `content`.
    try {
      final dynamic d = jsonDecode(text);
      if (d is Map && d['content'] is String) {
        final String c = d['content'] as String;
        try {
          return utf8.decode(base64.decode(c), allowMalformed: true);
        } catch (_) {
          return c;
        }
      }
    } catch (_) {}
    // Bare base64.
    final String t = text.trim();
    if (t.isNotEmpty && !t.startsWith('[') && !t.startsWith('{')) {
      try {
        final String decoded =
            utf8.decode(base64.decode(t), allowMalformed: true);
        if (decoded.contains('[')) return decoded;
      } catch (_) {}
    }
    return text;
  }

  // ===== login (phone + SMS) ===============================================

  /// `send_mobile_code` — asks Kugougn to SMS a verify code to [phone] (11-digit
  /// mainland mobile). Throws [KugougnApiException] on a non-`status:1` response.
  Future<void> sendMobileCode(String phone) async {
    final String p = _normalizePhone(phone);
    final int ts = int.parse(_nowSec());
    final String ak = _c.randHex16();
    final String masked = _mask(p);

    // Build the body ONCE — the exact text is both signed and sent.
    final String bodyText = jsonEncode(<String, dynamic>{
      'plat': '1',
      'businessid': 5,
      'clienttime_ms': ts,
      'pk': _c.rsaEncrypt(jsonEncode(
          <String, dynamic>{'clienttime_ms': ts, 'key': ak})),
      'mobile': masked,
      'params': _c.aesEncrypt(jsonEncode(<String, dynamic>{'mobile': p}), ak),
    });
    final Map<String, String> query = _commonParams();
    query['signature'] = _c.sign(query, bodyText);

    try {
      final Map<String, dynamic> resp = _json(await _post(
        _sendCodeUrl,
        query,
        bodyText,
        ua: 'SendMobileCodeProtocolV7-wifi',
        extraHeaders: const <String, String>{'kg-rc': '2'},
      ));
      if (_int(resp['status']) != 1) {
        throw KugougnApiException(_loginErrorText(resp, '验证码发送失败'));
      }
    } on DioException catch (e) {
      throw KugougnApiException(e.message ?? '验证码发送失败');
    }
  }

  /// `login_by_verifycode` (pure algorithm, `use_frida=False`) — exchanges
  /// [phone]+[code] for an account. Returns the signed-in [KugougnAccount]; throws
  /// [KugougnApiException] on failure.
  Future<KugougnAccount> loginByVerifyCode(String phone, String code) async {
    final String p = _normalizePhone(phone);
    // NativeParams order: t1 → t2 → clienttime, each its own millisecond read.
    final int t1Ts = _nowMs();
    final int t2Ts = _nowMs();
    final int clientTs = _nowMs();
    final String t1 = _c.genT1(t1Ts);
    final String t2 = _c.genT2(t2Ts);
    final String ts = clientTs.toString();
    final String ak = _c.randHex16();
    final String key = _c.genTimeKey(ts);

    final String bodyText = jsonEncode(<String, dynamic>{
      'mobile': _mask(p),
      'clienttime_ms': ts,
      'dfid': KugougnCrypto.dfid,
      'dev': KugougnCrypto.deviceModel,
      'busi_type': 'concept',
      'plat': 1,
      // clienttime_ms is a STRING here (Python uses str(client_ts)) — quoted in
      // the JSON, unlike send_mobile_code which uses an int.
      'pk': _c.rsaEncrypt(
          jsonEncode(<String, dynamic>{'clienttime_ms': ts, 'key': ak})),
      't1': t1,
      't2': t2,
      'support_multi': 1,
      'gitversion': KugougnCrypto.gitVersion,
      'opt_product_types': 'dvip,qvip,wvip',
      'key': key,
      'params': _c.aesEncrypt(
          jsonEncode(<String, dynamic>{'mobile': p, 'code': code}), ak),
    });
    final Map<String, String> query = _commonParams();
    query['signature'] = _c.sign(query, bodyText);

    try {
      final Map<String, dynamic> resp = _json(
          await _post(_loginUrl, query, bodyText, ua: 'LOGIN-wifi'));
      final KugougnAccount? account = _accountFromLogin(resp, ak);
      if (account == null) {
        throw KugougnApiException(_loginErrorText(resp, '登录失败'));
      }
      return account;
    } on DioException catch (e) {
      throw KugougnApiException(e.message ?? '登录失败');
    }
  }

  /// Parses a `login_by_verifycode` response (`update_identity_from_login`). The
  /// token may be plaintext in `data`, or under `secu_params` (AES-encrypted with
  /// the login's own [ak]).
  KugougnAccount? _accountFromLogin(Map<String, dynamic> resp, String ak) {
    if (_int(resp['status']) != 1) return null;
    Map<String, dynamic> data = _obj(resp['data']);
    if (data.isEmpty) data = resp;

    final String userId = _str(data['userid']);
    String token = _str(data['token']);
    if (token.isEmpty) {
      final String secu = _str(data['secu_params']);
      if (secu.isNotEmpty) {
        try {
          final dynamic dec = jsonDecode(_c.aesDecryptSecu(secu, ak));
          if (dec is Map) token = _str(dec['token']);
        } catch (e) {
          debugPrint('KugougnApi._accountFromLogin secu decrypt failed: $e');
        }
      }
    }
    if (userId.isEmpty || token.isEmpty) return null;

    int vipType = _int(data['vip_type']);
    if (vipType == 0) vipType = _int(data['svip_level']);
    return KugougnAccount(
      userId: userId,
      token: token,
      nickname: _str(data['nickname']),
      avatarUrl: _httpsPic(_str(data['pic'])),
      vipType: vipType,
    );
  }

  // ===== daily sign-in (免费 VIP 签到) ======================================

  static const String _freeModeInfoUrl =
      'https://gateway.kugou.com/concepts/v1/free_mode/info';
  static const String _receiveListenSongUrl =
      'https://gateway.kugou.com/youth/v1/recharge/receive_vip_listen_song';
  static const String _secondFloorUrl =
      'https://gateway.kugou.com/concepts/v1/free_mode/secondfloor_info';
  static const String _receiveNewUserVipUrl =
      'https://gateway.kugou.com/youth/v1/activity/receive_new_user_vip';
  static const String _receiveMorningUrl =
      'https://gateway.kugou.com/concepts/v1/free_mode/receive_vip_morning';

  /// Signed GET (`_signed_get`): appends the MD5 `signature` over the params
  /// (no body) then fetches + JSON-decodes.
  Future<Map<String, dynamic>> _signedGet(
      String url, Map<String, String> params, String ua) async {
    final Map<String, String> p = Map<String, String>.of(params);
    p['signature'] = _c.sign(p);
    return _json(await _get(url, p, ua: ua));
  }

  /// Signed POST (`_signed_post`): the compact JSON [body] is BOTH signed (as the
  /// signature suffix) and sent verbatim.
  Future<Map<String, dynamic>> _signedPost(String url,
      Map<String, String> query, Map<String, dynamic> body, String ua) async {
    final String bodyText = jsonEncode(body);
    final Map<String, String> p = Map<String, String>.of(query);
    p['signature'] = _c.sign(p, bodyText);
    return _json(await _post(url, p, bodyText, ua: ua));
  }

  /// Runs the 概念版 daily sign-in, claiming every currently-available free VIP
  /// (听歌 / 签到 / 早间), a faithful port of the reference `daily_signin()`.
  /// Requires a logged-in account; throws [KugougnApiException] when anonymous.
  /// Each claim is independent — one failing never blocks the others.
  Future<KugougnSignInResult> signInDaily() async {
    if (!(_account?.isValid ?? false)) {
      throw KugougnApiException('请先登录酷狗账号再签到');
    }
    final List<String> claimed = <String>[];
    final List<String> skipped = <String>[];
    final List<String> errors = <String>[];

    // 1. 听歌免费 VIP (listen_song_task) —— 面向所有账号的每日 VIP 主入口
    // (REVERSE_ENGINEERING_REPORT §11.2：非VIP账号直接 receive_vip_listen_song →
    //  status=1 即解锁，且「服务端根据 token 查询真实 VIP 状态」——即 App 端的
    //  active_send 只是提示位，不同账号口径不一致。旧逻辑把它当硬门控 →
    //  active_send 为假的账号整段被跳过、从不发起领取，这就是「一个账号能领、
    //  另一个领不到」的根因。改为：只要 free_mode 返回了听歌任务(或 auto_send)
    //  就发起领取，由服务端裁决；被服务端拒绝(今日已领/未达听歌时长/不符资格)
    //  归为「跳过 + 服务端原因」，而非报错。
    try {
      final Map<String, String> infoParams = _signBase()
        ..['fields'] = 'auto_send,listen_song_task,upgrade_ad';
      final Map<String, dynamic> data = _obj((await _signedGet(
              _freeModeInfoUrl, infoParams, 'MineMainFreeMode-wifi'))['data']);
      debugPrint('KugougnApi.signInDaily free_mode/info data=${jsonEncode(data)}');
      final Map<String, dynamic> listen = _obj(data['listen_song_task']);
      final bool hasListenTask =
          listen.isNotEmpty || _truthy(data['auto_send']);
      if (hasListenTask) {
        final Map<String, dynamic> r = await _signedPost(
            _receiveListenSongUrl,
            _signBase(),
            const <String, dynamic>{},
            'ReceiveVipListenSong-wifi');
        debugPrint(
            'KugougnApi.signInDaily receive_vip_listen_song resp=${jsonEncode(r)}');
        if (_int(r['status']) == 1) {
          final String txt = _str(listen['vip_txt']);
          claimed.add(txt.isEmpty ? '听歌VIP' : '听歌VIP（$txt）');
        } else {
          // 服务端说不能领 —— 已领/时长不够/不符资格：跳过并回显原因，不算失败。
          skipped.add('听歌VIP（${_loginErrorText(r, '暂不可领')}）');
        }
      } else {
        skipped.add('听歌VIP（今日不可领）');
      }
    } catch (e) {
      debugPrint('KugougnApi.signInDaily listen_song failed: $e');
      errors.add('听歌VIP：$e');
    }

    // 2. 签到 VIP + 早间 VIP (secondfloor_info)
    try {
      final Map<String, dynamic> sd = _obj((await _signedGet(
              _secondFloorUrl, _signBase(), 'ChannelFreeMode-wifi'))['data']);
      debugPrint('KugougnApi.signInDaily secondfloor_info data=${jsonEncode(sd)}');

      // 2a. 签到列表 (vip_signin.signin_list) — 领取第一个 receive_status==3 的
      final Map<String, dynamic> vipSignin = _obj(sd['vip_signin']);
      final List<dynamic> list =
          (vipSignin['signin_list'] as List<dynamic>?) ?? const <dynamic>[];
      bool didSignin = false;
      for (final dynamic it in list) {
        final Map<String, dynamic> m = _obj(it);
        if (_int(m['receive_status']) == 3) {
          final Map<String, dynamic> r = await _signedPost(
              _receiveNewUserVipUrl,
              _signBase(),
              <String, dynamic>{'period_id': m['period_id']},
              'ReceiveVipNewUser-wifi');
          if (_int(r['status']) == 1) {
            claimed.add('签到VIP');
          } else {
            errors.add('签到VIP：${_loginErrorText(r, '领取失败')}');
          }
          didSignin = true;
          break;
        }
      }
      if (!didSignin) {
        if (list.isEmpty) {
          skipped.add('签到VIP（无签到活动）');
        } else if (_truthy(vipSignin['received_today'])) {
          skipped.add('签到VIP（今日已领）');
        }
      }

      // 2b. 早间 VIP (需要 token_vip_morning，作为签名 query 参数)
      final Map<String, dynamic> morning = _obj(sd['vip_morning']);
      final String token = _str(morning['token_vip_morning']);
      if (token.isNotEmpty && !_truthy(morning['received_today'])) {
        final Map<String, String> q = _signBase()
          ..['token_vip_morning'] = token;
        final Map<String, dynamic> r = await _signedPost(_receiveMorningUrl, q,
            <String, dynamic>{'date': _todayDate()}, 'ReceiveVipMorning-wifi');
        if (_int(r['status']) == 1) {
          claimed.add('早间VIP');
        } else {
          errors.add('早间VIP：${_loginErrorText(r, '领取失败')}');
        }
      } else {
        skipped.add('早间VIP（无或已领）');
      }
    } catch (e) {
      debugPrint('KugougnApi.signInDaily signin failed: $e');
      errors.add('签到：$e');
    }

    return KugougnSignInResult(claimed: claimed, skipped: skipped, errors: errors);
  }

  /// Today's date as `YYYY-MM-DD` (the `receive_vip_morning` body needs it).
  String _todayDate() {
    final DateTime n = DateTime.now();
    final String mm = n.month.toString().padLeft(2, '0');
    final String dd = n.day.toString().padLeft(2, '0');
    return '${n.year}-$mm-$dd';
  }

  /// Loose truthiness for the API's mixed bool/int/string flags.
  bool _truthy(dynamic v) => v == true || v == 1 || v == '1' || v == 'true';

  // ===== discovery / feeds (no anon feed API → hot-search only) ============

  /// 首页推荐歌单 (`multi_special_recommend`, anonymous). Parsed defensively —
  /// the response nests 歌单 rows under several section keys.
  @override
  Future<List<Playlist>> personalizedPlaylists({int limit = 12}) async {
    try {
      final Map<String, dynamic> resp = await _signedGet(
        'http://service.mobile.kugou.com/v1/yueku/multi_special_recommend',
        _signBase(),
        'Recommend-wifi',
      );
      return _parseSpecialPlaylists(resp).take(limit).toList();
    } catch (e) {
      debugPrint('KugougnApi.personalizedPlaylists failed: $e');
      return const <Playlist>[];
    }
  }

  @override
  Future<List<Song>> recommendedSongs({int limit = 8}) async {
    // 登录态：真·每日推荐（everyday_song_recommend）。空/失败/未登录 → 热门搜索兜底。
    if (_account?.isValid ?? false) {
      final List<Song> daily = await _dailySongs(limit);
      if (daily.isNotEmpty) return daily.take(limit).toList();
    }
    try {
      final SearchResult r =
          await search(keyword: '热门', type: SearchType.song, limit: limit);
      if (r.songs.isNotEmpty) return r.songs.take(limit).toList();
      final SearchResult r2 =
          await search(keyword: '流行', type: SearchType.song, limit: limit);
      return r2.songs.take(limit).toList();
    } catch (_) {
      return const <Song>[];
    }
  }

  /// 每日推荐歌曲 `everyday_song_recommend`（需登录；`u_info = AES(token)`, API.md
  /// §4.7/§6.6）。响应 shape 未经抓包核实 → 防御式解析,失败静默返回空(首页不报错)。
  Future<List<Song>> _dailySongs(int limit) async {
    if (!(_account?.isValid ?? false)) return const <Song>[];
    final int ctsMs = _nowMs();
    final String key = _c.md5Hex(
        '1100vvuo4I2CfFGZKdud2168D7Ffu5YEiFZ0${KugougnCrypto.clientVer}$ctsMs');
    final String bodyText = jsonEncode(<String, dynamic>{
      'appid': 1100,
      'clientver': int.parse(KugougnCrypto.clientVer),
      'platform': 'android',
      'clienttime': ctsMs,
      'key': key,
      'area_code': '1',
      'birthday': '',
      'vip_flags': 0,
      'm_type': 0,
      // 见下方 platform：小写 'android'（App DKEngine.DKPlatform.ANDROID 常量值）。
      // 大写 'ANDROID' → everydayrec 后端 error_code 200103 空返回（实网复测确认）。
      'vip_type': _account?.vipType ?? 0,
      'mid': KugougnCrypto.mid,
      'uuid': '-',
      'userid': int.tryParse(_userid) ?? 0,
      'u_info': _c.genUInfo(_token.trim()),
    });
    final Map<String, String> query = _signBase();
    query['signature'] = _c.sign(query, bodyText);
    try {
      final Uint8List raw = await _post(
        'http://everydayrec.service.kugou.com/everyday_song_recommend',
        query,
        bodyText,
        ua: 'DailyBillProtocol-wifi',
        // body 是 JSON 串：必须 application/json（参考 http_post 默认值）。form-
        // urlencoded 会让 everydayrec 后端解析不出字段 → 空返回（本 bug 根因）。
        contentType: 'application/json',
      );
      final Map<String, dynamic> resp = _json(raw);
      final Map<String, dynamic> data = _obj(resp['data']);
      final Set<int> seen = <int>{};
      final List<Song> songs = <Song>[];
      final dynamic rows = data['song_list'] ?? data['songs'];
      if (rows is List) {
        for (final dynamic e in rows) {
          if (e is! Map) continue;
          final Song? s = _parseSong(Map<String, dynamic>.from(e));
          if (s != null && seen.add(s.id)) songs.add(s);
        }
      }
      if (songs.isEmpty) {
        for (final Map<String, dynamic> m in _walkMaps(data)) {
          final Song? s = _parseSong(m);
          if (s != null && seen.add(s.id)) songs.add(s);
        }
      }
      return songs.take(limit).toList();
    } on DioException {
      return const <Song>[];
    } catch (e) {
      debugPrint('KugougnApi._dailySongs failed: $e');
      return const <Song>[];
    }
  }

  /// 歌单详情 —— 用户云歌单(自建/收藏)的曲目走 `pubsongs/v2/get_other_list_file_nofilt`
  /// (主键是 [userPlaylists] 缓存的 `global_collection_id` + 原作者 userid，**不是**
  /// `special_id`;把 listid 当 special_id 发就是之前 400 `<html>` 的根因)。无 gcid 的
  /// 纯私有/临时列表酷狗无 HTTP 取歌端点 → 优雅降级为空歌单。响应防御式解析。
  @override
  Future<Playlist> playlistDetail(int id) async {
    ({String gcid, int ownerId})? ref = _kgnListRef[id];
    // 深链/冷启动缓存未就绪时，先拉一次 userPlaylists 填缓存再查。
    if (ref == null) {
      try {
        await userPlaylists(limit: 100);
      } catch (_) {}
      ref = _kgnListRef[id];
    }
    if (ref == null) {
      // 既非本人云歌单、又没在搜索里拿到 gid/suid（如深链冷启动）——酷狗无公开 HTTP
      // 取歌端点（get_special_detail 实测 400），优雅降级为空歌单。搜索→点开的正常
      // 路径已由 [_parsePlaylist] 把 collect 行的 gid+suid 存进 _kgnListRef，走上面的
      // 已验证 get_other_list_file_nofilt，不会落到这里。
      debugPrint('KGN playlistDetail($id): no gcid/owner (deep-link cold start) '
          '— empty playlist.');
      return Playlist(id: id, name: '酷狗歌单', tracks: const <Song>[]);
    }
    try {
      final Map<String, String> p = _signBase()
        ..['module'] = 'CloudMusic'
        ..['type'] = '0'
        ..['need_sort'] = '1'
        ..['need_rd'] = '0'
        ..['mode'] = '1'
        ..['userid'] = ref.ownerId.toString()
        ..['global_collection_id'] = ref.gcid
        ..['specialid'] = '0'
        ..['begin_idx'] = '0'
        ..['pagesize'] = '100';
      final Map<String, dynamic> resp = await _signedGet(
        'https://gateway.kugou.com/pubsongs/v2/get_other_list_file_nofilt',
        p,
        'SpecialDetail-wifi',
      );
      final Map<String, dynamic> data = _obj(resp['data']);
      final Set<int> seen = <int>{};
      final List<Song> tracks = <Song>[];
      final dynamic rows = data['info'] ?? data['song_list'] ?? data['songs'];
      if (rows is List) {
        for (final dynamic e in rows) {
          if (e is! Map) continue;
          final Song? s = _parseSong(Map<String, dynamic>.from(e));
          if (s != null && seen.add(s.id)) tracks.add(s);
        }
      }
      if (tracks.isEmpty) {
        for (final Map<String, dynamic> m in _walkMaps(data)) {
          final Song? s = _parseSong(m);
          if (s != null && seen.add(s.id)) tracks.add(s);
        }
      }
      final String name = _stripTags(_str(data['name'] ?? data['specialname']));
      return Playlist(
        id: id,
        name: name.isEmpty ? '酷狗歌单' : name,
        trackCount: tracks.length,
        tracks: tracks,
      );
    } on DioException catch (e) {
      // DEBUG kgn — remove after diagnosis.
      final dynamic rd = e.response?.data;
      final String body = rd is List<int>
          ? utf8.decode(_inflateBytes(Uint8List.fromList(rd)), allowMalformed: true)
          : _str(rd);
      debugPrint('KGN playlistDetail($id gcid=${ref.gcid}) DioErr: '
          'status=${e.response?.statusCode} '
          'body=${body.replaceAll("\n", " ").substring(0, body.length.clamp(0, 300))}');
      return Playlist(id: id, name: '酷狗歌单', tracks: const <Song>[]);
    }
  }

  /// 专辑详情 —— 概念版 gateway 的 `get_special_detail` 实测 400（文档端点是坏的）。
  /// 改走经典公开端点 `mobilecdn.kugou.com/api/v3/album/song`（无需签名/登录，全客户端
  /// 共用），返回 `data.info[]`（含 hash/album_audio_id/filename，[_parseSong] 直接可用）。
  @override
  Future<Playlist> albumDetail(int id) async {
    try {
      final Map<String, dynamic> resp = await _bareJson(
        'http://mobilecdn.kugou.com/api/v3/album/song',
        <String, String>{
          'version': '9108',
          'albumid': id.toString(),
          'plat': '0',
          'pagesize': '100',
          'area_code': '1',
          'page': '1',
        },
      );
      final Map<String, dynamic> data = _obj(resp['data']);
      final Set<int> seen = <int>{};
      final List<Song> tracks = <Song>[];
      final dynamic rows =
          data['info'] ?? data['songs'] ?? data['song_list'] ?? data['list'];
      if (rows is List) {
        for (final dynamic e in rows) {
          if (e is! Map) continue;
          final Song? s = _parseSong(Map<String, dynamic>.from(e));
          if (s != null && seen.add(s.id)) tracks.add(s);
        }
      }
      final String name = _stripTags(_str(
          data['album_name'] ?? data['albumname'] ?? resp['album_name']));
      // 专辑封面：先取响应顶层封面键，取不到回落第一首歌的封面（用户诉求）。
      final String? albumCover = _pic(
              data['imgurl'] ??
                  data['img'] ??
                  data['sizable_cover'] ??
                  data['album_sizable_cover'] ??
                  resp['imgurl'],
              480) ??
          (tracks.isNotEmpty ? tracks.first.artworkUrl : null);
      return Playlist(
        id: id,
        name: name.isEmpty ? '专辑' : name,
        coverUrl: albumCover,
        trackCount: tracks.length,
        tracks: tracks,
      );
    } catch (e) {
      debugPrint('KGN albumDetail($id) failed: $e');
      return Playlist(id: id, name: '专辑', tracks: const <Song>[]);
    }
  }

  static List<int> _bytesOf(dynamic d) => d is List<int>
      ? d
      : (d is String ? utf8.encode(d) : const <int>[]);

  /// The signed-in user's cloud 歌单 (`cloudlist.service/v8/get_all_list`, login).
  @override
  Future<List<Playlist>> userPlaylists({int limit = 30, int offset = 0}) async {
    if (!(_account?.isValid ?? false)) return const <Playlist>[];
    try {
      final Map<String, dynamic> resp = await _signedCloudPost(
        '8/get_all_list',
        <String, dynamic>{
          'userid': int.tryParse(_userid) ?? 0,
          'token': _token,
          'total_ver': 0,
          'page': 1,
          'pagesize': limit,
          'type': 2,
        },
        const <String, String>{'plat': '1'},
      );
      final Map<String, dynamic> data = _obj(resp['data']);
      final dynamic info = data['info'] ?? data['list'];
      if (info is! List) return const <Playlist>[];
      return info
          .whereType<Map>()
          .map((dynamic e) {
            final Map<String, dynamic> m = Map<String, dynamic>.from(e);
            // Keep Playlist.id = listid (add/delete-song management keys on it);
            // stash gcid + owner so playlistDetail can fetch the tracks.
            final int listid = _int(m['listid']);
            final String gcid = _str(m['global_collection_id']);
            final int ownerId = _int(m['list_create_userid']) > 0
                ? _int(m['list_create_userid'])
                : (int.tryParse(_userid) ?? 0);
            if (listid != 0 && gcid.isNotEmpty && gcid != '0') {
              _kgnListRef[listid] = (gcid: gcid, ownerId: ownerId);
            }
            return Playlist(
              id: listid,
              name: _str(m['name']),
              coverUrl: _pic(m['pic'] ?? m['imgurl'] ?? m['flexible_cover'], 200),
              trackCount: _int(m['count'] ?? m['songcount']),
            );
          })
          .where((Playlist p) => p.id != 0 && p.name.isNotEmpty)
          .toList();
    } catch (e) {
      debugPrint('KugougnApi.userPlaylists failed: $e');
      return const <Playlist>[];
    }
  }

  /// 每日推荐歌曲（`everyday_song_recommend`；需登录，`u_info` 已纯 Dart 复现，见
  /// [_dailySongs]）。未登录/失败返回空。
  @override
  Future<List<Song>> dailyRecommendSongs({int limit = 30}) => _dailySongs(limit);

  @override
  Future<List<Playlist>> dailyRecommendPlaylists({int limit = 30}) =>
      personalizedPlaylists(limit: limit);

  // ===== playlist management (cloudlist.service, login) ====================

  /// Creates a cloud 歌单 (`v4/add_list`); returns its new `listid`.
  @override
  Future<int> createPlaylist(String name, {int privacy = 0}) async {
    if (!(_account?.isValid ?? false)) {
      throw KugougnApiException('请先登录酷狗概念版账号');
    }
    final Map<String, dynamic> resp = await _signedCloudPost(
      '4/add_list',
      <String, dynamic>{
        'userid': int.tryParse(_userid) ?? 0,
        'token': _token,
        'total_ver': 0,
        'name': name,
        'type': 0,
        'source': 1,
        'list_create_userid': 0,
        'list_create_listid': 0,
      },
      <String, String>{'last_area': 'gztx', 'last_time': _nowSec()},
    );
    final Map<String, dynamic> data = _obj(resp['data']);
    final int listid = _int(data['listid'] ?? _obj(data['info'])['listid']);
    if (_int(resp['status']) != 1 || listid == 0) {
      throw KugougnApiException(_loginErrorText(resp, '创建歌单失败'));
    }
    return listid;
  }

  /// Deletes a cloud 歌单 (`v3/delete_list`).
  @override
  Future<void> deletePlaylist(int pid) async {
    if (!(_account?.isValid ?? false)) {
      throw KugougnApiException('请先登录酷狗概念版账号');
    }
    final Map<String, dynamic> resp = await _signedCloudPost(
      '3/delete_list',
      <String, dynamic>{
        'userid': int.tryParse(_userid) ?? 0,
        'token': _token,
        'listid': pid,
        'total_ver': 0,
        'type': 0,
      },
      <String, String>{'last_area': 'gztx', 'last_time': _nowSec()},
    );
    if (_int(resp['status']) != 1) {
      throw KugougnApiException(_loginErrorText(resp, '删除歌单失败'));
    }
  }

  // add/remove a track needs its FileHash + mixsongid, which the id-only
  // [MusicApi] signature can't carry (the int id is a one-way hash of the hash);
  // 共同歌单 already covers cross-source collection locally.
  @override
  Future<void> addTracksToPlaylist(int pid, List<int> ids) {
    throw KugougnApiException('酷狗概念版加歌需要完整曲目信息，请用共同歌单');
  }

  @override
  Future<void> removeTracksFromPlaylist(int pid, List<int> ids) {
    throw KugougnApiException('酷狗概念版删歌需要完整曲目信息，请用共同歌单');
  }

  @override
  Future<void> collectPlaylist(int id, bool collect) {
    throw KugougnApiException('酷狗概念版暂不支持收藏歌单');
  }

  // ===== feed/cloud helpers ================================================

  /// A signed cloud POST (`cloudlist.service/v<path>`) — mirrors the reference
  /// `_signed_cloud_post`: `_cloud_params` query + JSON body, both signed.
  Future<Map<String, dynamic>> _signedCloudPost(
      String path, Map<String, dynamic> body, Map<String, String> extra) async {
    final Map<String, String> p = <String, String>{
      'clienttime': _nowSec(),
      'mid': KugougnCrypto.mid,
      'uuid': KugougnCrypto.uuid,
      'clientver': KugougnCrypto.clientVer,
      'appid': KugougnCrypto.appId,
      'dfid': KugougnCrypto.dfid,
      ...extra,
    };
    final String bodyText = jsonEncode(body);
    p['signature'] = _c.sign(p, bodyText);
    return _json(await _post(
      'https://gateway.kugou.com/cloudlist.service/v$path',
      p,
      bodyText,
      ua: 'CloudMusic-wifi',
      contentType: 'application/json;charset=utf-8',
    ));
  }

  /// Recursively collects 歌单 rows (`specialid`/`specialname`) from the nested
  /// recommend response, dedup by id.
  List<Playlist> _parseSpecialPlaylists(Map<String, dynamic> resp) {
    final List<Playlist> out = <Playlist>[];
    final Set<int> seen = <int>{};
    void walk(dynamic node) {
      if (node is List) {
        for (final dynamic e in node) {
          walk(e);
        }
        return;
      }
      if (node is! Map) return;
      final Map<String, dynamic> m = Map<String, dynamic>.from(node);
      final int id = _int(m['specialid'] ?? m['special_id']);
      final String name = _str(m['specialname'] ?? m['special_name']);
      if (id != 0 && name.isNotEmpty && seen.add(id)) {
        out.add(Playlist(
          id: id,
          name: name,
          coverUrl: _pic(
              m['imgurl'] ?? m['img'] ?? m['flexible_cover'] ?? m['pic'], 400),
          trackCount: _int(m['songcount'] ?? m['song_count'] ?? m['total']),
          playCount: _int(m['playcount'] ?? m['play_count'] ?? m['heat']),
          creatorName: _emptyOrNull(_str(m['nickname'] ?? m['username'])),
        ));
      }
      for (final dynamic v in m.values) {
        walk(v);
      }
    }

    walk(resp['data'] ?? resp);
    return out;
  }

  /// Kugou cover template → https, `{size}` filled.
  String? _pic(dynamic raw, int size) {
    String s = _str(raw);
    if (s.isEmpty) return null;
    s = s.replaceAll('{size}', size.toString());
    if (s.startsWith('http://')) s = s.replaceFirst('http://', 'https://');
    return s;
  }

  String? _emptyOrNull(String s) => s.isEmpty ? null : s;

  // ===== helpers ===========================================================

  bool _isAuthError(Map<String, dynamic> resp) {
    if (resp.isEmpty) return false;
    if (_int(resp['status']) != 0) return false;
    final int err = _int(resp['error_code'] ?? resp['errcode'] ?? resp['err']);
    return _authErrorCodes.contains(err);
  }

  String _qualityFor(AudioLevel level) {
    switch (level) {
      case AudioLevel.standard:
      case AudioLevel.higher:
        return '128';
      case AudioLevel.exhigh:
        return '320';
      case AudioLevel.lossless:
      case AudioLevel.hires:
        return 'flac';
    }
  }

  int _brFor(String quality) {
    switch (quality) {
      case '320':
        return 320000;
      case 'flac':
        return 999000;
      default:
        return 128000;
    }
  }

  String _normalizePhone(String phone) {
    final String digits = phone.replaceAll(RegExp(r'\D'), '');
    if (!RegExp(r'^1\d{10}$').hasMatch(digits)) {
      throw KugougnApiException('请输入 11 位中国大陆手机号');
    }
    return digits;
  }

  String _mask(String phone) =>
      '${phone.substring(0, 3)}*****${phone.substring(phone.length - 3)}';

  String _loginErrorText(Map<String, dynamic> resp, String fallback) {
    final String msg = _str(resp['error_msg'] ??
        resp['errmsg'] ??
        resp['error'] ??
        resp['data']);
    final int code = _int(resp['error_code'] ?? resp['errcode']);
    if (msg.isNotEmpty && msg != '{}') {
      return code != 0 ? '$msg ($code)' : msg;
    }
    return code != 0 ? '$fallback ($code)' : fallback;
  }

  Iterable<Map<String, dynamic>> _walkMaps(dynamic value) sync* {
    if (value is Map) {
      final Map<String, dynamic> m = Map<String, dynamic>.from(value);
      yield m;
      for (final dynamic child in m.values) {
        yield* _walkMaps(child);
      }
    } else if (value is List) {
      for (final dynamic child in value) {
        yield* _walkMaps(child);
      }
    }
  }

  /// Parses a value that is either a JSON object or a JSON-object string.
  Map<String, dynamic> _obj(dynamic value) {
    if (value is Map) return Map<String, dynamic>.from(value);
    if (value is String && value.trim().isNotEmpty) {
      try {
        final dynamic d = jsonDecode(value);
        if (d is Map) return Map<String, dynamic>.from(d);
      } catch (_) {}
    }
    return <String, dynamic>{};
  }

  String _firstOf(Map<String, dynamic> m, List<String> keys) {
    for (final String k in keys) {
      final dynamic v = m[k];
      if (v != null && v.toString().isNotEmpty) return v.toString();
    }
    return '';
  }

  String _firstNumeric(Map<String, dynamic> m, List<String> keys) {
    for (final String k in keys) {
      final dynamic v = m[k];
      if (v == null) continue;
      final String s = v.toString();
      if (s.isNotEmpty && s != '0' && int.tryParse(s) != null) return s;
    }
    return '';
  }

  String _singerOf(Map<String, dynamic> raw) {
    final dynamic singers = raw['Singers'] ?? raw['singers'] ?? raw['singerinfo'];
    if (singers is List && singers.isNotEmpty) {
      final List<String> names = <String>[];
      for (final dynamic s in singers) {
        if (s is Map) {
          final String n = _stripTags(_str(s['name'] ?? s['author_name']));
          if (n.isNotEmpty) names.add(n);
        }
      }
      if (names.isNotEmpty) return names.join('、');
    }
    return _stripTags(_firstOf(raw, const <String>[
      'SingerName',
      'Singer',
      'singername',
      'author_name',
      'singer',
    ]));
  }

  String _cover(Map<String, dynamic> raw) {
    String url = _firstOf(raw, const <String>[
      'Image',
      'sizable_cover',
      'cover',
      'pic',
      'album_sizable_cover',
      'trans_param.union_cover',
    ]);
    if (url.isEmpty) {
      final dynamic tp = raw['trans_param'];
      if (tp is Map) url = _str(tp['union_cover'] ?? tp['cover']);
    }
    if (url.isEmpty) return '';
    url = url.replaceAll('{size}', '480');
    if (url.startsWith('http://')) url = url.replaceFirst('http://', 'https://');
    return url;
  }

  /// Stable 48-bit id from the (uppercase) FileHash — matches
  /// [Song.fromKugougnJson]'s scheme so persisted local-playlist rows keep pointing
  /// at the same track across launches.
  int _stableId(String hash, String audioId) {
    if (hash.length >= 12) {
      final int? v = int.tryParse(hash.substring(0, 12), radix: 16);
      if (v != null) return v;
    }
    if (audioId.isNotEmpty) return audioId.hashCode & 0x7fffffffffff;
    return hash.hashCode & 0x7fffffffffff;
  }

  static String _stripTags(String s) =>
      s.replaceAll(RegExp(r'<[^>]*>'), '').trim();

  static String? _httpsPic(String raw) {
    if (raw.isEmpty) return null;
    return raw.startsWith('http://')
        ? raw.replaceFirst('http://', 'https://')
        : raw;
  }
}

int _int(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}

String _str(dynamic v) => v?.toString() ?? '';
