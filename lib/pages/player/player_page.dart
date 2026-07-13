import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../animation/neon_flow_background.dart';
import '../../models/local_playlist.dart';
import '../../models/playlist.dart';
import '../../models/song.dart';
import '../../router/routes.dart';
import '../../services/mem_probe.dart';
import '../../shell/window_drag_region.dart';
import '../../state/library_provider.dart';
import '../../state/local_playlist_provider.dart';
import '../../state/player_provider.dart';
import '../../state/settings_provider.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_dimens.dart';
import '../../theme/app_typography.dart';
import '../../widgets/amll_icons.dart';
import '../../widgets/artwork_image.dart';
import '../../widgets/entrance.dart';
import '../lyrics/widgets/lyrics_view.dart';
import 'widgets/bouncing_track.dart';
import 'widgets/media_button.dart';
import 'widgets/player_artwork.dart';
import 'widgets/player_scrubber.dart';
import 'widgets/queue_panel.dart';
import 'widgets/toggle_icon_button.dart';

/// Full-screen desktop now-playing surface — a code-level replica of AMLL's
/// **horizontal** `PrebuiltLyricPlayer` (matching `design/target.png`): the album
/// cover + music-info + BouncingSlider progress + transport + volume + a bottom
/// toggle row on the LEFT (info-side `0.45fr`), the AMLL synced-lyric column on
/// the RIGHT (player-side `0.55fr`), over a dynamic album mesh-gradient field.
///
/// The only sanctioned deviation from AMLL is our own page-top grabber (小横条)
/// to dismiss, instead of AMLL's cover-top ControlThumb. No back-arrow, no mic,
/// no heart (per the target). It consumes [PlayerProvider] via `context.select`
/// (field-level) so the per-second tick only rebuilds the scrubber.
class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key});

  /// Shell-visible lyric-surface signal: `true` while a mounted [PlayerPage]
  /// is actually SHOWING its lyric pane (a song is loaded and the bottom-bar
  /// lyrics toggle hasn't collapsed it). The window buttons live ABOVE the
  /// Router (in the `MaterialApp.router` `builder:` frame), so this page-
  /// internal state is bridged to them through a static [ValueNotifier] —
  /// `WindowButtons` combines it with the current route (`/player`) to decide
  /// when its auto-fade may run. Maintained by [_PlayerPageState] (published
  /// post-frame from `build`, reset on `dispose`).
  static final ValueNotifier<bool> lyricSurfaceActive =
      ValueNotifier<bool>(false);

  /// AMLL cover size for a given window (logical) size: `min(50vh, 38vw)`,
  /// `min(45vh, 38vw)` when height ≤ 1000, clamped 160–560. Shared between
  /// [_InfoColumn] (the real layout) and the shell prewarmer, which precaches
  /// the cover at exactly this display size so the mini→player Hero flight
  /// never decodes mid-flight.
  static double coverSizeFor(Size window) {
    final double vh = window.height <= 1000 ? 0.45 : 0.50;
    return math.min(vh * window.height, 0.38 * window.width).clamp(160.0, 560.0);
  }

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  // AMLL `hideLyricViewAtom`: the bottom lyrics toggle collapses the right pane
  // and lets the info column take the whole width.
  bool _hideLyric = false;

  // Entrance gate for the HEAVY lyric pane (suspect-c of the Hero-flight jank):
  // [LyricsView]'s first build TextPainter-measures every line (and every word
  // of word-by-word lines) and then rebuilds the singing line every vsync —
  // doing all of that DURING the 420ms push transition starved the flight down
  // to ~6–10 present/s. The pane now mounts only after the route's entrance
  // animation completes and fades in over 240ms (the page-level FadeTransition
  // has just reached 1.0, so this reads as the tail of the same entrance —
  // no pop-in). Pop direction is untouched: the pane is long-mounted by then.
  bool _entranceDone = false;
  Animation<double>? _entranceAnim;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_entranceDone || _entranceAnim != null) return;
    final Animation<double>? anim = ModalRoute.of(context)?.animation;
    if (anim == null) {
      _entranceDone = true;
      return;
    }
    // ALWAYS arm the listener — the initial status cannot be trusted. On this
    // go_router push path the route's controller reads `completed`/value 1.0
    // during the page's very first build and only rewinds to `forward`/0.0
    // later in the same frame (measured on the release build: didChange sees
    // completed@1.0, the first post-frame sees forward@0.0). Deciding "no
    // entrance" from that first reading disarms the gate on exactly the
    // flight it exists for. Instead, confirm at the first post-frame: if the
    // route is STILL `completed` there really is no entrance transition
    // (e.g. a no-animation restore) and the pane mounts immediately.
    _entranceAnim = anim;
    anim.addStatusListener(_onEntranceStatus);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _entranceDone || _entranceAnim == null) return;
      if (_entranceAnim!.status == AnimationStatus.completed) {
        _detachEntranceListener();
        setState(() => _entranceDone = true);
      }
    });
  }

  void _onEntranceStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    _detachEntranceListener();
    if (mounted) setState(() => _entranceDone = true);
  }

  void _detachEntranceListener() {
    _entranceAnim?.removeStatusListener(_onEntranceStatus);
    _entranceAnim = null;
  }

  @override
  void dispose() {
    MemProbe.instance.mark('player.dispose (→home)');
    _detachEntranceListener();
    // The page owns the shell-facing surface signal — clear it when the route
    // is disposed. Post-frame: dispose can run inside the frame's tree
    // finalization, and flipping the notifier synchronously there would
    // markNeedsBuild the shell-level WindowButtons mid-pipeline. (Route
    // changes already restore the buttons via the router listener; this is
    // the belt-and-braces reset for the notifier itself.)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      PlayerPage.lyricSurfaceActive.value = false;
    });
    super.dispose();
  }

  /// Publishes "the lyric pane is on screen" to [PlayerPage.lyricSurfaceActive].
  /// Called from `build` (the single place that knows both `hasSong` and
  /// `_hideLyric`), so the write is deferred to post-frame — the shell's
  /// WindowButtons listens to this notifier, and notifying synchronously
  /// during this page's build would call `setState` on a widget that has
  /// already built this frame.
  bool _publishedSurface = false;
  void _publishLyricSurface(bool active) {
    if (_publishedSurface == active) return;
    _publishedSurface = active;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Reads the field (not the captured arg) so if several rebuilds land in
      // one frame the LAST computed state wins.
      if (mounted) PlayerPage.lyricSurfaceActive.value = _publishedSurface;
    });
  }

  void _dismiss() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(Routes.home);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool hasSong =
        context.select<PlayerProvider, bool>((PlayerProvider p) => p.hasSong);
    _publishLyricSurface(hasSong && !_hideLyric);

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: _ErrorListener(
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            const _Background(),
            SafeArea(
              child: Column(
                children: <Widget>[
                  _Grabber(onTap: _dismiss),
                  Expanded(
                    child: hasSong
                        ? _TwoPaneBody(
                            hideLyric: _hideLyric,
                            lyricsReady: _entranceDone,
                          )
                        : const _EmptyBody(),
                  ),
                  // AMLL `horizontalBottomControls`: a dedicated full-width row
                  // at the page bottom (grid-column 1/4), NOT nested in the info
                  // column — AirPlay pinned bottom-left, lyrics + queue bottom-
                  // right.
                  if (hasSong)
                    _PageBottomBar(
                      hideLyric: _hideLyric,
                      onToggleLyric: () =>
                          setState(() => _hideLyric = !_hideLyric),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The AMLL mesh-gradient field (`BackgroundRender`) behind everything, plus a
/// vertical scrim keeping controls / lyrics legible. Tinted by the album art.
class _Background extends StatelessWidget {
  const _Background();

  @override
  Widget build(BuildContext context) {
    final String? artworkUrl =
        context.select<PlayerProvider, String?>((p) => p.currentSong?.artworkUrl);
    final List<Color> colors =
        context.select<PlayerProvider, List<Color>>((p) => p.paletteColors);
    final bool playing =
        context.select<PlayerProvider, bool>((p) => p.isPlaying);
    final bool reactive =
        context.select<SettingsProvider, bool>((s) => s.rhythmEnabled);
    // Freeze this field while /lyrics is animating OVER this page: the player's
    // secondaryAnimation drives 1→0 as /lyrics pops, so 0<t<1 hits the morph
    // freeze gate and the revealed player field holds its last cached frame
    // instead of rastering a SECOND full ~40k-vertex draw + toImageSync
    // concurrently with the outgoing lyrics field — the other half of the
    // close-transition dual-mesh peak. (At rest with /lyrics fully open,
    // secondaryAnimation==1.0 and this page is obscured/offstage, not painting.)
    final Animation<double>? morph = ModalRoute.of(context)?.secondaryAnimation;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        RepaintBoundary(
          child: NeonFlowBackground(
            imageUrl: artworkUrl,
            colors: colors,
            playing: playing,
            reactive: reactive,
            morph: morph,
          ),
        ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[
                Color(0x33000000),
                Color(0x1A000000),
                Color(0x40000000),
              ],
              stops: <double>[0.0, 0.5, 1.0],
            ),
          ),
        ),
      ],
    );
  }
}

/// Top-centre pull handle. Tap dismisses the sheet.
///
/// The strip's EMPTY area doubles as the page's window-drag region (this route
/// covers the shell, so the top bar's drag middle is unreachable): a
/// [WindowDragRegion] fills the strip UNDER the pill, giving drag-to-move +
/// double-click maximize, fullscreen-guarded. The pill sits ON TOP with an
/// opaque hit test, so its taps never reach the strip — close always wins.
class _Grabber extends StatelessWidget {
  final VoidCallback onTap;
  const _Grabber({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 34,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          const WindowDragRegion(),
          Center(
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onTap,
                child: Container(
                  width: 42,
                  height: 5,
                  margin: const EdgeInsets.only(top: 12),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// AMLL horizontal grid: LEFT info column (`0.45fr`) · RIGHT lyric pane
/// (`0.55fr`). Collapses to the info column alone on very narrow windows
/// (< 760 content px) or when the lyrics toggle hides the pane. Measures the
/// cover's vertical centre and feeds it to the lyric pane so the bright active
/// line sits level with the cover (AMLL `alignAnchor:"center"`).
class _TwoPaneBody extends StatefulWidget {
  final bool hideLyric;

  /// False only while the route's entrance animation is still running — the
  /// lyric pane's slot stays empty (the mesh shows through, exactly what the
  /// fading-in page looked like anyway) and the pane mounts + fades in once
  /// the flight has settled. See [_PlayerPageState._entranceDone].
  final bool lyricsReady;

  const _TwoPaneBody({required this.hideLyric, required this.lyricsReady});

  @override
  State<_TwoPaneBody> createState() => _TwoPaneBodyState();
}

class _TwoPaneBodyState extends State<_TwoPaneBody> {
  final GlobalKey _bodyKey = GlobalKey();
  final GlobalKey _coverKey = GlobalKey();
  double _alignPosition = 0.34; // AMLL fallback (cover-centre fraction)

  // Guard so `_measure` is only re-scheduled when the constraints that affect
  // the cover-centre actually change — NOT on every build. Without this the
  // per-frame `TweenAnimationBuilder` rebuilds below would schedule a post-frame
  // measure every frame (and `_measure`'s `setState` could loop into it).
  Size? _measuredFor;

  void _measure() {
    final BuildContext? bodyCtx = _bodyKey.currentContext;
    final BuildContext? coverCtx = _coverKey.currentContext;
    if (bodyCtx == null || coverCtx == null) return;
    final RenderBox? body = bodyCtx.findRenderObject() as RenderBox?;
    final RenderBox? cover = coverCtx.findRenderObject() as RenderBox?;
    if (body == null || cover == null || !body.hasSize || !cover.hasSize) {
      return;
    }
    final double h = body.size.height;
    if (h <= 0) return;
    final double bodyTop = body.localToGlobal(Offset.zero).dy;
    final double coverCentre =
        cover.localToGlobal(Offset(0, cover.size.height / 2)).dy;
    final double frac = ((coverCentre - bodyTop) / h).clamp(0.08, 0.9);
    if ((frac - _alignPosition).abs() > 0.003) {
      setState(() => _alignPosition = frac);
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      key: _bodyKey,
      builder: (BuildContext context, BoxConstraints c) {
        final Size size = Size(c.maxWidth, c.maxHeight);
        if (_measuredFor != size) {
          _measuredFor = size;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _measure();
          });
        }

        final bool wide = c.maxWidth >= 760;
        final Widget info = _InfoColumn(coverKey: _coverKey);
        if (!wide) return info;

        // AMLL `hideLyricViewAtom`: rather than a hard swap, the info column
        // eases its width 45%↔100% while the lyric pane fades + is revealed/
        // clipped over 0.5s `cubic-bezier(.5,0,.5,1)` (spec §5). The lyric child
        // keeps its full 55% width the whole time (no per-frame re-layout) and
        // is just clipped + faded, so the animation stays smooth.
        return TweenAnimationBuilder<double>(
          tween: Tween<double>(end: widget.hideLyric ? 1.0 : 0.0),
          duration: const Duration(milliseconds: 500),
          curve: const Cubic(0.5, 0, 0.5, 1),
          builder: (BuildContext context, double hide, Widget? _) {
            final double total = c.maxWidth;
            final double lyricFullW = total * 0.55;
            final double infoW = total * (0.45 + 0.55 * hide);
            final double lyricW = (total - infoW).clamp(0.0, lyricFullW);
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                SizedBox(width: infoW, child: info),
                SizedBox(
                  width: lyricW,
                  child: lyricW < 1
                      ? const SizedBox.shrink()
                      : ClipRect(
                          child: OverflowBox(
                            alignment: Alignment.centerLeft,
                            minWidth: 0,
                            maxWidth: lyricFullW,
                            child: Opacity(
                              // Fade a touch faster than the slide (AMLL fades
                              // the lyric over 0.25s vs the 0.5s slide).
                              opacity: Curves.easeOut
                                  .transform((1 - hide).clamp(0.0, 1.0)),
                              child: SizedBox(
                                width: lyricFullW,
                                // Entrance defer: AnimatedOpacity animates only
                                // when `lyricsReady` FLIPS (the one moment the
                                // pane mounts post-flight); on every later
                                // rebuild / lyric-toggle remount it is a
                                // constant 1.0, so the AMLL 0.5s/0.25s toggle
                                // motion above is untouched.
                                child: AnimatedOpacity(
                                  opacity: widget.lyricsReady ? 1.0 : 0.0,
                                  duration: const Duration(milliseconds: 240),
                                  curve: Curves.easeOut,
                                  child: widget.lyricsReady
                                      ? _LyricsPane(
                                          alignPosition: _alignPosition)
                                      : const SizedBox.expand(),
                                ),
                              ),
                            ),
                          ),
                        ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

/// The LEFT column: the album cover + control block form a single TIGHT cluster
/// (cover-scaled gaps, no free `space-between` slack) that is centred vertically
/// in the column. Cover, transport icons, big play button and meta type all
/// scale with the window (spec §1.1–1.4), and the control block is width-clamped
/// to the cover and centred (AMLL `.controls`), so it reads like target.png at
/// both small and maximized sizes instead of ballooning apart.
class _InfoColumn extends StatelessWidget {
  final Key? coverKey;

  const _InfoColumn({this.coverKey});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final Size media = MediaQuery.of(context).size;
        // AMLL: cover = min(50vh, 38vw); min(45vh, 38vw) when height <= 1000.
        // Keyed off the WINDOW (viewport) so the whole cluster grows on a
        // maximized/fullscreen window — no 460 cap that pins it small.
        // Formula lives on [PlayerPage.coverSizeFor] so the shell prewarmer can
        // precache the cover at exactly this display size.
        final double coverSize = PlayerPage.coverSizeFor(media);

        // Cover-scaled rhythm (spec §1.4): fixed em-like gaps tied to the cover
        // instead of `space-between` free space, so the four rows stay a TIGHT
        // centred cluster instead of ballooning apart on a tall window.
        // Row rhythm measured off target.png (cover-normalized centre gaps):
        // cover→meta reads roomier and transport→volume TIGHTER than before.
        final double gCoverMeta = coverSize * 0.075; // more air under the cover
        final double gMetaScrub = coverSize * 0.05;
        final double gScrubTrans = coverSize * 0.06;
        final double gTransVol = coverSize * 0.04; // pull volume up to transport

        final Widget cluster = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Center(child: _Cover(key: coverKey, size: coverSize)),
            SizedBox(height: gCoverMeta),
            // Control block clamped to the cover width and centred (AMLL
            // `.controls { width: var(--horizontal-layout-max-width) }`).
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: coverSize),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _MetaRow(coverSize: coverSize),
                  SizedBox(height: gMetaScrub),
                  const _ScrubberBar(),
                  SizedBox(height: gScrubTrans),
                  _Transport(coverSize: coverSize),
                  SizedBox(height: gTransVol),
                  _VolumeRow(coverSize: coverSize),
                ],
              ),
            ),
          ],
        );

        // Vertically centre the cover+controls cluster in the info column, and
        // fall back to scrolling only if the window is too short to fit it —
        // never stretch the rows apart.
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: c.maxHeight),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppDimens.space16),
              child: Center(child: cluster),
            ),
          ),
        );
      },
    );
  }
}

