import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:flutter/services.dart'
    show KeyDownEvent, KeyEvent, LogicalKeyboardKey;
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../models/image_url.dart';
import '../../models/song.dart';
import '../../services/resource_cache.dart' show DiskCachedImage;
import '../../state/library_provider.dart';
import '../../state/local_playlist_provider.dart';
import '../../state/player_provider.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_dimens.dart';
import '../../theme/app_typography.dart';
import '../../widgets/entrance.dart';
import '../player/widgets/toggle_icon_button.dart';

/// Shared **desktop** UI kit used by the playlist / settings / accounts / login
/// pages. Everything is `Dk`-prefixed so it never collides with the shell agent's
/// `lib/widgets/` primitives. Pure presentation + provider glue — no logic is
/// re-implemented here (all behaviour goes through the existing providers).

// ---------------------------------------------------------------------------
// Formatting helpers
// ---------------------------------------------------------------------------

/// `m:ss` (or `h:mm:ss`) for a track duration; `--:--` when unknown.
String dkFormatDuration(Duration d) {
  if (d <= Duration.zero) return '--:--';
  final int h = d.inHours;
  final int m = d.inMinutes.remainder(60);
  final int s = d.inSeconds.remainder(60);
  final String two = s.toString().padLeft(2, '0');
  if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:$two';
  return '$m:$two';
}

/// A short glass toast at the bottom of the screen.
void dkToast(BuildContext context, String message) {
  final ScaffoldMessengerState m = ScaffoldMessenger.of(context);
  m.clearSnackBars();
  m.showSnackBar(
    SnackBar(
      behavior: SnackBarBehavior.floating,
      backgroundColor: AppColors.surface2,
      duration: const Duration(seconds: 2),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppDimens.radiusMd),
        side: const BorderSide(color: AppColors.glassBorder),
      ),
      content: Text(message, style: AppTypography.body),
    ),
  );
}

// ---------------------------------------------------------------------------
// Glass surface
// ---------------------------------------------------------------------------

/// Frosted glass surface primitive (BackdropFilter + fill + hairline + shadow).
class DkGlass extends StatelessWidget {
  final Widget child;
  final double blur;
  final Color? color;
  final double radius;
  final EdgeInsetsGeometry? padding;
  final bool border;

  const DkGlass({
    super.key,
    required this.child,
    this.blur = AppDimens.blurPanel,
    this.color,
    this.radius = AppDimens.radiusLg,
    this.padding,
    this.border = true,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: color ?? AppColors.glass,
            borderRadius: BorderRadius.circular(radius),
            border: border
                ? Border.all(color: AppColors.glassBorder, width: 1)
                : null,
          ),
          child: child,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Artwork
// ---------------------------------------------------------------------------

/// Album / avatar art with Netease CDN headers + graceful placeholder.
class DkArt extends StatelessWidget {
  final String? url;
  final double size;
  final double? radius;
  final bool circle;
  final IconData placeholder;

  const DkArt({
    super.key,
    required this.url,
    required this.size,
    this.radius,
    this.circle = false,
    this.placeholder = Icons.music_note_rounded,
  });

  Map<String, String>? _headers(String u) =>
      (u.contains('126.net') || u.contains('music.163'))
          ? kNeteaseImageHeaders
          : null;

  @override
  Widget build(BuildContext context) {
    final double r =
        circle ? size / 2 : (radius ?? AppDimens.albumRadius(size));
    final String? norm = httpsImageUrl(url);
    // Decode the CDN artwork at (roughly) its on-screen pixel size rather than
    // at full source resolution. For a 36px row cover this turns a ~300–800px
    // decode into ~72px, which — together with the virtualized track list — keeps
    // a 1000+ track playlist from ballooning image memory. Capped by DPR so the
    // art stays crisp on hiDPI displays.
    final int cachePx = (size * MediaQuery.devicePixelRatioOf(context)).round();
    final Widget fallback = Container(
      width: size,
      height: size,
      color: AppColors.surface2,
      alignment: Alignment.center,
      child: Icon(placeholder, size: size * 0.4, color: AppColors.onFaint),
    );
    // Same decode-at-display-size behavior as the old CachedNetworkImage
    // (memCacheWidth/Height == ResizeImage.resizeIfNeeded), now over the
    // app's bounded disk cache; placeholder-until-frame + 500ms fade-in
    // mirror the old widget's defaults.
    final Widget content = (norm == null)
        ? fallback
        : Image(
            image: ResizeImage.resizeIfNeeded(
              cachePx,
              cachePx,
              DiskCachedImage(norm, headers: _headers(norm)),
            ),
            width: size,
            height: size,
            fit: BoxFit.cover,
            frameBuilder: (BuildContext context, Widget child, int? frame,
                    bool wasSync) =>
                wasSync
                    ? child
                    : Stack(
                        fit: StackFit.passthrough,
                        children: <Widget>[
                          if (frame == null)
                            Container(
                              width: size,
                              height: size,
                              color: AppColors.surface2,
                            ),
                          AnimatedOpacity(
                            opacity: frame == null ? 0.0 : 1.0,
                            duration: const Duration(milliseconds: 500),
                            curve: Curves.easeOut,
                            child: child,
                          ),
                        ],
                      ),
            errorBuilder: (_, __, ___) => fallback,
          );
    return ClipRRect(
      borderRadius: BorderRadius.circular(r),
      child: SizedBox(width: size, height: size, child: content),
    );
  }
}

// ---------------------------------------------------------------------------
// Buttons
// ---------------------------------------------------------------------------

/// Filled accent CTA (Play-all, Login, …). No layout-shifting scale on hover.
class DkPrimaryButton extends StatefulWidget {
  final IconData? icon;
  final String label;
  final VoidCallback? onPressed;
  final Color? color;
  final bool dense;

  const DkPrimaryButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.color,
    this.dense = false,
  });

  @override
  State<DkPrimaryButton> createState() => _DkPrimaryButtonState();
}

