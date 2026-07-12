import 'playlist.dart';
import 'song.dart';

/// Kind of discovery-feed section (drives which renderer the home page uses).
enum HomeSectionKind {
  playlistCarousel,
  albumCarousel,
  recommendedGrid,
  dailySongs,
}

/// One section of the home / discovery feed.
class HomeSection {
  final String title;
  final HomeSectionKind kind;
  final List<Playlist> playlists;
  final List<Song> songs;

  /// Optional muted line shown under the title (e.g. the daily-recommend
  /// tagline). Null for sections that show only a title.
  final String? subtitle;

  const HomeSection({
    required this.title,
    required this.kind,
    this.playlists = const <Playlist>[],
    this.songs = const <Song>[],
    this.subtitle,
  });
}
