import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:pointycastle/export.dart';

import '../models/kugou_account.dart';
import '../models/lyric_line.dart';
import '../models/play_url.dart';
import '../models/playlist.dart';
import '../models/search_result.dart';
import '../models/song.dart';
import 'music_api.dart';

class KugouApiException implements Exception {
  final String message;
  KugouApiException(this.message);
  @override
  String toString() => 'KugouApiException: $message';
}

/// Anonymous Kugou (酷狗音乐) backend — no login required. Every API request is
/// signed `md5(SALT + sortedKeys.join("key=value") + SALT)` (lowercase); an empty
/// `token`/`userid` (="0") makes the signature pass without an account. Endpoints:
///  - search:  `complexsearch.kugou.com/v2/search/song` — **JSONP** (strip the
///             `callback123( … )` wrapper); `data.lists[]` carries `EMixSongID`
///             (the play id) + `FileHash` (the lyric hash + a stable int [Song.id]).
///  - play:    `wwwapi.kugou.com/play/songinfo?encode_album_audio_id=<EMixSongID>`
///             → `data.play_url`. **Needs a Kugou LOGIN** — anonymous returns
///             `status:0, err 30020`. The play call authenticates purely from the
///             `token` + `userid` query pair (NO cookies / AES / RSA): the exact
///             `token` the QR poll returns (see [qrPoll]) is the play token. So once
///             an account is set via [setAccount], full songs resolve; with none,
///             play degrades to null → skip-to-next (like a Migu VIP track).
///  - login:   QR — [qrCreate] (`login-user.kugou.com/v2/qrcode`) draws a scannable
///             PNG, [qrPoll] (`/v2/get_userinfo_qrcode`) returns `data.status`
///             (1/2/4) and, on 4, the `token`+`userid` to inject. No crypto step.
///  - lyric:   the classic anonymous pair `lyrics.kugou.com/search` (by FileHash)
///             → `candidates[0].{id,accesskey}` → `/download?fmt=lrc` → base64 LRC.
///             Verified working anonymously.
///
/// The signing salt / constants come from the reference spider (`Code/Spider/
/// kugouMusic`). Per-quality (SQ/HQ/FLAC) hashes aren't wired — the base FileHash
/// is used. Search + lyric were live-verified anonymous; play requires login.
class KugouApi implements MusicApi {
  final Dio _dio;

  /// A per-session device id (`md5(guid)` in the reference). Held constant for
  /// this instance and reused as both `mid` and `uuid` (they must match).
  final String _mid;

  /// The active signed-in account (null = anonymous). Set by [KugouAuthProvider]
  /// from the persisted store / after a QR login; its `token`+`userid` are folded
  /// into search + play requests, which is what unlocks full-song playback.
  KugouAccount? _account;

  /// Installs (or clears with null) the active account. Idempotent.
  void setAccount(KugouAccount? account) => _account = account;

  KugouAccount? get account => _account;

  String get _token => _account?.token ?? '';
  String get _userid => _account?.userId ?? '0';