class _DkPrimaryButtonState extends State<DkPrimaryButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final bool enabled = widget.onPressed != null;
    final Color base = widget.color ?? AppColors.accentPlay;
    final Color fill = enabled
        ? (_hover ? Color.lerp(base, Colors.white, 0.12)! : base)
        : base.withValues(alpha: 0.35);
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AmllBounce(
        onTap: enabled ? widget.onPressed : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: EdgeInsets.symmetric(
            horizontal: widget.dense ? AppDimens.space16 : AppDimens.space24,
            vertical: widget.dense ? AppDimens.space8 : AppDimens.space12,
          ),
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(AppDimens.radiusPill),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (widget.icon != null) ...<Widget>[
                Icon(widget.icon, size: 18, color: Colors.black),
                const SizedBox(width: AppDimens.space8),
              ],
              Text(
                widget.label,
                style: AppTypography.label.copyWith(
                  color: Colors.black,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Glass / outline secondary button.
class DkSecondaryButton extends StatefulWidget {
  final IconData? icon;
  final String label;
  final VoidCallback? onPressed;

  const DkSecondaryButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
  });

  @override
  State<DkSecondaryButton> createState() => _DkSecondaryButtonState();
}

class _DkSecondaryButtonState extends State<DkSecondaryButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final bool enabled = widget.onPressed != null;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AmllBounce(
        onTap: enabled ? widget.onPressed : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.symmetric(
            horizontal: AppDimens.space20,
            vertical: AppDimens.space12,
          ),
          decoration: BoxDecoration(
            color: _hover ? AppColors.pressed : AppColors.glass,
            borderRadius: BorderRadius.circular(AppDimens.radiusPill),
            border: Border.all(color: AppColors.glassBorder),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (widget.icon != null) ...<Widget>[
                Icon(widget.icon,
                    size: 18,
                    color: enabled ? AppColors.onSurface : AppColors.onFaint),
                const SizedBox(width: AppDimens.space8),
              ],
              Text(
                widget.label,
                style: AppTypography.label.copyWith(
                  color: enabled ? AppColors.onSurface : AppColors.onFaint,
                  fontSize: 14,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A hover-tinted icon button that can report its global tap position (used to
/// anchor context menus). Transparent, monochrome, pointer cursor.
class DkHoverIcon extends StatefulWidget {
  final IconData icon;
  final double size;
  final Color? color;
  final String? tooltip;
  final VoidCallback? onTap;
  final void Function(Offset globalPosition)? onTapAt;

  const DkHoverIcon({
    super.key,
    required this.icon,
    this.size = 20,
    this.color,
    this.tooltip,
    this.onTap,
    this.onTapAt,
  });

  @override
  State<DkHoverIcon> createState() => _DkHoverIconState();
}

class _DkHoverIconState extends State<DkHoverIcon> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final Widget core = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AmllBounce.circle(
        diameter: widget.size + 16,
        onTap: widget.onTapAt == null ? widget.onTap : null,
        onTapAt: widget.onTapAt,
        child: Icon(
          widget.icon,
          size: widget.size,
          color: widget.color ??
              (_hover ? AppColors.onSurface : AppColors.onMuted),
        ),
      ),
    );
    return widget.tooltip == null
        ? core
        : Tooltip(message: widget.tooltip!, child: core);
  }
}

// ---------------------------------------------------------------------------
// Section header
// ---------------------------------------------------------------------------

class DkSectionTitle extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;

  const DkSectionTitle({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(title, style: AppTypography.titleL),
              if (subtitle != null) ...<Widget>[
                const SizedBox(height: 2),
                Text(subtitle!, style: AppTypography.label),
              ],
            ],
          ),
        ),
        if (trailing != null) trailing!,
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Track table
// ---------------------------------------------------------------------------

/// A single dense, hover-reactive track row (index · title · artist · album ·
/// like · duration · ⋯). Right-click / ⋯ opens the shared song menu.
///
/// [flashNonce] drives the "定位" flash-highlight: whenever it changes to a
/// non-zero value (or the row is first built with one), a brief accent-tinted
/// wash fades out over ~1.2s. `0` (the default) renders the row exactly as
/// before — hover/active visuals are untouched.
class DkTrackRow extends StatefulWidget {
  final int index;
  final Song song;
  final bool active;
  final bool showAlbum;
  final int flashNonce;
  final VoidCallback onPlay;
  final void Function(Offset globalPosition) onMenu;

  const DkTrackRow({
    super.key,
    required this.index,
    required this.song,
    required this.active,
    required this.onPlay,
    required this.onMenu,
    this.showAlbum = true,
    this.flashNonce = 0,
  });

  @override
  State<DkTrackRow> createState() => _DkTrackRowState();
}

class _DkTrackRowState extends State<DkTrackRow>
    with SingleTickerProviderStateMixin {
  bool _hover = false;

  late final AnimationController _flash = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  @override
  void initState() {
    super.initState();
    // The row may only be built AFTER the locate-scroll lands on it (rows are
    // virtualized), so a fresh row created mid-flash must start its own fade.
    if (widget.flashNonce != 0) _flash.forward(from: 0);
  }

  @override
  void didUpdateWidget(DkTrackRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.flashNonce != oldWidget.flashNonce && widget.flashNonce != 0) {
      _flash.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _flash.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Color accent = AppColors.accentOf(context);
    final Song s = widget.song;
    final Color titleColor = widget.active ? accent : AppColors.onSurface;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onPlay,
        onDoubleTap: widget.onPlay,
        onSecondaryTapDown: (TapDownDetails d) =>
            widget.onMenu(d.globalPosition),
        child: AnimatedBuilder(
          animation: _flash,
          builder: (BuildContext context, Widget? rowChild) {
            Color bg = widget.active
                ? AppColors.rowSelected
                : (_hover ? AppColors.hover : Colors.transparent);
            if (widget.flashNonce != 0) {
              final double wash =
                  (1 - Curves.easeOutCubic.transform(_flash.value)) * 0.30;
              if (wash > 0) {
                bg = Color.alphaBlend(accent.withValues(alpha: wash), bg);
              }
            }
            return Container(
              height: 52,
              padding:
                  const EdgeInsets.symmetric(horizontal: AppDimens.space12),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(AppDimens.radiusSm),
              ),
              child: rowChild,
            );
          },
          child: Row(
            children: <Widget>[
              SizedBox(
                width: 34,
                child: _hover
                    ? DkHoverIcon(
                        icon: Icons.play_arrow_rounded,
                        size: 22,
                        color: AppColors.onSurface,
                        onTap: widget.onPlay,
                      )
                    : Text(
                        widget.active ? '♪' : '${widget.index + 1}',
                        textAlign: TextAlign.center,
                        style: AppTypography.label.copyWith(
                          color: widget.active ? accent : AppColors.onFaint,
                        ),
                      ),
              ),
              const SizedBox(width: AppDimens.space8),
              DkArt(url: s.artworkUrl, size: 36),
              const SizedBox(width: AppDimens.space12),
              Expanded(
                flex: 4,
                child: Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        s.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.body.copyWith(
                          color: titleColor,
                          fontWeight:
                              widget.active ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                    ),
                    const SizedBox(width: AppDimens.space8),
                    _DkSourceBadge(source: s.source),
                  ],
                ),
              ),
              const SizedBox(width: AppDimens.space12),
              Expanded(
                flex: 3,
                child: Text(
                  s.artistNames.isEmpty ? '未知艺人' : s.artistNames,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.label,
                ),
              ),
              if (widget.showAlbum) ...<Widget>[
                const SizedBox(width: AppDimens.space12),
                Expanded(
                  flex: 3,
                  child: Text(
                    s.album?.name ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        AppTypography.label.copyWith(color: AppColors.onFaint),
                  ),
                ),
              ],
              const SizedBox(width: AppDimens.space12),
              SizedBox(
                width: 52,
                child: Text(
                  dkFormatDuration(s.duration),
                  textAlign: TextAlign.right,
                  style: AppTypography.caption,
                ),
              ),
              const SizedBox(width: AppDimens.space4),
              SizedBox(
                width: 36,
                child: Opacity(
                  opacity: _hover ? 1 : 0,
                  child: DkHoverIcon(
                    icon: Icons.more_horiz_rounded,
                    size: 20,
                    tooltip: '更多',
                    onTapAt: widget.onMenu,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Fixed pixel height of a [DkTrackRow] (== [DkTrackTable]'s `itemExtent`).
const double kDkTrackRowExtent = 52;

/// Header row + **virtualized** [DkTrackRow] list, exposed as *slivers* (via
/// [SliverMainAxisGroup]) so it drops straight into the playlist page's
/// [CustomScrollView]. Only the rows currently on screen (and their downsized
/// covers) are built, so opening a 1000+ track playlist no longer realises every
/// row up front — the previous `ListView.builder(shrinkWrap: true)` inside a
/// `SliverToBoxAdapter` defeated laziness by measuring (building) all rows.
/// Hides the album column below [AppDimens.tableAlbumHideWidth].
class DkTrackTable extends StatelessWidget {
  final List<Song> songs;

  /// Plays the tapped track in the context of the whole list. The index is
  /// ALWAYS an index into [songs] (the original full list), even when
  /// [visibleIndices] filters the view — prev/next keep walking the whole
  /// playlist.
  final void Function(int index) onPlay;

  /// Opens the song menu at a global position.
  final void Function(Song song, Offset globalPosition) onMenu;

  /// When non-null, only these ORIGINAL indices of [songs] are rendered (the
  /// in-playlist search filter). Rows keep their original numbering and all
  /// callbacks stay keyed to the original index/Song. An empty list renders
  /// the "无匹配歌曲" placeholder row.
  final List<int>? visibleIndices;

  /// Attached to the column-header block so pages can measure where row 0
  /// starts (for 定位 scrolling). See [DkTrackPageBody].
  final Key? headerKey;

  /// Original index of the row to flash-highlight, driven by [flashNonce]
  /// (see [DkTrackRow.flashNonce]).
  final int? flashIndex;
  final int flashNonce;

  const DkTrackTable({
    super.key,
    required this.songs,
    required this.onPlay,
    required this.onMenu,
    this.visibleIndices,
    this.headerKey,
    this.flashIndex,
    this.flashNonce = 0,
  });

  @override
  Widget build(BuildContext context) {
    final int? activeId =
        context.select<PlayerProvider, int?>((PlayerProvider p) {
      final Song? c = p.currentSong;
      return c?.id;
    });

    // A sliver context has no LayoutBuilder, so derive the album-column
    // visibility from the page width (the playlist page pads by space32 on each
    // side — matching what the old LayoutBuilder measured).
    final double width =
        MediaQuery.sizeOf(context).width - AppDimens.space32 * 2;
    final bool showAlbum = width >= AppDimens.tableAlbumHideWidth;

    final List<int>? visible = visibleIndices;
    return SliverMainAxisGroup(
      slivers: <Widget>[
        SliverToBoxAdapter(
          child: Column(
            key: headerKey,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _header(showAlbum),
              const Divider(height: 1, color: AppColors.glassBorder),
              const SizedBox(height: AppDimens.space4),
            ],
          ),
        ),
        if (visible != null && visible.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: AppDimens.space32),
              child: Center(
                child: Text('无匹配歌曲', style: AppTypography.label),
              ),
            ),
          )
        else
          SliverFixedExtentList.builder(
            // Rows are a fixed 52px tall, so the sliver can lay out lazily
            // without measuring off-screen children at all.
            itemExtent: kDkTrackRowExtent,
            itemCount: visible?.length ?? songs.length,
            itemBuilder: (BuildContext context, int i) {
              // Map the visual row back to its ORIGINAL playlist index so
              // numbering, playback and the ⋯ menu ignore the filter.
              final int orig = visible == null ? i : visible[i];
              final Song s = songs[orig];
              return DkTrackRow(
                index: orig,
                song: s,
                active: activeId != null && s.id == activeId,
                showAlbum: showAlbum,
                flashNonce:
                    (flashIndex != null && flashIndex == orig) ? flashNonce : 0,
                onPlay: () => onPlay(orig),
                onMenu: (Offset pos) => onMenu(s, pos),
              );
            },
          ),
      ],
    );
  }

  Widget _header(bool showAlbum) {
    final TextStyle st = AppTypography.caption.copyWith(letterSpacing: 1.2);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppDimens.space12,
        vertical: AppDimens.space8,
      ),
      child: Row(
        children: <Widget>[
          SizedBox(
              width: 34,
              child: Text('#', textAlign: TextAlign.center, style: st)),
          const SizedBox(width: AppDimens.space8 + 36 + AppDimens.space12),
          Expanded(flex: 4, child: Text('标题', style: st)),
          const SizedBox(width: AppDimens.space12),
          Expanded(flex: 3, child: Text('艺人', style: st)),
          if (showAlbum) ...<Widget>[
            const SizedBox(width: AppDimens.space12),
            Expanded(flex: 3, child: Text('专辑', style: st)),
          ],
          const SizedBox(width: AppDimens.space12),
          SizedBox(
              width: 52,
              child: Text('时长', textAlign: TextAlign.right, style: st)),
          const SizedBox(width: AppDimens.space4 + 36),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// In-playlist search + locate (shared by the two playlist detail pages)
// ---------------------------------------------------------------------------

/// Precomputed lowercase search keys for one tracks list — built ONCE per list
/// (not per keystroke per row). [search] returns the matching ORIGINAL indices.
class DkTrackSearchIndex {
  final List<Song> tracks;
  final List<String> _keys;

  DkTrackSearchIndex(this.tracks)
      : _keys = List<String>.generate(
          tracks.length,
          (int i) {
            final Song s = tracks[i];
            // \n separates the fields so a query can't match across them.
            return '${s.name}\n${s.artistNames}\n${s.album?.name ?? ''}'
                .toLowerCase();
          },
          growable: false,
        );

  /// Case-insensitive substring match on title + artist + album (CJK works as
  /// a plain substring). Empty/whitespace query matches everything.
  List<int> search(String query) {
    final String q = query.trim().toLowerCase();
    if (q.isEmpty) {
      return List<int>.generate(tracks.length, (int i) => i, growable: false);
    }
    return <int>[
      for (int i = 0; i < _keys.length; i++)
        if (_keys[i].contains(q)) i,
    ];
  }
}

/// The header-row toolbar shared by both playlist detail pages: a magnifier
/// that expands into an inline frosted search field (with live "N 首" match
/// count), plus the 定位到正在播放 crosshair.
///
/// The locate button watches ONLY the current song's identity via
/// `context.select` — never the whole [PlayerProvider] (per-tick trap).
class DkTrackToolbar extends StatefulWidget {
  /// The page's ORIGINAL full tracks list (locate enablement checks membership
  /// by id + source).
  final List<Song> tracks;

  /// Live filter callback; fired with '' when the field clears/collapses.
  final ValueChanged<String> onQuery;

  /// Match count to show next to the field while a query is active.
  final int? matchCount;

  /// Locate click (the page owns the scroll).
  final VoidCallback onLocate;

  /// Bump to force-collapse + clear the search field from outside (used when
  /// locate clears an active filter).
  final int resetNonce;

  const DkTrackToolbar({
    super.key,
    required this.tracks,
    required this.onQuery,
    required this.onLocate,
    this.matchCount,
    this.resetNonce = 0,
  });

  @override
  State<DkTrackToolbar> createState() => _DkTrackToolbarState();
}

class _DkTrackToolbarState extends State<DkTrackToolbar> {
  bool _open = false;
  final TextEditingController _ctrl = TextEditingController();
  late final FocusNode _focus = FocusNode(
    onKeyEvent: (FocusNode node, KeyEvent event) {
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.escape) {
        _collapse();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
  );

  @override
  void initState() {
    super.initState();
    // Clearing + losing focus collapses back to the icon.
    _focus.addListener(() {
      if (!_focus.hasFocus && _ctrl.text.isEmpty && _open && mounted) {
        setState(() => _open = false);
      }
    });
  }

  @override
  void didUpdateWidget(DkTrackToolbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.resetNonce != oldWidget.resetNonce) {
      _ctrl.clear();
      _open = false;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _collapse() {
    _ctrl.clear();
    widget.onQuery('');
    if (mounted) setState(() => _open = false);
  }

  @override
  Widget build(BuildContext context) {
    // Identity-only watch: rebuilds when the playing song changes, NOT on
    // every position tick.
    final (int, MusicSource)? now =
        context.select<PlayerProvider, (int, MusicSource)?>(
      (PlayerProvider p) {
        final Song? s = p.currentSong;
        return s == null ? null : (s.id, s.source);
      },
    );
    final bool canLocate = now != null &&
        widget.tracks.any((Song s) => s.id == now.$1 && s.source == now.$2);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          alignment: Alignment.centerRight,
          child: _open
              ? _field()
              : DkHoverIcon(
                  icon: Icons.search_rounded,
                  tooltip: '歌单内搜索',
                  onTap: () => setState(() => _open = true),
                ),
        ),
        const SizedBox(width: AppDimens.space4),
        DkHoverIcon(
          icon: Icons.my_location_rounded,
          tooltip: canLocate ? '定位到正在播放' : '当前播放的歌曲不在此歌单',
          color: canLocate ? null : AppColors.onFaint,
          onTap: canLocate ? widget.onLocate : null,
        ),
      ],
    );
  }

  Widget _field() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        DkGlass(
          radius: AppDimens.radiusPill,
          padding: const EdgeInsets.symmetric(horizontal: AppDimens.space12),
          child: SizedBox(
            width: 220,
            height: 36,
            child: Row(
              children: <Widget>[
                const Icon(Icons.search_rounded,
                    size: 16, color: AppColors.onMuted),
                const SizedBox(width: AppDimens.space8),
                Expanded(
                  child: Center(
                    child: TextField(
                      controller: _ctrl,
                      focusNode: _focus,
                      autofocus: true,
                      style: AppTypography.body,
                      cursorColor: AppColors.accentPlay,
                      decoration: InputDecoration.collapsed(
                        hintText: '搜索本歌单',
                        hintStyle: AppTypography.label,
                      ),
                      onChanged: (String v) {
                        widget.onQuery(v);
                        setState(() {}); // clear-X / count visibility
                      },
                    ),
                  ),
                ),
                if (_ctrl.text.isNotEmpty)
                  DkHoverIcon(
                    icon: Icons.close_rounded,
                    size: 14,
                    tooltip: '清除',
                    onTap: () {
                      _ctrl.clear();
                      widget.onQuery('');
                      setState(() {});
                      _focus.requestFocus();
                    },
                  ),
              ],
            ),
          ),
        ),
        if (_ctrl.text.trim().isNotEmpty && widget.matchCount != null)
          Padding(
            padding: const EdgeInsets.only(left: AppDimens.space8),
            child: Text('${widget.matchCount} 首', style: AppTypography.caption),
          ),
      ],
    );
  }
}

/// The shared scroll body of a playlist detail page: header sliver (built by
/// the page around the [DkTrackToolbar] this widget hands it) + padded
/// [DkTrackTable], with in-playlist search and 定位到正在播放 wired up.
///
/// Search-filter play semantics: [onPlayIndex] always receives the ORIGINAL
/// index into [tracks]; pages call `playQueue(tracks, index: i)` so the queue
/// stays the full playlist regardless of the filter.
class DkTrackPageBody extends StatefulWidget {
  /// The full, original tracks list.
  final List<Song> tracks;

  /// Builds the page-specific header; embed [toolbar] next to the header's
  /// existing action buttons.
  final Widget Function(BuildContext context, Widget toolbar) headerBuilder;

  /// Play a track by its ORIGINAL index in [tracks] (full-queue semantics).
  final void Function(int index) onPlayIndex;

  /// Open the ⋯ / right-click menu for an (original) [Song].
  final void Function(Song song, Offset globalPosition) onMenu;

  /// Rendered instead of the table when [tracks] is empty.
  final Widget emptyPlaceholder;

  const DkTrackPageBody({
    super.key,
    required this.tracks,
    required this.headerBuilder,
    required this.onPlayIndex,
    required this.onMenu,
    required this.emptyPlaceholder,
  });

  @override
  State<DkTrackPageBody> createState() => _DkTrackPageBodyState();
}

class _DkTrackPageBodyState extends State<DkTrackPageBody> {
  final ScrollController _scroll = ScrollController();
  final GlobalKey _tableHeaderKey = GlobalKey();

  String _query = '';
  int _resetNonce = 0;
  int? _flashIndex;
  int _flashNonce = 0;
  Timer? _flashTimer;

  DkTrackSearchIndex? _searchIndex;
  double? _rowStartCache;

  /// Lowercase keys, rebuilt only when the tracks LIST INSTANCE changes
  /// (copy-on-write providers hand out a new list on edit).
  DkTrackSearchIndex get _index {
    if (_searchIndex == null ||
        !identical(_searchIndex!.tracks, widget.tracks)) {
      _searchIndex = DkTrackSearchIndex(widget.tracks);
    }
    return _searchIndex!;
  }

  @override
  void initState() {
    super.initState();
    // Opportunistic measure while the header is guaranteed attached (page
    // opens at offset 0) so locate still works after scrolling it out of the
    // build window.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _measureRowStart();
    });
  }

  @override
  void dispose() {
    _flashTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  /// Scroll offset at which table row 0 begins: measured from the table's
  /// column-header block (GlobalKey) — its reveal offset within the viewport
  /// plus its own pixel height. Cached because the block is virtualized away
  /// when scrolled deep.
  double? _measureRowStart() {
    final BuildContext? ctx = _tableHeaderKey.currentContext;
    if (ctx != null) {
      final RenderObject? ro = ctx.findRenderObject();
      if (ro is RenderBox && ro.attached && ro.hasSize) {
        _rowStartCache =
            RenderAbstractViewport.of(ro).getOffsetToReveal(ro, 0).offset +
                ro.size.height;
      }
    }
    return _rowStartCache;
  }

  Future<void> _locate() async {
    final Song? cur = context.read<PlayerProvider>().currentSong;
    if (cur == null) return;
    final int orig = widget.tracks
        .indexWhere((Song s) => s.id == cur.id && s.source == cur.source);
    if (orig < 0) return;

    List<int>? visible = _query.trim().isEmpty ? null : _index.search(_query);
    if (visible != null && !visible.contains(orig)) {
      // The active filter hides the playing song: clear it first, then scroll
      // once the full list is laid out again.
      setState(() {
        _query = '';
        _resetNonce++;
      });
      visible = null;
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
    }

    if (!_scroll.hasClients) return;
    final double? rowStart = _measureRowStart();
    if (rowStart == null) return;

    // Visual position of the row under the current filter (== original index
    // when unfiltered).
    final int display = visible == null ? orig : visible.indexOf(orig);
    final ScrollPosition pos = _scroll.position;
    final double target = (rowStart +
            display * kDkTrackRowExtent +
            kDkTrackRowExtent / 2 -
            pos.viewportDimension / 2)
        .clamp(0.0, pos.maxScrollExtent)
        .toDouble();
    await _scroll.animateTo(
      target,
      duration: const Duration(milliseconds: 550),
      curve: Curves.easeInOutCubic,
    );
    if (!mounted) return;

    // Flash after the scroll settles; drop the trigger once the fade is done
    // so re-built rows don't replay it later.
    setState(() {
      _flashIndex = orig;
      _flashNonce++;
    });
    _flashTimer?.cancel();
    _flashTimer = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _flashIndex = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final List<int>? visible =
        _query.trim().isEmpty ? null : _index.search(_query);
    final Widget toolbar = DkTrackToolbar(
      tracks: widget.tracks,
      matchCount: visible?.length,
      resetNonce: _resetNonce,
      onQuery: (String v) => setState(() => _query = v),
      onLocate: _locate,
    );
    return CustomScrollView(
      controller: _scroll,
      slivers: <Widget>[
        SliverToBoxAdapter(child: widget.headerBuilder(context, toolbar)),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            AppDimens.space32,
            AppDimens.space16,
            AppDimens.space32,
            AppDimens.space48,
          ),
          sliver: widget.tracks.isEmpty
              ? SliverToBoxAdapter(child: widget.emptyPlaceholder)
              : DkTrackTable(
                  songs: widget.tracks,
                  visibleIndices: visible,
                  headerKey: _tableHeaderKey,
                  flashIndex: _flashIndex,
                  flashNonce: _flashNonce,
                  onPlay: widget.onPlayIndex,
                  onMenu: widget.onMenu,
                ),
        ),
      ],
    );
  }
}

class _DkSourceBadge extends StatelessWidget {
  final MusicSource source;
  const _DkSourceBadge({required this.source});

  @override
  Widget build(BuildContext context) {
    final String label;
    switch (source) {
      case MusicSource.netease:
        label = '网易';
      case MusicSource.migu:
        label = 'QQ';
      case MusicSource.kugou:
        label = '酷狗';
      case MusicSource.kugougn:
        label = '概念';
      case MusicSource.kuwo:
        label = '酷我';
      case MusicSource.qqcn:
        label = 'QQ安';
      case MusicSource.local:
        label = '本地';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: AppColors.glass,
        borderRadius: BorderRadius.circular(AppDimens.radiusSm),
        border: Border.all(color: AppColors.glassBorder),
      ),
      child: Text(
        label,
        style: AppTypography.caption.copyWith(fontSize: 10),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Song context menu (play / add to 共同歌单 / add to 我的歌单)
// ---------------------------------------------------------------------------

enum _DkMenuAction { play, addLocal, addUser, remove }

// ---------------------------------------------------------------------------
// White frosted-glass popup menu (shared by the song ⋯ menu + settings selectors)
// ---------------------------------------------------------------------------

const double _kDkMenuItemH = 44;
const double _kDkMenuDividerH = 9;

/// One row of a [dkShowGlassMenu]. Use [DkMenuEntry.divider] for a hairline.
class DkMenuEntry<T> {
  final T? value;
  final IconData? icon;
  final String? label;
  final bool selected;
  final bool danger;
  final bool divider;

  const DkMenuEntry({
    required this.value,
    this.icon,
    this.label,
    this.selected = false,
    this.danger = false,
  }) : divider = false;

  const DkMenuEntry.divider()
      : value = null,
        icon = null,
        label = null,
        selected = false,
        danger = false,
        divider = true;
}

/// Frosted-glass popup anchored at [globalPosition] (top-left), clamped on
/// screen. Matches the queue panel material per AMLL_FIDELITY_SPEC_2 §2:
/// blur 28, white α0.15 fill, white α0.25 hairline. Over the app's dark
/// frosted backdrops the panel reads dark, so item text/icons are **light**
/// (white α0.88 text / α0.72 icons — see [_DkGlassMenuItem]). Returns the
/// tapped entry's value, or null if dismissed.
Future<T?> dkShowGlassMenu<T>(
  BuildContext context,
  Offset globalPosition,
  List<DkMenuEntry<T>> entries, {
  double width = 236,
}) {
  double estHeight = 16; // top + bottom padding
  for (final DkMenuEntry<T> e in entries) {
    estHeight += e.divider ? _kDkMenuDividerH : _kDkMenuItemH;
  }
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 130),
    pageBuilder: (BuildContext ctx, _, __) {
      final Size sz = MediaQuery.of(ctx).size;
      final double left =
          globalPosition.dx.clamp(8.0, math.max(8.0, sz.width - width - 8));
      final double top = globalPosition.dy
          .clamp(8.0, math.max(8.0, sz.height - estHeight - 8));
      return Stack(
        children: <Widget>[
          Positioned(
            left: left,
            top: top,
            child: _DkGlassMenu<T>(width: width, entries: entries),
          ),
        ],
      );
    },
    // 「向下展开」：菜单锚定在触发器下方，从顶边纵向拉开（统一入场逻辑）。
    transitionBuilder:
        (BuildContext ctx, Animation<double> anim, _, Widget child) =>
            dkVerticalMenuTransition(anim, child),
  );
}

class _DkGlassMenu<T> extends StatelessWidget {
  final double width;
  final List<DkMenuEntry<T>> entries;

  const _DkGlassMenu({required this.width, required this.entries});

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppDimens.radiusMd),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 28, sigmaY: 28),
          child: Container(
            width: width,
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(AppDimens.radiusMd),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.25),
                width: 1,
              ),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.28),
                  blurRadius: 30,
                  offset: const Offset(0, 12),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (final DkMenuEntry<T> e in entries)
                  if (e.divider)
                    Container(
                      height: _kDkMenuDividerH,
                      alignment: Alignment.center,
                      child: Container(
                        height: 1,
                        margin: const EdgeInsets.symmetric(horizontal: 12),
                        color: Colors.white.withValues(alpha: 0.14),
                      ),
                    )
                  else
                    _DkGlassMenuItem<T>(entry: e),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DkGlassMenuItem<T> extends StatefulWidget {
  final DkMenuEntry<T> entry;
  const _DkGlassMenuItem({required this.entry});

  @override
  State<_DkGlassMenuItem<T>> createState() => _DkGlassMenuItemState<T>();
}

