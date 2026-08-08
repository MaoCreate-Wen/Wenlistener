import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:flutter/foundation.dart';

import '../models/album.dart';
import '../models/artist.dart';
import '../models/lyric_line.dart';
import '../models/play_url.dart';
import '../models/playlist.dart';
import '../models/qq_login.dart';
import '../models/search_result.dart';
import '../models/song.dart';
import 'music_api.dart';
import 'qq_cookie_store.dart';
import 'qq_crypto.dart';

class QqApiException implements Exception {
  final String message;
  QqApiException(this.message);
  @override
  String toString() => 'QqApiException: $message';
}

/// QQ Music (QQ音乐) backend — replaces Migu as the third source (it occupies the
/// historically-named [MusicSource.migu] slot; the router field is still `migu`,
/// and [MiguApi] is kept dormant for a one-line rollback).
///
/// All API calls go through the encrypted gateway
/// `u6.y.qq.com/cgi-bin/musics.fcg?encoding=ag-1&sign=…`: the compact-JSON body is
/// signed ([QqCrypto.securitySign]) + AES-GCM encrypted ([QqCrypto.cgiEncrypt]) and
/// the binary response is decrypted ([QqCrypto.cgiDecrypt]). **QQ needs a login for
/// everything** — anonymous search returns an empty `song.list` — so [QqCookieStore]
/// (populated by [qrCreate]/[qrPoll]/[completeLogin]) gates the whole source.
class QqApi implements MusicApi {
  final Dio _dio;
  final QqCrypto _crypto;
  final QqCookieStore _cookies;

  /// Fired when [verifyLoginState] confirms the session is dead (a well-formed
  /// authed reply that rejects the login). The auth layer clears the session so
  /// the QR prompt reappears. Never fired on an ambiguous/unknown result, so a
  /// transient failure can't log the user out.
  void Function()? onSessionExpired;