/// Album cover with the AMLL pause-dip: rests at 1.0 while playing, dips to 0.86
/// when paused (400ms easeOutCubic).
///
/// Presents an [ArtworkImage] tagged `'album_art'` — the SAME shared-element tag
/// the mini-player thumbnail carries (`mini_player.dart`) — so opening / closing
/// the now-playing surface flies the cover between the two, morphing corner
/// radius + fading the shadow via [ArtworkImage]'s flight shuttle (spec §6). The
/// pause-dip [Transform.scale] wraps the Hero (not the reverse) so the flight
/// geometry never fights the dip.
class _Cover extends StatelessWidget {
  final double size;
  const _Cover({super.key, required this.size});

  @override
  Widget build(BuildContext context) {
    final String? artworkUrl =
        context.select<PlayerProvider, String?>((p) => p.currentSong?.artworkUrl);
    final bool playing =
        context.select<PlayerProvider, bool>((p) => p.isPlaying);
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: playing ? 1.0 : 0.86),
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOutCubic,
      builder: (BuildContext _, double dip, Widget? child) =>
          Transform.scale(scale: dip, child: child),
      child: ArtworkImage(
        url: artworkUrl,
        size: size,
        radius: AppDimens.albumRadius(size),
        heroTag: 'album_art',
        shadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x59000000),
            blurRadius: 34,
            offset: Offset(0, 18),
            spreadRadius: -6,
          ),
        ],
      ),
    );
  }
}

