import 'package:flutter/gestures.dart'
    show
        GestureBinding,
        PointerDeviceKind,
        PointerScrollEvent,
        PointerSignalEvent;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../models/image_url.dart';
import '../../../models/song.dart';
import '../../../services/resource_cache.dart' show DiskCachedImage;
import '../../../widgets/artwork_image.dart' as aw;
import '../../../state/player_provider.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_dimens.dart';
import '../../../theme/app_motion.dart';
import '../../../theme/app_typography.dart';

/// Shared desktop-native UI primitives consumed by the Home / Search / Library
/// pages: hover wrappers, artwork, media cards, section headers, horizontal
/// carousels, the compact multi-column track row/table, skeletons and empty
/// states. These are page-owned (they live under `pages/home/widgets/`) and are
/// deliberately self-contained on the `theme/` tokens + the models/state layer —
/// no dependency on a `lib/widgets/` package. Every interactive surface is
/// pointer-first (`MouseRegion` hover + click cursor) with no layout-shifting
/// resize (paint-only `Transform.scale` on cards).

// ---------------------------------------------------------------------------
// small formatters / label helpers
// ---------------------------------------------------------------------------

/// `m:ss`, or `--:--` for an unknown/zero duration.
String fmtDuration(Duration d) {
  if (d.inMilliseconds <= 0) return '--:--';
  final int m = d.inMinutes;
  final int s = d.inSeconds % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}

/// Full Chinese name of a backend source (音源).
String sourceLabel(MusicSource s) {
  switch (s) {
    case MusicSource.netease:
      return '网易云';
    case MusicSource.migu:
      // The `migu` enum slot currently hosts the QQ音乐 backend (see wiring docs).
      return 'QQ音乐';
    case MusicSource.kugou:
      return '酷狗';
    case MusicSource.kugougn:
      return '概念版';
    case MusicSource.kuwo:
      return '酷我';
    case MusicSource.qqcn:
      return 'QQ音乐(安卓)';
    case MusicSource.local:
      return '本地';
  }
}

/// 2-char source tag for the per-song badge.
String sourceShort(MusicSource s) {
  switch (s) {
    case MusicSource.netease:
      return '网易';
    case MusicSource.migu:
      // `migu` slot = QQ音乐 backend; short tag reads "QQ".
      return 'QQ';
    case MusicSource.kugou:
      return '酷狗';
    case MusicSource.kugougn:
      return '概念';
    case MusicSource.kuwo:
      return '酷我';
    case MusicSource.qqcn:
      return 'QQ安';
    case MusicSource.local:
      return '本地';
  }
}

/// Netease CDN images 403 the default UA — attach browser headers only for them.
Map<String, String>? _headersFor(String url) {
  if (url.contains('126.net') || url.contains('music.163')) {
    return kNeteaseImageHeaders;
  }
  return null;
}

// ---------------------------------------------------------------------------
// HoverBuilder — MouseRegion → hovering flag (+ pointer cursor)
// ---------------------------------------------------------------------------

class HoverBuilder extends StatefulWidget {
  final Widget Function(BuildContext context, bool hovering) builder;
  final MouseCursor cursor;
  const HoverBuilder({
    super.key,
    required this.builder,
    this.cursor = SystemMouseCursors.click,
  });

  @override
  State<HoverBuilder> createState() => _HoverBuilderState();
}

class _HoverBuilderState extends State<HoverBuilder> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: widget.cursor,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: widget.builder(context, _hovering),
    );
  }
}

// ---------------------------------------------------------------------------
// ArtworkImage — reserved-size cached cover with rounded corners
// ---------------------------------------------------------------------------

class ArtworkImage extends StatelessWidget {
  final String? url;
  final double size;
  final double? radius;
  final bool circle;
  final IconData placeholderIcon;
  const ArtworkImage({
    super.key,
    required this.url,
    required this.size,
    this.radius,
    this.circle = false,
    this.placeholderIcon = Icons.music_note_rounded,
  });

