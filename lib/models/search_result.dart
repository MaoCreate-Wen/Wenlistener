import 'album.dart';
import 'artist.dart';
import 'playlist.dart';
import 'song.dart';

/// Cloudsearch result category. [code] is the wire `type` value.
enum SearchType { song, album, artist, playlist, lyric, comprehensive }

extension SearchTypeX on SearchType {
  int get code {
    switch (this) {
      case SearchType.song:
        return 1;
      case SearchType.album:
        return 10;
      case SearchType.artist:
        return 100;
      case SearchType.playlist:
        return 1000;
      case SearchType.lyric:
        return 1006;
      case SearchType.comprehensive:
        return 1018;
    }
  }

  String get label {
    switch (this) {
      case SearchType.song:
        return 'Songs';
      case SearchType.album:
        return 'Albums';
      case SearchType.artist:
        return 'Artists';
      case SearchType.playlist:
        return 'Playlists';
      case SearchType.lyric:
        return 'Lyrics';
      case SearchType.comprehensive:
        return 'All';
    }
  }
}

/// A page of search results for one [SearchType].
class SearchResult {
  final SearchType type;
  final List<Song> songs;
  final List<Album> albums;
  final List<Artist> artists;
  final List<Playlist> playlists;
  final int total;
  final bool hasMore;

  const SearchResult({
    required this.type,
    this.songs = const <Song>[],
    this.albums = const <Album>[],
    this.artists = const <Artist>[],
    this.playlists = const <Playlist>[],
    this.total = 0,
    this.hasMore = false,
  });

  factory SearchResult.fromJson(Map<String, dynamic> json, SearchType type) {
    List<T> parse<T>(String key, T Function(Map<String, dynamic>) fromJson) {
      final dynamic raw = json[key];
      if (raw is! List) return <T>[];
      return raw
          .whereType<Map>()
          .map((e) => fromJson(Map<String, dynamic>.from(e)))
          .toList();
    }

    final songs = parse<Song>('songs', Song.fromSearchJson);
    final albums = parse<Album>('albums', Album.fromJson);
    final artists = parse<Artist>('artists', Artist.fromJson);
    final playlists = parse<Playlist>('playlists', Playlist.fromJson);
    final total = _int(json['songCount'] ??
        json['albumCount'] ??
        json['artistCount'] ??
        json['playlistCount'] ??
        0);
    final loaded =
        songs.length + albums.length + artists.length + playlists.length;
    return SearchResult(
      type: type,
      songs: songs,
      albums: albums,
      artists: artists,
      playlists: playlists,
      total: total,
      hasMore: total > loaded,
    );
  }

  static SearchResult empty([SearchType type = SearchType.song]) =>
      SearchResult(type: type);
}

int _int(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}
