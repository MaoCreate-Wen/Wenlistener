import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:flutter/foundation.dart';

import '../models/album.dart';
import '../models/artist.dart';
import '../models/lyric_line.dart';
import '../models/play_url.dart';
import '../models/playlist.dart';
import '../models/qqcn_login.dart';
import '../models/search_result.dart';
import '../models/song.dart';
import 'music_api.dart';
import 'qqcn_cookie_store.dart';
import 'qqcn_crypto.dart';
import 'qqcn_lyric_crypto.dart';

class QqcnApiException implements Exception {
  final String message;
  QqcnApiException(this.message);
  @override
  String toString() => 'QqcnApiException: $message';
}

/// QQ Music（QQ音乐 安卓客户端）backend — an INDEPENDENT source on its own
/// [MusicSource.qqcn] enum value + router slot + `.qqcn_cookies` jar, wholly
/// separate from the web-QQ ([QqApi]) that occupies the `migu` slot.
///
/// This is the **Android pure-algorithm** implementation (ported from
/// `spider/QQmusic_Android`): every data call goes through the Android gateway
/// `u6.y.qq.com/cgi-bin/musics.fcg` — the compact-JSON body is signed
/// ([QqcnCrypto.signBody]) + masked ([QqcnCrypto.maskFor]), zlib-compressed with a
/// 5-byte random prefix, and the response is zlib/gzip-inflated back to JSON. Login
/// is the QQ **ptlogin** QR → graph.qq.com OAuth `code` → `musicu.fcg`
/// `QQConnectLogin.QQLogin` → `music.getSession.GetSession`, producing the Android
/// session (`uid`/`sid`/`authst`) persisted by [QqcnCookieStore]. Search / lyric work
/// anonymously; play (vkey) needs the session.
class QqcnApi implements MusicApi {
  final Dio _dio;
  final QqcnCrypto _crypto;
  final QqcnCookieStore _cookies;

  /// Fired when [verifyLoginState] confirms the session is dead (a well-formed
  /// reply that rejects the login). The auth layer clears the session so the QR
  /// prompt reappears. Never fired on an ambiguous/unknown result.
  void Function()? onSessionExpired;

  /// albumid(int) → album_mid(String), populated by [_albumFromQqcnRow] during a
  /// 专辑 search so [albumDetail] (int-keyed route) can call the mid-based
  /// GetAlbumSongList. QQ 专辑详情只认字符串 mid。
  final Map<int, String> _albumMidById = <int, String>{};