/// AMLL `MusicInfo`: song title (display font) + artist, with a real "···"
/// add-to-playlist popup on the trailing edge. No heart / like (per target.png).
class _MetaRow extends StatelessWidget {
  final double coverSize;
  const _MetaRow({required this.coverSize});

  @override
  Widget build(BuildContext context) {
    final String title = context
        .select<PlayerProvider, String>((p) => p.currentSong?.name ?? '');
    final String artist = context
        .select<PlayerProvider, String>((p) => p.currentSong?.artistNames ?? '');

    // Meta type scales with the cover (spec §1.4 "meta font SCALE with window").
    // At cover ~330 this lands on the previous fixed 26/16 sizes and grows past.
    final double titleSize = (coverSize * 0.075).clamp(18.0, 34.0);
    final double artistSize = titleSize * 0.62;
    // AMLL `MenuButton` = 3.5vh circle, glyph 72% of it. Scaled off the cover so
    // it reads as big as target.png (~0.08·cover circle) instead of the old
    // fixed 38/20.
    final double moreSize = (coverSize * 0.078).clamp(38.0, 54.0);
    final double moreGlyph = moreSize * 0.6;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                title,
                style: AppTypography.displayM.copyWith(
                  fontSize: titleSize,
                  height: 1.15,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.4,
                  color: Colors.white.withValues(alpha: 0.95),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: AppDimens.space4),
              Text(
                artist,
                style: AppTypography.label.copyWith(
                  fontSize: artistSize,
                  letterSpacing: 0.4,
                  color: Colors.white.withValues(alpha: 0.5),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        const SizedBox(width: AppDimens.space8),
        _MorePopup(size: moreSize, glyphSize: moreGlyph),
      ],
    );
  }
}