  @override
  Widget build(BuildContext context) {
    final double r = circle ? size / 2 : (radius ?? AppDimens.albumRadius(size));
    final String? u = url;

    Widget placeholder = Container(
      width: size,
      height: size,
      color: AppColors.surface2,
      alignment: Alignment.center,
      child: Icon(
        placeholderIcon,
        size: size * 0.38,
        color: AppColors.onSurfaceFaint,
      ),
    );

    Widget img;
    if (u == null || u.isEmpty) {
      img = placeholder;
    } else {
      // Disk-cached (bounded LRU) replacement for the old CachedNetworkImage;
      // placeholder-until-frame + AppMotion.fast fade-in match its behavior.
      // Decode at DISPLAY size (ResizeImage bucketing, same 64px buckets as
      // widgets/ArtworkImage) — WITHOUT this a Netease cover decoded at its
      // native 2000-3000px = 25-36MB RGBA, and the home/library/search grids
      // (kept alive in the shell IndexedStack) pinned dozens of them in the live
      // imageCache = a several-hundred-MB resident floor. Bucketed it's ~150-220KB.
      final int px = aw.ArtworkImage.cachePxFor(
        size,
        MediaQuery.devicePixelRatioOf(context),
      );
      img = Image(
        image: ResizeImage.resizeIfNeeded(
          px,
          px,
          DiskCachedImage(u, headers: _headersFor(u)),
        ),
        width: size,
        height: size,
        fit: BoxFit.cover,
        frameBuilder:
            (BuildContext context, Widget child, int? frame, bool wasSync) =>
                wasSync
                    ? child
                    : Stack(
                        fit: StackFit.passthrough,
                        children: <Widget>[
                          if (frame == null) placeholder,
                          AnimatedOpacity(
                            opacity: frame == null ? 0.0 : 1.0,
                            duration: AppMotion.fast,
                            curve: Curves.easeOut,
                            child: child,
                          ),
                        ],
                      ),
        errorBuilder: (_, __, ___) => placeholder,
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(r),
      child: SizedBox(width: size, height: size, child: img),
    );
  }
}

// ---------------------------------------------------------------------------
// MediaCard — 150px hover-scale carousel / grid card (playlist / song / artist)
// ---------------------------------------------------------------------------

class MediaCard extends StatelessWidget {
  final String? artUrl;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  /// Optional dedicated play affordance (revealed on hover). Null hides it.
  final VoidCallback? onPlay;
  final double size;
  final bool circle;
  const MediaCard({
    super.key,
    required this.artUrl,
    required this.title,
    this.subtitle,
    required this.onTap,
    this.onPlay,
    this.size = AppDimens.cardSize,
    this.circle = false,
  });