  QqcnApi({required QqcnCookieStore cookies, QqcnCrypto crypto = const QqcnCrypto()})
      : _cookies = cookies,
        _crypto = crypto,
        _dio = Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 20),
          receiveTimeout: const Duration(seconds: 25),
          followRedirects: true,
          maxRedirects: 10,
          // No global Origin/Referer: the login GETs must NOT carry a cross-origin
          // Origin (graph's OAuth rejects it); each call sets its own.
          headers: const <String, String>{
            'User-Agent': _webUa,
            'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
          },
        ))
          ..interceptors.add(CookieManager(cookies.jar));

  // UA for the ptlogin/graph OAuth walk (a real browser UA).
  static const String _webUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36';
  // UA for the Android gateway (musics.fcg / musicu.fcg).
  static const String _androidUa = 'QQMusic 20070008(android 14)';
  static const String _musicsUrl = 'https://u6.y.qq.com/cgi-bin/musics.fcg';
  static const String _musicuUrl = 'https://u6.y.qq.com/cgi-bin/musicu.fcg';

  final Random _rng = Random.secure();

  QqcnCookieStore get cookies => _cookies;
  bool get isLoggedIn => _cookies.isLoggedIn;

  // === Android gateway plumbing ============================================

  /// Signs + masks + zlib-compresses the [items] body and POSTs it to `musics.fcg`,
  /// returning the inflated JSON map. Response is keyed by `"{module}.{method}"`.
  Future<Map<String, dynamic>> _callMusics(
      List<Map<String, dynamic>> items,
      {Map<String, dynamic>? comm}) async {
    // The scan-login calls (CreateQRCode / GetQRCodeStatus / QRCodeLogin) sign the
    // anonymous device comm ([QqcnCookieStore.loginComm], uid `0`) — NOT an empty
    // `{}`, which the server rejects as `104610 "not in cts-white-list"` because
    // it carries no ct/cv/chid/tmeAppID identity. Everything else uses the
    // persisted session comm.
    final Map<String, dynamic> commBlock = comm ?? _cookies.sessionComm();
    final Map<String, dynamic> body = <String, dynamic>{
      'comm': commBlock,
    };
    for (final Map<String, dynamic> it in items) {
      body['${it['module']}.${it['method']}'] = it;
    }
    final String bj = jsonEncode(body);
    final Uint8List bjBytes = Uint8List.fromList(utf8.encode(bj));
    final int epoch = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final int tsMs = DateTime.now().millisecondsSinceEpoch;
    final String sign = _crypto.signBody(bjBytes, epochSec: epoch);
    final String mask = _crypto.maskFor(
      uid: (commBlock['uid'] ?? '0').toString(),
      udid: QqcnCookieStore.udid,
      tsMs: tsMs,
      sign: sign,
      epochSec: epoch,
    );
    // body = 5 random bytes + zlib(bodyJson)
    final Uint8List compressed =
        Uint8List.fromList(ZLibCodec().encode(bjBytes));
    final Uint8List pb = Uint8List(5 + compressed.length);
    for (int i = 0; i < 5; i++) {
      pb[i] = _rng.nextInt(256);
    }
    pb.setRange(5, pb.length, compressed);
    final Response<dynamic> resp = await _dio.post<dynamic>(
      _musicsUrl,
      data: pb, // dio sends a Uint8List as the raw request body
      options: Options(
        responseType: ResponseType.bytes,
        // No Content-Type (the reference sends none on this POST); dio derives
        // Content-Length from the byte body.
        headers: <String, String>{
          'User-Agent': _androidUa,
          'M-Encoding': 'm1',
          'x-sign-data-type': 'json',
          'Accept': '*/*',
          'Accept-Encoding': 'gzip',
          'sign': sign,
          'mask': mask,
        },
      ),
    );
    return _decodeBody(resp.data);
  }

  /// POSTs a raw (uncompressed) JSON body to `musicu.fcg` with only the `sign`
  /// header (login exchange / GetSession). The response echoes the request [key].
  Future<Map<String, dynamic>> _callMusicu({
    required Map<String, dynamic> comm,
    required String key,
    required Map<String, dynamic> item,
    String? referer,
    String userAgent = _androidUa,
  }) async {
    final Map<String, dynamic> body = <String, dynamic>{
      'comm': comm,
      key: item,
    };
    final String bj = jsonEncode(body);
    final Uint8List bjBytes = Uint8List.fromList(utf8.encode(bj));
    final int epoch = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final String sign = _crypto.signBody(bjBytes, epochSec: epoch);
    final Response<dynamic> resp = await _dio.post<dynamic>(
      _musicuUrl,
      data: bj,
      options: Options(
        responseType: ResponseType.bytes,
        contentType: 'application/json',
        headers: <String, String>{
          'User-Agent': userAgent,
          if (referer != null) 'Referer': referer,
          'sign': sign,
        },
      ),
    );
    return _decodeBody(resp.data);
  }

  /// Inflates a gateway response body (zlib `0x78` / gzip `1f8b` / plain) into a
  /// JSON map. Mirrors the reference `_decompress`.
  Map<String, dynamic> _decodeBody(dynamic data) {
    Uint8List raw;
    if (data is Uint8List) {
      raw = data;
    } else if (data is List) {
      raw = Uint8List.fromList(data.cast<int>());
    } else if (data is String) {
      raw = Uint8List.fromList(utf8.encode(data));
    } else {
      return <String, dynamic>{};
    }
    if (raw.isEmpty) return <String, dynamic>{};
    List<int> plain;
    try {
      if (raw.length >= 2 && raw[0] == 0x1f && raw[1] == 0x8b) {
        List<int> d = GZipCodec().decode(raw);
        try {
          d = ZLibCodec().decode(d);
        } catch (_) {}
        plain = d;
      } else if (raw[0] == 0x78) {
        plain = ZLibCodec().decode(raw);
      } else {
        plain = raw;
      }
    } catch (_) {
      plain = raw;
    }
    try {
      final dynamic obj = jsonDecode(utf8.decode(plain, allowMalformed: true));
      return obj is Map ? Map<String, dynamic>.from(obj) : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  /// Reads the `.data` block from the response entry keyed [key].
  Map<String, dynamic> _dataFor(Map<String, dynamic> resp, String key) {
    final dynamic entry = resp[key];
    if (entry is! Map) return <String, dynamic>{};
    final dynamic data = entry['data'];
    return data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
  }

  // === search ===============================================================

  @override
  Future<SearchResult> search({
    required String keyword,
    SearchType type = SearchType.song,
    int limit = 30,
    int offset = 0,
  }) async {
    // do_search_v2 支持按 search_type 搜不同类型（jadx 实证：专辑=2、歌单=3、单曲/综合
    // =100/0；歌手=1）；响应 body 是多块结构，每块 {items:[...]}。歌词本批不接。
    if (type == SearchType.lyric) {
      return SearchResult.empty(type);
    }
    final int page = (limit <= 0) ? 1 : (offset ~/ limit) + 1;
    final int num = limit <= 0 ? 20 : limit;
    try {
      switch (type) {
        case SearchType.album:
          // 专用 web 专辑搜索（client_search_cp t=8）→ data.album.list 全量分页。
          final Map<String, dynamic> resp = await _qqWebJson(
            'https://c.y.qq.com/soso/fcgi-bin/client_search_cp',
            <String, String>{
              'format': 'json',
              't': '8',
              'n': num.toString(),
              'p': page.toString(),
              'w': keyword,
              'cr': '1',
              'g_tk': '5381',
              'loginUin': '0',
              'hostUin': '0',
              'inCharset': 'utf8',
              'outCharset': 'utf-8',
              'notice': '0',
              'platform': 'yqq.json',
              'needNewCode': '0',
              'aggr': '1',
              'catZhida': '1',
              'lossless': '0',
              'flag_qc': '0',
              'remoteplace': 'txt.mqq.all',
            },
          );
          final Map<String, dynamic> aData =
              resp['data'] is Map ? Map<String, dynamic>.from(resp['data']) : {};
          final Map<String, dynamic> albObj = aData['album'] is Map
              ? Map<String, dynamic>.from(aData['album'])
              : {};
          final int aTotal = _int(albObj['totalnum'] ?? albObj['sum']);
          final dynamic aRows = albObj['list'];
          final List<Album> albums = <Album>[];
          if (aRows is List) {
            for (final dynamic e in aRows) {
              if (e is! Map) continue;
              final Album a = _albumFromQqcnRow(Map<String, dynamic>.from(e));
              if (a.name.isNotEmpty) albums.add(a);
            }
          }
          return SearchResult(
            type: type,
            albums: albums,
            total: aTotal > 0 ? aTotal : albums.length,
            hasMore: aTotal > 0
                ? (offset + albums.length) < aTotal
                : albums.length >= num,
          );
        case SearchType.playlist:
          // 专用 web 歌单搜索 → data.list 全量分页（page_no 从 0 起）。
          final Map<String, dynamic> resp = await _qqWebJson(
            'https://c.y.qq.com/soso/fcgi-bin/client_music_search_songlist',
            <String, String>{
              'remoteplace': 'txt.yqq.playlist',
              'page_no': (page - 1).toString(),
              'num_per_page': num.toString(),
              'query': keyword,
              'format': 'json',
              'inCharset': 'utf8',
              'outCharset': 'utf-8',
              'g_tk': '5381',
              'loginUin': '0',
              'hostUin': '0',
              'platform': 'yqq',
              'needNewCode': '0',
            },
          );
          final Map<String, dynamic> pData =
              resp['data'] is Map ? Map<String, dynamic>.from(resp['data']) : {};
          final int pTotal = _int(pData['sum'] ?? pData['total']);
          final dynamic pRows = pData['list'];
          final List<Playlist> playlists = <Playlist>[];
          if (pRows is List) {
            for (final dynamic e in pRows) {
              if (e is! Map) continue;
              final Playlist p =
                  _playlistFromQqcnRow(Map<String, dynamic>.from(e));
              if (p.name.isNotEmpty && p.id != 0) playlists.add(p);
            }
          }
          return SearchResult(
            type: type,
            playlists: playlists,
            total: pTotal > 0 ? pTotal : playlists.length,
            hasMore: pTotal > 0
                ? (offset + playlists.length) < pTotal
                : playlists.length >= num,
          );
        case SearchType.artist:
          final Map<String, dynamic> body =
              await _doSearchBody(keyword, 1, page, num);
          final List<Artist> artists =
              _pickRows(body, <String>['singer', 'item_user'])
                  .map((Map<String, dynamic> r) => _artistFromQqcnRow(r))
                  .where((Artist a) => a.name.isNotEmpty)
                  .toList();
          return SearchResult(
            type: type,
            artists: artists,
            total: artists.length,
            hasMore: artists.length >= num,
          );
        default: // song / comprehensive
          final Map<String, dynamic> body =
              await _doSearchBody(keyword, 100, page, num);
          final List<Song> songs = _rowsOf(body, 'item_song')
              .map((Map<String, dynamic> e) => _songFromQqcnRow(e))
              .where((Song s) =>
                  s.name.isNotEmpty && (s.ref['mid']?.isNotEmpty ?? false))
              .toList();
          return SearchResult(
            type: SearchType.song,
            songs: songs,
            total: songs.length,
            hasMore: songs.length >= num,
          );
      }
    } on DioException catch (e) {
      throw QqcnApiException(e.message ?? 'QQ search failed');
    }
  }

  // === play url (vkey) ======================================================

  @override
  Future<PlayUrl?> songUrl(Song song,
      {AudioLevel level = AudioLevel.exhigh}) async {
    final String mid = song.ref['mid'] ?? song.ref['songmid'] ?? '';
    if (mid.isEmpty) return null;
    // QQ 的 vkey 必须靠 filename 才能定向取某档音质的 purl；缺 filename 时服务端只
    // 回落「默认档」，VIP/高音质/部分无版权歌会回空 purl → 点了不播。filename =
    // {prefix}{mediaMid}.{ext}，按请求音质从高到低排降级链，末档 C400 是免费/试听
    // 默认档（等价旧的无 filename 行为，保证免费歌不回退）。mediaMid 已由
    // _songFromQqcnRow 存入 song.ref['mediaMid']。
    final String media = song.ref['mediaMid'] ?? mid;
    final List<String> files = _fileLadder(media, level);
    try {
      final Map<String, dynamic> resp = await _callMusics(<Map<String, dynamic>>[
        <String, dynamic>{
          'module': 'vkey.GetVkeyServer',
          'method': 'CgiGetVkey',
          'param': <String, dynamic>{
            'guid': QqcnCookieStore.udid,
            'songmid': <String>[for (final String _ in files) mid],
            'songtype': <int>[for (final String _ in files) 0],
            'filename': files,
            'uin': _cookies.qq,
            'loginflag': 1,
            'platform': '20',
          },
        },
      ]);
      final Map<String, dynamic> d =
          _dataFor(resp, 'vkey.GetVkeyServer.CgiGetVkey');
      final dynamic infos = d['midurlinfo'];
      if (infos is! List || infos.isEmpty) return null;
      // midurlinfo 与 files 同序：从高音质到低音质取第一条 result==0 且 purl 非空者。
      for (final dynamic raw in infos) {
        if (raw is! Map) continue;
        final Map<String, dynamic> info = Map<String, dynamic>.from(raw);
        if (_int(info['result']) != 0) continue;
        final String purl = _str(info['purl']);
        final String vkey = _str(info['vkey']);
        if (purl.isEmpty || vkey.isEmpty) continue;
        final String url = 'http://ws.stream.qqmusic.qq.com/$purl'
            '?vkey=$vkey&guid=${QqcnCookieStore.udid}&uin=${_cookies.uid}&fromtag=66';
        final (int br, String ext) = _qualityOf(purl);
        return PlayUrl(
          id: song.id,
          url: url,
          br: br,
          type: ext,
          size: 0,
          level: level,
        );
      }
      return null;
    } on DioException {
      return null;
    }
  }

  /// Bitrate/type guessed from the purl filename prefix/extension.
  /// filename 降级链：{prefix}{mediaMid}.{ext}，从请求音质到最低。末档 C400
  /// （128k m4a）是免费/试听默认档，等价于旧实现的无 filename 行为。前缀与
  /// _qualityOf 的识别一致（F000=flac / M800=320 / M500=128mp3 / C400=aac）。
  static List<String> _fileLadder(String media, AudioLevel level) {
    switch (level) {
      case AudioLevel.hires:
      case AudioLevel.lossless:
        return <String>[
          'F000$media.flac',
          'M800$media.mp3',
          'M500$media.mp3',
          'C400$media.m4a',
        ];
      case AudioLevel.exhigh:
        return <String>['M800$media.mp3', 'M500$media.mp3', 'C400$media.m4a'];
      case AudioLevel.higher:
        return <String>['M500$media.mp3', 'C400$media.m4a'];
      case AudioLevel.standard:
        return <String>['C400$media.m4a'];
    }
  }

  static (int, String) _qualityOf(String purl) {
    final String p = purl.toUpperCase();
    if (p.contains('.FLAC') || p.startsWith('F000')) return (900000, 'flac');
    if (p.contains('.MP3') || p.startsWith('M800')) return (320000, 'mp3');
    if (p.startsWith('M500')) return (192000, 'mp3');
    if (p.contains('.OGG')) return (192000, 'ogg');
    return (128000, 'm4a');
  }

  // === lyric ================================================================

  @override
  Future<Lyrics> lyric(Song song) async {
    final String mid = song.ref['mid'] ?? song.ref['songmid'] ?? '';
    if (mid.isEmpty) return Lyrics.empty;
    // 行级 LRC + 翻译走明文 fcg（可靠、匿名可用）。逐字 QRC 作为增强叠加：拿不到
    // 或解密失败时自然回退到这份行级 LRC，行为与旧实现一致。
    String lrc = '';
    String trans = '';
    final String url =
        'https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg'
        '?songmid=$mid&g_tk=5381&format=json&nobase64=0';
    try {
      final Response<dynamic> resp = await _dio.get<dynamic>(
        url,
        options: Options(
          responseType: ResponseType.plain,
          headers: <String, String>{
            'User-Agent': _webUa,
            'Referer': 'https://y.qq.com/',
          },
        ),
      );
      final dynamic decoded = jsonDecode(_stripJsonp(_str(resp.data)));
      if (decoded is Map) {
        lrc = _decodeMaybeB64(_str(decoded['lyric']));
        trans = _decodeMaybeB64(_str(decoded['trans']));
      }
    } on DioException {
      // Transient transport failure → surface so PlayerProvider can retry.
      rethrow;
    }
    // 逐字 QRC（增强，best-effort，永不抛）：lyric_download.fcg(lrctype=4) 返回 XML，
    // <content> 的 CDATA 是 DES 加密 hex → qqcnDecryptQrc 解密 → 内层
    // <Lyric_1 LyricContent="[QRC]"> → 提取 QRC → _qrcToKlyric 转 klyric（时间在字前）。
    // musicid = 数字 song.id；翻译沿用上面的明文 LRC（其绝对时间与 QRC ms 对齐）。
    String klyric = '';
    if (song.id != 0) {
      try {
        final Response<dynamic> r = await _dio.post<dynamic>(
          'https://c.y.qq.com/qqmusic/fcgi-bin/lyric_download.fcg',
          data: 'version=15&miniversion=82&lrctype=4&musicid=${song.id}',
          options: Options(
            responseType: ResponseType.plain,
            contentType: 'application/x-www-form-urlencoded',
            headers: <String, String>{
              'User-Agent': _webUa,
              'Referer': 'https://c.y.qq.com/',
            },
          ),
        );
        final String xml =
            _str(r.data).replaceAll('<!--', '').replaceAll('-->', '');
        final String qrcText = _qrcFieldFrom(xml, 'content');
        if (qrcText.isNotEmpty) klyric = _qrcToKlyric(qrcText);
      } catch (e) {
        debugPrint('QQ QRC lyric unavailable: $e');
      }
    }
    if (lrc.trim().isEmpty && klyric.trim().isEmpty) return Lyrics.empty;
    return Lyrics.parse(
      klyric: klyric.trim().isEmpty ? null : klyric,
      lrc: lrc.trim().isEmpty ? null : lrc,
      tlyric: trans.trim().isEmpty ? null : trans,
    );
  }

  /// 从 lyric_download.fcg 的 XML 里取 `<tag>` 的 CDATA 加密 hex → DES 解密 → 若
  /// 内层是 `<Lyric_1 … LyricContent="[QRC]">` 则提取该属性，否则返回解密文本本身。
  String _qrcFieldFrom(String xml, String tag) {
    final Match? m = RegExp('<$tag[^>]*>\\s*<!\\[CDATA\\[([0-9A-Fa-f]*)\\]\\]>')
        .firstMatch(xml);
    final String hex = m?.group(1) ?? '';
    if (hex.isEmpty) return '';
    final String dec = qqcnDecryptQrc(hex) ?? '';
    if (dec.isEmpty) return '';
    final Match? lc = RegExp('LyricContent="([^"]*)"').firstMatch(dec);
    return lc != null ? (lc.group(1) ?? '') : dec;
  }

  /// QRC(`文字(s,d)`，时间在字后) → klyric(`(s,d)文字`，时间在字前) 供 _parseKlyric。
  /// 行头 `[起,长]` 原样保留；元数据行([ti:]/[ar:]/[offset:]) 跳过。QRC 用绝对毫秒，
  /// 与 _parseKlyric 的绝对分支一致。
  static String _qrcToKlyric(String qrc) {
    final StringBuffer out = StringBuffer();
    final RegExp head = RegExp(r'^\[(\d+),(\d+)\](.*)$');
    final RegExp word = RegExp(r'([^()\r\n]*?)\((\d+),(\d+)\)');
    for (final String rawLine in qrc.split('\n')) {
      final Match? h = head.firstMatch(rawLine.trimRight());
      if (h == null) continue;
      out.write('[${h.group(1)},${h.group(2)}]');
      for (final Match m in word.allMatches(h.group(3)!)) {
        out.write('(${m.group(2)},${m.group(3)})${m.group(1) ?? ''}');
      }
      out.write('\n');
    }
    return out.toString();
  }

  static String _stripJsonp(String s) {
    final int lb = s.indexOf('{');
    final int rb = s.lastIndexOf('}');
    if (lb >= 0 && rb > lb) return s.substring(lb, rb + 1);
    return s;
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

  // === scan login (QQ: web ptlogin OAuth walk; WeChat: qrconnect) ===========
  //
  // QQ side is a faithful port of tools/qq_login_v3.py — the ONLY flow 手机QQ can
  // confirm: xlogin(seed cookies) → ptqrshow(QR + qrsig) → ptqrlogin(poll ptuiCB)
  // → follow redirect → graph.qq.com OAuth `code`
  // → _androidExchange(QQConnectLogin.QQLogin → GetSession → authst).
  // The earlier "QQ音乐 App 原生" CreateQRCode flow minted a *device* login code, so
  // 手机QQ reported "scanned by other app" and the poll never confirmed.
  static const String _ptClientId = '100497308'; // pt_3rd_aid / graph client_id
  static const String _ptAppid = '716027609'; //    ptlogin appid / aid
  static const String _ptSurl = 'https://graph.qq.com/oauth2.0/login_jump';
  static const String _ptRedirect =
      'https://y.qq.com/portal/wx_redirect.html?login_type=1&surl=https%3A%2F%2Fy.qq.com%2F';
  // Mobile UA for the ptlogin walk (matches qq_login_v3.py — the proven path).
  static const String _ptUa =
      'Mozilla/5.0 (Linux; Android 14; 22021211RC) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.6721.99 Mobile Safari/537.36';
  // Referer reused across create → poll → complete.
  String _qqXloginUrl = '';

  // WeChat handoff: 微信开放平台 qrconnect → wx_code → 落 wx_redirect cookie →
  // 与 QQ 共用的 QQLogin{code} 交换（qq_wechat_login.py 权威链路）。
  static const String _wxAppid = 'wx48db31d50e334801';
  // surl 预编码一次；整段 redirect_uri 进 qrconnect 时再 encodeComponent 一次，
  // 才能与微信注册的 redirect_uri 完全匹配（reference REDIRECT_URI）。
  static const String _wxRedirect =
      'https://y.qq.com/portal/wx_redirect.html?login_type=2&surl=https%3A%2F%2Fy.qq.com%2F';
  static const String _wxHref =
      'https://y.qq.com/mediastyle/music_v17/src/css/popup_wechat.css#wechat_redirect';
  static const String _wxState = 'STATE';

  /// Creates a scan-login session (QQ: native CreateQRCode; WeChat: qrconnect).
  Future<QqcnQrSession> qrCreate(QqcnLoginMethod method) async {
    // Start from a CLEAN jar so no stale session interferes with the new login.
    await _cookies.clear();
    return method == QqcnLoginMethod.qq ? _qqQrCreate() : _wxQrCreate();
  }

  /// QQ web ptlogin: seed `xlogin` cookies → `ptqrshow` → QR PNG + `qrsig`
  /// (the pollKey). Port of qq_login_v3.py:69-84.
  Future<QqcnQrSession> _qqQrCreate() async {
    final String feedback =
        'https://support.qq.com/products/77942?customInfo=.appid$_ptClientId';
    _qqXloginUrl =
        'https://xui.ptlogin2.qq.com/cgi-bin/xlogin?appid=$_ptAppid&daid=383'
        '&style=33&login_text=%E7%99%BB%E5%BD%95&hide_title_bar=1&hide_border=1'
        '&target=self&s_url=${Uri.encodeComponent(_ptSurl)}'
        '&pt_3rd_aid=$_ptClientId'
        '&pt_feedback_link=${Uri.encodeComponent(feedback)}&theme=2&verify_theme=';
    await _dio.get<dynamic>(
      _qqXloginUrl,
      options: Options(responseType: ResponseType.plain, headers: <String, String>{
        'User-Agent': _webUa,
        'Referer': 'https://xui.ptlogin2.qq.com/',
      }),
    );
    final double t = DateTime.now().millisecondsSinceEpoch / 1000;
    final String qrUrl = 'https://ssl.ptlogin2.qq.com/ptqrshow'
        '?s=8&e=0&appid=$_ptAppid&type=0&t=$t'
        '&u1=${Uri.encodeComponent(_ptSurl)}&daid=383&pt_3rd_aid=$_ptClientId';
    final Response<dynamic> img = await _dio.get<dynamic>(
      qrUrl,
      options: Options(responseType: ResponseType.bytes, headers: <String, String>{
        'User-Agent': _webUa,
        'Referer': _qqXloginUrl,
      }),
    );
    final Map<String, String> jar =
        await _cookies.loadFor(Uri.parse('https://ssl.ptlogin2.qq.com/'));
    final String qrsig = jar['qrsig'] ?? '';
    if (qrsig.isEmpty) throw QqcnApiException('ptqrshow 未返回 qrsig');
    return QqcnQrSession(
      image: Uint8List.fromList((img.data as List<dynamic>).cast<int>()),
      pollKey: qrsig,
    );
  }

  /// 微信开放平台扫码：GET qrconnect 解析 uuid → 拉二维码 PNG。pollKey = uuid。
  /// Port of tools/qq_wechat_login.py:build_qrconnect_url/get_uuid/get_qrcode_image。
  /// redirect_uri 用预编码的 [_wxRedirect]，`#wechat_redirect` 片段是 href 的一部分，
  /// 不挂在 connect URL 上。
  Future<QqcnQrSession> _wxQrCreate() async {
    final String connect = 'https://open.weixin.qq.com/connect/qrconnect'
        '?appid=$_wxAppid'
        '&redirect_uri=${Uri.encodeComponent(_wxRedirect)}'
        '&response_type=code&scope=snsapi_login&state=$_wxState'
        '&href=${Uri.encodeComponent(_wxHref)}';
    final Response<dynamic> page = await _dio.get<dynamic>(
      connect,
      options: Options(responseType: ResponseType.plain, headers: <String, String>{
        'User-Agent': _webUa,
        'Referer': 'https://y.qq.com/',
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      }),
    );
    final String html = _str(page.data);
    final String uuid =
        (RegExp(r'/connect/qrcode/([A-Za-z0-9_-]+)').firstMatch(html) ??
                RegExp(r'''uuid\s*[=:]\s*['"]?([A-Za-z0-9_-]{8,})''')
                    .firstMatch(html))
            ?.group(1) ??
            '';
    if (uuid.isEmpty) throw QqcnApiException('微信二维码 uuid 解析失败');
    final Response<dynamic> img = await _dio.get<dynamic>(
      'https://open.weixin.qq.com/connect/qrcode/$uuid',
      options: Options(responseType: ResponseType.bytes, headers: <String, String>{
        'User-Agent': _webUa,
        'Referer': 'https://y.qq.com/',
      }),
    );
    return QqcnQrSession(
      image: Uint8List.fromList((img.data as List<dynamic>).cast<int>()),
      pollKey: uuid,
    );
  }

  /// Polls a scan session. On confirmation the [QqcnQrPoll.payload] carries the QQ
  /// `redirect_url` / the WeChat `code` for [completeLogin].
  Future<QqcnQrPoll> qrPoll(QqcnLoginMethod method, String pollKey) async {
    return method == QqcnLoginMethod.qq ? _qqPoll(pollKey) : _wxPoll(pollKey);
  }

  /// QQ web ptlogin poll: `ptqrlogin` with `ptqrtoken = hash33(qrsig)`; the reply
  /// is a `ptuiCB('<code>',…,'<redirect_url>',…)` JSONP. Codes (qq_login_v3.py:96):
  /// `0`=confirmed (payload = redirect_url), `67`=scanned, `65`=expired, else wait.
  Future<QqcnQrPoll> _qqPoll(String qrsig) async {
    final int ptqrtoken = QqcnCrypto.hash33(qrsig);
    final int ms = DateTime.now().millisecondsSinceEpoch;
    final double t = ms / 1000;
    final String url = 'https://ssl.ptlogin2.qq.com/ptqrlogin'
        '?u1=${Uri.encodeComponent(_ptSurl)}&from_ui=1&type=1&ptlang=2052'
        '&ptqrtoken=$ptqrtoken&daid=383&aid=$_ptAppid&pt_3rd_aid=$_ptClientId'
        '&action=0-0-$ms&t=$t';
    final Response<dynamic> resp = await _dio.get<dynamic>(
      url,
      options: Options(responseType: ResponseType.plain, headers: <String, String>{
        'User-Agent': _webUa,
        'Referer': _qqXloginUrl,
      }),
    );
    final RegExpMatch? m =
        RegExp(r"ptuiCB\('(\d+)','(\d*)','([^']*)'").firstMatch(_str(resp.data));
    switch (m?.group(1) ?? '') {
      case '0':
        final String redirect = (m!.group(3) ?? '')
            .replaceAll(r'\x2d', '-')
            .replaceAll(r'\x3d', '=');
        return QqcnQrPoll(status: QqcnQrStatus.confirmed, payload: redirect);
      case '67':
        return const QqcnQrPoll(status: QqcnQrStatus.scanned);
      case '65':
        return const QqcnQrPoll(status: QqcnQrStatus.expired);
      case '66':
      default:
        return const QqcnQrPoll(status: QqcnQrStatus.waiting);
    }
  }

  /// 微信长轮询（qq_wechat_login.py:poll_qr）：405=确认成功(payload=wx_code)、
  /// 404=已扫待确认、408=等待扫码、403=取消、402=过期。长轮询会挂起 ~30s，故放大
  /// receiveTimeout；空返回归为 waiting，避免中断轮询。
  Future<QqcnQrPoll> _wxPoll(String uuid) async {
    final String url = 'https://long.open.weixin.qq.com/connect/l/qrconnect'
        '?uuid=$uuid&_=${DateTime.now().millisecondsSinceEpoch}';
    final Response<dynamic> resp = await _dio.get<dynamic>(
      url,
      options: Options(
        responseType: ResponseType.plain,
        receiveTimeout: const Duration(seconds: 40),
        headers: <String, String>{
          'User-Agent': _webUa,
          'Referer': 'https://y.qq.com/',
        },
      ),
    );
    final String body = _str(resp.data);
    final String errcode =
        RegExp(r'wx_errcode=(\d+)').firstMatch(body)?.group(1) ?? '';
    final String wxCode =
        RegExp(r"wx_code='([^']*)'").firstMatch(body)?.group(1) ?? '';
    switch (errcode) {
      case '405':
        if (wxCode.isEmpty) return const QqcnQrPoll(status: QqcnQrStatus.unknown);
        return QqcnQrPoll(status: QqcnQrStatus.confirmed, payload: wxCode);
      case '404': // 已扫码，等待手机确认
        return const QqcnQrPoll(status: QqcnQrStatus.scanned);
      case '408': // 长轮询窗口内无人扫，继续轮询
        return const QqcnQrPoll(status: QqcnQrStatus.waiting);
      case '403':
        return const QqcnQrPoll(status: QqcnQrStatus.canceled);
      case '402':
        return const QqcnQrPoll(status: QqcnQrStatus.expired);
      default:
        return const QqcnQrPoll(status: QqcnQrStatus.waiting);
    }
  }

  /// Finishes the login: walk the OAuth chain to a `code`, then exchange it on the
  /// Android endpoints. Returns whether the `authst` session landed.
  Future<bool> completeLogin(QqcnLoginMethod method, String payload) async {
    try {
      if (method == QqcnLoginMethod.qq) {
        return await _completeQqcnLogin(payload);
      }
      return await _completeWxLogin(payload);
    } catch (e) {
      debugPrint('QQ completeLogin error: $e');
      await _cookies.reload();
      return _cookies.isLoggedIn;
    }
  }

  /// QQ web ptlogin handoff (port of qq_login_v3.py:104-151): follow the confirmed
  /// [redirectUrl] so `p_skey`/`uin` land on `.qq.com` → `graph.qq.com` OAuth
  /// `show` + `authorize` for a one-time `code` → reuse [_androidExchange]
  /// (`QQConnectLogin.LoginServer.QQLogin` → `GetSession` → `authst`).
  /// GETs [url] and follows redirects MANUALLY (followRedirects:false per hop) so
  /// dio's CookieManager captures every hop's Set-Cookie. HttpClient's auto-follow
  /// only exposes the FINAL response to the interceptor, so intermediate
  /// p_skey/uin (set mid-chain on the ptlogin→graph walk) would otherwise be lost.
  Future<String> _followCapturingCookies(String url, String referer,
      {String userAgent = _ptUa}) async {
    String hop = url;
    for (int i = 0; i < 10; i++) {
      final Response<dynamic> r = await _dio.get<dynamic>(
        hop,
        options: Options(
          responseType: ResponseType.plain,
          followRedirects: false,
          // 任何状态都读取（不抛），避免中途 ≥400 打断整条 cookie 链。
          validateStatus: (int? s) => true,
          headers: <String, String>{'User-Agent': userAgent, 'Referer': referer},
        ),
      );
      final String? loc = r.headers.value('location');
      if (loc == null || loc.isEmpty) break;
      referer = hop;
      hop = loc.startsWith('http')
          ? loc
          : Uri.parse(hop).resolve(loc).toString();
    }
    return hop;
  }

  /// A dio with NO CookieManager — the caller sets an explicit `Cookie` header.
  /// Essential for the graph `authorize` POST: the shared [_dio]'s CookieManager
  /// emits p_skey/p_uin/pt4_token TWICE (stored under both `.qq.com` and
  /// `graph.qq.com`), so graph can't bind g_tk to a single p_skey and bounces
  /// authorize to the login page. A deduped manual header (one value per name)
  /// fixes it. (Mirrors qq_api.dart's verified fix.)
  Dio _bareDio() => Dio(BaseOptions(
        followRedirects: false,
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 25),
        headers: <String, String>{
          // Mobile UA — EXACTLY matches qq_login_v3.py (the verified path).
          'User-Agent': _ptUa,
          'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
        },
      ));

  Future<bool> _completeQqcnLogin(String redirectUrl) async {
    if (redirectUrl.isEmpty) return false;
    // A) follow the ptlogin redirect (check_sig → login_jump) so graph.qq.com's
    //    p_skey/p_uin land. MANUAL hop following — p_skey is set on an intermediate
    //    302 that dio's auto-follow would drop.
    await _followCapturingCookies(redirectUrl, _qqXloginUrl, userAgent: _webUa);
    // Build the graph.qq.com cookie set ONCE (one value per name), and drive BOTH
    // `show` and `authorize` through a BARE dio with this deduped Cookie header.
    // The shared _dio's CookieManager otherwise emits p_skey/p_uin/pt4_token TWICE
    // (`.qq.com` + `graph.qq.com` scopes, kept because the jar ignoreExpires-keeps
    // the `qq.com` deletion cookie); graph then can't bind g_tk to a single p_skey
    // and bounces to the login page — for `show` too, so it never sets `ui` /
    // returns the consent page. (Mirrors qq_api.dart's verified fix.)
    final Map<String, String> graph =
        await _cookies.loadFor(Uri.parse('https://graph.qq.com/'));
    final String pSkey = graph['p_skey'] ?? '';
    final int gtk = pSkey.isNotEmpty ? QqcnCrypto.hash33(pSkey) : 5381;
    final String cookieHeader = graph.entries
        .where((MapEntry<String, String> e) => e.value.isNotEmpty)
        .map((MapEntry<String, String> e) => '${e.key}=${e.value}')
        .join('; ');
    final Dio bare = _bareDio();
    // B) OAuth `show` (bare dio + deduped cookies) — when graph recognises the
    //    login it returns the consent/auto-submit page carrying the `ui` token.
    final String showUrl = 'https://graph.qq.com/oauth2.0/show'
        '?which=Login&display=pc&response_type=code&client_id=$_ptClientId'
        '&redirect_uri=${Uri.encodeComponent(_ptRedirect)}&state=state'
        '&scope=${Uri.encodeComponent('get_user_info,get_app_friends')}';
    String showHtml = '';
    try {
      final Response<dynamic> showResp = await bare.get<dynamic>(
        showUrl,
        options: Options(
          responseType: ResponseType.plain,
          followRedirects: false,
          validateStatus: (int? s) => true,
          headers: <String, String>{
            'Referer': 'https://y.qq.com/',
            'Cookie': cookieHeader,
          },
        ),
      );
      showHtml = _str(showResp.data);
    } catch (_) {}
    final String uiFromHtml = RegExp(r'''name=["']ui["'][^>]*value=["']([^"']+)["']''')
            .firstMatch(showHtml)?.group(1) ??
        RegExp(r'''value=["']([^"']+)["'][^>]*name=["']ui["']''')
            .firstMatch(showHtml)?.group(1) ??
        '';
    final String ui = (graph['ui'] ?? '').isNotEmpty ? graph['ui']! : uiFromHtml;
    // C) authorize via the same bare dio + deduped Cookie header.
    final Response<dynamic> authResp;
    try {
      authResp = await bare.post<dynamic>(
        'https://graph.qq.com/oauth2.0/authorize',
        data: <String, String>{
          'response_type': 'code',
          'client_id': _ptClientId,
          'redirect_uri': _ptRedirect,
          'scope': 'get_user_info,get_app_friends',
          'state': 'state',
          'switch': '',
          'from_ptlogin': '1',
          'src': '1',
          'update_auth': '1',
          'openapi': '1010_1030',
          'g_tk': gtk.toString(),
          'auth_time': DateTime.now().millisecondsSinceEpoch.toString(),
          'ui': ui,
        },
        options: Options(
          responseType: ResponseType.plain,
          contentType: 'application/x-www-form-urlencoded',
          followRedirects: false,
          validateStatus: (int? s) => s != null && s < 400,
          headers: <String, String>{
            'Origin': 'https://graph.qq.com',
            'Referer': showUrl,
            'Cookie': cookieHeader,
          },
        ),
      );
    } finally {
      bare.close();
    }
    // 302 Location = REDIRECT_URI?code=<code>. It may instead point at an
    // intermediate (login_jump) — follow the rest of the chain until code appears.
    String callbackUrl = authResp.headers.value('location') ?? '';
    if (callbackUrl.isEmpty) callbackUrl = authResp.realUri.toString();
    String code = Uri.tryParse(callbackUrl)?.queryParameters['code'] ?? '';
    if (code.isEmpty && callbackUrl.startsWith('http')) {
      final String fin =
          await _followCapturingCookies(callbackUrl, showUrl, userAgent: _webUa);
      code = Uri.tryParse(fin)?.queryParameters['code'] ?? '';
      if (code.isNotEmpty) callbackUrl = fin;
    }
    if (code.isEmpty) {
      debugPrint('QQ ptlogin: authorize returned no code (bounced to login)');
      return false;
    }
    // D) QQLogin → GetSession → saveSession; Referer = callback_url.
    return _androidExchange(
      method: 'QQLogin',
      param: <String, dynamic>{'code': code},
      gtk: gtk,
      referer: callbackUrl,
    );
  }

  /// 微信收尾（qq_wechat_login.py step4–6）：
  ///  A) GET wx_redirect.html?login_type=2&code=wx_code，手动跟 302 把 login_type=2
  ///     / wxuin 等微信登录 cookie 落到 .qq.com —— 后端据此把该 code 当微信 code。
  ///  A') 若这条链里后端已代换出 qm_keyst，直接拿它当 authst 收口。
  ///  B) 否则用裸 wx_code 走与 QQ 共用的 QQConnectLogin.LoginServer.QQLogin{code}
  ///     （微信这条不走 graph.authorize，无 p_skey → comm.g_tk=hash33('')=5381，
  ///     已在 _androidExchange 内硬编码）。Referer = wx_redirect URL。
  Future<bool> _completeWxLogin(String wxCode) async {
    if (wxCode.isEmpty) return false;
    final String wxRedirectUrl = 'https://y.qq.com/portal/wx_redirect.html'
        '?login_type=2&surl=https%3A%2F%2Fy.qq.com%2F'
        '&code=${Uri.encodeComponent(wxCode)}&state=$_wxState';
    // A) 落微信 cookie（逐跳跟 302，让 CookieManager 抓到每一跳的 Set-Cookie）。
    await _followCapturingCookies(wxRedirectUrl, 'https://y.qq.com/');
    // A') 后端已代换 → 直接收口（authst = qm_keyst）。
    final Map<String, String> jar =
        await _cookies.loadFor(Uri.parse('https://y.qq.com/'));
    final String keyst = jar['qm_keyst'] ?? jar['qqmusic_key'] ?? '';
    final String wxuin = jar['wxuin'] ?? jar['uin'] ?? '';
    if (keyst.isNotEmpty && wxuin.isNotEmpty) {
      await _cookies.saveSession(<String, dynamic>{
        'uid': wxuin,
        'authst': keyst,
        'qq': wxuin,
        'psrf_qqaccess_token': jar['psrf_qqaccess_token'] ?? '',
        'psrf_qqopenid': jar['wxopenid'] ?? jar['psrf_qqopenid'] ?? '',
      });
      if (_cookies.isLoggedIn) return true;
    }
    // B) 与 QQ 共用的交换：QQLogin{code=wx_code}。
    return _androidExchange(
      method: 'QQLogin',
      param: <String, dynamic>{'code': wxCode},
      gtk: 5381,
      referer: wxRedirectUrl,
    );
  }

  /// The verified Android session exchange:
  ///  1. `musicu.fcg` `QQConnectLogin.LoginServer/<method>{code}` → access_token /
  ///     openid / musicid(qq) / musickey.
  ///  2. `musicu.fcg` `music.getSession.GetSession` (carrying the psrf tokens) →
  ///     uid / sid / authst.
  /// Persists everything via [QqcnCookieStore.saveSession]; returns whether `authst`
  /// landed.
  Future<bool> _androidExchange({
    required String method,
    required Map<String, dynamic> param,
    required int gtk,
    required String referer,
  }) async {
    final Map<String, dynamic> loginResp = await _callMusicu(
      comm: <String, dynamic>{
        // QQLogin 的 comm.g_tk 恒为 5381（qq_login_v3.py:205）—— 算出的
        // hash33(p_skey) 只用在上游 graph authorize 那步。gtk 形参对本环节
        // 已无用，仅为兼容旧调用点保留。
        'g_tk': 5381,
        'platform': 'yqq',
        'ct': 24,
        'cv': 0,
      },
      key: 'req',
      item: <String, dynamic>{
        'module': 'QQConnectLogin.LoginServer',
        'method': method,
        'param': param,
      },
      referer: referer,
      // QQLogin token exchange uses the browser UA (matches qq_login_v3.py); the
      // GetSession call below keeps the App UA (its default).
      userAgent: _ptUa,
    );
    final dynamic reqBlk = loginResp['req'];
    final dynamic loginData = reqBlk is Map ? reqBlk['data'] : null;
    if (loginData is! Map) {
      debugPrint('QQ exchange: no login data ($method)');
      return false;
    }
    final Map<String, dynamic> ld = Map<String, dynamic>.from(loginData);
    final String accessToken = _str(ld['access_token']);
    final String openid = _str(ld['openid']);
    final String qq = _str(ld['musicid'] ?? ld['uin']);
    // The login-session ticket IS musickey (= web qqmusic_key). GetSession during
    // login often returns only uid/sid (not authst/vkey), so musickey is the
    // PRIMARY authst — it's what android_auth.json carries and every authed
    // musics.fcg call is verified to accept. GetSession.vkey is only the renewal
    // ticket for later.
    final String musickey = _str(ld['musickey'] ?? ld['qqmusic_key']);
    if (qq.isEmpty || (accessToken.isEmpty && musickey.isEmpty)) {
      debugPrint('QQ exchange: incomplete tokens');
      return false;
    }
    final String nick = _str(ld['nick'] ?? ld['nickname'] ?? ld['name']);
    final String logo =
        _str(ld['logo'] ?? ld['headimgurl'] ?? ld['figureurl_qq_2']);
    final String expiresAt = _str(ld['expired_at'] ?? ld['expires_at']);

    // 2) GetSession → uid/sid (+ a fresh vkey on renewal). Login must NOT depend
    //    on it succeeding: authst = GetSession vkey/authst if present, else the
    //    login's own musickey.
    Map<String, dynamic> sessData;
    try {
      sessData = await _getSession(
        accessToken: accessToken,
        openid: openid,
        qq: qq,
      );
    } catch (_) {
      sessData = <String, dynamic>{};
    }
    final String uid = _str(sessData['uid'] ?? sessData['uin']);
    final String sid = _str(sessData['sid']);
    final String sessAuthst = _str(sessData['authst']);
    final String authst = sessAuthst.isNotEmpty ? sessAuthst : musickey;
    if (authst.isEmpty) {
      debugPrint('QQ exchange: no GetSession ticket and no musickey');
      return false;
    }

    await _cookies.saveSession(
      <String, dynamic>{
        'uid': uid.isEmpty ? qq : uid,
        'sid': sid,
        'authst': authst,
        'qq': qq,
        'psrf_qqaccess_token': accessToken,
        'psrf_qqopenid': openid,
        if (expiresAt.isNotEmpty) 'psrf_access_token_expiresAt': expiresAt,
      },
      nick: nick.isEmpty ? null : nick,
      logo: logo.isEmpty ? null : logo,
    );
    return _cookies.isLoggedIn;
  }

  /// Runs `music.getSession.GetSession` with the psrf tokens and returns the
  /// session block. The ticket nests under `data.session` (`uid`/`sid`/`vkey`) —
  /// faithful to `qqmusic_client.py::refresh_session` — so this unwraps that layer
  /// and exposes the `vkey` ticket under the `authst` key (its web equivalent) so
  /// callers read one consistent field. Falls back to a flat `data` for any
  /// response shape that doesn't nest.
  Future<Map<String, dynamic>> _getSession({
    required String accessToken,
    required String openid,
    required String qq,
  }) async {
    const String key = 'music.getSession.session.GetSession';
    final Map<String, dynamic> comm = <String, dynamic>{
      'uid': '0',
      'udid': QqcnCookieStore.udid,
      'OpenUDID': QqcnCookieStore.udid,
      'ct': '11',
      'cv': QqcnCrypto.appVersion,
      'v': QqcnCrypto.appVersion,
      'chid': '73387',
      'os_ver': '14',
      'aid': '8c54b1e0c50ad8cd',
      'phonetype': '22021211RC',
      'QIMEI36': QqcnCookieStore.qimei36,
      'tmeAppID': 'qqmusic',
      'tmeLoginType': 2,
      'tmeLoginMethod': 3,
      'psrf_qqaccess_token': accessToken,
      'psrf_qqopenid': openid,
      'qq': qq,
      'nettype': '1030',
      'gzip': '1',
    };
    final Map<String, dynamic> resp = await _callMusicu(
      comm: comm,
      key: key,
      item: <String, dynamic>{
        'module': 'music.getSession.session',
        'method': 'GetSession',
        'param': <String, dynamic>{},
      },
    );
    final Map<String, dynamic> data = _dataFor(resp, key);
    // musicu login-time GetSession returns FLAT `data.{authst,sid,uin}`; musics
    // renewal-time returns NESTED `data.session.{vkey,sid,uid}`. Read both — flat
    // first, nested to fill gaps, `vkey` normalized to `authst` — so a response
    // that carries both a `session` object AND flat fields doesn't drop the flat
    // authst.
    final Map<String, dynamic> out = <String, dynamic>{
      // v3 reads data.get('uin', data.get('uid')) — uin FIRST.
      'uid': data['uin'] ?? data['uid'],
      'sid': data['sid'],
      'authst': data['authst'],
    };
    final dynamic sessRaw = data['session'];
    if (sessRaw is Map) {
      final Map<String, dynamic> sess = Map<String, dynamic>.from(sessRaw);
      if (_str(out['uid']).isEmpty) out['uid'] = sess['uin'] ?? sess['uid'];
      if (_str(out['sid']).isEmpty) out['sid'] = sess['sid'];
      if (_str(out['authst']).isEmpty) {
        out['authst'] =
            _str(sess['authst']).isNotEmpty ? sess['authst'] : sess['vkey'];
      }
    }
    return out;
  }

  Future<QqcnAccount?> accountProfile() async {
    await _cookies.reload();
    if (!_cookies.isLoggedIn) return null;
    bool vip = false;
    try {
      vip = await _vipInfo();
    } catch (_) {}
    return QqcnAccount(
      uin: _cookies.qq,
      nickname: _cookies.nickname ?? '',
      avatarUrl: _cookies.avatarUrl,
      isVip: vip,
    );
  }

  /// Best-effort VIP flag via `userInfo.VipQueryServer.SRFVipQuery_V2`.
  Future<bool> _vipInfo() async {
    final String qq = _cookies.qq;
    if (qq == '0') return false;
    const String key = 'userInfo.VipQueryServer.SRFVipQuery_V2';
    final Map<String, dynamic> resp = await _callMusics(<Map<String, dynamic>>[
      <String, dynamic>{
        'module': 'userInfo.VipQueryServer',
        'method': 'SRFVipQuery_V2',
        'param': <String, dynamic>{
          'uin_list': <String>[qq],
        },
      },
    ]);
    final Map<String, dynamic> d = _dataFor(resp, key);
    final dynamic infoMap = d['infoMap'];
    final dynamic info = infoMap is Map ? infoMap[qq] : null;
    if (info is! Map) return false;
    return _int(info['iVipFlag']) > 0 ||
        _int(info['iSuperVip']) > 0 ||
        _int(info['iNewSuperVip']) > 0 ||
        _int(info['HugeVip']) > 0;
  }

  /// Server-side login-state check. Re-runs GetSession with the stored psrf
  /// tokens: when it returns a fresh ticket (`vkey`), silently refreshes
  /// `authst`/`sid`/`uid` and returns true. Otherwise returns null so the caller
  /// KEEPS the current session — GetSession returns an empty/ambiguous block
  /// often enough (transient / rate-limit) that treating "no ticket back" as a
  /// hard expiry would strand a valid login logged-out on every startup/resume.
  /// A truly dead session surfaces as failing authed calls, recoverable by a
  /// manual re-login. (Never fires [onSessionExpired] on an ambiguous reply.)
  Future<bool?> verifyLoginState() async {
    await _cookies.reload();
    if (!_cookies.isLoggedIn) return null;
    final String accessToken = _cookies['psrf_qqaccess_token'] ?? '';
    final String openid = _cookies['psrf_qqopenid'] ?? '';
    final String qq = _cookies.qq;
    if (accessToken.isEmpty || qq == '0') return null; // can't verify → keep
    Map<String, dynamic> data;
    try {
      data = await _getSession(
          accessToken: accessToken, openid: openid, qq: qq);
    } catch (e) {
      debugPrint('[qqcn] silent-refresh GetSession threw: $e — keep session');
      return null; // transport failure → unknown, keep session
    }
    final String authst = _str(data['authst']);
    debugPrint('[qqcn] silent-refresh GetSession → '
        'freshAuthst=${authst.isNotEmpty} uid=${_str(data['uid'] ?? data['uin'])} '
        'sid=${_str(data['sid']).isNotEmpty}');
    if (authst.isNotEmpty) {
      // Silent refresh — persist the fresh authst(vkey)/sid/uid.
      await _cookies.saveSession(<String, dynamic>{
        'uid': _str(data['uid'] ?? data['uin']).isEmpty
            ? _cookies.uid
            : _str(data['uid'] ?? data['uin']),
        'sid': _str(data['sid']),
        'authst': authst,
        'qq': qq,
        'psrf_qqaccess_token': accessToken,
        'psrf_qqopenid': openid,
      });
      return true;
    }
    // No fresh ticket — ambiguous, NOT a confirmed expiry. Keep the session.
    return null;
  }

  Future<void> logout() => _cookies.clear();

  // === discovery / playlist =================================================

  @override
  Future<List<Playlist>> personalizedPlaylists({int limit = 12}) async {
    const String key = 'music.playlist.PlaylistSquare.GetRecommendFeed';
    try {
      final Map<String, dynamic> resp = await _callMusics(<Map<String, dynamic>>[
        <String, dynamic>{
          'module': 'music.playlist.PlaylistSquare',
          'method': 'GetRecommendFeed',
          'param': <String, dynamic>{'From': 0, 'Size': limit},
        },
      ]);
      final Map<String, dynamic> d = _dataFor(resp, key);
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
                    cover['small_url'] ??
                    cover['pic_url'])
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
    // 稳定歌曲来源：QQ 榜单（热歌榜 topid=26）。个性化推荐在 QQ 安卓端极不稳定 ——
    // GetRadarSongForTop 是消费型雷达（每页 1 首、首页 HasMore=false）；GetRecommend
    // 返回的是首页卡片（推荐歌单/心动瞬间报告），歌曲散落、每次调用结构都不同、常只
    // 解析出 1 首。榜单 GetDetail 一次返回一整批固定歌曲，稳定可靠。登出/空时兜底
    // 热门搜索维持匿名首页可用。
    const String key = 'musicToplist.ToplistInfoServer.GetDetail';
    final int want = limit <= 0 ? 10 : limit;
    try {
      final Map<String, dynamic> resp = await _callMusics(<Map<String, dynamic>>[
        <String, dynamic>{
          'module': 'musicToplist.ToplistInfoServer',
          'method': 'GetDetail',
          'param': <String, dynamic>{
            'topid': 26,
            'offset': 0,
            'num': want < 30 ? 30 : want,
            'period': '',
          },
        },
      ]);
      final Map<String, dynamic> d = _dataFor(resp, key);
      final dynamic rows =
          d['songInfoList'] ?? d['songlist'] ?? d['song'] ?? d['list'];
      final List<Song> songs = <Song>[];
      final Set<String> seenMids = <String>{};
      if (rows is List) {
        for (final dynamic e in rows) {
          if (e is! Map) continue;
          // 榜单行可能把歌曲对象嵌在 .data / .songInfo 下（旧格式）。
          final dynamic inner = e['data'] ?? e['songInfo'] ?? e;
          if (inner is! Map) continue;
          final Song s = _songFromQqcnRow(Map<String, dynamic>.from(inner));
          final String rmid = s.ref['mid'] ?? '';
          if (s.name.isEmpty || rmid.isEmpty || !seenMids.add(rmid)) continue;
          songs.add(s);
          if (songs.length >= want) break;
        }
      }
      if (songs.isNotEmpty) return songs.take(want).toList();
    } catch (e) {
      debugPrint('QQ toplist recommend failed: $e');
    }
    try {
      final SearchResult r =
          await search(keyword: '热门', type: SearchType.song, limit: limit);
      return r.songs.take(limit).toList();
    } catch (_) {
      return const <Song>[];
    }
  }

  /// 专辑详情：`GetAlbumSongList(albumMid)` → songList[].songInfo。album_mid 由
  /// [_albumFromQqcnRow] 在搜索时按 int id 存下（QQ 专辑详情只认字符串 mid，而路由是
  /// int）。搜过才有 mid；直链冷启动无 mid → 空。
  @override
  Future<Playlist> albumDetail(int id) async {
    final String mid = _albumMidById[id] ?? '';
    if (mid.isEmpty) {
      debugPrint('[qqcn] albumDetail($id): no album_mid cached — empty.');
      return Playlist(id: id, name: '专辑', tracks: const <Song>[]);
    }
    const String key = 'music.musichallAlbum.AlbumSongList.GetAlbumSongList';
    try {
      final Map<String, dynamic> resp = await _callMusics(<Map<String, dynamic>>[
        <String, dynamic>{
          'module': 'music.musichallAlbum.AlbumSongList',
          'method': 'GetAlbumSongList',
          'param': <String, dynamic>{
            'albumMid': mid,
            'begin': 0,
            'num': 100,
            'order': 2,
          },
        },
      ]);
      final Map<String, dynamic> data = _dataFor(resp, key);
      final dynamic songList =
          data['songList'] ?? data['songs'] ?? data['list'];
      final List<Song> tracks = <Song>[];
      if (songList is List) {
        for (final dynamic e in songList) {
          if (e is! Map) continue;
          final Map<String, dynamic> m = Map<String, dynamic>.from(e);
          // 每行常把歌曲包在 songInfo 下；否则就是扁平行。
          final Map<String, dynamic> row = m['songInfo'] is Map
              ? Map<String, dynamic>.from(m['songInfo'] as Map)
              : m;
          final Song s = _songFromQqcnRow(row);
          if (s.name.isNotEmpty && (s.ref['mid']?.isNotEmpty ?? false)) {
            tracks.add(s);
          }
        }
      }
      final String name = _str(data['albumName'] ?? data['name']);
      return Playlist(
        id: id,
        name: name.isEmpty ? '专辑' : name,
        coverUrl:
            'https://y.gtimg.cn/music/photo_new/T002R800x800M000$mid.jpg',
        trackCount: tracks.length,
        tracks: tracks,
      );
    } catch (e) {
      debugPrint('[qqcn] albumDetail($id) failed: $e');
      return Playlist(id: id, name: '专辑', tracks: const <Song>[]);
    }
  }

  /// QQ playlist (歌单) detail by `disstid` (`music.srfDissInfo.aiDissInfo`).
  @override
  Future<Playlist> playlistDetail(int id) async {
    const String key = 'music.srfDissInfo.aiDissInfo.uniform_get_Dissinfo';
    try {
      final Map<String, dynamic> resp = await _callMusics(<Map<String, dynamic>>[
        <String, dynamic>{
          'module': 'music.srfDissInfo.aiDissInfo',
          'method': 'uniform_get_Dissinfo',
          'param': <String, dynamic>{
            'disstid': id,
            'song_begin': 0,
            'song_num': 300,
            'ctx': 1,
          },
        },
      ]);
      final Map<String, dynamic> d = _dataFor(resp, key);
      final dynamic dir = d['dirinfo'];
      final Map<String, dynamic> dirinfo =
          dir is Map ? Map<String, dynamic>.from(dir) : <String, dynamic>{};
      final dynamic songlist = d['songlist'];
      final List<Song> tracks = songlist is List
          ? songlist
              .whereType<Map>()
              .map((dynamic e) => _songFromQqcnRow(Map<String, dynamic>.from(e)))
              .where((Song s) => s.name.isNotEmpty)
              .toList()
          : <Song>[];
      final dynamic creator = dirinfo['creator'];
      final String cover = _str(dirinfo['picurl']);
      final String desc = _str(dirinfo['desc']);
      final String name = _str(dirinfo['title']).isNotEmpty
          ? _str(dirinfo['title'])
          : _str(dirinfo['dissname']);
      return Playlist(
        id: id,
        name: name,
        coverUrl: cover.isEmpty ? null : cover,
        creatorName: creator is Map ? _str(creator['nick']) : null,
        description: desc.isEmpty ? null : desc,
        trackCount: _int(d['total_song_num']) > 0
            ? _int(d['total_song_num'])
            : (_int(dirinfo['songnum']) > 0
                ? _int(dirinfo['songnum'])
                : tracks.length),
        playCount: _int(dirinfo['visitnum']),
        tracks: tracks,
      );
    } on DioException catch (e) {
      throw QqcnApiException(e.message ?? 'QQ playlist detail failed');
    }
  }

  /// The signed-in user's created playlists via `c6.y.qq.com/fcg_user_created_diss`
  /// (a plain web GET, authenticated by a hand-built `qqmusic_key={authst}` cookie —
  /// the Android session key doubles as the web key). Empty when logged out.
  @override
  Future<List<Playlist>> userPlaylists({int limit = 30, int offset = 0}) async {
    await _cookies.reload();
    if (!_cookies.isLoggedIn) return const <Playlist>[];
    final String qq = _cookies.qq;
    if (qq == '0') return const <Playlist>[];
    final String authst = _cookies.authst;
    final int gtk = QqcnCrypto.hash33(authst);
    final int ts = DateTime.now().millisecondsSinceEpoch;
    final String url = 'https://c6.y.qq.com/rsc/fcgi-bin/fcg_user_created_diss'
        '?r=$ts&_=${ts + 1}&cv=4747474&ct=24&format=json'
        '&uin=$qq&g_tk=$gtk&hostuin=$qq&sin=$offset&size=$limit';
    final String cookie = 'qqmusic_key=$authst; '
        'psrf_qqaccess_token=${_cookies['psrf_qqaccess_token'] ?? ''}; '
        'psrf_qqopenid=${_cookies['psrf_qqopenid'] ?? ''}; '
        'uin=$qq; qm_keyst=$authst';
    try {
      final Response<dynamic> resp = await _dio.get<dynamic>(
        url,
        options: Options(
          responseType: ResponseType.plain,
          headers: <String, String>{
            'User-Agent': _webUa,
            'Referer': 'https://y.qq.com/',
            'Cookie': cookie,
          },
        ),
      );
      final dynamic decoded = jsonDecode(_stripJsonp(_str(resp.data)));
      final dynamic dl = decoded is Map && decoded['data'] is Map
          ? decoded['data']['disslist']
          : null;
      if (dl is! List) return const <Playlist>[];
      return dl
          .whereType<Map>()
          .map((dynamic e) {
            final Map<String, dynamic> m = Map<String, dynamic>.from(e);
            return Playlist(
              // 歌单 id 必须用 tid（全局 disstid）—— playlistDetail 拿它当
              // disstid 调 uniform_get_Dissinfo；dirid 是本地小序号，会查不到详情。
              // 与已验证的 qq_api.dart 一致。
              id: _int(m['tid']),
              name: _str(m['diss_name'] ?? m['title']),
              coverUrl: _emptyNull(_str(m['diss_cover'])),
              trackCount: _int(m['song_cnt']),
              playCount: _int(m['listen_num']),
            );
          })
          .where((Playlist p) => p.id != 0 && p.name.isNotEmpty)
          .toList();
    } on DioException {
      return const <Playlist>[];
    } catch (_) {
      return const <Playlist>[];
    }
  }

  @override
  Future<List<Song>> dailyRecommendSongs({int limit = 30}) =>
      recommendedSongs(limit: limit);

  @override
  Future<List<Playlist>> dailyRecommendPlaylists({int limit = 30}) =>
      personalizedPlaylists(limit: limit);

  // CreatePlaylist returns 40000 and DelPlaylist needs a native dirId on the
  // Android surface (see qqmusic_client.py) — not reliably callable, so left
  // unsupported. Add/remove a song into an existing 歌单 (dirId=[pid]) DO work.
  @override
  Future<int> createPlaylist(String name, {int privacy = 0}) =>
      throw QqcnApiException('QQ音乐暂不支持新建歌单');

  @override
  Future<void> deletePlaylist(int pid) =>
      throw QqcnApiException('QQ音乐暂不支持删除歌单');

  /// Adds song [ids] (QQ numeric songIds — a [Song.id] for a QQ track) into the
  /// 歌单 [pid] via `music.musicasset.PlaylistDetailWrite.AddSonglist`.
  @override
  Future<void> addTracksToPlaylist(int pid, List<int> ids) async {
    if (ids.isEmpty) return;
    const String key = 'music.musicasset.PlaylistDetailWrite.AddSonglist';
    final Map<String, dynamic> resp = await _callMusics(<Map<String, dynamic>>[
      <String, dynamic>{
        'module': 'music.musicasset.PlaylistDetailWrite',
        'method': 'AddSonglist',
        'param': <String, dynamic>{
          'dirId': pid,
          'v_songInfo': <Map<String, dynamic>>[
            for (final int id in ids)
              <String, dynamic>{'songType': 0, 'songId': id},
          ],
        },
      },
    ]);
    final dynamic entry = resp[key];
    if (entry is! Map || _int(entry['code']) != 0) {
      throw QqcnApiException('添加到歌单失败');
    }
  }

  /// Removes song [ids] from 歌单 [pid] via `PlaylistDetailWrite.DelSonglist`.
  @override
  Future<void> removeTracksFromPlaylist(int pid, List<int> ids) async {
    if (ids.isEmpty) return;
    const String key = 'music.musicasset.PlaylistDetailWrite.DelSonglist';
    final Map<String, dynamic> resp = await _callMusics(<Map<String, dynamic>>[
      <String, dynamic>{
        'module': 'music.musicasset.PlaylistDetailWrite',
        'method': 'DelSonglist',
        'param': <String, dynamic>{
          'dirId': pid,
          'v_songInfo': <Map<String, dynamic>>[
            for (final int id in ids)
              <String, dynamic>{'songType': 0, 'songId': id},
          ],
        },
      },
    ]);
    final dynamic entry = resp[key];
    if (entry is! Map || _int(entry['code']) != 0) {
      throw QqcnApiException('从歌单删除失败');
    }
  }

  @override
  Future<void> collectPlaylist(int id, bool collect) =>
      throw QqcnApiException('QQ音乐暂不支持收藏歌单');

  // === parsing ==============================================================

  String _searchId() =>
      (DateTime.now().microsecondsSinceEpoch % 100000000000000000).toString();

  /// One do_search_v2 request for [searchType] (jadx: 专辑=2, 歌单=3, 单曲/综合=100),
  /// returning the multi-block `data.body` map ({} on miss). Each block is
  /// `body['item_*']['items']`.
  Future<Map<String, dynamic>> _doSearchBody(
      String keyword, int searchType, int page, int num) async {
    const String key = 'music.adaptor.SearchAdaptorQMMobile.do_search_v2';
    final Map<String, dynamic> resp = await _callMusics(<Map<String, dynamic>>[
      <String, dynamic>{
        'module': 'music.adaptor.SearchAdaptorQMMobile',
        'method': 'do_search_v2',
        'param': <String, dynamic>{
          'ver': 0,
          'searchid': _searchId(),
          'sub_searchid': 0,
          'search_type': searchType,
          'query': keyword,
          'page_id': page,
          'page_num': page,
          'num_per_page': num,
          'remoteplace': 'search.android.search',
        },
      },
    ]);
    final dynamic entry = resp[key];
    final dynamic data = entry is Map ? entry['data'] : null;
    final dynamic body = data is Map ? data['body'] : null;
    return body is Map ? Map<String, dynamic>.from(body) : <String, dynamic>{};
  }

  /// Bare GET to a public QQ **web** search endpoint (`c.y.qq.com`, `format=json`,
  /// no Android sign) → decoded JSON map. do_search_v2 only returns tiny per-type
  /// previews (album≈3, 歌单≈5); the web `client_search_cp` / songlist endpoints
  /// return the FULL paged list. Reuses [_decodeBody] for gzip/zlib/plain.
  Future<Map<String, dynamic>> _qqWebJson(
      String url, Map<String, String> q) async {
    final Response<dynamic> r = await _dio.get<dynamic>(
      url,
      queryParameters: q,
      options: Options(
        responseType: ResponseType.bytes,
        headers: <String, String>{
          'Referer': 'https://y.qq.com/',
          'User-Agent': _ptUa,
        },
      ),
    );
    try {
      return _decodeBody(r.data);
    } catch (e) {
      debugPrint('[qqcn] webJson $url decode failed: $e');
      return <String, dynamic>{};
    }
  }

  /// Rows of a do_search_v2 body block. A block is either `{items:[...]}` or a
  /// bare list. Empty on any miss.
  List<Map<String, dynamic>> _rowsOf(Map<String, dynamic> body, String block) {
    final dynamic blk = body[block];
    final dynamic items =
        blk is Map ? blk['items'] : (blk is List ? blk : null);
    if (items is! List) return const <Map<String, dynamic>>[];
    return items
        .whereType<Map>()
        .map((dynamic e) => Map<String, dynamic>.from(e))
        .toList();
  }

  /// do_search_v2 returns the SAME mixed body for every search_type; `item_*`
  /// blocks are 3–5 row previews, while `vertical_*` blocks hold the full paged
  /// list for the requested type. Picks the fuller block among [keys] and logs
  /// each candidate's row count (so the right key is verifiable at runtime).
  List<Map<String, dynamic>> _pickRows(
      Map<String, dynamic> body, List<String> keys) {
    List<Map<String, dynamic>> best = const <Map<String, dynamic>>[];
    for (final String k in keys) {
      final List<Map<String, dynamic>> rows = _rowsOf(body, k);
      if (rows.length > best.length) best = rows;
    }
    return best;
  }

  /// item_album row → [Album]. Cover falls back to the CDN template from the
  /// album mid when no `pic` field is present.
  Album _albumFromQqcnRow(Map<String, dynamic> row) {
    final int id = _int(row['id'] ?? row['albumid'] ?? row['albumID']);
    final String name =
        _str(row['name'] ?? row['albumName'] ?? row['album_name']);
    final String albummid = _str(
        row['albummid'] ?? row['albumMID'] ?? row['album_mid'] ?? row['mid']);
    // 专辑详情要用字符串 album_mid，而 /album/:id 路由与 loadAlbum 缓存都是 int →
    // 按 int id 存下 mid（同 kugougn 存 gid/suid 的套路），albumDetail 据此取歌。
    if (id != 0 && albummid.isNotEmpty) _albumMidById[id] = albummid;
    String cover = _str(row['pic'] ?? row['albumPic'] ?? row['logo']);
    if (cover.isEmpty && albummid.isNotEmpty) {
      cover =
          'https://y.gtimg.cn/music/photo_new/T002R800x800M000$albummid.jpg';
    }
    return Album(id: id, name: name, picUrl: _emptyNull(cover));
  }

  /// item_songlist row → [Playlist]. `dissid` (numeric global id) is compatible
  /// with [playlistDetail]'s int arg — tapping the card opens end to end.
  Playlist _playlistFromQqcnRow(Map<String, dynamic> row) {
    final int id = _int(row['dissid'] ?? row['dissID'] ?? row['id']);
    final String name = _str(
        row['dissname'] ?? row['dissName'] ?? row['title'] ?? row['name']);
    final String cover =
        _str(row['imgurl'] ?? row['logo'] ?? row['cover'] ?? row['pic']);
    // web 歌单搜索里 creator 是嵌套对象 {name,...}；do_search_v2 里是扁平 nickname。
    final dynamic cr = row['creator'];
    final String creator = cr is Map
        ? _str(cr['name'] ?? cr['nick'])
        : _str(row['creator_name'] ?? row['nickname'] ?? row['nick']);
    final int count =
        _int(row['song_count'] ?? row['songnum'] ?? row['listennum']);
    return Playlist(
      id: id,
      name: name,
      coverUrl: _emptyNull(cover),
      creatorName: _emptyNull(creator),
      trackCount: count,
    );
  }

  /// singer block row → [Artist]. Pic falls back to the CDN template from the
  /// singer mid.
  Artist _artistFromQqcnRow(Map<String, dynamic> row) {
    final int id = _int(row['singerid'] ?? row['id'] ?? row['singerID']);
    final String name =
        _str(row['singername'] ?? row['name'] ?? row['singerName']);
    final String mid =
        _str(row['singermid'] ?? row['singerMID'] ?? row['mid']);
    String pic = _str(row['singerpic'] ?? row['pic'] ?? row['avatar']);
    if (pic.isEmpty && mid.isNotEmpty) {
      pic = 'https://y.gtimg.cn/music/photo_new/T001R800x800M000$mid.jpg';
    }
    return Artist(id: id, name: name, picUrl: _emptyNull(pic));
  }

  /// Builds a [Song] from an Android search / playlist row. The canonical id is
  /// `mid` (songmid) — stashed in [ref] under both `mid` and `songmid` so
  /// [songUrl]/[lyric] can read it. Tags [MusicSource.qqcn] — its OWN independent
  /// source, distinct from the web QQ in the `migu` slot.
  Song _songFromQqcnRow(Map<String, dynamic> row) {
    // 兼容多种 QQ 行格式：安卓(mid/id/singer[]) 与 web/榜单(songmid/songid/singerName)。
    String mid = _str(row['mid']);
    if (mid.isEmpty) mid = _str(row['songmid']);
    int songid = _int(row['id']);
    if (songid == 0) songid = _int(row['songid']);
    final int id =
        songid != 0 ? songid : (mid.isEmpty ? row.hashCode : mid.hashCode);

    List<Artist> artists =
        ((row['singer'] as List<dynamic>?) ?? const <dynamic>[])
            .whereType<Map>()
            .map((dynamic s) => Artist(
                  id: _int((s as Map)['id']),
                  name: _str(s['name'] ?? s['title']),
                ))
            .where((Artist a) => a.name.isNotEmpty)
            .toList();
    if (artists.isEmpty) {
      // 榜单/旧格式：singer 是字符串或 singerName。
      final String sn = _str(row['singerName']);
      final String s2 = sn.isNotEmpty ? sn : (row['singer'] is String ? _str(row['singer']) : '');
      if (s2.isNotEmpty) artists = <Artist>[Artist(id: 0, name: s2)];
    }

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

    final dynamic file = row['file'];
    final String mediaMid = _str(file is Map
        ? file['media_mid']
        : (row['media_mid'] ?? row['strMediaMid']));

    return Song(
      id: id,
      name: _str(row['name'] ?? row['title'] ?? row['songname']),
      artists: artists,
      album: album,
      duration: Duration(seconds: _int(row['interval'])),
      fee: 0,
      playable: true,
      source: MusicSource.qqcn,
      ref: <String, String>{
        'mid': mid,
        'songmid': mid,
        if (songid != 0) 'id': songid.toString(),
        'mediaMid': mediaMid.isEmpty ? mid : mediaMid,
        if (albumMid.isNotEmpty) 'albumMid': albumMid,
        if (cover.isNotEmpty) 'cover': cover,
      },
    );
  }

  static String? _emptyNull(String s) => s.isEmpty ? null : s;

}

int _int(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}

String _str(dynamic v) => v?.toString() ?? '';
