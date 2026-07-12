import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/image_url.dart';
import '../models/lyric_line.dart';
import '../models/play_url.dart';
import '../models/playlist.dart';
import '../models/qr_login.dart';
import '../models/search_result.dart';
import '../models/song.dart';
import 'cookie_store.dart';
import 'music_api.dart';
import 'netease_crypto.dart';
import 'netease_endpoints.dart';

class NeteaseApiException implements Exception {
  final String message;
  final int? statusCode;

  NeteaseApiException(this.message, {this.statusCode});

  @override
  String toString() => 'NeteaseApiException(${statusCode ?? '-'}): $message';
}

/// The signed-in user's account snapshot (from `/w/nuser/account/get`). Carried
/// out of [NeteaseApi.accountProfile] so the login layer can show who's logged
/// in and resolve the uid for [NeteaseApi.userPlaylists].
class NeteaseAccount {
  final int uid;
  final String nickname;
  final String? avatarUrl;
  final int vipType;

  const NeteaseAccount({
    required this.uid,
    required this.nickname,
    this.avatarUrl,
    this.vipType = 0,
  });
}

/// The weapi client. All networking funnels through [postWeapi], which injects
/// `csrf_token` (from [cookies]) into the payload BEFORE encryption. Implements
/// the backend-agnostic [MusicApi]; QR login + song detail are Netease-only.
class NeteaseApi implements MusicApi {
  final Dio dio;
  final NeteaseCrypto crypto;
  final CookieStore cookies;

  NeteaseApi({required this.dio, required this.crypto, required this.cookies});

  /// Fired by [postWeapi] when the server rejects an authed call with a
  /// login-required code (301 / 20001) — the reliable "session expired" signal.
  /// The auth layer wires this to attempt a silent [refreshSession] and, failing
  /// that, drop to logged-out so the UI re-prompts a QR scan. Never fired for a
  /// transport error (that stays a transient failure), so a network blip can't
  /// log the user out.
  void Function()? onSessionExpired;

  static final Random _random = Random.secure();

  /// QR-login session correlation, set once in [qrCreate] and reused by every
  /// [qrPoll]. `_qrChainId` is the stable `x-login-chain-id`
  /// (`v1_<sDeviceId>_web_login_<ms>`, embedding the persisted device id) sent
  /// on the unikey request, baked into the QR URL, AND attached to every poll —
  /// this is what ties the phone scan to the polling client. `_qrYdToken` is the
  /// one-per-session `ydDeviceToken` (NOT re-minted each poll).
  String? _qrChainId;
  String? _qrYdToken;

  /// Cached uid, populated the first time [accountProfile] resolves it and reused
  /// by [userPlaylists] so it doesn't re-fetch the profile every call.
  int? _cachedUid;

  /// The signed-in uid, once a profile fetch has resolved it (else null).
  int? get cachedUid => _cachedUid;

  /// Encrypts [payload] (+ csrf) and POSTs to [path], returning the decoded
  /// JSON body. Throws [NeteaseApiException] on transport errors or a non-200
  /// body `code`.
  Future<Map<String, dynamic>> postWeapi(
    String path,
    Map<String, dynamic> payload, {
    bool needsCsrf = true,
  }) async {
    final Map<String, dynamic> map =
        await _postWeapiRaw(path, payload, needsCsrf: needsCsrf);
    final int? code = (map['code'] as num?)?.toInt();
    if (code != null && code != 200) {
      // 301 / 20001 = "please log in" — the authoritative expired-session signal
      // for authed calls. Notify the auth layer (which tries a silent renewal,
      // then forces re-login) instead of letting feeds/songUrl silently fail.
      if (code == 301 || code == 20001) {
        onSessionExpired?.call();
      }
      throw NeteaseApiException(
        map['message']?.toString() ?? 'API error',
        statusCode: code,
      );
    }
    return map;
  }

