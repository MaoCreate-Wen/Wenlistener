import 'dart:convert';

import 'package:dio/dio.dart';

import '../models/lyric_line.dart';
import '../models/play_url.dart';
import '../models/playlist.dart';
import '../models/search_result.dart';
import '../models/song.dart';
import 'music_api.dart';

class MiguApiException implements Exception {
  final String message;
  MiguApiException(this.message);
  @override
  String toString() => 'MiguApiException: $message';
}

/// Anonymous Migu (咪咕音乐) backend — no login required. Verified endpoints:
///  - search:   `pd.musicapp.migu.cn/.../content/search_all.do`
///  - play url: `app.pd.nf.migu.cn/.../content/sub/listenSong.do` → 302 to a
///              `freetyst.nf.migu.cn` mp3 (free tracks only; VIP → no Location)
///  - lyric:    the `lyricUrl` returned inline by search (plain LRC)
class MiguApi implements MusicApi {
  final Dio _dio;

  MiguApi({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 20),
              headers: const <String, String>{
                'User-Agent': 'okhttp/3.12.0',
                'channel': '0146921',
              },
            ));

  static const String _searchUrl =
      'https://pd.musicapp.migu.cn/MIGUM2.0/v1.0/content/search_all.do';
  static const String _listenUrl =
      'https://app.pd.nf.migu.cn/MIGUM2.0/v1.0/content/sub/listenSong.do';
  static const String _strategyUrl =
      'https://app.c.nf.migu.cn/MIGUM2.0/strategy/listen-url/v2.4';
  static const String _searchSwitch =
      '{"song":1,"album":0,"singer":0,"tagSong":0,"mvSong":0,"songlist":0,"bestShow":1}';

  @override
  Future<SearchResult> search({
    required String keyword,
    SearchType type = SearchType.song,
    int limit = 30,
    int offset = 0,
  }) async {
    // Migu only serves the song list here; other tabs degrade to empty.
    if (type != SearchType.song && type != SearchType.comprehensive) {
      return SearchResult.empty(type);
    }
    final int pageNo = (limit <= 0) ? 1 : (offset ~/ limit) + 1;
    try {
      final Response<dynamic> resp = await _dio.get<dynamic>(
        _searchUrl,
        queryParameters: <String, dynamic>{
          'ua': 'Android_migu',
          'version': '5.0.1',
          'text': keyword,
          'pageNo': pageNo,
          'pageSize': limit,
          'searchSwitch': _searchSwitch,
        },
      );
      final Map<String, dynamic> data = _asMap(resp.data);
      final dynamic srd = data['songResultData'];
      if (srd is! Map) return SearchResult.empty(type);
      final dynamic result = srd['result'];
      if (result is! List) return SearchResult.empty(type);
      final List<Song> songs = result
          .whereType<Map>()
          .map((e) => Song.fromMiguJson(Map<String, dynamic>.from(e)))
          .where((Song s) => s.name.isNotEmpty)
          .toList();
      final int total =
          int.tryParse('${srd['totalCount']}') ?? songs.length;
      return SearchResult(
        type: SearchType.song,
        songs: songs,
        total: total,
        hasMore: songs.isNotEmpty && (offset + songs.length) < total,
      );
    } on DioException catch (e) {
      throw MiguApiException(e.message ?? 'Migu search failed');
    }
  }

  @override
  Future<PlayUrl?> songUrl(Song song, {AudioLevel level = AudioLevel.exhigh}) async {
    final String contentId = song.ref['contentId'] ?? '';
    final String copyrightId = song.ref['copyrightId'] ?? '';
    final String resourceType = song.ref['resourceType'] ?? '2';
    if (contentId.isEmpty) return null;

    // Try descending quality; free tracks usually resolve at PQ.
    for (final String tone in const <String>['PQ', 'LQ', 'HQ', 'SQ']) {
      final String? url = await _resolveListenUrl(
        tone: tone,
        contentId: contentId,
        copyrightId: copyrightId,
        resourceType: resourceType,
      );
      if (url != null && url.isNotEmpty) {
        return PlayUrl(
          id: song.id,
          url: url,
          br: 0,
          type: 'mp3',
          size: 0,
          level: level,
        );
      }
    }

    // Free path exhausted (VIP track → no 302 Location). Fall back to the
    // strategy listen-url endpoint, which resolves a direct CDN url for VIP
    // tracks too.
    final String? strategyUrl = await _resolveStrategyUrl(song, level);
    if (strategyUrl != null && strategyUrl.isNotEmpty) {
      return PlayUrl(
        id: song.id,
        url: strategyUrl,
        br: 0,
        type: 'mp3',
        size: 0,
        level: level,
      );
    }
    return null; // VIP / not free-streamable
  }

  /// Hits listenSong.do without following the redirect and returns the `Location`
  /// (the freetyst CDN mp3). Free tracks 302; VIP tracks return a 200 JSON error
  /// (no Location) → null.
  Future<String?> _resolveListenUrl({
    required String tone,
    required String contentId,
    required String copyrightId,
    required String resourceType,
  }) async {
    try {
      final Response<dynamic> resp = await _dio.get<dynamic>(
        _listenUrl,
        queryParameters: <String, dynamic>{
          'toneFlag': tone,
          'netType': '01',
          'ua': 'Android_migu',
          'version': '5.0.1',
          'userId': '15548614588',
          'copyrightId': copyrightId,
          'contentId': contentId,
          'resourceType': resourceType,
          'channel': '0',
        },
        options: Options(
          followRedirects: false,
          validateStatus: (int? s) => s != null && s < 400,
          responseType: ResponseType.plain,
        ),
      );
      // Verified free-track path: a 302 carries the freetyst CDN url in Location.
      final String? loc = _locationOf(resp.headers);
      if (loc != null) return loc;
      // No redirect (often VIP / region-gated). Some 200 JSON bodies still carry
      // a direct streamable url — try that before giving up.
      return _directUrlOf(resp.data);
    } on DioException catch (e) {
      // A 3xx that slips past validateStatus still carries the headers.
      if (e.response == null) return null;
      final String? loc = _locationOf(e.response!.headers);
      if (loc != null) return loc;
      return _directUrlOf(e.response!.data);
    }
  }

  String? _locationOf(Headers headers) {
    final String? loc =
        headers.value('location') ?? headers.value('Location');
    if (loc == null || loc.isEmpty) return null;
    return loc;
  }

  /// Pulls a direct playable url from a listenSong.do 200 JSON body when no 302
  /// `Location` was returned. Checks top-level `url` / `androidSurl` and a nested
  /// `data.{url,androidSurl,playUrl}`. Returns null when none is present.
  String? _directUrlOf(dynamic body) {
    final Map<String, dynamic> m = _asMap(body);
    if (m.isEmpty) return null;
    for (final String key in const <String>['url', 'androidSurl']) {
      final dynamic v = m[key];
      if (v is String && v.isNotEmpty) return v;
    }
    final dynamic data = m['data'];
    if (data is Map) {
      final Map<String, dynamic> d = Map<String, dynamic>.from(data);
      for (final String key in const <String>['url', 'androidSurl', 'playUrl']) {
        final dynamic v = d[key];
        if (v is String && v.isNotEmpty) return v;
      }
    }
    return null;
  }

  /// VIP fallback: the strategy listen-url endpoint (`app.c.nf.migu.cn`), which
  /// returns a direct CDN url under `data.url`. Faithful to the verified
  /// Android-client request (testdemo data.dart `GetSongInfo`) — a single PQ
  /// attempt with the captured `sign`/`aversionid`.
  ///
  /// NOTE: Migu now rejects the static `sign` server-side (`code 201007 请求失败`),
  /// so this currently returns null for every VIP track — the endpoint needs a
  /// *dynamically computed* `sign` (the captured constant has been invalidated).
  /// Kept as a best-effort hook (it resolves the moment a valid signer exists);
  /// until then VIP Migu tracks degrade to the "unplayable" path and the robust
  /// way to a fuller catalogue is a Netease login. We make ONE bounded request
  /// (not the 4-tone loop) so a dead VIP tap doesn't stall the queue.
  Future<String?> _resolveStrategyUrl(Song song, AudioLevel level) async {
    final String albumId = song.ref['albumId'] ?? '';
    final String contentId = song.ref['contentId'] ?? '';
    final String resourceType = song.ref['resourceType'] ?? '2';
    // ref['songId'] is always present (may be empty); fall back to contentId.
    String songId = song.ref['songId'] ?? '';
    if (songId.isEmpty) songId = contentId;
    try {
      final Response<dynamic> resp = await _dio.get<dynamic>(
        _strategyUrl,
        queryParameters: <String, dynamic>{
          'albumId': albumId,
          'lowerQualityContentId': contentId,
          'netType': '01',
          'resourceType': resourceType,
          'songId': songId,
          'toneFlag': 'PQ',
        },
        options: Options(
          responseType: ResponseType.json,
          headers: _strategyHeaders(),
        ),
      );
      final Map<String, dynamic> m = _asMap(resp.data);
      final dynamic data = m['data'];
      if (data is Map) {
        final dynamic url = data['url'];
        if (url is String && url.isNotEmpty) return url;
      }
    } catch (_) {
      // Sign rejected / track genuinely unavailable → null (skip-to-playable).
    }
    return null;
  }

  /// Headers for the strategy listen-url request — verbatim from the verified
  /// Android client (testdemo data.dart) minus `Host` (dio sets it). `timestamp`
  /// is regenerated per call; `sign`/`aversionid` are the captured constants.
  Map<String, String> _strategyHeaders() => <String, String>{
        'gsm': '0',
        'randomsessionkey': '000000',
        'mgm-user-agent': 'M2011K2C',
        'User-Agent':
            'Mozilla/5.0 (Linux; U; Android 13; zh-cn; M2011K2C Build/TKQ1.220829.002) AppleWebKit/533.1 (KHTML, like Gecko) Version/5.0 Mobile Safari/533.1',
        'channel': '0146921',
        'language': 'Chinese',
        'ua': 'Android_migu',
        'mode': 'android',
        'brand': 'Xiaomi',
        'recommendstatus': '1',
        'version': '7.32.0',
        'mgm-Network-type': '04',
        'mgm-network-operators': '02',
        'mgm-Network-standard': '01',
        'Accept-Language': 'zh-CN,zh;q=0.8',
        'OAID': '1ac40da59c1bba7e',
        'platform': 'M2011K2C',
        'userLevel': '0',
        'osVersion': 'Android 13',
        'verify': 'verify',
        'logId': '1693228561702',
        'os': 'Android 13',
        'Accept-Encoding': 'gzip',
        'signVersion': 'V004',
        'sign': '16467982D356C8D2B530506D217D2AED',
        'aversionid':
            'DF948B8F98A6A68F669888A6D07C99A593988ABC999DA388639A84A1897E9D6EC598B8BD8ED3A58F63C6BCA2BAACCD769BDFD0D391A9D88E97968ED0887D9DA4C99A898DDDECEE896B93859E8A8195729394828891ECA38E6B94899F8C7E9E779B9A87',
        'timestamp': (DateTime.now().microsecondsSinceEpoch / 1000).toString(),
      };

  @override
  Future<Lyrics> lyric(Song song) async {
    final String lyricUrl = song.ref['lyricUrl'] ?? '';
    if (lyricUrl.isEmpty) return Lyrics.empty;
    try {
      final Response<dynamic> resp = await _dio.get<dynamic>(
        lyricUrl,
        options: Options(responseType: ResponseType.plain),
      );
      final String lrc = resp.data is String ? resp.data as String : '${resp.data}';
      if (lrc.trim().isEmpty) return Lyrics.empty;
      return Lyrics.parse(lrc: lrc);
    } on DioException {
      // Transient CDN/transport failure — surface it so PlayerProvider can retry
      // instead of caching it as "no lyrics". A genuinely-absent lyric is the
      // empty-`lyricUrl` / empty-`lrc` return above, which still settles cleanly.
      rethrow;
    }
  }

  @override
  Future<List<Playlist>> personalizedPlaylists({int limit = 12}) async {
    // Migu playlist plaza isn't wired; the home shows a Migu hot-songs grid via
    // [recommendedSongs] instead. Return no carousels.
    return const <Playlist>[];
  }

  @override
  Future<List<Song>> recommendedSongs({int limit = 8}) async {
    try {
      final SearchResult res = await search(
        keyword: '热门',
        type: SearchType.song,
        limit: limit,
        offset: 0,
      );
      if (res.songs.isNotEmpty) return res.songs.take(limit).toList();
      final SearchResult fallback =
          await search(keyword: '流行', type: SearchType.song, limit: limit);
      return fallback.songs.take(limit).toList();
    } catch (_) {
      return const <Song>[];
    }
  }

  @override
  Future<Playlist> playlistDetail(int id) {
    throw MiguApiException('Migu has no playlist detail support');
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

  @override
  Future<int> createPlaylist(String name, {int privacy = 0}) {
    throw MiguApiException('Migu has no playlist management');
  }

  @override
  Future<void> deletePlaylist(int pid) {
    throw MiguApiException('Migu has no playlist management');
  }

  @override
  Future<void> addTracksToPlaylist(int pid, List<int> ids) {
    throw MiguApiException('Migu has no playlist management');
  }

  @override
  Future<void> removeTracksFromPlaylist(int pid, List<int> ids) {
    throw MiguApiException('Migu has no playlist management');
  }

  @override
  Future<void> collectPlaylist(int id, bool collect) {
    throw MiguApiException('Migu has no playlist management');
  }

  Map<String, dynamic> _asMap(dynamic data) {
    if (data is Map) return Map<String, dynamic>.from(data);
    if (data is String && data.trim().isNotEmpty) {
      // Dio hands back a String if the content-type wasn't JSON.
      try {
        final dynamic d = jsonDecode(data);
        if (d is Map) return Map<String, dynamic>.from(d);
      } catch (_) {}
    }
    return <String, dynamic>{};
  }
}