  QqApi({required QqCookieStore cookies, QqCrypto crypto = const QqCrypto()})
      : _cookies = cookies,
        _crypto = crypto,
        _dio = Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 20),
          receiveTimeout: const Duration(seconds: 25),
          followRedirects: true,
          maxRedirects: 10,
          // NOTE: no global Origin/Referer here. The login GETs (check_sig / show)
          // must NOT carry a cross-origin `Origin: y.qq.com` (the reference sends
          // none on GETs) or graph's OAuth won't authenticate. The API calls set
          // their own Origin/Referer; the authorize POST sets Origin: graph.qq.com.
          headers: const <String, String>{
            'User-Agent': _ua,
            'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
          },
        ))
          ..interceptors.add(CookieManager(cookies.jar));

  static const String _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36';
  static const String _musicsUrl = 'https://u6.y.qq.com/cgi-bin/musics.fcg';

  QqCookieStore get cookies => _cookies;
  bool get isLoggedIn => _cookies.isLoggedIn;

  // --- encrypted request ----------------------------------------------------

  /// Real g_tk from the login token (API doc: 登录后取 qqmusic_key → p_skey → skey).
  /// Falls back to 5381 when not logged in.
  int _gtkNow() {
    final String token = _cookies['qm_keyst'] ??
        _cookies['qqmusic_key'] ??
        _cookies['p_skey'] ??
        _cookies['skey'] ??
        '';
    if (token.isEmpty) return 5381;
    return _gtkHash(token);
  }

  Map<String, dynamic> _comm() {
    final int gtk = _gtkNow();
    return <String, dynamic>{
      'cv': 4747474,
      'ct': 24,
      'format': 'json',
      'inCharset': 'utf-8',
      'outCharset': 'utf-8',
      'notice': 0,
      'platform': 'yqq.json',
      'needNewCode': 1,
      'uin': int.tryParse(_cookies.uin) ?? 0,
      'g_tk_new_20200303': gtk,
      'g_tk': gtk,
    };
  }

  /// Signs + AES-GCM-encrypts [payload], POSTs it to `musics.fcg`, and decrypts
  /// the binary reply into a JSON map. The sign is computed over the SAME compact
  /// string that's encrypted, so the server (which re-signs the decrypted body)
  /// always matches — no key-order canonicalisation needed.
  Future<Map<String, dynamic>> _encReq(Map<String, dynamic> payload) async {
    final String plain = jsonEncode(payload);
    final String sign = _crypto.securitySign(plain);
    final String enc = _crypto.cgiEncrypt(plain);
    final String url = '$_musicsUrl'
        '?_=${DateTime.now().millisecondsSinceEpoch}&encoding=ag-1&sign=$sign';
    final Response<dynamic> resp = await _dio.post<dynamic>(
      url,
      data: enc,
      options: Options(
        responseType: ResponseType.bytes,
        contentType: 'text/plain',
        headers: const <String, String>{
          'Accept': 'application/octet-stream',
          // MUST be identity: dio can't inflate QQ's custom binary body.
          'Accept-Encoding': 'identity',
          'Origin': 'https://y.qq.com',
          'Referer': 'https://y.qq.com/',
        },
      ),
    );
    final Uint8List bytes = resp.data is Uint8List
        ? resp.data as Uint8List
        : Uint8List.fromList((resp.data as List<dynamic>).cast<int>());
    try {
      final dynamic d = jsonDecode(_crypto.cgiDecrypt(bytes));
      return d is Map ? Map<String, dynamic>.from(d) : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  Map<String, dynamic> _req1Data(Map<String, dynamic> body) {
    final dynamic req1 = body['req_1'];
    if (req1 is! Map) return <String, dynamic>{};
    final dynamic data = req1['data'];
    return data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
  }

  // --- search ---------------------------------------------------------------

  @override
  Future<SearchResult> search({
    required String keyword,
    SearchType type = SearchType.song,
    int limit = 30,
    int offset = 0,
  }) async {
    // Map the app's SearchType to QQ's (search_type, remoteplace, body key). QQ's
    // playlist section is keyed `songlist` (not `playlist`); singer = artist.
    final (int st, String rp, String key) = switch (type) {
      SearchType.album => (2, 'txt.yqq.album', 'album'),
      SearchType.artist => (1, 'txt.yqq.singer', 'singer'),
      SearchType.playlist => (3, 'txt.yqq.playlist', 'songlist'),
      _ => (0, 'txt.yqq.song', 'song'),
    };
    final int page = (limit <= 0) ? 1 : (offset ~/ limit) + 1;
    final Map<String, dynamic> payload = <String, dynamic>{
      'comm': _comm(),
      'req_1': <String, dynamic>{
        'method': 'DoSearchForQQMusicDesktop',
        'module': 'music.search.SearchCgiService',
        'param': <String, dynamic>{
          'remoteplace': rp,
          'searchid': _searchId(),
          'search_type': st,
          'query': keyword,
          'page_num': page,
          'num_per_page': limit,
          'grp': 1,
        },
      },
    };
    try {
      final Map<String, dynamic> data = await _encReq(payload);
      final Map<String, dynamic> d = _req1Data(data);
      final dynamic bodyBlk = d['body'];
      final dynamic section = bodyBlk is Map ? bodyBlk[key] : null;
      final dynamic list = section is Map ? section['list'] : null;
      if (list is! List) return SearchResult.empty(type);
      final List<Map<String, dynamic>> rows = list
          .whereType<Map>()
          .map((dynamic e) => Map<String, dynamic>.from(e))
          .toList();
      switch (type) {
        case SearchType.album:
          final List<Album> albums = rows.map(_albumFromQqRow).toList();
          return SearchResult(
              type: type,
              albums: albums,
              total: albums.length,
              hasMore: albums.length >= limit);
        case SearchType.artist:
          final List<Artist> artists = rows.map(_artistFromQqRow).toList();
          return SearchResult(
              type: type,
              artists: artists,
              total: artists.length,
              hasMore: artists.length >= limit);
        case SearchType.playlist:
          final List<Playlist> pls = rows.map(_playlistFromQqRow).toList();
          return SearchResult(
              type: type,
              playlists: pls,
              total: pls.length,
              hasMore: pls.length >= limit);
        default:
          final List<Song> songs = rows
              .map(_songFromQqRow)
              .where((Song s) =>
                  s.name.isNotEmpty && (s.ref['songmid']?.isNotEmpty ?? false))
              .toList();
          return SearchResult(
              type: SearchType.song,
              songs: songs,
              total: songs.length,
              hasMore: songs.length >= limit);
      }
    } on DioException catch (e) {
      throw QqApiException(e.message ?? 'QQ search failed');
    }
  }

  Album _albumFromQqRow(Map<String, dynamic> row) {
    final String mid = _str(row['albumMID']);
    return Album(
      id: _int(row['albumID']),
      name: _str(row['albumName']),
      picUrl: mid.isEmpty
          ? null
          : 'https://y.gtimg.cn/music/photo_new/T002R800x800M000$mid.jpg',
    );
  }

  Artist _artistFromQqRow(Map<String, dynamic> row) {
    final String mid = _str(row['singerMID']);
    return Artist(
      id: _int(row['singerID']),
      name: _str(row['singerName']),
      picUrl: mid.isEmpty
          ? null
          : 'https://y.gtimg.cn/music/photo_new/T001R800x800M000$mid.jpg',
    );
  }

  Playlist _playlistFromQqRow(Map<String, dynamic> row) {
    final dynamic creator = row['creator'];
    return Playlist(
      id: _int(row['dissid']),
      name: _str(row['dissname']),
      coverUrl: _emptyNull(_str(row['imgurl'])),
      creatorName: creator is Map ? _emptyNull(_str(creator['name'])) : null,
      description: _emptyNull(_str(row['introduction'])),
      playCount: _int(row['listennum']),
    );
  }

  static String? _emptyNull(String s) => s.isEmpty ? null : s;

  // --- play url (vkey) ------------------------------------------------------

  @override
  Future<PlayUrl?> songUrl(Song song, {AudioLevel level = AudioLevel.exhigh}) async {
    // songmid = song's own `mid` (e.g. "0039MnYb0qxYhV") → CgiGetVkey `songmid` param.
    // mediaMid = `file.media_mid` (e.g. "003Qui1q2u1Zho") → inside `filename` param
    //   ("C400{mediaMid}.m4a"). They are DIFFERENT for VIP/multi-quality tracks.
    // Sending mediaMid in the songmid param returns result≠0 even with a VIP cookie.
    final String songmid = song.ref['songmid'] ?? '';
    final String mediaMid = (song.ref['mediaMid']?.isNotEmpty ?? false)
        ? song.ref['mediaMid']!
        : songmid; // graceful fallback when file.media_mid was absent in JSON
    if (mediaMid.isEmpty) return null;
    final List<List<String>> tries = switch (level) {
      AudioLevel.standard => const <List<String>>[
          <String>['C400', 'm4a'],
        ],
      AudioLevel.higher || AudioLevel.exhigh => const <List<String>>[
          <String>['M800', 'mp3'],
          <String>['C400', 'm4a'],
        ],
      AudioLevel.lossless || AudioLevel.hires => const <List<String>>[
          <String>['F000', 'flac'],
          <String>['M800', 'mp3'],
          <String>['C400', 'm4a'],
        ],
    };
    for (final List<String> q in tries) {
      final String prefix = q[0];
      final String ext = q[1];
      final String? url = await _resolveVkey(
        songmid.isEmpty ? mediaMid : songmid, // songmid for the vkey param
        mediaMid,                             // mediaMid for the filename
        '$prefix$mediaMid.$ext',
      );
      if (url != null) {
        return PlayUrl(
          id: song.id,
          url: url,
          br: prefix == 'F000' ? 900000 : (prefix == 'M800' ? 320000 : 128000),
          type: ext,
          size: 0,
          level: level,
        );
      }
    }
    return null;
  }

  /// Requests vkey for a single quality. Returns playable url or null when
  /// `result != 0` (paid/no-copyright) or no `purl` granted.
  ///
  /// [songmid] = song's own `mid` (e.g. "0039MnYb0qxYhV") → CgiGetVkey `songmid`.
  /// [mediaMid] = `file.media_mid` (e.g. "003Qui1q2u1Zho") → embedded in [filename].
  /// Passing mediaMid as songmid yields result≠0 even with VIP cookie.
  Future<String?> _resolveVkey(
      String songmid, String mediaMid, String filename) async {
    final Map<String, dynamic> payload = <String, dynamic>{
      'comm': _comm(),
      'req_1': <String, dynamic>{
        'module': 'vkey.GetVkeyServer',
        'method': 'CgiGetVkey',
        'param': <String, dynamic>{
          'guid': _cookies.guid,
          'songmid': <String>[songmid],
          'filename': <String>[filename],
          'songtype': <int>[0],
          'uin': _cookies.uin,
          'loginflag': _cookies.uin == '0' ? 0 : 1,
          'platform': '20',
        },
      },
    };
    try {
      final Map<String, dynamic> data = await _encReq(payload);
      final Map<String, dynamic> d = _req1Data(data);
      final dynamic infos = d['midurlinfo'];
      final dynamic sip = d['sip'];
      if (infos is! List || infos.isEmpty || sip is! List || sip.isEmpty) {
        return null;
      }
      final Map<String, dynamic> info =
          Map<String, dynamic>.from(infos.first as Map);
      if (_int(info['result']) != 0) return null;
      final String purl = _str(info['purl']);
      if (purl.isEmpty) return null;
      final String host = _str(sip.first);
      return host.endsWith('/') || purl.startsWith('/')
          ? '$host$purl'
          : '$host/$purl';
    } on DioException {
      return null;
    }
  }

  // --- lyric ----------------------------------------------------------------

  @override
  Future<Lyrics> lyric(Song song) async {
    final String songmid = song.ref['songmid'] ?? '';
    if (songmid.isEmpty) return Lyrics.empty;
    // `PlayLyricInfo/GetPlayLyricInfo` (songMID + songID) — verified to return the
    // base64 LRC (`lyric`) + translation (`trans`). The old `LyricService`
    // `GetLyricByMid` returned nothing here.
    final Map<String, dynamic> payload = <String, dynamic>{
      'comm': _comm(),
      'req_1': <String, dynamic>{
        'module': 'music.musichallSong.PlayLyricInfo',
        'method': 'GetPlayLyricInfo',
        'param': <String, dynamic>{'songMID': songmid, 'songID': song.id},
      },
    };
    try {
      final Map<String, dynamic> data = await _encReq(payload);
      final Map<String, dynamic> d = _req1Data(data);
      final String lrc = _decodeMaybeB64(_str(d['lyric']));
      if (lrc.trim().isEmpty) return Lyrics.empty;
      final String trans = _decodeMaybeB64(_str(d['trans']));
      return Lyrics.parse(lrc: lrc, tlyric: trans.isEmpty ? null : trans);
    } on DioException {
      // Transient transport failure → surface so PlayerProvider can retry
      // (matches Kugou/Migu). Genuinely-absent lyric is the empty return above.
      rethrow;
    }
  }

  /// QQ returns the lyric base64-encoded; some paths return it already-plain.
  static String _decodeMaybeB64(String s) {
    if (s.isEmpty) return '';
    if (s.contains('[') && s.contains(']')) return s; // already LRC text
    try {
      return utf8.decode(base64.decode(s), allowMalformed: true);
    } catch (_) {
      return s;
    }
  }

  // --- scan login (QQMUSIC_API.md#登录认证) ---------------------------------

  static const String _clientId = '100497308';
  static const String _ptAppid = '716027609';
  static const String _daid = '383';
  static const String _sUrl = 'https://graph.qq.com/oauth2.0/login_jump';
  // QQ Music OAuth redirect_uri (login_type=1) + scope — the exact strings the web
  // client sends; the `surl` value is already %-encoded and gets encoded again in
  // the query (matching qq_qr_login.py's urlencode). Do not "clean up" the encoding.
  static const String _qqRedirectUri =
      'https://y.qq.com/portal/wx_redirect.html?login_type=1&surl=https%3A%2F%2Fy.qq.com%2F';
  static const String _qqScope = 'get_user_info,get_app_friends';
  static const String _wxAppid = 'wx48db31d50e334801';
  static const String _wxRedirect =
      'https://y.qq.com/portal/wx_redirect.html?login_type=2&surl=https://y.qq.com/';
  static const String _wxState = 'STATE';

  /// Creates a scan-login session. QQ: xlogin → ptqrshow (PNG + qrsig). WeChat:
  /// qrconnect (uuid) → qrcode (PNG). The [QqQrSession.pollKey] is qrsig / uuid.
  Future<QqQrSession> qrCreate(QqLoginMethod method) async {
    // Start each login from a CLEAN jar. The reference script uses a fresh
    // CookieJar per run; our PersistCookieJar accumulates cookies across attempts,
    // and a stale p_skey / partial session makes graph's `authorize` bounce to the
    // login page ("登录未完成") instead of granting a `code`. Verified: Python with a
    // fresh scan succeeds where the persistent-jar app bounced.
    await _cookies.clear();
    return method == QqLoginMethod.qq ? _qqQrCreate() : _wxQrCreate();
  }

  Future<QqQrSession> _qqQrCreate() async {
    // 1) xlogin — seeds the ptlogin session cookies.
    final String xlogin = _xloginUrl();
    await _dio.get<dynamic>(xlogin,
        options: Options(responseType: ResponseType.bytes));
    // 2) ptqrshow — the QR PNG + a `qrsig` Set-Cookie.
    final String show = 'https://ssl.ptlogin2.qq.com/ptqrshow'
        '?appid=$_ptAppid&e=0&s=8&type=0&u1=${Uri.encodeComponent(_sUrl)}'
        '&daid=$_daid&pt_3rd_aid=$_clientId&t=${DateTime.now().millisecondsSinceEpoch}';
    final Response<dynamic> resp = await _dio.get<dynamic>(
      show,
      options: Options(responseType: ResponseType.bytes, headers: <String, String>{
        'Referer': xlogin,
      }),
    );
    final String qrsig = _cookieFromResponse(resp, 'qrsig');
    if (qrsig.isEmpty) throw QqApiException('ptqrshow 未返回 qrsig');
    return QqQrSession(
      image: Uint8List.fromList((resp.data as List<dynamic>).cast<int>()),
      pollKey: qrsig,
    );
  }

  Future<QqQrSession> _wxQrCreate() async {
    final String connect = 'https://open.weixin.qq.com/connect/qrconnect'
        '?appid=$_wxAppid&redirect_uri=${Uri.encodeComponent(_wxRedirect)}'
        '&response_type=code&scope=snsapi_login&state=$_wxState'
        '&href=${Uri.encodeComponent('https://y.qq.com/mediastyle/music_v17/src/css/popup_wechat.css#wechat_redirect')}'
        '#wechat_redirect';
    final Response<dynamic> page = await _dio.get<dynamic>(
      connect,
      options: Options(responseType: ResponseType.plain),
    );
    final String html = _str(page.data);
    final RegExpMatch? m = RegExp(r'/connect/qrcode/([A-Za-z0-9_-]+)').firstMatch(html) ??
        RegExp(r'uuid=([A-Za-z0-9_-]+)').firstMatch(html);
    final String uuid = m?.group(1) ?? '';
    if (uuid.isEmpty) throw QqApiException('微信二维码 uuid 解析失败');
    final Response<dynamic> img = await _dio.get<dynamic>(
      'https://open.weixin.qq.com/connect/qrcode/$uuid',
      options: Options(responseType: ResponseType.bytes),
    );
    return QqQrSession(
      image: Uint8List.fromList((img.data as List<dynamic>).cast<int>()),
      pollKey: uuid,
    );
  }

  /// Polls a scan session. On confirmation the [QqQrPoll.payload] carries the QQ
  /// `redirect_url` / the WeChat `code` for [completeLogin].
  Future<QqQrPoll> qrPoll(QqLoginMethod method, String pollKey) async {
    return method == QqLoginMethod.qq ? _qqPoll(pollKey) : _wxPoll(pollKey);
  }

  Future<QqQrPoll> _qqPoll(String qrsig) async {
    final int token = _hash33(qrsig);
    final int ms = DateTime.now().millisecondsSinceEpoch;
    final String url = 'https://ssl.ptlogin2.qq.com/ptqrlogin'
        '?u1=${Uri.encodeComponent(_sUrl)}&ptqrtoken=$token&ptredirect=0&h=1'
        '&t=$ms&g=1&from_ui=1&ptlang=2052&action=0-0-$ms&js_ver=25000000'
        '&js_type=1&login_sig=&pt_uistyle=40&aid=$_ptAppid&daid=$_daid'
        '&pt_3rd_aid=$_clientId&';
    final Response<dynamic> resp = await _dio.get<dynamic>(
      url,
      options: Options(responseType: ResponseType.plain, headers: <String, String>{
        'Referer': _xloginUrl(),
      }),
    );
    final String body = _str(resp.data);
    final RegExpMatch? m =
        RegExp(r"ptuiCB\('([^']*)','([^']*)','([^']*)'").firstMatch(body);
    final String code = m?.group(1) ?? '';
    final String redirect = m?.group(3) ?? '';
    switch (code) {
      case '0':
        return QqQrPoll(status: QqQrStatus.confirmed, payload: redirect);
      case '66':
        return const QqQrPoll(status: QqQrStatus.waiting);
      case '67':
        return const QqQrPoll(status: QqQrStatus.scanned);
      case '65':
        return const QqQrPoll(status: QqQrStatus.expired);
      case '68':
        return const QqQrPoll(status: QqQrStatus.canceled);
      default:
        return const QqQrPoll(status: QqQrStatus.unknown);
    }
  }

  Future<QqQrPoll> _wxPoll(String uuid) async {
    final String url = 'https://long.open.weixin.qq.com/connect/l/qrconnect'
        '?uuid=$uuid&_=${DateTime.now().millisecondsSinceEpoch}';
    final Response<dynamic> resp = await _dio.get<dynamic>(
      url,
      options: Options(responseType: ResponseType.plain),
    );
    final String body = _str(resp.data);
    final String errcode =
        RegExp(r'wx_errcode=(\d+)').firstMatch(body)?.group(1) ?? '';
    final String wxCode =
        RegExp(r"wx_code='([^']*)'").firstMatch(body)?.group(1) ?? '';
    switch (errcode) {
      case '405':
        return QqQrPoll(status: QqQrStatus.confirmed, payload: wxCode);
      case '404':
        return const QqQrPoll(status: QqQrStatus.waiting);
      case '408':
        return const QqQrPoll(status: QqQrStatus.scanned);
      case '403':
        return const QqQrPoll(status: QqQrStatus.canceled);
      case '402':
        return const QqQrPoll(status: QqQrStatus.expired);
      default:
        return const QqQrPoll(status: QqQrStatus.unknown);
    }
  }

  /// Finishes the login by running the FULL OAuth handoff that mints the
  /// `qm_keyst` music session — the step a plain redirect-follow can't do (the
  /// web client does it in JS). Faithfully ports qq_qr_login.py
  /// `finalize_qqmusic_login`. Returns whether a session cookie was obtained.
  Future<bool> completeLogin(QqLoginMethod method, String payload) async {
    try {
      if (method == QqLoginMethod.qq) {
        return await _completeQqLogin(payload);
      }
      return await _completeWxLogin(payload);
    } catch (_) {
      await _cookies.reload();
      return _cookies.isLoggedIn;
    }
  }

  /// QQ handoff: check_sig redirect (→ graph `p_skey`) → graph `oauth2.0/show` →
  /// POST graph `oauth2.0/authorize` (→ callback with `code`) → POST plain
  /// `u.y.qq.com/cgi-bin/musicu.fcg` `QQConnectLogin.LoginServer/QQLogin{code}`
  /// whose response body carries `musickey` → written out as `qm_keyst`.
  Future<bool> _completeQqLogin(String redirectUrl) async {
    // 1) Walk the check_sig redirect chain so graph.qq.com's p_skey/p_uin land
    //    (they're set on an intermediate 302 — see [_followChain]).
    await _followChain(redirectUrl, referer: _xloginUrl());
    // 2) GET the QQ Music OAuth show page (referer y.qq.com).
    final String showUrl = _qqShowUrl();
    await _followChain(showUrl, referer: 'https://y.qq.com/');
    // 3) POST graph authorize — the 302 Location is the callback with ?code=.
    final Map<String, String> graph =
        await _cookies.loadFor(Uri.parse('https://graph.qq.com/'));
    final String pSkey = graph['p_skey'] ?? '';
    // Build a DEDUPED Cookie header and POST authorize with a BARE dio (no
    // CookieManager). dio's CookieManager otherwise emits p_skey / p_uin /
    // pt4_token TWICE (stored under both `.qq.com` and `graph.qq.com`); graph then
    // can't bind g_tk to a single p_skey and bounces authorize to the login page
    // ("登录未完成"). One value per name — the very p_skey g_tk is derived from — wins.
    final String cookieHeader = graph.entries
        .map((MapEntry<String, String> e) => '${e.key}=${e.value}')
        .join('; ');
    final String body = _formEncode(<String, String>{
      'response_type': 'code',
      'client_id': _clientId,
      'redirect_uri': _qqRedirectUri,
      'scope': _qqScope,
      'state': 'state',
      'switch': '',
      'from_ptlogin': '1',
      'src': '1',
      'update_auth': '1',
      'openapi': '1010_1030',
      'g_tk': _gtkHash(pSkey).toString(),
      'auth_time': DateTime.now().millisecondsSinceEpoch.toString(),
      'ui': graph['ui'] ?? '',
    });
    final Dio bare = _bareDio();
    final Response<dynamic> authResp = await bare.post<dynamic>(
      'https://graph.qq.com/oauth2.0/authorize',
      data: body,
      options: Options(
        contentType: 'application/x-www-form-urlencoded',
        followRedirects: false,
        responseType: ResponseType.plain,
        headers: <String, String>{
          'Origin': 'https://graph.qq.com',
          'Referer': showUrl,
          'Cookie': cookieHeader,
        },
        validateStatus: (int? s) => s != null && s < 400,
      ),
    );
    bare.close();
    String callback = authResp.headers.value('location') ?? '';
    if (callback.isEmpty) callback = authResp.realUri.toString();
    String code = Uri.tryParse(callback)?.queryParameters['code'] ?? '';
    // The authorize 302 may point at an intermediate (e.g. login_jump) rather than
    // the callback directly — follow the rest of the chain until the code appears.
    if (code.isEmpty && callback.startsWith('http')) {
      final String finalUrl = await _followChain(callback, referer: showUrl);
      code = Uri.tryParse(finalUrl)?.queryParameters['code'] ?? '';
      if (code.isNotEmpty) callback = finalUrl;
    }
    if (code.isNotEmpty) {
      await _exchangeCode('QQLogin', <String, dynamic>{'code': code},
          referer: callback);
    }
    await _cookies.reload();
    debugPrint('QQ completeLogin(QQ): isLoggedIn=${_cookies.isLoggedIn}');
    return _cookies.isLoggedIn;
  }

  /// WeChat handoff (best-effort — mirrors the QQ exchange with `WXLogin`; the QQ
  /// path is the verified one). Follows the wx callback, then exchanges the code.
  Future<bool> _completeWxLogin(String wxCode) async {
    final String cb = '$_wxRedirect&code=$wxCode&state=$_wxState';
    await _followChain(cb, referer: 'https://y.qq.com/');
    await _exchangeCode(
      'WXLogin',
      <String, dynamic>{'code': wxCode, 'strAppid': _wxAppid},
      referer: cb,
    );
    await _cookies.reload();
    return _cookies.isLoggedIn;
  }

  /// POSTs the plain (unencrypted) `QQConnectLogin.LoginServer/<method>` exchange
  /// to `musicu.fcg` and writes the `musickey`/`musicid` it returns into the jar.
  Future<void> _exchangeCode(
    String method,
    Map<String, dynamic> param, {
    required String referer,
  }) async {
    // Same dedup concern as authorize: send ONE cookie per name via a bare dio.
    final Map<String, String> ck = await _cookies
        .loadFor(Uri.parse('https://u.y.qq.com/cgi-bin/musicu.fcg'));
    final String token = ck['qqmusic_key'] ??
        ck['p_skey'] ??
        ck['skey'] ??
        ck['p_lskey'] ??
        ck['lskey'] ??
        '';
    final String cookieHeader = ck.entries
        .map((MapEntry<String, String> e) => '${e.key}=${e.value}')
        .join('; ');
    final Map<String, dynamic> payload = <String, dynamic>{
      'comm': <String, dynamic>{
        'g_tk': _gtkHash(token),
        'platform': 'yqq',
        'ct': 24,
        'cv': 0,
      },
      'req': <String, dynamic>{
        'module': 'QQConnectLogin.LoginServer',
        'method': method,
        'param': param,
      },
    };
    final Dio bare = _bareDio();
    final Response<dynamic> resp = await bare.post<dynamic>(
      'https://u.y.qq.com/cgi-bin/musicu.fcg',
      data: jsonEncode(payload),
      options: Options(
        contentType: 'application/x-www-form-urlencoded',
        responseType: ResponseType.plain,
        headers: <String, String>{
          'Origin': 'https://y.qq.com',
          'Referer': referer,
          'Cookie': cookieHeader,
        },
        validateStatus: (int? s) => s != null && s < 500,
      ),
    );
    bare.close();
    try {
      final dynamic decoded = jsonDecode(_str(resp.data));
      final dynamic req = decoded is Map ? decoded['req'] : null;
      final dynamic data = req is Map ? req['data'] : null;
      if (data is Map) {
        await _cookies.saveLoginCookies(Map<String, dynamic>.from(data));
      }
    } catch (e) {
      // Non-JSON / empty reply → no session; caller reports isLoggedIn=false.
      debugPrint('QQ login: exchange parse failed: $e');
    }
  }

  /// A bare dio with NO CookieManager — used for the OAuth `authorize` / exchange
  /// POSTs where we set a hand-built, DEDUPED `Cookie` header ourselves (the shared
  /// `_dio`'s CookieManager would emit duplicate p_skey/p_uin and break the grant).
  Dio _bareDio() => Dio(BaseOptions(
        followRedirects: false,
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 25),
        headers: <String, String>{
          'User-Agent': _ua,
          'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
        },
      ));

  /// Manually walks a redirect chain (up to [maxHops]), issuing each hop as its
  /// OWN dio request so the [CookieManager] interceptor persists EVERY response's
  /// `Set-Cookie`. This is essential: dio's auto-follow (`followRedirects:true`)
  /// runs the interceptor only on the FINAL response, silently dropping cookies
  /// set by intermediate 302s — e.g. graph's `p_skey`, which `check_sig` sets on
  /// the hop that then redirects to `login_jump` (QQMUSIC_API.md step 6). Without
  /// p_skey the authorize `g_tk` is wrong → no `code` → "登录未完成". Returns the
  /// final URL. (urllib's HTTPCookieProcessor captures every hop, which is why the
  /// reference script works and the naive dio port didn't.)
  Future<String> _followChain(String url, {String? referer, int maxHops = 10}) async {
    String current = url;
    String? ref = referer;
    for (int i = 0; i < maxHops; i++) {
      try {
        final Response<dynamic> resp = await _dio.get<dynamic>(
          current,
          options: Options(
            followRedirects: false,
            responseType: ResponseType.bytes,
            headers: ref != null ? <String, String>{'Referer': ref} : null,
            validateStatus: (int? s) => s != null && s < 400,
          ),
        );
        final int status = resp.statusCode ?? 0;
        final String? loc = resp.headers.value('location');
        if (status >= 300 && status < 400 && loc != null && loc.isNotEmpty) {
          ref = current;
          current = loc.startsWith('http')
              ? loc
              : Uri.parse(current).resolve(loc).toString();
          continue;
        }
        break;
      } catch (_) {
        break; // a hop may 4xx/5xx; cookies set so far already stuck
      }
    }
    return current;
  }

  String _qqShowUrl() =>
      'https://graph.qq.com/oauth2.0/show?${_formEncode(<String, String>{
        'which': 'Login',
        'display': 'pc',
        'response_type': 'code',
        'client_id': _clientId,
        'redirect_uri': _qqRedirectUri,
        'state': 'state',
        'scope': _qqScope,
      })}';

  static String _formEncode(Map<String, String> m) => m.entries
      .map((MapEntry<String, String> e) =>
          '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
      .join('&');

  /// QQ's `g_tk` hash (base 5381) over a session key — distinct from [_hash33]
  /// (base 0, used for `ptqrtoken`). Kept in 32-bit lanes to match the reference.
  static int _gtkHash(String s) {
    int h = 5381;
    for (final int c in s.codeUnits) {
      h = (h + ((h << 5) & 0xFFFFFFFF) + c) & 0xFFFFFFFF;
    }
    return h & 0x7fffffff;
  }

  /// Best-effort signed-in profile from the cookies: uin, the nickname decoded
  /// from `ptnick_<uin>`, and the public QQ avatar derived from a numeric uin.
  /// Null when not logged in.
  Future<QqAccount?> accountProfile() async {
    await _cookies.reload();
    if (!_cookies.isLoggedIn) return null;
    return QqAccount(
      uin: _cookies.uin,
      nickname: _cookies.nickname ?? '',
      avatarUrl: _cookies.avatarUrl,
    );
  }

  /// Server-side login-state check via the doc's designated verifier
  /// (`music.paycenterapi.LoginStateVerificationApi/GetChargeAccount`, 登录态校验).
  /// Returns:
  ///  • `true`  — session valid (well-formed authed reply accepted);
  ///  • `false` — session DEFINITIVELY expired (well-formed reply that rejects
  ///              the login: top-level `code` present & non-zero, or `req_1.code`
  ///              non-zero) → fires [onSessionExpired];
  ///  • `null`  — unknown (not logged in locally, empty/undecodable reply, or
  ///              transport error) → caller keeps the current session.
  ///
  /// QQ exposes no clean per-call expiry signal (an empty search / vkey 104003
  /// are indistinguishable from "no results" / VIP-locked), so this dedicated
  /// probe is the only reliable detector. It is deliberately conservative: only
  /// a well-formed rejection logs out; anything ambiguous is treated as transient.
  Future<bool?> verifyLoginState() async {
    await _cookies.reload();
    if (!_cookies.isLoggedIn) return null;
    Map<String, dynamic> body;
    try {
      body = await _encReq(<String, dynamic>{
        'comm': _comm(),
        'req_1': <String, dynamic>{
          'module': 'music.paycenterapi.LoginStateVerificationApi',
          'method': 'GetChargeAccount',
          'param': <String, dynamic>{'appid': 'mlive'},
        },
      });
    } catch (_) {
      return null; // transport/decrypt failure → unknown, keep session
    }
    if (body.isEmpty) return null;
    final int? top = (body['code'] as num?)?.toInt();
    final dynamic req1 = body['req_1'];
    final int? reqCode =
        req1 is Map ? (req1['code'] as num?)?.toInt() : null;
    // A well-formed reply carries at least one code. Reject only when a code is
    // present AND non-zero (login refused); code 1000 = "module not implemented"
    // is NOT an auth failure, so keep the session on that.
    final bool rejected = (top != null && top != 0 && top != 1000) ||
        (reqCode != null && reqCode != 0);
    if (rejected) {
      onSessionExpired?.call();
      return false;
    }
    if ((top == 0) || (reqCode == 0)) return true;
    return null; // no usable code → unknown
  }

  Future<void> logout() => _cookies.clear();

  String _xloginUrl() => 'https://xui.ptlogin2.qq.com/cgi-bin/xlogin'
      '?appid=$_ptAppid&daid=$_daid&style=33&login_text=${Uri.encodeComponent('登录')}'
      '&hide_title_bar=1&hide_border=1&target=self'
      '&s_url=${Uri.encodeComponent(_sUrl)}&pt_3rd_aid=$_clientId'
      '&theme=2&verify_theme=';

  /// QQ's `hash33` (`qrsig` → `ptqrtoken`). Kept in 32-bit lanes so it matches the
  /// reference's arbitrary-precision-then-mask result on the low 31 bits.
  static int _hash33(String s) {
    int h = 0;
    for (final int c in s.codeUnits) {
      h = (h + ((h << 5) & 0xFFFFFFFF) + c) & 0xFFFFFFFF;
    }
    return h & 0x7fffffff;
  }

  /// Reads a `Set-Cookie` value by name from a dio response (used for `qrsig`,
  /// which is set for a different domain than the API cookie cache tracks).
  static String _cookieFromResponse(Response<dynamic> resp, String name) {
    final List<String>? setCookies = resp.headers['set-cookie'];
    if (setCookies == null) return '';
    for (final String raw in setCookies) {
      final String head = raw.split(';').first.trim();
      final int eq = head.indexOf('=');
      if (eq > 0 && head.substring(0, eq) == name) {
        return head.substring(eq + 1);
      }
    }
    return '';
  }

  // --- discovery / playlist (QQ guest UI: not wired) ------------------------

  @override
  Future<List<Playlist>> personalizedPlaylists({int limit = 12}) async {
    final Map<String, dynamic> payload = <String, dynamic>{
      'comm': _comm(),
      'req_1': <String, dynamic>{
        'module': 'music.playlist.PlaylistSquare',
        'method': 'GetRecommendFeed',
        'param': <String, dynamic>{'From': 0, 'Size': limit},
      },
    };
    try {
      final Map<String, dynamic> data = await _encReq(payload);
      final Map<String, dynamic> d = _req1Data(data);
      final dynamic list = d['List'];
      if (list is! List) return const <Playlist>[];
      return list
          .whereType<Map>()
          .map((dynamic e) {
            final dynamic pl = e['Playlist'];
            final dynamic basic = pl is Map ? pl['basic'] : null;
            if (basic is! Map) return null;
            final Map<String, dynamic> b = Map<String, dynamic>.from(basic);
            final dynamic cover = b['cover'];
            final String coverUrl = cover is Map
                ? _str(cover['medium_url'] ??
                    cover['big_url'] ??
                    cover['small_url'])
                : '';
            final dynamic creator = b['creator'];
            return Playlist(
              id: _int(b['tid']),
              name: _str(b['title']),
              coverUrl: _emptyNull(coverUrl),
              creatorName:
                  creator is Map ? _emptyNull(_str(creator['nick'])) : null,
              trackCount: _int(b['song_cnt']),
              playCount: _int(b['play_cnt']),
            );
          })
          .whereType<Playlist>()
          .where((Playlist p) => p.id != 0 && p.name.isNotEmpty)
          .toList();
    } on DioException {
      return const <Playlist>[];
    }
  }

  @override
  Future<List<Song>> recommendedSongs({int limit = 8}) async {
    if (!_cookies.isLoggedIn) return const <Song>[];
    try {
      final SearchResult r =
          await search(keyword: '热门', type: SearchType.song, limit: limit);
      return r.songs.take(limit).toList();
    } catch (_) {
      return const <Song>[];
    }
  }

  /// QQ playlist (歌单) detail by `disstid` (`music.srfDissInfo.aiDissInfo`). Pulls
  /// up to 300 tracks in one call. Reachable via the router's per-source dispatch
  /// (`playlistDetailFrom`) so a local "共同歌单" forked from a QQ list can re-sync.
  @override
  Future<Playlist> albumDetail(int id) async =>
      Playlist(id: id, name: '专辑', tracks: const <Song>[]);

  @override
  Future<Playlist> playlistDetail(int id) async {
    final Map<String, dynamic> payload = <String, dynamic>{
      'comm': _comm(),
      'req_1': <String, dynamic>{
        'module': 'music.srfDissInfo.aiDissInfo',
        'method': 'uniform_get_Dissinfo',
        'param': <String, dynamic>{
          'disstid': id,
          'song_begin': 0,
          'song_num': 300,
          'ctx': 1,
        },
      },
    };
    try {
      final Map<String, dynamic> data = await _encReq(payload);
      final Map<String, dynamic> d = _req1Data(data);
      final dynamic dir = d['dirinfo'];
      final Map<String, dynamic> dirinfo =
          dir is Map ? Map<String, dynamic>.from(dir) : <String, dynamic>{};
      final dynamic songlist = d['songlist'];
      final List<Song> tracks = songlist is List
          ? songlist
              .whereType<Map>()
              .map((dynamic e) => _songFromQqRow(Map<String, dynamic>.from(e)))
              .where((Song s) => s.name.isNotEmpty)
              .toList()
          : <Song>[];
      final dynamic creator = dirinfo['creator'];
      final String cover = _str(dirinfo['picurl']);
      final String desc = _str(dirinfo['desc']);
      return Playlist(
        id: id,
        name: _str(dirinfo['title']),
        coverUrl: cover.isEmpty ? null : cover,
        creatorName: creator is Map ? _str(creator['nick']) : null,
        description: desc.isEmpty ? null : desc,
        trackCount: _int(dirinfo['songnum']) > 0
            ? _int(dirinfo['songnum'])
            : tracks.length,
        playCount: _int(dirinfo['visitnum']),
        tracks: tracks,
      );
    } on DioException catch (e) {
      throw QqApiException(e.message ?? 'QQ playlist detail failed');
    }
  }

  /// The signed-in user's created playlists via `c6.y.qq.com/fcg_user_created_diss`
  /// (a plain JSONP-ish GET, not the encrypted gateway). Skips the tid=0 default
  /// entry (not openable via aiDissInfo). Empty when logged out.
  @override
  Future<List<Playlist>> userPlaylists({int limit = 30, int offset = 0}) async {
    await _cookies.reload();
    if (!_cookies.isLoggedIn) return const <Playlist>[];
    final String uin = _cookies.uin;
    if (uin == '0') return const <Playlist>[];
    final int gtk =
        _gtkHash(_cookies['qm_keyst'] ?? _cookies['qqmusic_key'] ?? '');
    final String url = 'https://c6.y.qq.com/rsc/fcgi-bin/fcg_user_created_diss'
        '?hostuin=$uin&sin=$offset&size=$limit&g_tk=$gtk&format=json'
        '&inCharset=utf8&outCharset=utf-8&platform=yqq.json&needNewCode=0';
    try {
      final Response<dynamic> resp = await _dio.get<dynamic>(
        url,
        options: Options(
          responseType: ResponseType.plain,
          headers: <String, String>{
            'Origin': 'https://y.qq.com',
            'Referer': 'https://y.qq.com/',
          },
        ),
      );
      final dynamic decoded = jsonDecode(_str(resp.data));
      final dynamic dl =
          decoded is Map && decoded['data'] is Map ? decoded['data']['disslist'] : null;
      if (dl is! List) return const <Playlist>[];
      return dl
          .whereType<Map>()
          .map((dynamic e) {
            final Map<String, dynamic> m = Map<String, dynamic>.from(e);
            return Playlist(
              id: _int(m['tid']),
              name: _str(m['diss_name']),
              coverUrl: _emptyNull(_str(m['diss_cover'])),
              trackCount: _int(m['song_cnt']),
              playCount: _int(m['listen_num']),
            );
          })
          .where((Playlist p) => p.id != 0 && p.name.isNotEmpty)
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

  @override
  Future<int> createPlaylist(String name, {int privacy = 0}) =>
      throw QqApiException('QQ has no playlist management');

  @override
  Future<void> deletePlaylist(int pid) =>
      throw QqApiException('QQ has no playlist management');

  @override
  Future<void> addTracksToPlaylist(int pid, List<int> ids) =>
      throw QqApiException('QQ has no playlist management');

  @override
  Future<void> removeTracksFromPlaylist(int pid, List<int> ids) =>
      throw QqApiException('QQ has no playlist management');

  @override
  Future<void> collectPlaylist(int id, bool collect) =>
      throw QqApiException('QQ has no playlist management');

  // --- parsing --------------------------------------------------------------

  String _searchId() =>
      (DateTime.now().microsecondsSinceEpoch % 100000000000000000).toString();

  /// Builds a [Song] from a QQ search / playlist row. `id` = numeric songid (else
  /// a hash), `songmid` (canonical id) + `mediaMid` (vkey/file) + `albumMid`
  /// (cover) live in [ref]. Keeps [MusicSource.migu] (the reused source slot).
  Song _songFromQqRow(Map<String, dynamic> row) {
    final String songmid = _str(row['mid']);
    final int songid = _int(row['id']);
    final int id =
        songid != 0 ? songid : (songmid.isEmpty ? row.hashCode : songmid.hashCode);

    final List<Artist> artists =
        ((row['singer'] as List<dynamic>?) ?? const <dynamic>[])
            .whereType<Map>()
            .map((dynamic s) => Artist(
                  id: _int((s as Map)['id']),
                  name: _str(s['name'] ?? s['title']),
                ))
            .where((Artist a) => a.name.isNotEmpty)
            .toList();

    String albumMid = '';
    String albumName = '';
    int albumId = 0;
    final dynamic al = row['album'];
    if (al is Map) {
      albumMid = _str(al['mid']);
      albumName = _str(al['name'] ?? al['title']);
      albumId = _int(al['id']);
    } else {
      albumMid = _str(row['albummid']);
      albumName = _str(row['albumname']);
      albumId = _int(row['albumid']);
    }
    final String cover = albumMid.isEmpty
        ? ''
        : 'https://y.gtimg.cn/music/photo_new/T002R800x800M000$albumMid.jpg';
    final Album? album = (albumName.isNotEmpty || cover.isNotEmpty)
        ? Album(id: albumId, name: albumName, picUrl: cover.isEmpty ? null : cover)
        : null;

    final String mediaMid = _str((row['file'] is Map)
        ? (row['file'] as Map)['media_mid']
        : row['media_mid']);

    return Song(
      id: id,
      name: _str(row['name'] ?? row['title'] ?? row['songname']),
      artists: artists,
      album: album,
      duration: Duration(seconds: _int(row['interval'])),
      fee: 0,
      playable: true,
      source: MusicSource.migu,
      ref: <String, String>{
        'songmid': songmid,
        'mediaMid': mediaMid.isEmpty ? songmid : mediaMid,
        'albumMid': albumMid,
        if (cover.isNotEmpty) 'cover': cover,
      },
    );
  }
}

int _int(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}

String _str(dynamic v) => v?.toString() ?? '';
