import 'package:flutter/material.dart';

import '../models/song.dart';
import '../theme/app_colors.dart';
import '../theme/app_dimens.dart';
import '../theme/app_typography.dart';
import 'context_menu.dart';
import 'like_button.dart';
import 'source_badge.dart';

/// Formats a track [Duration] as `m:ss` (`--:--` when zero/unknown).
String formatTrackDuration(Duration d) {
  if (d <= Duration.zero) return '--:--';
  final int m = d.inMinutes;
  final int s = d.inSeconds % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}

/// The desktop compact track-table row: `index/▶ · title(+source) · artist ·
/// album · ♥ · duration · ⋯`. Behaves like a mature PC player row:
///  - **single-click** → [onSelect] (select/highlight only, never plays);
///  - **double-click** or the hover play glyph → [onPlay];
///  - **right-click** / ⋯ → the [menuActions] context menu;
///  - **hover** fills the row and reveals the play glyph, like heart and ⋯ menu.
///
/// The active (now-playing) row tints its index/title with the accent; a
/// [selected] row gets the [AppColors.rowSelected] fill (distinct affordance
/// from the accent-coloured now-playing text).
class TrackRow extends StatelessWidget {
  final int index;
  final Song song;
  final bool isActive;
  final bool isPlaying;
  final bool selected;
  final bool showAlbum;
  final bool showSourceBadge;
  final VoidCallback? onPlay;
  final VoidCallback? onSelect;
  final List<WenMenuAction> menuActions;
  final Color accent;

  const TrackRow({
    super.key,
    required this.index,
    required this.song,
    this.isActive = false,
    this.isPlaying = false,
    this.selected = false,
    this.showAlbum = true,
    this.showSourceBadge = false,
    this.onPlay,
    this.onSelect,
    this.menuActions = const <WenMenuAction>[],
    this.accent = AppColors.accentPlay,
  });

  @override
  Widget build(BuildContext context) {
    return _HoverRow(
      onPlay: onPlay,
      onSelect: onSelect,
      menuActions: menuActions,
      builder: (bool hovering) {
        final bool showActions = hovering;
        return Container(
          height: 52,
          padding: const EdgeInsets.symmetric(horizontal: AppDimens.space12),
          decoration: BoxDecoration(
            color: (isActive || selected)
                ? AppColors.rowSelected
                : hovering
                    ? AppColors.hover
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(AppDimens.radiusSm),
          ),
          child: Row(
            children: <Widget>[
              SizedBox(
                width: 28,
                child: Center(child: _leading(showActions)),
              ),
              const SizedBox(width: AppDimens.space12),
              Expanded(
                flex: 4,
                child: Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        song.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.body.copyWith(
                          color:
                              isActive ? accent : AppColors.onSurface,
                          fontWeight:
                              isActive ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                    ),
                    if (showSourceBadge) ...<Widget>[
                      const SizedBox(width: AppDimens.space8),
                      SourceBadge(source: song.source),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: AppDimens.space16),
              Expanded(
                flex: 3,
                child: Text(
                  song.artistNames,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.label,
                ),
              ),
              if (showAlbum) ...<Widget>[
                const SizedBox(width: AppDimens.space16),
                Expanded(
                  flex: 3,
                  child: Text(
                    song.album?.name ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.label,
                  ),
                ),
              ],
              const SizedBox(width: AppDimens.space12),
              SizedBox(
                width: 36,
                child: Opacity(
                  opacity: showActions ? 1 : 0,
                  child: IgnorePointer(
                    ignoring: !showActions,
                    child: LikeButton(song: song, size: 32),
                  ),
                ),
              ),
              SizedBox(
                width: 52,
                child: Text(
                  formatTrackDuration(song.duration),
                  textAlign: TextAlign.right,
                  style: AppTypography.caption,
                ),
              ),
              SizedBox(
                width: 32,
                child: (menuActions.isEmpty || !showActions)
                    ? const SizedBox.shrink()
                    : Builder(
                        builder: (BuildContext ctx) => IconButton(
                          padding: EdgeInsets.zero,
                          iconSize: 18,
                          splashRadius: 16,
                          color: AppColors.onSurfaceMuted,
                          icon: const Icon(Icons.more_horiz_rounded),
                          onPressed: () {
                            final RenderBox box =
                                ctx.findRenderObject()! as RenderBox;
                            final Offset pos = box.localToGlobal(
                                box.size.center(Offset.zero));
                            showWenContextMenu(ctx, pos, menuActions);
                          },
                        ),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _leading(bool hovering) {
    if (hovering && onPlay != null) {
      return Icon(Icons.play_arrow_rounded,
          size: 20, color: AppColors.onSurface);
    }
    if (isActive) {
      return Icon(
        isPlaying ? Icons.graphic_eq_rounded : Icons.pause_rounded,
        size: 16,
        color: accent,
      );
    }
    return Text(
      '$index',
      style: AppTypography.caption.copyWith(color: AppColors.onSurfaceFaint),
    );
  }
}

/// Wraps a row body with hover tracking + PC-style interaction: single-click
/// selects ([onSelect]), double-click plays ([onPlay]), right-click opens the
/// [menuActions] context menu.
class _HoverRow extends StatefulWidget {
  final Widget Function(bool hovering) builder;
  final VoidCallback? onPlay;
  final VoidCallback? onSelect;
  final List<WenMenuAction> menuActions;

  const _HoverRow({
    required this.builder,
    required this.onPlay,
    required this.onSelect,
    required this.menuActions,
  });

  @override
  State<_HoverRow> createState() => _HoverRowState();
}

class _HoverRowState extends State<_HoverRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        // Single click only selects; playback is reserved for double-click and
        // the hover play glyph (mature PC-player behaviour).
        onTap: widget.onSelect,
        onDoubleTap: widget.onPlay,
        onSecondaryTapUp: widget.menuActions.isEmpty
            ? null
            : (TapUpDetails d) =>
                showWenContextMenu(context, d.globalPosition, widget.menuActions),
        child: widget.builder(_hover),
      ),
    );
  }
}