class _DkGlassMenuItemState<T> extends State<_DkGlassMenuItem<T>> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final DkMenuEntry<T> e = widget.entry;
    // Legible on the app's dark frosted surfaces: white α0.88 text,
    // white α0.72 icons (matches the other dk glass surfaces); light danger
    // red for destructive rows (same red as showWenContextMenu).
    final Color fg =
        e.danger ? const Color(0xFFEF4444) : const Color(0xE0FFFFFF);
    final Color iconC =
        e.danger ? const Color(0xFFEF4444) : const Color(0xB8FFFFFF);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => Navigator.of(context).pop(e.value),
        child: Container(
          height: _kDkMenuItemH,
          margin: const EdgeInsets.symmetric(horizontal: 6),
          padding: const EdgeInsets.symmetric(horizontal: AppDimens.space12),
          decoration: BoxDecoration(
            color: _hover
                ? Colors.white.withValues(alpha: 0.10)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(AppDimens.radiusSm),
          ),
          child: Row(
            children: <Widget>[
              if (e.icon != null) ...<Widget>[
                Icon(e.icon, size: 18, color: iconC),
                const SizedBox(width: AppDimens.space12),
              ],
              Expanded(
                child: Text(
                  e.label ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.body.copyWith(color: fg),
                ),
              ),
              if (e.selected) ...<Widget>[
                const SizedBox(width: AppDimens.space8),
                Icon(Icons.check_rounded,
                    size: 18, color: AppColors.accentOf(context)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Shows the right-click / ⋯ menu for [song] at [globalPosition] as a white
/// frosted-glass popup (see [dkShowGlassMenu]).
///
/// Always offers 播放 and 添加到共同歌单…; adds 添加到我的歌单… when the active
/// source is Netease; adds 从歌单移除 when [onRemove] is given.
Future<void> dkShowSongMenu(
  BuildContext context,
  Song song,
  Offset globalPosition, {
  VoidCallback? onRemove,
}) async {
  final bool netease =
      context.read<LibraryProvider>().source == MusicSource.netease;

  final _DkMenuAction? choice = await dkShowGlassMenu<_DkMenuAction>(
    context,
    globalPosition,
    <DkMenuEntry<_DkMenuAction>>[
      const DkMenuEntry<_DkMenuAction>(
          value: _DkMenuAction.play,
          icon: Icons.play_arrow_rounded,
          label: '播放'),
      const DkMenuEntry<_DkMenuAction>(
          value: _DkMenuAction.addLocal,
          icon: Icons.playlist_add_rounded,
          label: '添加到共同歌单…'),
      if (netease)
        const DkMenuEntry<_DkMenuAction>(
            value: _DkMenuAction.addUser,
            icon: Icons.favorite_border_rounded,
            label: '添加到我的歌单…'),
      if (onRemove != null) ...<DkMenuEntry<_DkMenuAction>>[
        const DkMenuEntry<_DkMenuAction>.divider(),
        const DkMenuEntry<_DkMenuAction>(
            value: _DkMenuAction.remove,
            icon: Icons.delete_outline_rounded,
            label: '从歌单移除',
            danger: true),
      ],
    ],
  );

  if (choice == null || !context.mounted) return;
  switch (choice) {
    case _DkMenuAction.play:
      await context.read<PlayerProvider>().playSong(song);
    case _DkMenuAction.addLocal:
      await dkAddToLocalPlaylist(context, song);
    case _DkMenuAction.addUser:
      await _dkAddToUserPlaylist(context, song);
    case _DkMenuAction.remove:
      onRemove?.call();
  }
}

/// Picks (or creates) a 共同歌单 and adds [song] to it.
Future<void> dkAddToLocalPlaylist(BuildContext context, Song song) async {
  final LocalPlaylistProvider lp = context.read<LocalPlaylistProvider>();
  final String? id = await showDialog<String>(
    context: context,
    builder: (BuildContext ctx) {
      return SimpleDialog(
        backgroundColor: AppColors.surface2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppDimens.radiusLg),
          side: const BorderSide(color: AppColors.glassBorder),
        ),
        title: Text('添加到共同歌单', style: AppTypography.titleM),
        children: <Widget>[
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, '__new__'),
            child: Row(
              children: <Widget>[
                const Icon(Icons.add_rounded, color: AppColors.accentPlay),
                const SizedBox(width: AppDimens.space12),
                Text('新建共同歌单…', style: AppTypography.body),
              ],
            ),
          ),
          const Divider(color: AppColors.glassBorder, height: 1),
          for (final dynamic pl in lp.playlists)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, pl.id as String),
              child: Row(
                children: <Widget>[
                  const Icon(Icons.queue_music_rounded,
                      color: AppColors.onMuted),
                  const SizedBox(width: AppDimens.space12),
                  Expanded(
                    child: Text(
                      '${pl.name} · ${pl.trackCount}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.body,
                    ),
                  ),
                ],
              ),
            ),
        ],
      );
    },
  );

  if (id == null || !context.mounted) return;
  if (id == '__new__') {
    final String? name =
        await dkPromptText(context, title: '新建共同歌单', hint: '歌单名称');
    if (name == null || name.trim().isEmpty || !context.mounted) return;
    await lp.create(name.trim(), tracks: <Song>[song]);
    if (context.mounted) dkToast(context, '已创建并添加到「${name.trim()}」');
    return;
  }
  final bool added = await lp.addSong(id, song);
  if (context.mounted) {
    dkToast(context, added ? '已添加到共同歌单' : '歌曲已在该歌单中');
  }
}