  /// Silent session renewal. POSTs to [NeteaseEndpoints.tokenRefresh]; the jar's
  /// `MUSIC_R_T` (refresh token) rides along via the [CookieManager] and a 200
  /// Set-Cookies a fresh `MUSIC_U`. Returns true on success. Uses [_postWeapiRaw]
  /// (not [postWeapi]) so a non-200 renewal doesn't re-fire [onSessionExpired]
  /// and loop. Any transport/decoding failure returns false (treated as "couldn't
  /// renew" — the caller then decides whether to force logout).
  Future<bool> refreshSession() async {
    try {
      final Map<String, dynamic> res = await _postWeapiRaw(
        NeteaseEndpoints.tokenRefresh,
        <String, dynamic>{},
      );
      final int? code = (res['code'] as num?)?.toInt();
      if (code == 200) {
        await cookies.reload(); // pull the freshly Set-Cookie'd MUSIC_U into cache
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('NeteaseApi.refreshSession failed: $e');
      return false;
    }
  }

  /// Lower-level weapi POST: encrypts [payload] (+ csrf), POSTs, and returns the
  /// decoded body WITHOUT inspecting its `code`. Only throws
  /// [NeteaseApiException] on a transport error (DioException). Callers that want
  /// the `code != 200` guard use [postWeapi]; callers that must read an
  /// error-coded body themselves (e.g. [accountProfile], which treats a
  /// login-required body as a clean "not logged in" rather than a throw) use this.
  Future<Map<String, dynamic>> _postWeapiRaw(
    String path,
    Map<String, dynamic> payload, {
    bool needsCsrf = true,
  }) async {
    final Map<String, dynamic> body = Map<String, dynamic>.from(payload);
    final String csrf = cookies.csrf ?? '';
    if (needsCsrf) {
      body['csrf_token'] = csrf;
    }
    final WeapiPayload enc = crypto.weapi(body);
    try {
      final Response<dynamic> resp = await dio.post<dynamic>(
        path,
        data: enc.toForm(),
        queryParameters:
            needsCsrf ? <String, dynamic>{'csrf_token': csrf} : null,
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
      return _decode(resp.data);
    } on DioException catch (e) {
      throw NeteaseApiException(
        e.message ?? 'Network error',
        statusCode: e.response?.statusCode,
      );
    }
  }

  /// Low-level eapi POST: eapi-encrypts [payload] for [apiPath] (the path
  /// WITHOUT the `/eapi` prefix), POSTs `params=<hex>` (form-encoded) to the
  /// absolute [url] with [NeteaseEndpoints.eapiHeaders], and returns the decoded
  /// body. The shared [CookieManager] still attaches `MUSIC_U` / `__csrf` —
  /// the auth cookies are scoped to `.music.163.com`, which covers
  /// `interface.music.163.com`. Throws [NeteaseApiException] on a transport
  /// error (DioException).
  Future<Map<String, dynamic>> _postEapi(
    String url,
    String apiPath,
    Map<String, dynamic> payload,
  ) async {
    final String params = crypto.eapi(apiPath, payload);
    try {
      final Response<dynamic> resp = await dio.post<dynamic>(
        url,
        data: <String, dynamic>{'params': params},
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          headers: NeteaseEndpoints.eapiHeaders,
        ),
      );
      return _decode(resp.data);
    } on DioException catch (e) {
      throw NeteaseApiException(
        e.message ?? 'Network error',
        statusCode: e.response?.statusCode,
      );
    }
  }

  @override
  Future<SearchResult> search({
    required String keyword,
    SearchType type = SearchType.song,
    int limit = 30,
    int offset = 0,
  }) async {
    final Map<String, dynamic> res =
        await postWeapi(NeteaseEndpoints.search, <String, dynamic>{
      's': keyword,
      'type': type.code,
      'limit': limit,
      'offset': offset,
      'total': offset == 0,
    });
    final dynamic result = res['result'];
    if (result is! Map) return SearchResult.empty(type);
    return SearchResult.fromJson(Map<String, dynamic>.from(result), type);
  }

  Future<Song?> songDetail(int id) async {
    final List<Song> songs = await songDetails(<int>[id]);
    return songs.isEmpty ? null : songs.first;
  }

  Future<List<Song>> songDetails(List<int> ids) async {
    if (ids.isEmpty) return <Song>[];
    // `c` is a JSON STRING nested inside the payload map (double encoding).
    final String c = jsonEncode(
      ids.map((int id) => <String, String>{'id': id.toString()}).toList(),
    );
    final Map<String, dynamic> res = await postWeapi(
      NeteaseEndpoints.songDetail,
      <String, dynamic>{'c': c},
    );
    final dynamic songsJson = res['songs'];
    if (songsJson is! List) return <Song>[];
    final dynamic privs = res['privileges'];
    final List<dynamic> privList = privs is List ? privs : const <dynamic>[];
    final List<Song> out = <Song>[];
    for (int i = 0; i < songsJson.length; i++) {
      final dynamic s = songsJson[i];
      if (s is! Map) continue;
      final Map<String, dynamic> m = Map<String, dynamic>.from(s);
      if (m['privilege'] == null && i < privList.length && privList[i] is Map) {
        m['privilege'] = privList[i];
      }
      out.add(Song.fromDetailJson(m));
    }
    return out;
  }

  @override
  Future<PlayUrl?> songUrl(Song song, {AudioLevel level = AudioLevel.exhigh}) async {
    // Quality fallback: a non-VIP track frequently has no url at the requested
    // level but resolves at a lower one. Try the requested level, then descend
    // (exhigh → higher → standard); return null only when every level is empty
    // (genuinely VIP / unavailable).
    for (final AudioLevel lvl in _songUrlFallbackLevels(level)) {
      try {
        final Map<String, dynamic> res =
            await postWeapi(NeteaseEndpoints.songUrl, <String, dynamic>{
          'ids': '[${song.id}]', // bracketed STRING, not a JSON array
          'level': lvl.apiValue,
          'encodeType': lvl.encodeType,
        });
        final dynamic data = res['data'];
        if (data is List && data.isNotEmpty && data.first is Map) {
          final Map<String, dynamic> first =
              Map<String, dynamic>.from(data.first as Map);
          final dynamic url = first['url'];
          if (url is String && url.isNotEmpty) {
            return PlayUrl.fromJson(first, lvl);
          }
        }
      } on NeteaseApiException catch (e) {
        // A coded failure at one level shouldn't abort the fallback chain.
        debugPrint('songUrl level ${lvl.name} failed for ${song.id}: $e');
      }
    }
    // Last resort (WYmusic §3.3): the desktop DOWNLOAD endpoint sometimes yields a
    // URL when the streaming player-url endpoint returns none. One extra request.
    return _downloadUrl(song, level);
  }

  /// WYmusic §3.3 `song/enhance/download/url`: a single-bitrate DOWNLOAD link, used
  /// as a last-resort PLAYBACK source when the streaming player-url endpoint gives
  /// nothing. Its `data` is a single object with no `id` field, so the song id is
  /// stamped in. Returns null on any coded / empty result.
  Future<PlayUrl?> _downloadUrl(Song song, AudioLevel level) async {
    try {
      final Map<String, dynamic> res =
          await postWeapi(NeteaseEndpoints.downloadUrl, <String, dynamic>{
        'id': '${song.id}',
        'br': level.downloadBr,
      });
      final dynamic data = res['data'];
      if (data is Map) {
        final Map<String, dynamic> m = Map<String, dynamic>.from(data);
        final dynamic url = m['url'];
        if (url is String && url.isNotEmpty) {
          m['id'] = song.id; // the download endpoint omits the id
          return PlayUrl.fromJson(m, level);
        }
      }
    } on NeteaseApiException catch (e) {
      debugPrint('downloadUrl failed for ${song.id}: $e');
    }
    return null;
  }

  /// The level chain [songUrl] walks: the requested level first, then every
  /// strictly lower-quality level in descending order (more likely to be free).
  List<AudioLevel> _songUrlFallbackLevels(AudioLevel requested) {
    const List<AudioLevel> descending = <AudioLevel>[
      AudioLevel.hires,
      AudioLevel.lossless,
      AudioLevel.exhigh,
      AudioLevel.higher,
      AudioLevel.standard,
    ];
    final List<AudioLevel> out = <AudioLevel>[requested];
    for (final AudioLevel l in descending) {
      if (l.index < requested.index) out.add(l);
    }
    return out;
  }

  @override
  Future<Lyrics> lyric(Song song) async {
    // YRC-first: the desktop eapi endpoint returns word-by-word `yrc.lyric`
    // (parsed by Lyrics.parse(klyric:)). Fall back to the legacy weapi LRC when
    // eapi fails, comes back non-200, or parses to nothing (instrumental / no
    // word timings).
    try {
      final Map<String, dynamic> res = await _postEapi(
        NeteaseEndpoints.eapiLyricUrl,
        NeteaseEndpoints.eapiLyricPath,
        <String, dynamic>{
          'id': song.id.toString(),
          'cp': false,
          'tv': 0,
          'lv': 0,
          'rv': 0,
          'kv': 0,
          'yv': 0,
          'ytv': 0,
          'yrv': 0,
        },
      );
      if ((res['code'] as num?)?.toInt() == 200) {
        final String? yrc = (res['yrc'] as Map?)?['lyric'] as String?;
        final String? lrc = (res['lrc'] as Map?)?['lyric'] as String?;
        final String? tlyric = (res['tlyric'] as Map?)?['lyric'] as String?;
        final Lyrics parsed =
            Lyrics.parse(klyric: yrc, lrc: lrc, tlyric: tlyric);
        if (parsed.lines.isNotEmpty) return parsed;
      }
    } catch (e) {
      debugPrint('eapi YRC lyric failed for ${song.id}, falling back: $e');
    }
    return _weapiLyric(song);
  }

  /// Legacy weapi LRC lyric (the pre-YRC path), kept as the fallback for
  /// [lyric] when the eapi YRC fetch fails or yields nothing.
  Future<Lyrics> _weapiLyric(Song song) async {
    final Map<String, dynamic> res =
        await postWeapi(NeteaseEndpoints.lyric, <String, dynamic>{
      'id': song.id,
      'lv': -1,
      'kv': -1,
      'tv': -1,
    });
    final String? lrc = (res['lrc'] as Map?)?['lyric'] as String?;
    final String? tlyric = (res['tlyric'] as Map?)?['lyric'] as String?;
    final String? klyric = (res['klyric'] as Map?)?['lyric'] as String?;
    return Lyrics.parse(lrc: lrc, tlyric: tlyric, klyric: klyric);
  }

  @override
  Future<List<Playlist>> personalizedPlaylists({int limit = 12}) async {
    final Map<String, dynamic> res =
        await postWeapi(NeteaseEndpoints.personalized, <String, dynamic>{
      'limit': limit,
      'total': true,
      'n': 1000,
    });
    final dynamic result = res['result'];
    if (result is! List) return <Playlist>[];
    return result
        .whereType<Map>()
        .map((e) => Playlist.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  @override
  Future<List<Song>> recommendedSongs({int limit = 8}) async {
    final List<Playlist> playlists = await personalizedPlaylists(limit: 6);
    for (final Playlist p in playlists.take(3)) {
      try {
        // Lite fetch (inline tracks only, no full batch fill) — recommendedSongs
        // only needs a handful, so don't pay to realize a 1000-track playlist.
        final Playlist detail = await _fetchPlaylist(p.id, fetchAll: false);
        if (detail.tracks.length >= 4) {
          return detail.tracks.take(limit).toList();
        }
      } catch (e) {
        // Best-effort: a playlist without inline tracks just gets skipped.
      }
    }
    return const <Song>[];
  }

  @override
  Future<Playlist> playlistDetail(int id) => _fetchPlaylist(id, fetchAll: true);

  /// Fetches v6/playlist/detail and assembles the playlist. With [fetchAll] the
  /// FULL ordered `trackIds` list is realized: ids missing from the inline
  /// `tracks` are batch-fetched (500 per call, sequential, isolated per batch via
  /// try/catch) through [songDetails], and the result is ordered to match
  /// `trackIds`. Without [fetchAll] only the inline tracks are parsed (cheap).
  /// Mirrors playlist.py:parse_playlist_detail + fetch_songs_batch.
  Future<Playlist> _fetchPlaylist(int id, {required bool fetchAll}) async {
    final Map<String, dynamic> res =
        await postWeapi(NeteaseEndpoints.playlistDetail, <String, dynamic>{
      'id': id,
      'n': 100000,
      's': 8,
    });
    final dynamic plRaw = res['playlist'];
    if (plRaw is! Map) {
      throw NeteaseApiException('Playlist $id not found');
    }
    final Map<String, dynamic> pl = Map<String, dynamic>.from(plRaw);
    // Metadata + the inline track subset (cover/creator/desc/playCount/trackCount).
    final Playlist meta = Playlist.fromJson(pl);

    // The full, ordered id list — each entry is `{id: ...}` (or, defensively, a
    // bare id). Absent for some shapes → fall back to the inline tracks we got.
    final dynamic trackIdsRaw = pl['trackIds'];
    if (trackIdsRaw is! List || trackIdsRaw.isEmpty) {
      return meta;
    }
    final List<int> orderedIds = <int>[];
    for (final dynamic t in trackIdsRaw) {
      final int sid = t is Map ? (_readInt(t['id']) ?? 0) : (_readInt(t) ?? 0);
      if (sid != 0) orderedIds.add(sid);
    }

    // Index the inline tracks by id, then (when fetchAll) batch-fetch the rest.
    final Map<int, Song> byId = <int, Song>{
      for (final Song s in meta.tracks) s.id: s,
    };

    if (fetchAll) {
      final List<int> missing =
          orderedIds.where((int sid) => !byId.containsKey(sid)).toList();
      const int batchSize = 500;
      for (int i = 0; i < missing.length; i += batchSize) {
        final int end =
            (i + batchSize < missing.length) ? i + batchSize : missing.length;
        try {
          final List<Song> songs = await songDetails(missing.sublist(i, end));
          for (final Song s in songs) {
            byId[s.id] = s;
          }
        } catch (e) {
          // One bad batch shouldn't sink the whole playlist; skip and continue.
          debugPrint('playlistDetail $id batch @$i failed: $e');
        }
      }
    }

    // Assemble in trackIds order, dropping any ids we couldn't resolve.
    final List<Song> ordered = <Song>[];
    for (final int sid in orderedIds) {
      final Song? s = byId[sid];
      if (s != null) ordered.add(s);
    }

    return meta.copyWith(
      tracks: ordered,
      trackCount: meta.trackCount > 0 ? meta.trackCount : ordered.length,
    );
  }

  /// The login-correlation headers NetEase uses to tie the phone scan to the
  /// polling client (ports `login.py:login_headers`). Sent on BOTH the unikey
  /// request and every poll, all carrying the SAME [chainId]. The browser UA /
  /// origin / referer / `x-os` come from [WeapiInterceptor] (per-request
  /// `putIfAbsent` leaves these untouched).
  Map<String, String> _qrLoginHeaders(String chainId) => <String, String>{
        'x-loginmethod': 'QrCode',
        'x-login-chain-id': chainId,
        'x-channelsource': 'undefined',
      };

  Future<QrCreateResult> qrCreate() async {
    // Stable, persisted sDeviceId (the jar carries it on every request via the
    // CookieManager) → the chainId embeds it and is reused for the WHOLE session.
    final String id = await cookies.ensureDeviceId();
    final int epoch = DateTime.now().millisecondsSinceEpoch;
    _qrChainId = 'v1_${id}_web_login_$epoch';
    _qrYdToken = _randomDeviceToken();
    // POST the unikey directly (not via postWeapi) so the login headers ride
    // along with the weapi-encrypted {type:1} body — no csrf for this endpoint.
    final WeapiPayload enc = crypto.weapi(<String, dynamic>{'type': 1});
    try {
      final Response<dynamic> resp = await dio.post<dynamic>(
        NeteaseEndpoints.qrUnikey,
        data: enc.toForm(),
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          headers: _qrLoginHeaders(_qrChainId!),
        ),
      );
      final Map<String, dynamic> map = _decode(resp.data);
      final String? unikey =
          (map['unikey'] ?? (map['data'] as Map?)?['unikey']) as String?;
      if (unikey == null || unikey.isEmpty) {
        throw NeteaseApiException('Failed to create QR unikey');
      }
      final String qrContent =
          'https://music.163.com/st/platform/scanlogin?codekey=$unikey'
          '&chainId=${_qrChainId!}&hdw_device=web&hdw_appid=web&hitExp=1';
      return QrCreateResult(uniKey: unikey, qrContent: qrContent);
    } on DioException catch (e) {
      throw NeteaseApiException(
        e.message ?? 'Failed to create QR unikey',
        statusCode: e.response?.statusCode,
      );
    }
  }

  /// One poll of the QR session. On code 803 the auth cookies arrive via
  /// Set-Cookie response headers, captured into [cookies].
  Future<QrPollResult> qrPoll(String uniKey) async {
    final WeapiPayload enc = crypto.weapi(<String, dynamic>{
      'type': 1,
      'noCheckToken': true,
      'key': uniKey,
      // ONE ydDeviceToken per session (minted in qrCreate); fall back only if a
      // poll somehow precedes a create.
      'ydDeviceToken': _qrYdToken ?? _randomDeviceToken(),
    });
    try {
      final Response<dynamic> resp = await dio.post<dynamic>(
        NeteaseEndpoints.qrLogin,
        data: enc.toForm(),
        // Same login headers + SAME chainId as the unikey request and QR URL.
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          headers: _qrLoginHeaders(_qrChainId ?? ''),
        ),
      );
      final Map<String, dynamic> map = _decode(resp.data);
      final int code = (map['code'] as num?)?.toInt() ?? -1;
      final String? message = (map['message'] ?? map['nickname']) as String?;
      if (code == 803) {
        final List<String> setCookies =
            resp.headers.map['set-cookie'] ?? <String>[];
        await cookies.saveFromSetCookie(setCookies);
        return QrPollResult(
          status: QrStatus.authorized,
          code: code,
          musicU: cookies.musicU,
          csrf: cookies.csrf,
          message: message,
        );
      }
      return QrPollResult(
        status: QrPollResult.statusFromCode(code),
        code: code,
        message: message,
      );
    } on DioException catch (e) {
      throw NeteaseApiException(
        e.message ?? 'QR poll failed',
        statusCode: e.response?.statusCode,
      );
    }
  }

  /// Fetches the signed-in account/profile.
  ///
  /// Returns a [NeteaseAccount] when the body carries a real uid
  /// (`profile.userId` or `account.id`); returns null for a clean "not logged in"
  /// (a 200 body with null profile, or a login-required error code — both arrive
  /// as a normal body via [_postWeapiRaw], NOT a throw). A transport/network
  /// error PROPAGATES (rethrows) so callers can tell "definitely logged out" from
  /// "couldn't check right now".
  Future<NeteaseAccount?> accountProfile() async {
    final Map<String, dynamic> res =
        await _postWeapiRaw(NeteaseEndpoints.account, <String, dynamic>{});
    final dynamic profile = res['profile'];
    final dynamic account = res['account'];
    int? uid = profile is Map ? _readInt(profile['userId']) : null;
    uid ??= account is Map ? _readInt(account['id']) : null;
    if (uid == null || uid <= 0) return null;
    _cachedUid = uid;
    final Map<String, dynamic> p = profile is Map
        ? Map<String, dynamic>.from(profile)
        : <String, dynamic>{};
    return NeteaseAccount(
      uid: uid,
      nickname: (p['nickname'] as String?) ?? '',
      avatarUrl: httpsImageUrl(p['avatarUrl']),
      vipType: _readInt(p['vipType']) ?? 0,
    );
  }

  /// Server-confirmed login check. `true` when a real account/profile is present,
  /// `false` for a clean not-logged-in. A transient/network error is NOT treated
  /// as a logout — it propagates (via [accountProfile]) so the caller can keep
  /// the cookie-based truth.
  Future<bool> accountStatus() async => (await accountProfile()) != null;

  @override
  Future<List<Playlist>> userPlaylists({int limit = 30, int offset = 0}) async {
    int? uid = _cachedUid;
    if (uid == null) {
      final NeteaseAccount? acc = await accountProfile();
      uid = acc?.uid;
    }
    if (uid == null) return <Playlist>[];
    final Map<String, dynamic> res =
        await postWeapi(NeteaseEndpoints.userPlaylist, <String, dynamic>{
      'uid': uid,
      'limit': limit,
      'offset': offset,
    });
    final dynamic pl = res['playlist'];
    if (pl is! List) return <Playlist>[];
    return pl
        .whereType<Map>()
        .map((e) => Playlist.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  @override
  Future<List<Playlist>> dailyRecommendPlaylists({int limit = 30}) async {
    // Daily recommend requires login; an anonymous call comes back as a
    // login-required (non-200) body → postWeapi throws → degrade to empty.
    try {
      final Map<String, dynamic> res = await postWeapi(
        NeteaseEndpoints.recommendResource,
        const <String, dynamic>{},
      );
      final dynamic recommend = res['recommend'];
      if (recommend is! List) return const <Playlist>[];
      return recommend
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .where((Map<String, dynamic> m) => (_readInt(m['type']) ?? 1) == 1)
          .map((Map<String, dynamic> m) => Playlist.fromJson(m))
          .take(limit)
          .toList();
    } on NeteaseApiException {
      return const <Playlist>[];
    }
  }

  @override
  Future<List<Song>> dailyRecommendSongs({int limit = 30}) async {
    try {
      final Map<String, dynamic> res = await postWeapi(
        NeteaseEndpoints.recommendSongs,
        const <String, dynamic>{},
      );
      // The `v1` endpoint returns the songs under a top-level `recommend` list;
      // only the newer `v3` shape nests them under `data.dailySongs`. Try the v3
      // shape first, then fall back to `recommend` — mirrors
      // recommend.py:parse_recommend_songs. Without this fallback the v1 endpoint
      // always parsed to empty, so the 每日推荐 home section never appeared.
      final dynamic data = res['data'];
      dynamic daily = data is Map ? data['dailySongs'] : null;
      if (daily is! List || daily.isEmpty) {
        final dynamic rec = res['recommend'];
        if (rec is List && rec.isNotEmpty) daily = rec;
      }
      if (daily is! List) return const <Song>[];
      return daily
          .whereType<Map>()
          .map((e) => Song.fromDetailJson(Map<String, dynamic>.from(e)))
          .take(limit)
          .toList();
    } on NeteaseApiException {
      return const <Song>[];
    }
  }

  @override
  Future<int> createPlaylist(String name, {int privacy = 0}) async {
    final Map<String, dynamic> res =
        await postWeapi(NeteaseEndpoints.playlistCreate, <String, dynamic>{
      'name': name,
      'privacy': privacy,
    });
    final dynamic pl = res['playlist'];
    final int? id = pl is Map ? _readInt(pl['id']) : _readInt(res['id']);
    if (id == null || id <= 0) {
      throw NeteaseApiException('Create playlist returned no id');
    }
    return id;
  }

  @override
  Future<void> deletePlaylist(int pid) async {
    await postWeapi(NeteaseEndpoints.playlistDelete, <String, dynamic>{
      'pid': pid.toString(),
    });
  }

  @override
  Future<void> addTracksToPlaylist(int pid, List<int> ids) =>
      _manipulateTracks('add', pid, ids);

  @override
  Future<void> removeTracksFromPlaylist(int pid, List<int> ids) =>
      _manipulateTracks('del', pid, ids);

  /// add/del tracks on a playlist (`/weapi/playlist/manipulate/tracks`). No-op
  /// when [ids] is empty. `trackIds` is a JSON STRING of stringified ids
  /// (double-encoded), verbatim from `playlist.py:playlist_tracks`.
  Future<void> _manipulateTracks(String op, int pid, List<int> ids) async {
    if (ids.isEmpty) return;
    await postWeapi(NeteaseEndpoints.playlistTracks, <String, dynamic>{
      'op': op,
      'pid': pid.toString(),
      'trackIds': jsonEncode(ids.map((int e) => e.toString()).toList()),
    });
  }

  @override
  Future<void> collectPlaylist(int id, bool collect) async {
    await postWeapi(NeteaseEndpoints.playlistSubscribe, <String, dynamic>{
      'id': id.toString(),
      't': collect ? 1 : 2,
    });
  }

  Map<String, dynamic> _decode(dynamic data) {
    if (data is Map) return Map<String, dynamic>.from(data);
    if (data is String && data.isNotEmpty) {
      final dynamic d = jsonDecode(data);
      if (d is Map) return Map<String, dynamic>.from(d);
    }
    throw NeteaseApiException('Unexpected response shape');
  }

  String _randomDeviceToken() {
    final List<int> bytes =
        List<int>.generate(24, (_) => _random.nextInt(256));
    return base64.encode(bytes);
  }
}

/// Lenient int parse (num / int-ish String) → null when absent/unparseable.
int? _readInt(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim());
  return null;
}
