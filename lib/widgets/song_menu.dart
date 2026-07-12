import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../models/song.dart';
import '../pages/playlist/desktop_kit.dart' show dkAddToLocalPlaylist;
import '../router/routes.dart';
import '../state/player_provider.dart';
import '../state/search_provider.dart';
import 'context_menu.dart';

/// Builds the shared **PC-style** right-click / ⋯ context menu for a track
/// [song]. Centralised here so every list (home / search / library / playlist /
/// queue) that renders through [TrackRow] / [TrackTable] offers the *same*
/// actions and wiring — the single source of truth for track interaction.
///
/// Actions are wired to the existing providers only; nothing is faked:
///  - **播放** → [PlayerProvider.playSong].
///  - **添加到歌单…** → the shared 共同歌单 picker ([dkAddToLocalPlaylist]).
///  - **查看专辑 / 查看歌手** → best-effort: there are no album/artist detail
///    routes yet, so the name is run as a search and the 搜索 tab is shown.
///    Emitted only when the song actually carries that metadata.
///  - **从歌单移除** → the caller-supplied [onRemove] (playlist / queue detail
///    pages pass their own removal callback), shown only when non-null.
///
/// **Omitted on purpose:** 下一首播放 / 添加到播放队列. [PlayerProvider] and the
/// underlying `AudioService` have no in-place queue-insert primitive — the only
/// way to change the queue is [PlayerProvider.playQueue], which rebuilds the
/// audio source and restarts the current track. Emitting these would either fake
/// the behaviour or disrupt playback, so per the "omit unsupported rather than
/// fake" rule they are left out until a non-disruptive insert lands.
List<WenMenuAction> songMenuActions(
  BuildContext context,
  Song song, {
  VoidCallback? onRemove,
}) {
  final String album = song.album?.name.trim() ?? '';
  final String artist =
      song.artists.isEmpty ? '' : song.artists.first.name.trim();

  return <WenMenuAction>[
    WenMenuAction(
      label: '播放',
      icon: Icons.play_arrow_rounded,
      onSelected: () => context.read<PlayerProvider>().playSong(song),
    ),
    WenMenuAction(
      label: '添加到歌单…',
      icon: Icons.playlist_add_rounded,
      onSelected: () => dkAddToLocalPlaylist(context, song),
    ),
    if (album.isNotEmpty)
      WenMenuAction(
        label: '查看专辑',
        icon: Icons.album_outlined,
        onSelected: () => _searchAndShow(context, album),
      ),
    if (artist.isNotEmpty)
      WenMenuAction(
        label: '查看歌手',
        icon: Icons.person_outline_rounded,
        onSelected: () => _searchAndShow(context, artist),
      ),
    if (onRemove != null)
      WenMenuAction(
        label: '从歌单移除',
        icon: Icons.delete_outline_rounded,
        danger: true,
        onSelected: onRemove,
      ),
  ];
}

/// Best-effort "查看专辑 / 查看歌手": no detail routes exist, so run [keyword] as
/// a search and switch to the 搜索 branch so the results are visible.
void _searchAndShow(BuildContext context, String keyword) {
  context.read<SearchProvider>().search(keyword);
  context.go(Routes.search);
}
