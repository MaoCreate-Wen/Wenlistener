import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/song.dart';
import '../state/player_provider.dart';
import '../theme/app_colors.dart';
import '../theme/app_dimens.dart';
import '../theme/app_typography.dart';
import 'context_menu.dart';
import 'song_menu.dart';
import 'track_row.dart';

/// A dense, virtualized track table: a `# TITLE ARTIST ALBUM ⏱` header over a
/// [ListView.builder] of [TrackRow]s. Marks the now-playing row (from
/// [PlayerProvider]) with the accent, hides the album column under
/// [AppDimens.tableAlbumHideWidth], and gives every row full PC interaction —
/// single-click selects (tracked here), double-click / play glyph calls
/// [onPlayAt], right-click / ⋯ opens the context menu.
///
/// The row menu defaults to the shared [songMenuActions] so every list inherits
/// the same 播放 / 添加到歌单 / 查看专辑·歌手 set; pass [menuActionsFor] to override
/// per-row (e.g. a playlist detail adding 从歌单移除).
///
/// Not scrollable itself when [shrinkWrap] is true (embed in an outer scroll
/// view / sliver); otherwise it owns its own scroll.
class TrackTable extends StatefulWidget {
  final List<Song> songs;
  final ValueChanged<int> onPlayAt;
  final List<WenMenuAction> Function(Song song, int index)? menuActionsFor;
  final bool showHeader;
  final bool showSourceBadge;
  final bool shrinkWrap;
  final ScrollController? controller;
  final EdgeInsetsGeometry padding;

  const TrackTable({
    super.key,
    required this.songs,
    required this.onPlayAt,
    this.menuActionsFor,
    this.showHeader = true,
    this.showSourceBadge = false,
    this.shrinkWrap = false,
    this.controller,
    this.padding = EdgeInsets.zero,
  });

  @override
  State<TrackTable> createState() => _TrackTableState();
}

class _TrackTableState extends State<TrackTable> {
  /// The single-click-selected row (highlight only; does not play). Cleared when
  /// it would point past a shortened list.
  int? _selectedIndex;

  void _select(int i) {
    if (_selectedIndex == i) return;
    setState(() => _selectedIndex = i);
  }

  @override
  Widget build(BuildContext context) {
    final int? currentId =
        context.select((PlayerProvider p) => p.currentSong?.id);
    final bool isPlaying = context.select((PlayerProvider p) => p.isPlaying);
    final Color accent = context.select((PlayerProvider p) => p.dynamicAccent);

    final int? selected =
        (_selectedIndex != null && _selectedIndex! < widget.songs.length)
            ? _selectedIndex
            : null;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final bool showAlbum = c.maxWidth >= AppDimens.tableAlbumHideWidth;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (widget.showHeader) _Header(showAlbum: showAlbum),
            Flexible(
              child: ListView.builder(
                controller: widget.controller,
                shrinkWrap: widget.shrinkWrap,
                physics: widget.shrinkWrap
                    ? const NeverScrollableScrollPhysics()
                    : null,
                padding: widget.padding,
                itemCount: widget.songs.length,
                itemExtent: 52,
                itemBuilder: (BuildContext context, int i) {
                  final Song s = widget.songs[i];
                  final bool active = currentId != null && s.id == currentId;
                  return TrackRow(
                    index: i + 1,
                    song: s,
                    isActive: active,
                    isPlaying: active && isPlaying,
                    selected: selected == i,
                    showAlbum: showAlbum,
                    showSourceBadge: widget.showSourceBadge,
                    accent: accent,
                    onSelect: () => _select(i),
                    onPlay: () => widget.onPlayAt(i),
                    menuActions: widget.menuActionsFor?.call(s, i) ??
                        songMenuActions(context, s),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  final bool showAlbum;
  const _Header({required this.showAlbum});

  @override
  Widget build(BuildContext context) {
    final TextStyle st = AppTypography.caption.copyWith(
      color: AppColors.onSurfaceFaint,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.5,
    );
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: AppDimens.space12),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: AppColors.glassBorder, width: 1),
        ),
      ),
      child: Row(
        children: <Widget>[
          SizedBox(width: 28, child: Text('#', textAlign: TextAlign.center, style: st)),
          const SizedBox(width: AppDimens.space12),
          Expanded(flex: 4, child: Text('标题', style: st)),
          const SizedBox(width: AppDimens.space16),
          Expanded(flex: 3, child: Text('艺术家', style: st)),
          if (showAlbum) ...<Widget>[
            const SizedBox(width: AppDimens.space16),
            Expanded(flex: 3, child: Text('专辑', style: st)),
          ],
          const SizedBox(width: AppDimens.space12),
          const SizedBox(width: 36),
          SizedBox(
            width: 52,
            child: Icon(Icons.schedule_rounded,
                size: 14, color: AppColors.onSurfaceFaint),
          ),
          const SizedBox(width: 32),
        ],
      ),
    );
  }
}