Future<void> _dkAddToUserPlaylist(BuildContext context, Song song) async {
  final LibraryProvider lib = context.read<LibraryProvider>();
  final List<dynamic> created = lib.createdPlaylists;
  if (created.isEmpty) {
    dkToast(context, '没有可添加的网易歌单（请先登录并创建）');
    return;
  }
  final int? pid = await showDialog<int>(
    context: context,
    builder: (BuildContext ctx) {
      return SimpleDialog(
        backgroundColor: AppColors.surface2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppDimens.radiusLg),
          side: const BorderSide(color: AppColors.glassBorder),
        ),
        title: Text('添加到我的歌单', style: AppTypography.titleM),
        children: <Widget>[
          for (final dynamic pl in created)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, pl.id as int),
              child: Row(
                children: <Widget>[
                  const Icon(Icons.queue_music_rounded,
                      color: AppColors.onMuted),
                  const SizedBox(width: AppDimens.space12),
                  Expanded(
                    child: Text(
                      pl.name as String,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.body,
                    ),
                  ),
                ],
              ),
            ),
        ],
      );
    },
  );
  if (pid == null || !context.mounted) return;
  try {
    await lib.addSongToPlaylist(pid, song);
    if (context.mounted) dkToast(context, '已添加到我的歌单');
  } catch (e) {
    if (context.mounted) dkToast(context, '添加失败：$e');
  }
}