/// The "···" overflow: the AMLL `MenuButton` chip (`#ffffff15` frosted circle +
/// `icon_more` glyph) opening a **frosted-glass** popover anchored under it with
/// "添加到歌单" / "添加到本地歌单", each opening a picker dialog. Never a toast.
///
/// `PopupMenuButton` can't host a `BackdropFilter` behind its Material menu, so
/// the popover is a bespoke `showGeneralDialog` overlay whose panel shares the
/// queue panel's glass material (spec §3/§4).
class _MorePopup extends StatefulWidget {
  /// Diameter of the frosted circle chip.
  final double size;

  /// The `···` glyph box inside the chip.
  final double glyphSize;

  const _MorePopup({this.size = 38, this.glyphSize = 20});

  @override
  State<_MorePopup> createState() => _MorePopupState();
}

class _MorePopupState extends State<_MorePopup> {
  final GlobalKey _anchorKey = GlobalKey();

  void _open() {
    final Song? song = context.read<PlayerProvider>().currentSong;
    if (song == null) return;
    final RenderBox? box =
        _anchorKey.currentContext?.findRenderObject() as RenderBox?;
    final RenderBox? overlay =
        Navigator.of(context).overlay?.context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;
    // Anchor rect in overlay coordinates.
    final Offset topLeft = box.localToGlobal(Offset.zero, ancestor: overlay);
    final Rect anchor = topLeft & box.size;

    showGeneralDialog<void>(
      context: context,
      barrierColor: Colors.transparent,
      barrierDismissible: true,
      barrierLabel: '更多',
      transitionDuration: const Duration(milliseconds: 160),
      pageBuilder: (BuildContext _, __, ___) => const SizedBox.shrink(),
      transitionBuilder: (BuildContext ctx, Animation<double> anim, _,
          Widget __) {
        const double menuW = 208;
        final double left = math.min(
          anchor.right - menuW,
          overlay.size.width - menuW - 8,
        );
        return Stack(
          children: <Widget>[
            Positioned(
              left: math.max(8, left),
              top: anchor.bottom + 6,
              // 「向下展开」：菜单从顶边向下拉开（统一入场逻辑）。
              child: dkVerticalMenuTransition(
                anim,
                _MoreMenuPanel(
                  width: menuW,
                  onAddToPlaylist: () {
                    Navigator.of(ctx).pop();
                    _showAddToPlaylist(context, song);
                  },
                  onAddToLocalPlaylist: () {
                    Navigator.of(ctx).pop();
                    _showAddToLocalPlaylist(context, song);
                  },
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '更多',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _open,
          child: Container(
            key: _anchorKey,
            width: widget.size,
            height: widget.size,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Color(0x1FFFFFFF), // AMLL MenuButton `#ffffff15`
            ),
            child: AmllMoreIcon(size: widget.glyphSize),
          ),
        ),
      ),
    );
  }

  void _showAddToPlaylist(BuildContext context, Song song) {
    showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => _AddToPlaylistDialog(song: song),
    );
  }

  void _showAddToLocalPlaylist(BuildContext context, Song song) {
    showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => _AddToLocalPlaylistDialog(song: song),
    );
  }
}

/// The frosted-glass surface of the ⋯ popover: a `BackdropFilter` blur + dark
/// translucent tint + hairline + 12px radius (matching the queue panel), with
/// the two add-to-playlist actions as hover-tinted rows.
class _MoreMenuPanel extends StatelessWidget {
  final double width;
  final VoidCallback onAddToPlaylist;
  final VoidCallback onAddToLocalPlaylist;

