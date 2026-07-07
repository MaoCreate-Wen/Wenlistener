import 'image_url.dart';
import 'song.dart';

/// A playlist. [fromJson] handles both the personalized-feed shape
/// (`picUrl`, `copywriter`, `trackCount`) and the detail shape
/// (`coverImgUrl`, `creator.nickname`, `description`, `tracks[]`).
class Playlist {
  final int id;
  final String name;
  final String? coverUrl;
  final String? creatorName;
  final String? description;
  final int trackCount;

  /// Total play count (`playCount`); 0 when the shape doesn't carry it.
  final int playCount;

  /// Whether the signed-in user has subscribed/collected this playlist
  /// (`subscribed`); only meaningful in the user-playlist shape.
  final bool subscribed;

  /// Recommend algorithm tag (`alg`, e.g. "alg_mgc_red"); null when absent.
  final String? alg;

  final List<Song> tracks;

  const Playlist({
    required this.id,
    required this.name,
    this.coverUrl,
    this.creatorName,
    this.description,
    this.trackCount = 0,
    this.playCount = 0,
    this.subscribed = false,
    this.alg,
    this.tracks = const <Song>[],
  });

  factory Playlist.fromJson(Map<String, dynamic> json) {
    final dynamic creator = json['creator'];
    final dynamic rawTracks = json['tracks'];
    final List<Song> tracks = rawTracks is List
        ? rawTracks
            .whereType<Map>()
            .map((e) => Song.fromDetailJson(Map<String, dynamic>.from(e)))
            .toList()
        : <Song>[];
    return Playlist(
      id: _int(json['id']),
      name: _str(json['name']),
      coverUrl: httpsImageUrl(
          json['coverImgUrl'] ?? json['picUrl'] ?? json['coverUrl']),
      creatorName: creator is Map
          ? creator['nickname'] as String?
          : json['creatorName'] as String?,
      description: (json['description'] ?? json['copywriter']) as String?,
      trackCount: _int(json['trackCount'] ?? tracks.length),
      playCount: _int(json['playCount'] ?? json['playcount']),
      subscribed: json['subscribed'] == true,
      alg: json['alg'] as String?,
      tracks: tracks,
    );
  }

  Playlist copyWith({
    List<Song>? tracks,
    int? trackCount,
    int? playCount,
    String? alg,
  }) =>
      Playlist(
        id: id,
        name: name,
        coverUrl: coverUrl,
        creatorName: creatorName,
        description: description,
        trackCount: trackCount ?? this.trackCount,
        playCount: playCount ?? this.playCount,
        subscribed: subscribed,
        alg: alg ?? this.alg,
        tracks: tracks ?? this.tracks,
      );
}

int _int(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}

String _str(dynamic v) => v?.toString() ?? '';