/// A single-field text prompt dialog. Returns the entered text or null.
Future<String?> dkPromptText(
  BuildContext context, {
  required String title,
  String hint = '',
  String initial = '',
  String confirmLabel = '确定',
}) {
  final TextEditingController ctrl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (BuildContext ctx) {
      return AlertDialog(
        backgroundColor: AppColors.surface2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppDimens.radiusLg),
          side: const BorderSide(color: AppColors.glassBorder),
        ),
        title: Text(title, style: AppTypography.titleM),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: AppTypography.body,
          onSubmitted: (String v) => Navigator.pop(ctx, v),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: AppTypography.label,
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppDimens.radiusMd),
              borderSide: const BorderSide(color: AppColors.glassBorder),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppDimens.radiusMd),
              borderSide: const BorderSide(color: AppColors.accentPlay),
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('取消', style: AppTypography.label),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: Text(confirmLabel,
                style:
                    AppTypography.label.copyWith(color: AppColors.accentPlay)),
          ),
        ],
      );
    },
  );
}

// ---------------------------------------------------------------------------
// Small labelled avatar / membership pill used by accounts + settings
// ---------------------------------------------------------------------------

class DkVipPill extends StatelessWidget {
  final String label;
  const DkVipPill({super.key, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFFF5C518).withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(AppDimens.radiusSm),
        border:
            Border.all(color: const Color(0xFFF5C518).withValues(alpha: 0.5)),
      ),
      child: Text(
        label,
        style: AppTypography.caption.copyWith(
          color: const Color(0xFFF5C518),
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Source metadata shared by settings + login + accounts
// ---------------------------------------------------------------------------

/// The selectable UI music sources. The old web QQ (`migu` slot) was removed;
/// [MusicSource.qqcn] (Android QQ) is the only QQ source now.
const List<MusicSource> dkSelectableSources = <MusicSource>[
  MusicSource.netease,
  MusicSource.qqcn,
  MusicSource.kugou,
  MusicSource.kugougn,
  MusicSource.kuwo,
];

/// Display name for a UI source.
String dkSourceLabel(MusicSource s) {
  switch (s) {
    case MusicSource.netease:
      return '网易云音乐';
    case MusicSource.migu:
      return 'QQ音乐';
    case MusicSource.kugou:
      return '酷狗音乐';
    case MusicSource.kugougn:
      return '酷狗概念版';
    case MusicSource.kuwo:
      return '酷我音乐';
    case MusicSource.qqcn:
      return 'QQ音乐';
    case MusicSource.local:
      return '本地音乐';
  }
}

IconData dkSourceIcon(MusicSource s) {
  switch (s) {
    case MusicSource.netease:
      return Icons.cloud_outlined;
    case MusicSource.migu:
      return Icons.music_note_rounded;
    case MusicSource.kugou:
      return Icons.headphones_rounded;
    case MusicSource.kugougn:
      return Icons.auto_awesome_rounded;
    case MusicSource.kuwo:
      return Icons.radio_rounded;
    case MusicSource.qqcn:
      return Icons.music_note_outlined;
    case MusicSource.local:
      return Icons.folder_outlined;
  }
}

/// The login-route `:source` token for a UI source (kuwo/kugou/netease/qq).
String dkSourceLoginToken(MusicSource s) {
  switch (s) {
    case MusicSource.migu:
      return 'qq';
    case MusicSource.netease:
      return 'netease';
    case MusicSource.kugou:
      return 'kugou';
    case MusicSource.kugougn:
      return 'kugougn';
    case MusicSource.kuwo:
      return 'kuwo';
    case MusicSource.qqcn:
      return 'qqcn';
    case MusicSource.local:
      return 'netease';
  }
}

// ---------------------------------------------------------------------------
// QR rendering (shared by settings inline login + the login pages)
// ---------------------------------------------------------------------------

/// Decodes a `data:image/png;base64,…` (or bare base64) URL into bytes; null on
/// empty/invalid input.
Uint8List? dkDecodeDataUrl(String? dataUrl) {
  if (dataUrl == null || dataUrl.isEmpty) return null;
  final String raw = dataUrl.contains(',') ? dataUrl.split(',').last : dataUrl;
  try {
    return base64Decode(raw);
  } catch (_) {
    return null;
  }
}

/// A white QR card. Provide EITHER [content] (encoded client-side via qr_flutter,
/// for Netease's scanlogin URL) OR [bytes] (a server-rendered PNG, for QQ/Kugou).
/// Shows a spinner while [loading]; a hint when neither source is ready.
class DkQrCard extends StatelessWidget {
  final String? content;
  final Uint8List? bytes;
  final bool loading;
  final double size;

  const DkQrCard({
    super.key,
    this.content,
    this.bytes,
    this.loading = false,
    this.size = 200,
  });

  @override
  Widget build(BuildContext context) {
    Widget inner;
    if (loading) {
      inner = const Center(
        child: CircularProgressIndicator(
          color: Colors.black54,
          strokeWidth: 2.5,
        ),
      );
    } else if (bytes != null) {
      inner = Image.memory(bytes!,
          width: size, height: size, gaplessPlayback: true);
    } else if (content != null && content!.isNotEmpty) {
      inner = QrImageView(
        data: content!,
        version: QrVersions.auto,
        size: size,
        backgroundColor: Colors.white,
        eyeStyle: const QrEyeStyle(
          eyeShape: QrEyeShape.square,
          color: Colors.black,
        ),
        dataModuleStyle: const QrDataModuleStyle(
          dataModuleShape: QrDataModuleShape.square,
          color: Colors.black,
        ),
      );
    } else {
      inner = const Center(
        child: Icon(Icons.qr_code_2_rounded, color: Colors.black26, size: 64),
      );
    }
    return Container(
      width: size + 24,
      height: size + 24,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppDimens.radiusMd),
      ),
      child: inner,
    );
  }
}