  @override
  Widget build(BuildContext context) {
    final Color accent = AppColors.accentOf(context);
    return HoverBuilder(
      builder: (context, hovering) {
        return GestureDetector(
          onTap: onTap,
          child: AnimatedScale(
            scale: hovering ? 1.03 : 1.0,
            duration: AppMotion.fast,
            curve: AppMotion.enter,
            child: SizedBox(
              width: size,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Stack(
                    children: <Widget>[
                      AnimatedContainer(
                        duration: AppMotion.fast,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(
                            circle ? size / 2 : AppDimens.albumRadius(size),
                          ),
                          boxShadow: hovering ? AppDimens.albumShadow : null,
                        ),
                        child: ArtworkImage(
                          url: artUrl,
                          size: size,
                          circle: circle,
                          placeholderIcon: circle
                              ? Icons.person_rounded
                              : Icons.library_music_rounded,
                        ),
                      ),
                      if (onPlay != null)
                        Positioned(
                          right: 8,
                          bottom: 8,
                          child: AnimatedOpacity(
                            opacity: hovering ? 1 : 0,
                            duration: AppMotion.fast,
                            child: _PlayFab(color: accent, onTap: onPlay!),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: AppDimens.space8),
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.body.copyWith(
                      fontWeight: FontWeight.w600,
                      color: hovering ? Colors.white : AppColors.onSurface,
                    ),
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.caption,
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PlayFab extends StatelessWidget {
  final Color color;
  final VoidCallback onTap;
  const _PlayFab({required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return HoverBuilder(
      builder: (context, hovering) => GestureDetector(
        onTap: onTap,
        child: AnimatedScale(
          scale: hovering ? 1.08 : 1.0,
          duration: AppMotion.fast,
          child: Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: color.withValues(alpha: 0.45),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: const Icon(Icons.play_arrow_rounded,
                color: Colors.black, size: 26),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// SectionHeader — display-font section title + optional "更多 ›"
// ---------------------------------------------------------------------------

class SectionHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final VoidCallback? onMore;
  const SectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.onMore,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppDimens.space16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(title, style: AppTypography.titleL),
                if (subtitle != null && subtitle!.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(subtitle!, style: AppTypography.caption),
                ],
              ],
            ),
          ),
          if (onMore != null)
            HoverBuilder(
              builder: (context, hovering) => GestureDetector(
                onTap: onMore,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      '更多',
                      style: AppTypography.label.copyWith(
                        color: hovering
                            ? AppColors.onSurface
                            : AppColors.onSurfaceMuted,
                      ),
                    ),
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 18,
                      color: hovering
                          ? AppColors.onSurface
                          : AppColors.onSurfaceMuted,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// CarouselRow — horizontal hover-scroll strip of cards
// ---------------------------------------------------------------------------

class CarouselRow extends StatefulWidget {
  final List<Widget> children;
  final double height;
  const CarouselRow({super.key, required this.children, required this.height});

  @override
  State<CarouselRow> createState() => _CarouselRowState();
}

class _CarouselRowState extends State<CarouselRow> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Desktop mice emit a *vertical* wheel delta; a horizontal ListView ignores
  /// it, so nothing scrolls sideways. Translate that vertical wheel into a
  /// horizontal jump on this row's own controller so the whole strip is
  /// reachable with the wheel (drag still works via [_DragScrollBehavior]).
  void _onPointerScroll(PointerScrollEvent e) {
    if (!_controller.hasClients) return;
    // Prefer the dominant axis so trackpads that already scroll horizontally
    // aren't doubled up.
    final double delta =
        e.scrollDelta.dx.abs() > e.scrollDelta.dy.abs()
            ? e.scrollDelta.dx
            : e.scrollDelta.dy;
    if (delta == 0) return;
    final double target = (_controller.offset + delta).clamp(
      _controller.position.minScrollExtent,
      _controller.position.maxScrollExtent,
    );
    _controller.jumpTo(target);
  }

  /// Handles a wheel signal over the strip. Merely reading the event in
  /// [Listener.onPointerSignal] is NOT enough: the ancestor vertical
  /// [CustomScrollView] also handles the same signal, and because pointer
  /// signals are resolved (not bubbled), whichever handler registers with the
  /// [pointerSignalResolver] first wins. Registering here — from a descendant of
  /// the page scroll view, so we register before it — claims the wheel for this
  /// strip and stops the page from stealing it (the "can't wheel-scroll the
  /// carousel" bug).
  void _onPointerSignal(PointerSignalEvent s) {
    if (s is! PointerScrollEvent) return;
    if (!_controller.hasClients) return;
    // Nothing to scroll sideways (strip fits, or not laid out yet): decline so
    // the wheel falls through to the vertical page scroll — a short strip must
    // not trap the wheel and freeze the page.
    if (_controller.position.maxScrollExtent <= 0) return;
    GestureBinding.instance.pointerSignalResolver.register(
      s,
      (PointerSignalEvent e) {
        if (e is PointerScrollEvent) _onPointerScroll(e);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      child: Listener(
        onPointerSignal: _onPointerSignal,
        child: ScrollConfiguration(
          behavior: const _DragScrollBehavior(),
          child: ListView.separated(
            controller: _controller,
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            padding: EdgeInsets.zero,
            itemCount: widget.children.length,
            separatorBuilder: (_, __) =>
                const SizedBox(width: AppDimens.space16),
            itemBuilder: (_, int i) => widget.children[i],
          ),
        ),
      ),
    );
  }
}

/// Lets the horizontal strips be dragged with the mouse (desktop pointers).
class _DragScrollBehavior extends MaterialScrollBehavior {
  const _DragScrollBehavior();
  @override
  Set<PointerDeviceKind> get dragDevices => <PointerDeviceKind>{
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
      };
}

// ---------------------------------------------------------------------------
// SourceBadge — per-song backend chip
// ---------------------------------------------------------------------------

class SourceBadge extends StatelessWidget {
  final MusicSource source;
  const SourceBadge({super.key, required this.source});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: AppColors.glass,
        borderRadius: BorderRadius.circular(AppDimens.radiusSm),
        border: Border.all(color: AppColors.glassBorder, width: 1),
      ),
      child: Text(
        sourceShort(source),
        style: AppTypography.caption.copyWith(
          fontSize: 10,
          color: AppColors.onSurfaceMuted,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// TrackRow — compact multi-column desktop list row
// ---------------------------------------------------------------------------

/// One entry in the [TrackTable] / any dense song list.
///
/// Columns: `index/▶ · title (+source badge) · artist · album · ♥ · duration · ⋯`.
/// Hover reveals the play triangle, like and overflow affordances and tints the
/// row. Double-click or the play button calls [onPlay]; right-click opens
/// [onContext]. The active (currently-playing) row is accent-tinted. `♥`/active
/// state come through narrow `context.select`s so an unrelated position tick
/// doesn't rebuild every row's chrome.
class TrackRow extends StatelessWidget {
  final Song song;
  final int displayIndex;
  final bool showAlbum;
  final VoidCallback onPlay;
  final void Function(Offset globalPosition)? onContext;
  const TrackRow({
    super.key,
    required this.song,
    required this.displayIndex,
    required this.onPlay,
    this.showAlbum = true,
    this.onContext,
  });

  @override
  Widget build(BuildContext context) {
    final bool active =
        context.select((PlayerProvider p) => p.currentSong?.id == song.id);
    final bool liked =
        context.select((PlayerProvider p) => p.isLikedSong(song));
    final Color accent = AppColors.accentOf(context);

    return HoverBuilder(
      builder: (context, hovering) {
        final Color titleColor = active
            ? accent
            : (hovering ? Colors.white : AppColors.onSurface);
        return GestureDetector(
          onDoubleTap: onPlay,
          onSecondaryTapDown: onContext == null
              ? null
              : (TapDownDetails d) => onContext!(d.globalPosition),
          child: AnimatedContainer(
            duration: AppMotion.fast,
            height: 52,
            padding: const EdgeInsets.symmetric(horizontal: AppDimens.space12),
            decoration: BoxDecoration(
              color: active
                  ? AppColors.rowSelected
                  : (hovering ? AppColors.hover : Colors.transparent),
              borderRadius: BorderRadius.circular(AppDimens.radiusSm),
            ),
            child: Row(
              children: <Widget>[
                // index / play
                SizedBox(
                  width: 34,
                  child: _IndexCell(
                    index: displayIndex,
                    active: active,
                    hovering: hovering,
                    accent: accent,
                    onPlay: onPlay,
                  ),
                ),
                const SizedBox(width: AppDimens.space8),
                // title (+ source badge)
                Expanded(
                  flex: 5,
                  child: Row(
                    children: <Widget>[
                      Flexible(
                        child: Text(
                          song.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTypography.body.copyWith(
                            color: titleColor,
                            fontWeight:
                                active ? FontWeight.w600 : FontWeight.w500,
                          ),
                        ),
                      ),
                      const SizedBox(width: AppDimens.space8),
                      SourceBadge(source: song.source),
                    ],
                  ),
                ),
                const SizedBox(width: AppDimens.space12),
                // artist
                Expanded(
                  flex: 3,
                  child: Text(
                    song.artistNames.isEmpty ? '未知艺人' : song.artistNames,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.label,
                  ),
                ),
                if (showAlbum) ...<Widget>[
                  const SizedBox(width: AppDimens.space12),
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
                // like (hover / liked)
                SizedBox(
                  width: 32,
                  child: (hovering || liked)
                      ? _IconAction(
                          icon: liked
                              ? Icons.favorite_rounded
                              : Icons.favorite_border_rounded,
                          color: liked ? accent : AppColors.onSurfaceMuted,
                          tooltip: liked ? '取消喜欢' : '喜欢',
                          onTap: () => context
                              .read<PlayerProvider>()
                              .setLiked(song, !liked),
                        )
                      : const SizedBox.shrink(),
                ),
                // duration
                SizedBox(
                  width: 52,
                  child: Text(
                    fmtDuration(song.duration),
                    textAlign: TextAlign.right,
                    style: AppTypography.caption,
                  ),
                ),
                // overflow
                SizedBox(
                  width: 32,
                  child: (hovering && onContext != null)
                      ? _IconAction(
                          icon: Icons.more_horiz_rounded,
                          color: AppColors.onSurfaceMuted,
                          tooltip: '更多',
                          onTap: () {
                            final RenderBox box =
                                context.findRenderObject() as RenderBox;
                            onContext!(
                                box.localToGlobal(box.size.center(Offset.zero)));
                          },
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _IndexCell extends StatelessWidget {
  final int index;
  final bool active;
  final bool hovering;
  final Color accent;
  final VoidCallback onPlay;
  const _IndexCell({
    required this.index,
    required this.active,
    required this.hovering,
    required this.accent,
    required this.onPlay,
  });

  @override
  Widget build(BuildContext context) {
    if (hovering) {
      return _IconAction(
        icon: Icons.play_arrow_rounded,
        color: active ? accent : Colors.white,
        tooltip: '播放',
        onTap: onPlay,
        size: 22,
      );
    }
    if (active) {
      return Icon(Icons.graphic_eq_rounded, size: 18, color: accent);
    }
    return Text(
      '$index',
      textAlign: TextAlign.center,
      style: AppTypography.label.copyWith(color: AppColors.onSurfaceFaint),
    );
  }
}

class _IconAction extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String tooltip;
  final VoidCallback onTap;
  final double size;
  const _IconAction({
    required this.icon,
    required this.color,
    required this.tooltip,
    required this.onTap,
    this.size = 18,
  });

  @override
  Widget build(BuildContext context) {
    return HoverBuilder(
      builder: (context, hovering) => Tooltip(
        message: tooltip,
        waitDuration: const Duration(milliseconds: 500),
        child: GestureDetector(
          onTap: onTap,
          child: Icon(
            icon,
            size: size,
            color: hovering ? Colors.white : color,
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// TrackTableHeader — the `# TITLE ARTIST ALBUM ⏱` column labels
// ---------------------------------------------------------------------------

class TrackTableHeader extends StatelessWidget {
  final bool showAlbum;
  const TrackTableHeader({super.key, this.showAlbum = true});

  @override
  Widget build(BuildContext context) {
    final TextStyle s = AppTypography.caption.copyWith(
      letterSpacing: 1.0,
      fontWeight: FontWeight.w600,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppDimens.space12,
        vertical: AppDimens.space8,
      ),
      child: Row(
        children: <Widget>[
          SizedBox(width: 34, child: Text('#', style: s)),
          const SizedBox(width: AppDimens.space8),
          Expanded(flex: 5, child: Text('标题', style: s)),
          const SizedBox(width: AppDimens.space12),
          Expanded(flex: 3, child: Text('艺人', style: s)),
          if (showAlbum) ...<Widget>[
            const SizedBox(width: AppDimens.space12),
            Expanded(flex: 3, child: Text('专辑', style: s)),
          ],
          const SizedBox(width: AppDimens.space12),
          const SizedBox(width: 32),
          SizedBox(
            width: 52,
            child: Icon(Icons.schedule_rounded,
                size: 15, color: AppColors.onSurfaceFaint),
          ),
          const SizedBox(width: 32),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Skeleton — shimmer-free reserved placeholder blocks
// ---------------------------------------------------------------------------

class SkeletonBox extends StatelessWidget {
  final double width;
  final double height;
  final double radius;
  final bool circle;
  const SkeletonBox({
    super.key,
    required this.width,
    required this.height,
    this.radius = AppDimens.radiusSm,
    this.circle = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: AppColors.surface2,
        shape: circle ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: circle ? null : BorderRadius.circular(radius),
      ),
    );
  }
}

/// A skeleton card matching [MediaCard]'s footprint.
class SkeletonCard extends StatelessWidget {
  final double size;
  const SkeletonCard({super.key, this.size = AppDimens.cardSize});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SkeletonBox(
            width: size,
            height: size,
            radius: AppDimens.albumRadius(size),
          ),
          const SizedBox(height: AppDimens.space8),
          const SkeletonBox(width: 110, height: 12),
          const SizedBox(height: 6),
          const SkeletonBox(width: 70, height: 10),
        ],
      ),
    );
  }
}

/// A skeleton stand-in for one [TrackRow].
class SkeletonRow extends StatelessWidget {
  const SkeletonRow({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: AppDimens.space12),
      child: Row(
        children: const <Widget>[
          SkeletonBox(width: 16, height: 12),
          SizedBox(width: AppDimens.space16),
          Expanded(flex: 5, child: SkeletonBox(width: 200, height: 12)),
          SizedBox(width: AppDimens.space12),
          Expanded(flex: 3, child: SkeletonBox(width: 120, height: 10)),
          SizedBox(width: AppDimens.space12),
          Expanded(flex: 3, child: SkeletonBox(width: 120, height: 10)),
          SizedBox(width: AppDimens.space12),
          SkeletonBox(width: 40, height: 10),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// EmptyState — icon + message (+ optional CTA)
// ---------------------------------------------------------------------------

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final Color accent = AppColors.accentOf(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 56, color: AppColors.onSurfaceFaint),
          const SizedBox(height: AppDimens.space16),
          Text(title, style: AppTypography.titleM),
          if (message != null && message!.isNotEmpty) ...<Widget>[
            const SizedBox(height: AppDimens.space8),
            Text(
              message!,
              textAlign: TextAlign.center,
              style: AppTypography.label,
            ),
          ],
          if (actionLabel != null && onAction != null) ...<Widget>[
            const SizedBox(height: AppDimens.space20),
            HoverBuilder(
              builder: (context, hovering) => GestureDetector(
                onTap: onAction,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppDimens.space20,
                    vertical: AppDimens.space12,
                  ),
                  decoration: BoxDecoration(
                    color: hovering
                        ? accent
                        : accent.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(AppDimens.radiusPill),
                  ),
                  child: Text(
                    actionLabel!,
                    style: AppTypography.label.copyWith(
                      color: Colors.black,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// FilterChipButton — pill chip for search type / history
// ---------------------------------------------------------------------------

class PillChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;
  const PillChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final Color accent = AppColors.accentOf(context);
    return HoverBuilder(
      builder: (context, hovering) => GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: AppMotion.fast,
          padding: const EdgeInsets.symmetric(
            horizontal: AppDimens.space16,
            vertical: AppDimens.space8,
          ),
          decoration: BoxDecoration(
            color: selected
                ? accent.withValues(alpha: 0.22)
                : (hovering ? AppColors.hover : AppColors.glass),
            borderRadius: BorderRadius.circular(AppDimens.radiusPill),
            border: Border.all(
              color: selected ? accent : AppColors.glassBorder,
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (icon != null) ...<Widget>[
                Icon(icon,
                    size: 15,
                    color: selected ? accent : AppColors.onSurfaceMuted),
                const SizedBox(width: 6),
              ],
              Text(
                label,
                style: AppTypography.label.copyWith(
                  color: selected ? Colors.white : AppColors.onSurfaceMuted,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// context menu helper
// ---------------------------------------------------------------------------

/// Shows a themed popup menu at [globalPosition] and returns the picked value.
Future<T?> showTrackMenu<T>(
  BuildContext context,
  Offset globalPosition,
  List<PopupMenuEntry<T>> items,
) {
  final RenderBox overlay =
      Overlay.of(context).context.findRenderObject() as RenderBox;
  return showMenu<T>(
    context: context,
    color: AppColors.surface2,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppDimens.radiusMd),
      side: const BorderSide(color: AppColors.glassBorder),
    ),
    position: RelativeRect.fromRect(
      Rect.fromLTWH(globalPosition.dx, globalPosition.dy, 0, 0),
      Offset.zero & overlay.size,
    ),
    items: items,
  );
}