  const _MoreMenuPanel({
    required this.width,
    required this.onAddToPlaylist,
    required this.onAddToLocalPlaylist,
  });

  @override
  Widget build(BuildContext context) {
    // White Apple-Music frosted glass, matching the queue panel (spec §2):
    // blur 28, white α0.15 fill, white α0.25 hairline, deep drop shadow.
    return Material(
      type: MaterialType.transparency,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          boxShadow: const <BoxShadow>[
            BoxShadow(
              color: Color(0x47000000), // black α0.28
              blurRadius: 30,
              offset: Offset(0, 12),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 28, sigmaY: 28),
            child: Container(
              width: width,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                    color: Colors.white.withValues(alpha: 0.25), width: 1),
              ),
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  _MoreMenuItem(
                    icon: Icons.playlist_add_rounded,
                    label: '添加到歌单',
                    onTap: onAddToPlaylist,
                  ),
                  _MoreMenuItem(
                    icon: Icons.library_add_rounded,
                    label: '添加到本地歌单',
                    onTap: onAddToLocalPlaylist,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A single hover-tinted row inside [_MoreMenuPanel].
class _MoreMenuItem extends StatefulWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _MoreMenuItem({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  State<_MoreMenuItem> createState() => _MoreMenuItemState();
}

class _MoreMenuItemState extends State<_MoreMenuItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          // Dark text/icon on the light-frosted surface (spec §2); hover fill
          // is a black wash, not white.
          color: _hover ? const Color(0x0F000000) : Colors.transparent,
          padding: const EdgeInsets.symmetric(
              horizontal: AppDimens.space16, vertical: 10),
          child: Row(
            children: <Widget>[
              Icon(widget.icon, color: const Color(0xB8000000), size: 20),
              const SizedBox(width: AppDimens.space12),
              Text(
                widget.label,
                style: AppTypography.body
                    .copyWith(color: const Color(0xE0000000)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Isolates the position/duration ticks so a per-second tick rebuilds only the
/// scrubber, never the surrounding column.
class _ScrubberBar extends StatelessWidget {
  const _ScrubberBar();

  @override
  Widget build(BuildContext context) {
    final Duration position =
        context.select<PlayerProvider, Duration>((p) => p.position);
    final Duration duration =
        context.select<PlayerProvider, Duration>((p) => p.duration);
    // The scrubber legitimately rebuilds every second (position tick); isolate
    // its paint so it can't dirty neighbouring controls.
    return RepaintBoundary(
      child: PlayerScrubber(
        position: position,
        duration: duration,
        onSeek: context.read<PlayerProvider>().seek,
      ),
    );
  }
}

/// AMLL transport row: shuffle · ⏪ prev · big play/pause · ⏩ next · repeat,
/// every control a monochrome-white [MediaButton]. Active toggles pure white,
/// inactive dims to white @ 50 %. Uses the double-triangle fast-rewind /
/// fast-forward glyphs to match target.png (not skip-with-bar).
class _Transport extends StatelessWidget {
  final double coverSize;
  const _Transport({required this.coverSize});

  static const Color _white = Color(0xFFFFFFFF);
  static const Color _dim = Color(0x80FFFFFF);

  @override
  Widget build(BuildContext context) {
    final bool isPlaying =
        context.select<PlayerProvider, bool>((p) => p.isPlaying);
    final bool isBuffering =
        context.select<PlayerProvider, bool>((p) => p.isBuffering);
    final bool shuffleEnabled =
        context.select<PlayerProvider, bool>((p) => p.shuffleEnabled);
    final int repeatModeIndex =
        context.select<PlayerProvider, int>((p) => p.repeatMode.index);
    final PlayerProvider player = context.read<PlayerProvider>();
    final Color repeatColor = repeatModeIndex != 0 ? _white : _dim;

    // Button hit-circles + glyphs SCALE with the cover (spec §1.3). Sizes are
    // measured off AMLL's `design/target.png` (cover-normalized): the five
    // `space-between` buttons spread nearly EDGE-TO-EDGE (shuffle/repeat sit
    // tight to the cover rim → tiny outer hit-circles), and — the key parity
    // fix — the rewind/forward double-arrows are CHUNKY, ~1.7× their old size,
    // reading almost as large as the pause. Measured target vs. our prior look:
    //   • transport centre-span  0.92·cover  (was 0.83; target 0.95)
    //   • prev/next glyph width  0.092·cover  (was 0.054 → ×1.7)
    //   • play/pause glyph       ~unchanged (0.115·cover tall) — already right
    //   • shuffle/repeat glyph   0.042·cover  (small bump; the fix is position)
    final double sideBtn = coverSize * 0.08; // shuffle / repeat (edge-tight)
    final double midBtn = coverSize * 0.19; // prev / next
    final double playBtn = coverSize * 0.18; // play/pause
    final double playGlyph = coverSize * 0.12; // pause bars ≈0.115·cover tall
    final double sideGlyph = coverSize * 0.15; // prev / next double-arrow (chunky)
    final double smallGlyph = coverSize * 0.065; // shuffle / repeat glyph

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: <Widget>[
        MediaButton(
          size: sideBtn,
          onPressed: player.toggleShuffle,
          child: AmllShuffleIcon(
              size: smallGlyph, color: shuffleEnabled ? _white : _dim),
        ),
        MediaButton(
          size: midBtn,
          onPressed: player.previous,
          child: AmllPreviousIcon(size: sideGlyph, color: _white),
        ),
        MediaButton(
          size: playBtn,
          onPressed: player.togglePlay,
          child: isBuffering
              ? SizedBox(
                  width: playGlyph * 0.65,
                  height: playGlyph * 0.65,
                  child: const CircularProgressIndicator(
                      strokeWidth: 2, color: _white),
                )
              : (isPlaying
                  ? AmllPauseIcon(size: playGlyph, color: _white)
                  : AmllPlayIcon(size: playGlyph, color: _white)),
        ),
        MediaButton(
          size: midBtn,
          onPressed: player.next,
          child: AmllNextIcon(size: sideGlyph, color: _white),
        ),
        MediaButton(
          size: sideBtn,
          onPressed: player.cycleRepeat,
          child: repeatModeIndex == 2
              ? AmllRepeatOneIcon(size: smallGlyph, color: repeatColor)
              : AmllRepeatIcon(size: smallGlyph, color: repeatColor),
        ),
      ],
    );
  }
}

/// AMLL `VolumeControl`: a knob-less [BouncingTrack] flanked by the two speaker
/// glyphs. Selects only [PlayerProvider.volume].
class _VolumeRow extends StatelessWidget {
  final double coverSize;
  const _VolumeRow({required this.coverSize});

  @override
  Widget build(BuildContext context) {
    final double volume =
        context.select<PlayerProvider, double>((p) => p.volume);
    final PlayerProvider player = context.read<PlayerProvider>();
    const Color speaker = Color(0x80FFFFFF); // white @ 50%
    // Speaker glyphs scale with the cover (land on the old 18/22 near cover 400).
    final double lowSize = (coverSize * 0.045).clamp(14.0, 26.0);
    final double highSize = (coverSize * 0.05).clamp(16.0, 30.0);
    return Row(
      children: <Widget>[
        AmllVolumeLowIcon(size: lowSize, color: speaker),
        const SizedBox(width: AppDimens.space12),
        Expanded(
          child: BouncingTrack(
            value: volume.clamp(0.0, 1.0),
            onChanged: player.setVolume,
            onChangeEnd: player.setVolume,
          ),
        ),
        const SizedBox(width: AppDimens.space12),
        AmllVolumeHighIcon(size: highSize, color: speaker),
      ],
    );
  }
}

/// AMLL `horizontalBottomControls` — a page-level, full-width row (grid-column
/// 1/4) pinned to the window's bottom edge: AirPlay at the far bottom-**left**,
/// a flex spacer, then the lyrics toggle + playlist/queue button at the far
/// bottom-**right** (AMLL `flex-direction: row-reverse`). Horizontal insets track
/// AMLL's `4em` (`2em` on windows ≤1600px wide). The lyrics toggle only shows on
/// wide layouts, where the right pane exists to collapse.
class _PageBottomBar extends StatelessWidget {
  final bool hideLyric;
  final VoidCallback onToggleLyric;

  const _PageBottomBar({required this.hideLyric, required this.onToggleLyric});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final bool wide = c.maxWidth >= 760;
        // AMLL: gap/padding 4em → 2em under `max-width:1600px`; the toggle
        // buttons themselves are 4em → 3em (`ToggleIconButton` spec), so the
        // bottom glyphs read as big as target.png — NOT the old tiny 26px.
        final bool small = c.maxWidth <= 1600;
        final double pad = small ? 32 : 64;
        final double gap = small ? 32 : 64;
        // Glyph fills the AMLL 4em(≈64)/3em(≈48) button. `size` here is the
        // glyph box; the AMLL vectors fit their viewBox inside it.
        final double iconSize = small ? 40 : 52;
        final double btnTarget = small ? 50 : 64;
        return Padding(
          padding: EdgeInsets.fromLTRB(pad, 4, pad, 10),
          child: Row(
            children: <Widget>[
              ToggleIconButton(
                tooltip: 'AirPlay',
                iconSize: iconSize,
                target: btnTarget,
                onTap: () =>
                    _snack(ScaffoldMessenger.of(context), 'AirPlay 暂不支持'),
                child: AmllAirplayIcon(size: iconSize),
              ),
              const Spacer(),
              if (wide) ...<Widget>[
                ToggleIconButton(
                  checked: !hideLyric,
                  tooltip: hideLyric ? '显示歌词' : '隐藏歌词',
                  iconSize: iconSize,
                  target: btnTarget,
                  onTap: onToggleLyric,
                  // AMLL ToggleIconButton state pair: checked (lyrics shown) →
                  // lyrics_on.svg filled plate; unchecked → lyrics_off.svg
                  // outlined bubble.
                  child:
                      AmllLyricsToggleIcon(size: iconSize, filled: !hideLyric),
                ),
                SizedBox(width: gap),
              ],
              ToggleIconButton(
                tooltip: '播放队列',
                iconSize: iconSize,
                target: btnTarget,
                onTap: () => showQueuePanel(context),
                child: AmllPlaylistIcon(size: iconSize),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// The right lyrics pane: the AMLL [LyricsView] with soft top/bottom fade masks
/// so lines dissolve at the column edges (like target.png). Its active line is
/// anchored at [alignPosition] — the measured cover-centre fraction.
class _LyricsPane extends StatelessWidget {
  final double alignPosition;
  const _LyricsPane({required this.alignPosition});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        // AMLL `.lyric { padding-right: 15% }` (8% on narrow/short windows).
        final bool tight = c.maxWidth <= 1600 || c.maxHeight <= 1000;
        final double padRight = c.maxWidth * (tight ? 0.08 : 0.15);
        // Edge dissolve is delegated to LyricsView's per-line LineEdgeFade
        // (fadeTop/BottomFraction) instead of a pane-sized ShaderMask — that
        // mask forced a near-full-window saveLayer EVERY frame the lyrics
        // animate, and it was the last such layer on this surface.
        return Padding(
          padding: EdgeInsets.only(right: padRight),
          child: LyricsView(
            padding: const EdgeInsets.symmetric(horizontal: AppDimens.space24),
            alignPosition: alignPosition,
            fadeTopFraction: 0.10,
            fadeBottomFraction: 0.10,
          ),
        );
      },
    );
  }
}

/// Empty state when nothing is queued.
class _EmptyBody extends StatelessWidget {
  const _EmptyBody();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(Icons.music_off_rounded,
              size: 64, color: AppColors.onSurfaceFaint),
          const SizedBox(height: AppDimens.space16),
          Text('当前没有播放', style: AppTypography.titleM),
        ],
      ),
    );
  }
}

/// Surfaces [PlayerProvider.playbackError] once as a floating snack bar.
class _ErrorListener extends StatelessWidget {
  final Widget child;
  const _ErrorListener({required this.child});

  @override
  Widget build(BuildContext context) {
    final String? error =
        context.select<PlayerProvider, String?>((p) => p.playbackError);
    if (error != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        _snack(ScaffoldMessenger.of(context), error);
        context.read<PlayerProvider>().clearPlaybackError();
      });
    }
    return child;
  }
}

void _snack(ScaffoldMessengerState messenger, String message) {
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(message, style: AppTypography.body),
      behavior: SnackBarBehavior.floating,
      backgroundColor: AppColors.surface,
    ));
}

/// Dialog: add [song] to one of the signed-in user's playlists.
class _AddToPlaylistDialog extends StatefulWidget {
  final Song song;
  const _AddToPlaylistDialog({required this.song});

  @override
  State<_AddToPlaylistDialog> createState() => _AddToPlaylistDialogState();
}

class _AddToPlaylistDialogState extends State<_AddToPlaylistDialog> {
  late final LibraryProvider _lib;

  @override
  void initState() {
    super.initState();
    _lib = context.read<LibraryProvider>();
    if (_lib.userPlaylists.isEmpty && !_lib.userPlaylistsLoading) {
      _lib.loadUserPlaylists();
    }
  }

  Future<void> _add(Playlist playlist) async {
    final NavigatorState navigator = Navigator.of(context);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    navigator.pop();
    try {
      await _lib.addSongToPlaylist(playlist.id, widget.song);
      _snack(messenger, '已添加到「${playlist.name}」');
    } catch (_) {
      _snack(messenger, '添加失败');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface,
      title: const Text('添加到歌单', style: AppTypography.titleM),
      content: SizedBox(
        width: 360,
        height: 380,
        child: Consumer<LibraryProvider>(
          builder: (BuildContext context, LibraryProvider lib, Widget? _) {
            if (lib.userPlaylistsLoading) {
              return const Center(child: CircularProgressIndicator());
            }
            if (lib.createdPlaylists.isEmpty) {
              return Center(
                child: Text('暂无可用歌单（请先登录）',
                    style: AppTypography.label, textAlign: TextAlign.center),
              );
            }
            return ListView.builder(
              itemCount: lib.createdPlaylists.length,
              itemBuilder: (BuildContext context, int index) {
                final Playlist pl = lib.createdPlaylists[index];
                return ListTile(
                  leading: PlayerArtwork(
                    url: pl.coverUrl,
                    size: 44,
                    radius: AppDimens.radiusSm,
                  ),
                  title: Text(pl.name,
                      style: AppTypography.body,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  subtitle:
                      Text('${pl.trackCount} 首', style: AppTypography.caption),
                  onTap: () => _add(pl),
                );
              },
            );
          },
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ],
    );
  }
}

/// Dialog: add [song] to a LOCAL cross-source ("共同歌单") playlist, or create a
/// new one. Works for a track from any backend.
class _AddToLocalPlaylistDialog extends StatelessWidget {
  final Song song;
  const _AddToLocalPlaylistDialog({required this.song});

  Future<void> _createAndAdd(BuildContext context) async {
    final NavigatorState navigator = Navigator.of(context);
    final LocalPlaylistProvider prov = context.read<LocalPlaylistProvider>();
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String? name = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => const _NameDialog(),
    );
    if (name == null || name.isEmpty) return;
    final LocalPlaylist pl = await prov.create(name, tracks: <Song>[song]);
    navigator.pop();
    _snack(messenger, '已创建「${pl.name}」并添加');
  }

  Future<void> _add(BuildContext context, LocalPlaylist pl) async {
    final NavigatorState navigator = Navigator.of(context);
    final LocalPlaylistProvider prov = context.read<LocalPlaylistProvider>();
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool added = await prov.addSong(pl.id, song);
    navigator.pop();
    _snack(messenger, added ? '已添加到「${pl.name}」' : '「${pl.name}」已有这首歌');
  }

  @override
  Widget build(BuildContext context) {
    final List<LocalPlaylist> playlists =
        context.watch<LocalPlaylistProvider>().playlists;
    return AlertDialog(
      backgroundColor: AppColors.surface,
      title: const Text('添加到本地歌单', style: AppTypography.titleM),
      content: SizedBox(
        width: 360,
        height: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading:
                  const Icon(Icons.add_rounded, color: AppColors.onSurface),
              title: Text('新建歌单并添加', style: AppTypography.body),
              onTap: () => _createAndAdd(context),
            ),
            const Divider(height: 1, color: AppColors.glassBorder),
            Expanded(
              child: playlists.isEmpty
                  ? Center(
                      child: Text('还没有本地歌单',
                          style: AppTypography.label,
                          textAlign: TextAlign.center),
                    )
                  : ListView.builder(
                      itemCount: playlists.length,
                      itemBuilder: (BuildContext context, int index) {
                        final LocalPlaylist pl = playlists[index];
                        final bool has = pl.contains(song.id);
                        return ListTile(
                          leading: PlayerArtwork(
                            url: pl.coverUrl,
                            size: 44,
                            radius: AppDimens.radiusSm,
                          ),
                          title: Text(pl.name,
                              style: AppTypography.body,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                          subtitle: Text('${pl.trackCount} 首',
                              style: AppTypography.caption),
                          trailing: has
                              ? const Icon(Icons.check_rounded,
                                  color: AppColors.onSurfaceMuted)
                              : const Icon(Icons.add_rounded,
                                  color: AppColors.onSurfaceFaint),
                          onTap: () => _add(context, pl),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ],
    );
  }
}

/// Minimal name-entry dialog owning its own controller.
class _NameDialog extends StatefulWidget {
  const _NameDialog();

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text.trim());

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface,
      title: const Text('新建本地歌单', style: AppTypography.titleM),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: 40,
        style: AppTypography.body,
        decoration: const InputDecoration(hintText: '歌单名称'),
        onSubmitted: (_) => _submit(),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        TextButton(onPressed: _submit, child: const Text('创建')),
      ],
    );
  }
}