  KugouApi({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 20),
              headers: const <String, String>{
                'User-Agent': _ua,
                'Referer': 'https://www.kugou.com/',
                'Accept': '*/*',
                'Accept-Language': 'zh-CN,zh;q=0.9',
              },
            )),
        _mid = _randomMid();

  static const String _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36';
  static const String _salt = 'NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt';

  static const String _searchUrl =
      'https://complexsearch.kugou.com/v2/search/song';
  static const String _songInfoUrl = 'https://wwwapi.kugou.com/play/songinfo';
  static const String _lyricSearchUrl = 'https://lyrics.kugou.com/search';
  static const String _lyricDownloadUrl = 'https://lyrics.kugou.com/download';
  static const String _qrCreateUrl = 'https://login-user.kugou.com/v2/qrcode';
  static const String _qrPollUrl =
      'https://login-user.kugou.com/v2/get_userinfo_qrcode';

  // --- signing -------------------------------------------------------------

  /// Kugou request signature: `md5(SALT + Σ"key=value" (keys ASCII-sorted) + SALT)`
  /// over EVERY param that will be sent EXCEPT `signature` itself. Lowercase hex
  /// (the case used for search + songinfo).
  String _sign(Map<String, String> params) {
    final List<String> keys = params.keys.toList()..sort();
    final StringBuffer sb = StringBuffer(_salt);
    for (final String k in keys) {
      sb
        ..write(k)
        ..write('=')
        ..write(params[k]);
    }
    sb.write(_salt);
    return _md5Hex(sb.toString());
  }

  static String _md5Hex(String input) {
    final Uint8List out =
        MD5Digest().process(Uint8List.fromList(utf8.encode(input)));
    final StringBuffer sb = StringBuffer();
    for (final int b in out) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  /// 32 hex chars, like the reference's `md5(guid())` device id. A per-instance
  /// value is enough for anonymous use (Kugou only needs mid/uuid to be present
  /// and folded into the signature).
  static String _randomMid() {
    final Random r = Random();
    final StringBuffer sb = StringBuffer();
    for (int i = 0; i < 32; i++) {
      sb.write(r.nextInt(16).toRadixString(16));
    }
    return sb.toString();
  }

  String _now() => DateTime.now().millisecondsSinceEpoch.toString();

  // --- search --------------------------------------------------------------

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
    final int page = (limit <= 0) ? 1 : (offset ~/ limit) + 1;
    final Map<String, String> params = <String, String>{
      'callback': 'callback123',
      'srcappid': '2919',
      'clientver': '1000',
      'clienttime': _now(),
      'mid': _mid,
      'uuid': _mid,
      'dfid': '-',
      'keyword': keyword,
      'page': page.toString(),
      'pagesize': limit.toString(),
      'bitrate': '0',
      'isfuzzy': '0',
      'inputtype': '0',
      'platform': 'WebFilter',
      'userid': _userid,
      'iscorrection': '1',
      'privilege_filter': '0',
      'filter': '10',
      'token': _token,
      'appid': '1014',
    };
    params['signature'] = _sign(params);

    try {
      final Response<dynamic> resp = await _dio.get<dynamic>(
        _searchUrl,
        queryParameters: params,
        options: Options(responseType: ResponseType.plain),
      );
      final Map<String, dynamic> body = _stripJsonp(resp.data);
      final dynamic data = body['data'];
      if (data is! Map) return SearchResult.empty(type);
      final dynamic lists = data['lists'] ?? data['list'] ?? data['info'];
      if (lists is! List) return SearchResult.empty(type);

      final List<Song> songs = lists
          .whereType<Map>()
          .map((dynamic e) => Song.fromKugouJson(Map<String, dynamic>.from(e)))
          .where((Song s) =>
              s.name.isNotEmpty && (s.ref['albumAudioId']?.isNotEmpty ?? false))
          .toList();

      final int total = _int(data['total']);
      return SearchResult(
        type: SearchType.song,
        songs: songs,
        total: total > 0 ? total : songs.length,
        hasMore: total > 0
            ? (offset + songs.length) < total
            : songs.length >= limit,
      );
    } on DioException catch (e) {
      throw KugouApiException(e.message ?? 'Kugou search failed');
    }
  }

  /// Strips the JSONP `callback123( … )` wrapper and decodes the inner JSON.
  Map<String, dynamic> _stripJsonp(dynamic raw) {
    String text = (raw is String ? raw : '$raw').trim();
    final int lp = text.indexOf('(');
    final int rp = text.lastIndexOf(')');
    if (lp >= 0 && rp > lp) text = text.substring(lp + 1, rp);
    try {
      final dynamic d = jsonDecode(text);
      if (d is Map) return Map<String, dynamic>.from(d);
    } catch (_) {}
    return <String, dynamic>{};
  }

  // --- play url ------------------------------------------------------------

  @override
  Future<PlayUrl?> songUrl(Song song,
      {AudioLevel level = AudioLevel.exhigh}) async {
    final String mixId = song.ref['albumAudioId'] ?? '';
    if (mixId.isEmpty) return null;
    final Map<String, String> params = <String, String>{
      'srcappid': '2919',
      'clientver': '20000',
      'clienttime': _now(),
      'mid': _mid,
      'uuid': _mid,
      'dfid': '-',
      'appid': '1014',
      'platid': '4',
      'encode_album_audio_id': mixId,
      'token': _token,
      'userid': _userid,
    };
    params['signature'] = _sign(params);

    try {
      final Response<dynamic> resp = await _dio.get<dynamic>(
        _songInfoUrl,
        queryParameters: params,
        options: Options(
          responseType: ResponseType.plain,
          headers: const <String, String>{'Origin': 'https://www.kugou.com'},
        ),
      );
      final Map<String, dynamic> body = _asMap(resp.data);
      final dynamic data = body['data'];
      if (data is! Map) return null;
      final String url = _pickUrl(Map<String, dynamic>.from(data));
      // Anonymous → `err 30020` / empty url (Kugou requires a login for playback);
      // returns null so the queue skips to the next playable track, same as a Migu
      // VIP track. Resolves automatically once a Kugou session cookie is present.
      if (url.isEmpty) return null;
      return PlayUrl(
        id: song.id,
        url: url,
        br: 0,
        type: 'mp3',
        size: 0,
        level: level,
      );
    } on DioException {
      return null;
    }
  }

  /// Picks a direct stream url from a `play/songinfo` `data` block. Tries
  /// `play_url` / `url`, then `backup_url`; each may be a string or a list.
  String _pickUrl(Map<String, dynamic> data) {
    for (final String key in const <String>[
      'play_url',
      'playUrl',
      'url',
      'backup_url'
    ]) {
      final dynamic v = data[key];
      if (v is String && v.isNotEmpty) return v;
      if (v is List && v.isNotEmpty) {
        final dynamic first = v.first;
        if (first is String && first.isNotEmpty) return first;
      }
    }
    return '';
  }

  // --- lyric ---------------------------------------------------------------

  @override
  Future<Lyrics> lyric(Song song) async {
    final String hash = song.ref['hash'] ?? '';
    if (hash.isEmpty) return Lyrics.empty;
    try {
      // 1) Find a lyric candidate by the song's file hash.
      final Response<dynamic> searchResp = await _dio.get<dynamic>(
        _lyricSearchUrl,
        queryParameters: <String, dynamic>{
          'ver': 1,
          'man': 'yes',
          'client': 'pc',
          'hash': hash,
        },
        options: Options(responseType: ResponseType.plain),
      );
      final Map<String, dynamic> sm = _asMap(searchResp.data);
      final dynamic candidates = sm['candidates'];
      if (candidates is! List || candidates.isEmpty) return Lyrics.empty;
      final Map<String, dynamic> first =
          Map<String, dynamic>.from(candidates.first as Map);
      final String id = _str(first['id']);
      final String accesskey = _str(first['accesskey']);
      if (id.isEmpty || accesskey.isEmpty) return Lyrics.empty;

      // 2) Download it as plain LRC (fmt=lrc → base64 of the LRC text; no KRC
      // zlib/XOR needed).
      final Response<dynamic> dlResp = await _dio.get<dynamic>(
        _lyricDownloadUrl,
        queryParameters: <String, dynamic>{
          'ver': 1,
          'client': 'pc',
          'id': id,
          'accesskey': accesskey,
          'fmt': 'lrc',
          'charset': 'utf8',
        },
        options: Options(responseType: ResponseType.plain),
      );
      final Map<String, dynamic> dm = _asMap(dlResp.data);
      final String contentB64 = _str(dm['content']);
      if (contentB64.isEmpty) return Lyrics.empty;
      final String lrc = utf8.decode(
        base64.decode(contentB64),
        allowMalformed: true,
      );
      if (lrc.trim().isEmpty) return Lyrics.empty;
      return Lyrics.parse(lrc: lrc);
    } on DioException {
      // Transient CDN/transport failure — surface it so PlayerProvider can retry
      // instead of caching "no lyrics" (matches Migu). A genuinely-absent lyric is
      // the empty-candidate / empty-content return above, which settles cleanly.
      rethrow;
    }
  }

  // --- login (QR) ----------------------------------------------------------

  /// Base cookies the login endpoints expect (device id mirrors the reference's
  /// `kg_mid`). Same value the signature folds in as `mid`/`uuid`.
  Map<String, String> get _loginHeaders => <String, String>{
        'Referer': 'https://login-user.kugou.com/',
        'Cookie': 'kg_mid=$_mid; kg_mid_temp=$_mid; kg_dfid=-',
      };

  /// Creates a QR-login session. Returns the polling id + a ready-to-render PNG
  /// data-url (`data.qrcode` / `data.qrcode_img`). The scannable image is drawn
  /// server-side, so the phone's Kugou app scans it directly.
  Future<KugouQrCreate> qrCreate() async {
    final Map<String, String> params = <String, String>{
      'appid': '1014',
      'clientver': '8131',
      'clienttime': _now(),
      'mid': _mid,
      'uuid': _mid,
      'dfid': '-',
      'type': '1',
      'plat': '4',
      'qrcode_txt':
          'https://h5.kugou.com/apps/loginQRCode/html/index.html?appid=1014&',
      'srcappid': '2919',
    };
    params['signature'] = _sign(params);
    try {
      final Response<dynamic> resp = await _dio.get<dynamic>(
        _qrCreateUrl,
        queryParameters: params,
        options: Options(
          responseType: ResponseType.plain,
          headers: _loginHeaders,
        ),
      );
      final Map<String, dynamic> body = _asMap(resp.data);
      final dynamic data = body['data'];
      if (data is! Map) {
        throw KugouApiException('二维码创建失败：${body['error_code'] ?? body}');
      }
      final Map<String, dynamic> d = Map<String, dynamic>.from(data);
      final String qrcode = _str(d['qrcode']);
      final String img = _str(d['qrcode_img']);
      if (qrcode.isEmpty) throw KugouApiException('二维码创建失败：无 qrcode');
      return KugouQrCreate(qrcode: qrcode, imageDataUrl: img);
    } on DioException catch (e) {
      throw KugouApiException(e.message ?? 'Kugou qrCreate failed');
    }
  }

  /// Polls a QR session. Maps the nested `data.status` (1 waiting / 2 scanned /
  /// 4 confirmed / 0 expired); on confirmation builds a [KugouAccount] from the
  /// returned `token`+`userid` (+ nickname / pic) — the credential the play call
  /// needs.
  Future<KugouQrPoll> qrPoll(String qrcode) async {
    final Map<String, String> params = <String, String>{
      'appid': '1014',
      'clientver': '8131',
      'clienttime': _now(),
      'mid': _mid,
      'uuid': _mid,
      'dfid': '-',
      'plat': '4',
      'qrcode': qrcode,
      'srcappid': '2919',
    };
    params['signature'] = _sign(params);
    try {
      final Response<dynamic> resp = await _dio.get<dynamic>(
        _qrPollUrl,
        queryParameters: params,
        options: Options(
          responseType: ResponseType.plain,
          headers: _loginHeaders,
        ),
      );
      final Map<String, dynamic> body = _asMap(resp.data);
      final dynamic data = body['data'];
      final Map<String, dynamic> d =
          data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
      final KugouQrStatus status =
          KugouQrPoll.statusFromData(_int(d['status']));
      if (status == KugouQrStatus.confirmed) {
        final String token = _str(d['token']);
        final String userId = _str(d['userid']);
        if (token.isEmpty || userId.isEmpty) {
          return const KugouQrPoll(status: KugouQrStatus.unknown);
        }
        return KugouQrPoll(
          status: status,
          account: KugouAccount(
            userId: userId,
            token: token,
            nickname: _str(d['nickname']),
            avatarUrl: _httpsPic(_str(d['pic'])),
          ),
        );
      }
      return KugouQrPoll(status: status);
    } on DioException catch (e) {
      throw KugouApiException(e.message ?? 'Kugou qrPoll failed');
    }
  }

  static String? _httpsPic(String raw) {
    if (raw.isEmpty) return null;
    return raw.startsWith('http://')
        ? raw.replaceFirst('http://', 'https://')
        : raw;
  }

  // --- discovery / feeds (anonymous → hot search only) ---------------------

  @override
  Future<List<Playlist>> personalizedPlaylists({int limit = 12}) async =>
      const <Playlist>[];

  @override
  Future<List<Song>> recommendedSongs({int limit = 8}) async {
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

  @override
  Future<Playlist> playlistDetail(int id) {
    throw KugouApiException('Kugou has no playlist detail support');
  }

  @override
  Future<List<Playlist>> userPlaylists({int limit = 30, int offset = 0}) async =>
      const <Playlist>[];

  @override
  Future<List<Song>> dailyRecommendSongs({int limit = 30}) async =>
      const <Song>[];

  @override
  Future<List<Playlist>> dailyRecommendPlaylists({int limit = 30}) async =>
      const <Playlist>[];

  // --- playlist management (unsupported) -----------------------------------

  @override
  Future<int> createPlaylist(String name, {int privacy = 0}) {
    throw KugouApiException('Kugou has no playlist management');
  }

  @override
  Future<void> deletePlaylist(int pid) {
    throw KugouApiException('Kugou has no playlist management');
  }

  @override
  Future<void> addTracksToPlaylist(int pid, List<int> ids) {
    throw KugouApiException('Kugou has no playlist management');
  }

  @override
  Future<void> removeTracksFromPlaylist(int pid, List<int> ids) {
    throw KugouApiException('Kugou has no playlist management');
  }

  @override
  Future<void> collectPlaylist(int id, bool collect) {
    throw KugouApiException('Kugou has no playlist management');
  }

  // --- helpers -------------------------------------------------------------

  Map<String, dynamic> _asMap(dynamic data) {
    if (data is Map) return Map<String, dynamic>.from(data);
    if (data is String && data.trim().isNotEmpty) {
      try {
        final dynamic d = jsonDecode(data);
        if (d is Map) return Map<String, dynamic>.from(d);
      } catch (_) {}
    }
    return <String, dynamic>{};
  }
}

int _int(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}

String _str(dynamic v) => v?.toString() ?? '';
