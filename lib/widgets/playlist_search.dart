import '../models/song.dart';

/// Fixed row height of a [SongTile]-based playlist row: the leading artwork
/// (`AppDimens.tileArtwork` = 56) plus [SongTile]'s vertical padding
/// (`space8` × 2 = 16) = 72. The 56px artwork dominates the single-line
/// title/artist column, so the row height is deterministic.
///
/// Used both as the `itemExtent` of the track list (so it can be virtualized
/// with exact geometry) AND in the "定位/locate" scroll-offset math on the main
/// playlist page and the local 共同歌单 page — both lead with the 56px artwork,
/// so the extent is identical. **Bump this if [SongTile] ever grows a taller
/// second line**, or the list will clip and locate will land slightly off.
const double kPlaylistRowExtent = 72;

/// Case-insensitive in-playlist match on a song's name OR artist(s). Empty query
/// matches everything. The single place to extend matching later (e.g. pinyin
/// initials); today it's a plain substring test on `name` + `artistNames`.
bool songMatchesQuery(Song song, String query) {
  final String q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  return song.name.toLowerCase().contains(q) ||
      song.artistNames.toLowerCase().contains(q);
}
