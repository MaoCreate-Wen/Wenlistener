import 'dart:io';

import '../models/lyric_line.dart';
import '../models/play_url.dart';
import '../models/playlist.dart';
import '../models/search_result.dart';
import '../models/song.dart';
import 'music_api.dart';

class LocalMusicApiException implements Exception {
  final String message;
  LocalMusicApiException(this.message);
  @override
  String toString() => 'LocalMusicApiException: $message';
}

/// Backend for LOCAL, on-device music imported by the user ([MusicSource.local]).
/// There is nothing to fetch over the network: [songUrl] turns the stored file
/// path into a `file://` URL that [ResolvingAudioSource] reads straight off disk,
/// and [lyric] looks for a sidecar `.lrc` next to the audio file. Everything else
/// (search / feeds / playlist management) is empty/unsupported — local files only
/// ever live inside a 共同歌单 the user built.
class LocalMusicApi implements MusicApi {
  const LocalMusicApi();

  @override
  Future<PlayUrl?> songUrl(Song song, {AudioLevel level = AudioLevel.exhigh}) async {
    final String path = song.ref['path'] ?? '';
    if (path.isEmpty) return null;
    // Missing file (moved/deleted since import) → null so the queue skips it.
    if (!await File(path).exists()) return null;
    return PlayUrl(
      id: song.id,
      url: Uri.file(path).toString(),
      br: 0,
      type: _ext(path),
      size: 0,
      level: level,
    );
  }

  @override
  Future<Lyrics> lyric(Song song) async {
    final String path = song.ref['path'] ?? '';
    if (path.isEmpty) return Lyrics.empty;
    // Sidecar lyric: same path with the audio extension swapped for `.lrc`.
    final int dot = path.lastIndexOf('.');
    if (dot <= 0) return Lyrics.empty;
    final File lrc = File('${path.substring(0, dot)}.lrc');
    try {
      if (!await lrc.exists()) return Lyrics.empty;
      final String text = await lrc.readAsString();
      if (text.trim().isEmpty) return Lyrics.empty;
      return Lyrics.parse(lrc: text);
    } catch (_) {
      return Lyrics.empty;
    }
  }

  static String _ext(String path) {
    final int dot = path.lastIndexOf('.');
    if (dot < 0 || dot == path.length - 1) return 'mp3';
    return path.substring(dot + 1).toLowerCase();
  }

  // --- everything else: not applicable to local files ----------------------

  @override
  Future<SearchResult> search({
    required String keyword,
    SearchType type = SearchType.song,
    int limit = 30,
    int offset = 0,
  }) async =>
      SearchResult.empty(type);

  @override
  Future<List<Playlist>> personalizedPlaylists({int limit = 12}) async =>
      const <Playlist>[];

  @override
  Future<List<Song>> recommendedSongs({int limit = 8}) async => const <Song>[];

  @override
  Future<Playlist> playlistDetail(int id) =>
      throw LocalMusicApiException('local music has no playlists');

  // 本地源无专辑概念；返回空(不抛)。类是 const 构造，异步方法体不影响 const-ness。
  @override
  Future<Playlist> albumDetail(int id) async =>
      Playlist(id: id, name: '专辑', tracks: const <Song>[]);

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
  Future<int> createPlaylist(String name, {int privacy = 0}) =>
      throw LocalMusicApiException('local music has no playlists');

  @override
  Future<void> deletePlaylist(int pid) =>
      throw LocalMusicApiException('local music has no playlists');

  @override
  Future<void> addTracksToPlaylist(int pid, List<int> ids) =>
      throw LocalMusicApiException('local music has no playlists');

  @override
  Future<void> removeTracksFromPlaylist(int pid, List<int> ids) =>
      throw LocalMusicApiException('local music has no playlists');

  @override
  Future<void> collectPlaylist(int id, bool collect) =>
      throw LocalMusicApiException('local music has no playlists');
}
