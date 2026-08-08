import '../models/lyric_line.dart';
import '../models/play_url.dart';
import '../models/playlist.dart';
import '../models/search_result.dart';
import '../models/song.dart';

/// The backend-agnostic music interface the providers/audio service talk to.
/// Implemented by both [NeteaseApi] and `MiguApi`, and multiplexed by
/// `MusicApiRouter` (default Migu, switches to Netease on login).
///
/// Play/lyric take the whole [Song] (not a bare int id) so each backend can read
/// its own identifiers — Netease uses [Song.id]; Migu uses [Song.ref].
abstract interface class MusicApi {
  Future<SearchResult> search({
    required String keyword,
    SearchType type,
    int limit,
    int offset,
  });

  Future<PlayUrl?> songUrl(Song song, {AudioLevel level});

  Future<Lyrics> lyric(Song song);

  /// Discovery carousels for the home feed (empty when the backend has none).
  Future<List<Playlist>> personalizedPlaylists({int limit});

  /// Songs for the home "推荐歌曲" grid (Netease: from a recommended playlist;
  /// Migu: a hot/popular search).
  Future<List<Song>> recommendedSongs({int limit});

  /// Full playlist detail incl. tracks (Netease only; Migu throws).
  Future<Playlist> playlistDetail(int id);

  /// Full album detail incl. tracks. Only kugougn implements it for real
  /// (via `get_special_detail(is_album=True)`); every other backend returns an
  /// empty [Playlist] (never throws) so opening one of their album cards
  /// degrades gracefully instead of erroring.
  Future<Playlist> albumDetail(int id);

  /// Logged-in user's own/created/subscribed playlists (NetEase only;
  /// Migu → empty).
  Future<List<Playlist>> userPlaylists({int limit, int offset});

  /// NetEase daily-recommended songs (每日推荐歌曲). Requires login; the
  /// anonymous/Migu backend returns const [] (never throws).
  Future<List<Song>> dailyRecommendSongs({int limit});

  /// NetEase daily-recommended playlists (每日推荐歌单). Requires login; the
  /// anonymous/Migu backend returns const [] (never throws).
  Future<List<Playlist>> dailyRecommendPlaylists({int limit});

  // --- playlist management (NetEase only; Migu throws) ---------------------

  /// Creates a new playlist named [name] and returns its id.
  Future<int> createPlaylist(String name, {int privacy});

  /// Deletes the playlist [pid].
  Future<void> deletePlaylist(int pid);

  /// Adds song [ids] to playlist [pid] (no-op when [ids] is empty).
  Future<void> addTracksToPlaylist(int pid, List<int> ids);

  /// Removes song [ids] from playlist [pid] (no-op when [ids] is empty).
  Future<void> removeTracksFromPlaylist(int pid, List<int> ids);

  /// Subscribes ([collect] true) / unsubscribes ([collect] false) playlist [id].
  Future<void> collectPlaylist(int id, bool collect);
}
