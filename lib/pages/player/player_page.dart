import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../animation/art_background.dart';
import '../../animation/neon_flow_background.dart';
import '../../models/local_playlist.dart';
import '../../models/playlist.dart';
import '../../models/song.dart';
import '../../router/routes.dart';
import '../../services/fft_service.dart';
import '../../state/library_provider.dart';
import '../../state/local_playlist_provider.dart';
import '../../state/player_provider.dart';
import '../../state/settings_provider.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_dimens.dart';
import '../../theme/app_typography.dart';
import '../../widgets/artwork_image.dart';
import '../../widgets/dismissible_sheet.dart';
import '../../widgets/glass_container.dart';
import '../../widgets/song_tile.dart';
import '../lyrics/widgets/lyrics_view.dart';
import 'widgets/media_button.dart';
import 'widgets/player_background.dart';
import 'widgets/player_scrubber.dart';

/// The full-screen now-playing view + integrated synced-lyrics panel.
///
/// Tapping the album cover slides the lyrics panel in from the right with an
/// animated cover-shrink (hero-like, internal). The two views share a SINGLE
/// [DismissibleSheet] and a SINGLE [SheetGrabber] — both always pull-down to
/// the home tab ([Routes.home]). The lyrics panel is NOT a separate route;
/// [Routes.lyrics] is kept as a no-op redirect.
class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key});

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage>
    with SingleTickerProviderStateMixin {
  /// 0.0 = player view, 1.0 = lyrics view.
  late final AnimationController _modeCtrl;
  late final Animation<double> _modeAnim;
  late FftService _fft;
  bool _fftRunning = false;

  /// LyricsView is mounted (at Opacity 0) once the /player push settles, so its
  /// one-time cold measure+layout lands on an idle frame — never on the hero
  /// flight and never on a player↔lyrics morph. Until then the `t>0` guard still
  /// mounts it if a fast tap-open beats the push completing.
  bool _lyricsReady = false;
  bool _lyricsDeferScheduled = false;

  @override
  void initState() {
    super.initState();
    _modeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );
    _modeAnim = CurvedAnimation(
      parent: _modeCtrl,
      // easeOutQuart: starts fast, decelerates into place — snappier than cubic.
      curve: const Cubic(0.25, 0.46, 0.45, 0.94),
      reverseCurve: const Cubic(0.55, 0.06, 0.68, 0.19),
    );
    _modeCtrl.addStatusListener(_onModeStatus);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _fft = context.read<FftService>();
    // Mount LyricsView only after the /player push has fully settled, so its
    // ~43ms cold measure+layout is paid on an idle frame instead of on the
    // MiniPlayer→Player hero flight or the first player→lyrics morph frame.
    if (!_lyricsReady && !_lyricsDeferScheduled) {
      _lyricsDeferScheduled = true;
      final Animation<double>? anim = ModalRoute.of(context)?.animation;
      if (anim == null || anim.isCompleted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _lyricsReady = true);
        });
      } else {
        void onStatus(AnimationStatus s) {
          if (s == AnimationStatus.completed) {
            anim.removeStatusListener(onStatus);
            if (mounted) setState(() => _lyricsReady = true);
          }
        }

        anim.addStatusListener(onStatus);
      }
    }
  }

  /// Start the native FFT/Visualizer only once the morph has fully SETTLED into
  /// the lyrics view, and tear it down the instant we start heading back. The
  /// Visualizer kickoff (mic-permission request + an EventChannel broadcast that
  /// builds an android.media.audiofx.Visualizer on the platform thread) dropped
  /// frames when it fired mid-morph (the old value>0.45 threshold sat dead-centre
  /// of the transition); gating on animation STATUS keeps that native setup off
  /// the transition entirely.
  void _onModeStatus(AnimationStatus status) {
    final bool rhythmEnabled =
        context.read<SettingsProvider>().rhythmEnabled;
    if (status == AnimationStatus.completed && !_fftRunning && rhythmEnabled) {
      _fft.start();
      _fftRunning = true;
    } else if (status != AnimationStatus.completed && _fftRunning) {
      _fft.stop();
      _fftRunning = false;
    }
  }

  @override
  void dispose() {
    if (_fftRunning) _fft.stop();
    _modeCtrl.removeStatusListener(_onModeStatus);
    _modeCtrl.dispose();
    super.dispose();
  }

  void _openLyrics() => _modeCtrl.forward();
  void _closeLyrics() => _modeCtrl.reverse();

  @override
  Widget build(BuildContext context) {
    final String? error = context.select<PlayerProvider, String?>(
      (PlayerProvider p) => p.playbackError,
    );
    _showErrorIfNeeded(context, error);
    final bool hasSong =
        context.select<PlayerProvider, bool>((PlayerProvider p) => p.hasSong);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: DismissibleSheet(
        // Both the player grabber AND the lyrics grabber send the user home.
        // dragAnywhere: player side can be dragged anywhere; the lyrics side has
        // LyricsView scroll — the DismissibleSheet restricts to grabber-only when
        // the lyrics panel is visible (managed via IgnorePointer on the drag area).
        dragAnywhere: true,
        onDismiss: () {
          if (context.canPop()) {
            context.pop();
          } else {
            context.go(Routes.home);
          }
        },
        builder: (BuildContext context, VoidCallback dismiss,
                ValueListenable<bool> heroSuppressed) =>
            hasSong
                ? _IntegratedBody(
                    modeAnim: _modeAnim,
                    heroSuppressed: heroSuppressed,
                    onOpenLyrics: _openLyrics,
                    onCloseLyrics: _closeLyrics,
                    onDismiss: dismiss,
                    onMore: () => _showMore(context),
                    onQueue: () => _showQueue(context),
                    onLike: () => _toggleLike(context),
                    fft: _fft,
                    lyricsReady: _lyricsReady,
                  )
                : _EmptyBody(onDismiss: dismiss),
      ),
    );
  }

  /// Surfaces a transient playback error (e.g. VIP / login required) as a
  /// floating snack bar, then clears it so it shows only once.
  void _showErrorIfNeeded(BuildContext context, String? error) {
    if (error == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(error, style: AppTypography.body),
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppColors.surface,
        ));
      context.read<PlayerProvider>().clearPlaybackError();
    });
  }

  // --- narrow (single-pane vertical) [REMOVED — lyrics now integrated] ----

  /// The "···" overflow menu: a glass sheet with the add-to-playlist action.
  void _showMore(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (BuildContext sheetContext) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(AppDimens.space12),
          child: GlassContainer(
            blur: AppDimens.blurPanel,
            padding: const EdgeInsets.symmetric(vertical: AppDimens.space8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                ListTile(
                  leading: const Icon(Icons.playlist_add_rounded,
                      color: AppColors.onSurface),
                  title: Text('添加到歌单', style: AppTypography.body),
                  onTap: () {
                    final Song? song =
                        context.read<PlayerProvider>().currentSong;
                    Navigator.of(sheetContext).pop();
                    if (song != null) _showAddToPlaylist(context, song);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.library_add_rounded,
                      color: AppColors.onSurface),
                  title: Text('添加到本地歌单', style: AppTypography.body),
                  subtitle: Text('跨音源整合（网易 / QQ / 酷狗）',
                      style: AppTypography.caption),
                  onTap: () {
                    final Song? song =
                        context.read<PlayerProvider>().currentSong;
                    Navigator.of(sheetContext).pop();
                    if (song != null) _showAddToLocalPlaylist(context, song);
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showAddToPlaylist(BuildContext context, Song song) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (BuildContext sheetContext) => _AddToPlaylistSheet(song: song),
    );
  }

  /// Adds the current song to a LOCAL cross-source ("共同歌单") playlist — the
  /// path that lets a Kugou/Migu track land next to Netease ones in one list.
  void _showAddToLocalPlaylist(BuildContext context, Song song) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (BuildContext sheetContext) =>
          _AddToLocalPlaylistSheet(song: song),
    );
  }

  /// Likes / unlikes the current song against the user's "liked" playlist (the
  /// first entry in [LibraryProvider.userPlaylists]). Flips the heart
  /// optimistically and reverts on failure; nudges a login when no playlists
  /// exist yet.
  Future<void> _toggleLike(BuildContext context) async {
    final PlayerProvider player = context.read<PlayerProvider>();
    final Song? song = player.currentSong;
    if (song == null) return;
    final LibraryProvider lib = context.read<LibraryProvider>();
    // Capture the messenger before any await so we never touch a stale context.
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    if (lib.userPlaylists.isEmpty) {
      unawaited(lib.loadUserPlaylists());
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text('请先登录网易云账号后再试', style: AppTypography.body),
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppColors.surface,
        ));
      return;
    }
    final Playlist liked = lib.userPlaylists.first;
    // Target the captured [song] explicitly (not "current"): the optimistic flip
    // and the on-failure revert must hit the same track even if the queue
    // auto-advances during the add/remove round-trip.
    final bool wasLiked = player.isLikedSong(song);
    player.setLiked(song, !wasLiked);
    try {
      if (wasLiked) {
        await lib.removeSongFromPlaylist(liked.id, song);
      } else {
        await lib.addSongToPlaylist(liked.id, song);
      }
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(
            wasLiked ? '已从「${liked.name}」移除' : '已添加到「${liked.name}」',
            style: AppTypography.body,
          ),
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppColors.surface,
        ));
    } catch (_) {
      player.setLiked(song, wasLiked); // revert the SAME captured song
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text('操作失败', style: AppTypography.body),
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppColors.surface,
        ));
    }
  }

  void _showQueue(BuildContext context) {
    final PlayerProvider player = context.read<PlayerProvider>();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (BuildContext sheetContext) => _QueueSheet(player: player),
    );
  }
}

/// The control block: title · scrubber · transport · volume · play-queue. Holds
/// no provider state itself — each child below selects only the fields it paints
/// so a per-second position tick rebuilds the scrubber alone, not this column.
class _Controls extends StatelessWidget {
  final VoidCallback onMore;
  final VoidCallback onQueue;
  final VoidCallback onLike;

  const _Controls({
    required this.onMore,
    required this.onQueue,
    required this.onLike,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _TitleRow(onLike: onLike, onMore: onMore),
        const SizedBox(height: AppDimens.space20),
        const _ScrubberBar(),
        const SizedBox(height: AppDimens.space20),
        const _Transport(),
        const SizedBox(height: AppDimens.space24),
        const _VolumeRow(),
        const SizedBox(height: AppDimens.space16),
        IconButton(
          icon: const Icon(Icons.queue_music_rounded),
          iconSize: 24,
          color: Colors.white.withValues(alpha: 0.55),
          onPressed: onQueue,
        ),
      ],
    );
  }
}

/// Isolates the position/duration ticks: the only part of the player that
/// selects [PlayerProvider.position]/[PlayerProvider.duration], so a per-second
/// tick rebuilds just the scrubber and never the surrounding page.
class _ScrubberBar extends StatelessWidget {
  const _ScrubberBar();

  @override
  Widget build(BuildContext context) {
    final Duration position = context
        .select<PlayerProvider, Duration>((PlayerProvider p) => p.position);
    final Duration duration = context
        .select<PlayerProvider, Duration>((PlayerProvider p) => p.duration);
    return PlayerScrubber(
      position: position,
      duration: duration,
      onSeek: context.read<PlayerProvider>().seek,
    );
  }
}

/// The volume rail flanked by the two speaker glyphs. Selects only
/// [PlayerProvider.volume] so a volume drag doesn't rebuild the transport row.
class _VolumeRow extends StatelessWidget {
  const _VolumeRow();

  @override
  Widget build(BuildContext context) {
    final double volume =
        context.select<PlayerProvider, double>((PlayerProvider p) => p.volume);
    return Row(
      children: <Widget>[
        Icon(Icons.volume_down_rounded,
            size: 20, color: Colors.white.withValues(alpha: 0.5)),
        const SizedBox(width: AppDimens.space12),
        Expanded(
          child: _VolumeBar(
            value: volume,
            onChanged: context.read<PlayerProvider>().setVolume,
          ),
        ),
        const SizedBox(width: AppDimens.space12),
        Icon(Icons.volume_up_rounded,
            size: 20, color: Colors.white.withValues(alpha: 0.5)),
      ],
    );
  }
}

/// Empty state when nothing is queued.
class _EmptyBody extends StatelessWidget {
  final VoidCallback onDismiss;
  const _EmptyBody({required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        const PlayerBackground(),
        SafeArea(
          child: Column(
            children: <Widget>[
              SheetGrabber(onTap: onDismiss),
              const Spacer(),
              const Icon(Icons.music_off_rounded,
                  size: 64, color: AppColors.onSurfaceFaint),
              const SizedBox(height: AppDimens.space16),
              Text('Nothing playing', style: AppTypography.titleM),
              const Spacer(),
            ],
          ),
        ),
      ],
    );
  }
}

/// The integrated player+lyrics body. Lyrics live to the "right" conceptually:
/// tapping the cover animates [modeAnim] 0→1, shrinking the cover into the header
/// while the lyrics panel fades in from the right. The single [SheetGrabber] is
/// always visible at the top; pulling it down → go(home).
class _IntegratedBody extends StatelessWidget {
  final Animation<double> modeAnim;
  final ValueListenable<bool> heroSuppressed;
  final VoidCallback onOpenLyrics;
  final VoidCallback onCloseLyrics;
  final VoidCallback onDismiss;
  final VoidCallback onMore;
  final VoidCallback onQueue;
  final VoidCallback onLike;
  final FftService fft;
  final bool lyricsReady;

  const _IntegratedBody({
    required this.modeAnim,
    required this.heroSuppressed,
    required this.onOpenLyrics,
    required this.onCloseLyrics,
    required this.onDismiss,
    required this.onMore,
    required this.onQueue,
    required this.onLike,
    required this.fft,
    required this.lyricsReady,
  });

  @override
  Widget build(BuildContext context) {
    final String? artworkUrl = context.select<PlayerProvider, String?>(
      (p) => p.currentSong?.artworkUrl,
    );
    final List<Color> colors =
        context.select<PlayerProvider, List<Color>>((p) => p.paletteColors);
    final bool playing =
        context.select<PlayerProvider, bool>((p) => p.isPlaying);
    final bool rhythmEnabled =
        context.select<SettingsProvider, bool>((s) => s.rhythmEnabled);

    // Backgrounds are built ONCE (hoisted out of the per-tick AnimatedBuilder)
    // and wrapped in RepaintBoundary so the morph only re-composites their
    // cached layers instead of repainting the blur / mesh shader every frame.
    // NeonFlowBackground reads the beat from its ValueListenable internally,
    // so it stays live without per-frame rebuilds.
    final Widget artBg = RepaintBoundary(
      child: ArtBackground(
        imageUrl: artworkUrl,
        paletteColors: colors,
      ),
    );
    final Widget neonBg = RepaintBoundary(
      child: NeonFlowBackground(
        imageUrl: artworkUrl,
        colors: colors,
        playing: playing,
        lowFreqVolume: fft.lowFreqVolume,
        reactive: rhythmEnabled,
        morph: modeAnim,
      ),
    );

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        // ── Backgrounds ─────────────────────────────────────────────────
        // ArtBackground (blurred album cover) fades out; NeonFlowBackground
        // fades in. Both wrapped in Positioned.fill as direct Stack children
        // — Positioned.fill inside Opacity breaks Flutter's Stack positioning.
        // The two children carry STABLE KEYS: at t==1.0 the ArtBackground child
        // drops, shrinking the list 2→1; without keys Flutter would reconcile
        // NeonFlowBackground by list position onto the old ArtBackground slot,
        // tearing down its State (ticker + flow clock) and snapping the flow
        // back to phase 0 exactly as the morph settles. Keys pin the element
        // by identity so the neon flow stays continuous across the transition.
        AnimatedBuilder(
          animation: modeAnim,
          builder: (_, __) {
            final double t = modeAnim.value;
            return Stack(
              fit: StackFit.expand,
              children: <Widget>[
                // BOTH backgrounds stay PERMANENTLY MOUNTED (no `if` guards) so:
                //  • the ~40k-vertex BhpMesh + its State (ticker, flow clock,
                //    texture) are built ONCE on first mount and NEVER torn down —
                //    the old `if (t > 0.0)` re-created NeonFlowBackground on every
                //    lyrics-open, re-running a 10–30ms synchronous mesh build AND
                //    re-fading the mesh layer from 0 over 500ms = the flash.
                //  • the flow clock is continuous across opens (no phase-0 snap).
                // Visibility is pure Opacity: RenderOpacity skips painting a
                // 0-alpha child, so the hidden layer costs no GPU (neon in player
                // mode, art in lyrics mode).
                //
                // Art shows ONLY in player mode (t<=0.02). The neon subtree is a
                // FULLY OPAQUE background (its _PaletteWash is an opaque gradient
                // under the mesh), and it snaps to opacity 1.0 at t>0.02 — so for
                // the entire morph the art would be painted but 100% OCCLUDED
                // behind the neon: pure wasted full-screen overdraw (a blurred
                // album image, ~4.6M px) every transition frame, on top of the
                // mesh's own fill. Dropping it at t>0.02 is a ZERO-visual-change
                // win (it was already hidden) that halves the background fill
                // during the morph → only ONE opaque background paints, never two.
                // Mutually exclusive with the neon's t>0.02 gate, so coverage is
                // always exactly 1.0 with no dip.
                Positioned.fill(
                  key: const ValueKey<String>('art_bg'),
                  child: Opacity(
                    opacity: t <= 0.02 ? 1.0 : 0.0,
                    child: artBg,
                  ),
                ),
                Positioned.fill(
                  key: const ValueKey<String>('neon_bg'),
                  child: Opacity(
                    // BINARY opacity — never a partial alpha. The art background
                    // stays FULLY OPAQUE underneath for the entire morph (its
                    // opacity is 1.0 until t==1), so the neon never needs to
                    // cross-fade; a partial-alpha neon only bought a full-screen
                    // `saveLayer` that re-encoded the 16k-vertex mesh offscreen
                    // (measured 12.96ms — the single worst frame of the reverse
                    // morph, and the peak of the forward one). Snapping 0→1 at
                    // t>0.02 means RenderOpacity always takes a fast path:
                    // alpha==0 skips painting the mesh entirely (player mode),
                    // alpha==255 drops the OpacityLayer so the frozen mesh
                    // composites straight from its cached RepaintBoundary (lyrics
                    // mode + whole morph). No offscreen, no re-encode, ever. The
                    // frozen album-toned mesh appearing instantly over the
                    // identically album-toned art blur is visually indistinct from
                    // the old ~28ms fade — the cover is in motion over both.
                    opacity: t > 0.02 ? 1.0 : 0.0,
                    child: neonBg,
                  ),
                ),
              ],
            );
          },
        ),
        // ── Content ────────────────────────────────────────────────────────
        SafeArea(
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints c) {
              return _AnimatedLayout(
                modeAnim: modeAnim,
                heroSuppressed: heroSuppressed,
                onOpenLyrics: onOpenLyrics,
                onCloseLyrics: onCloseLyrics,
                onDismiss: onDismiss,
                onMore: onMore,
                onQueue: onQueue,
                onLike: onLike,
                availableWidth: c.maxWidth,
                availableHeight: c.maxHeight,
                artworkUrl: artworkUrl,
                lyricsReady: lyricsReady,
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Core animated layout: cover morphs 大居中→小左上，歌词从右淡入。
class _AnimatedLayout extends StatelessWidget {
  final Animation<double> modeAnim;
  final ValueListenable<bool> heroSuppressed;
  final VoidCallback onOpenLyrics;
  final VoidCallback onCloseLyrics;
  final VoidCallback onDismiss;
  final VoidCallback onMore;
  final VoidCallback onQueue;
  final VoidCallback onLike;
  final double availableWidth;
  final double availableHeight;
  final String? artworkUrl;
  final bool lyricsReady;

  static const double _headerH = 44.0 + AppDimens.space4 + AppDimens.space8;
  static const double _grabberH = 40.0;
  static const double _controlsH = 280.0;

  const _AnimatedLayout({
    required this.modeAnim,
    required this.heroSuppressed,
    required this.onOpenLyrics,
    required this.onCloseLyrics,
    required this.onDismiss,
    required this.onMore,
    required this.onQueue,
    required this.onLike,
    required this.availableWidth,
    required this.availableHeight,
    required this.artworkUrl,
    required this.lyricsReady,
  });

  @override
  Widget build(BuildContext context) {
    final double bodyH = availableHeight - _grabberH;
    double coverMax = math.min(availableWidth,
        bodyH - _controlsH - AppDimens.space24 * 2);
    coverMax = math.min(coverMax, availableWidth - AppDimens.space48);
    final double playerCoverSize = coverMax.clamp(80.0, 380.0);

    final double playerRegionH = bodyH - _controlsH - AppDimens.space8;
    final double playerCoverTop =
        _grabberH + (playerRegionH - playerCoverSize) / 2;
    final double playerCoverLeft = (availableWidth - playerCoverSize) / 2;

    const double lyricsCoverSize = 44.0;
    const double lyricsCoverLeft = AppDimens.space16;
    const double lyricsCoverTop = _grabberH + AppDimens.space4;

    // Content widgets that consume providers are built ONCE per layout pass
    // (not per modeAnim tick). They subscribe to their own provider slices and
    // rebuild only when that data changes — the per-tick AnimatedBuilder below
    // just re-wraps these same instances in Opacity/Transform, so their heavy
    // subtrees (AMLL lyric engine, transport controls) are not rebuilt 60×/s
    // during the morph. RepaintBoundary caches their layers for cheap compositing.
    final Widget controls = RepaintBoundary(
      child: _Controls(
        onMore: onMore,
        onQueue: onQueue,
        onLike: onLike,
      ),
    );
    final Widget lyricsTitle = Row(
      children: <Widget>[
        Expanded(child: _LyricsTitleColumn()),
        _ReturnButton(onTap: onCloseLyrics),
      ],
    );
    // Pass the morph clock so the lyric engine FREEZES during the transition
    // (mutes its per-frame tick + drops blur/glow saveLayers) — the fix for the
    // 70-80ms/frame lyric re-raster measured on the player↔lyrics morph.
    final Widget lyricsView =
        RepaintBoundary(child: LyricsView(morph: modeAnim));

    return AnimatedBuilder(
      animation: modeAnim,
      builder: (BuildContext context, Widget? _) {
        final double t = modeAnim.value;
        final double coverSize =
            lerpDouble(playerCoverSize, lyricsCoverSize, t)!;
        final double coverTop =
            lerpDouble(playerCoverTop, lyricsCoverTop, t)!;
        final double coverLeft =
            lerpDouble(playerCoverLeft, lyricsCoverLeft, t)!;

        final double playerAlpha = (1.0 - t * 2.5).clamp(0.0, 1.0);
        final double lyricsAlpha = ((t - 0.35) / 0.65).clamp(0.0, 1.0);

        return Stack(
          children: <Widget>[
            // 1. Grabber — fixed at top, always goes home.
            Positioned(
              key: const ValueKey<String>('grabber'),
              top: 0, left: 0, right: 0,
              child: SheetGrabber(onTap: onDismiss),
            ),
            // 2. Lyrics title row (fades in next to small cover).
            if (t > 0)
              Positioned(
                key: const ValueKey<String>('lyrics_title'),
                top: lyricsCoverTop,
                left: lyricsCoverLeft + lyricsCoverSize + AppDimens.space12,
                right: AppDimens.space16,
                height: lyricsCoverSize,
                child: Opacity(
                  opacity: lyricsAlpha,
                  child: IgnorePointer(
                    ignoring: t < 0.5,
                    child: lyricsTitle,
                  ),
                ),
              ),
            // 3. Player controls (fade out).
            if (playerAlpha > 0)
              Positioned(
                key: const ValueKey<String>('player_controls'),
                left: 0, right: 0, bottom: 0,
                child: Opacity(
                  opacity: playerAlpha,
                  child: IgnorePointer(
                    ignoring: t > 0.3,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: AppDimens.space24),
                      child: controls,
                    ),
                  ),
                ),
              ),
            // 4. Lyrics view — mounted at Opacity(0) once the push settles
            //    (lyricsReady) so its cold measure+layout is paid on an idle
            //    frame and RETAINED across every morph; RenderOpacity skips PAINT
            //    at alpha 0 so it costs nothing in player mode. OR-ed with t>0 so
            //    a tap-open that beats the push completing still mounts it.
            if (lyricsReady || t > 0)
              Positioned(
                key: const ValueKey<String>('lyrics_view'),
                top: _grabberH + _headerH,
                left: 0, right: 0, bottom: 0,
                // NO group Opacity here: LyricsView applies the morph fade
                // PER LINE (Opacity over each line's RepaintBoundary = a cheap
                // compositor alpha), avoiding the full-screen offscreen saveLayer
                // that a whole-view Opacity(lyricsAlpha) costs on Impeller
                // (~8.6ms/frame). The lines are invisible at t<0.35 (fadeAlpha 0)
                // so the mounted-in-player-mode view paints nothing.
                child: Transform.translate(
                  offset: Offset((1.0 - t) * availableWidth * 0.15, 0),
                  child: IgnorePointer(
                    ignoring: t < 0.5,
                    child: lyricsView,
                  ),
                ),
              ),
            // 5. Cover — always rendered, animates position/size.
            //    The STABLE KEY is load-bearing: children 2–4 above are
            //    conditionally mounted, so this Positioned's index within the
            //    Stack shifts as `t` crosses thresholds. Without a key Flutter
            //    reconciles the unkeyed same-type Positioneds by list index and
            //    reuses this element for a sibling, destroying the pause-scale
            //    TweenAnimationBuilder's controller → the lift snaps instead of
            //    animating. The key pins the cover element by identity.
            Positioned(
              key: const ValueKey<String>('player_cover'),
              top: coverTop,
              left: coverLeft,
              width: coverSize,
              height: coverSize,
              child: GestureDetector(
                onTap: t < 0.3 ? onOpenLyrics : null,
                child: ValueListenableBuilder<bool>(
                  valueListenable: heroSuppressed,
                  builder: (BuildContext ctx, bool suppressed,
                      Widget? __) {
                    final bool playing =
                        ctx.select<PlayerProvider, bool>(
                            (p) => p.isPlaying);
                    // Pause-lift: cover rests at 0.72 when paused, 1.0 when
                    // playing. The TweenAnimationBuilder animates ONLY this
                    // play/pause dip (400ms easeOutCubic) — its State now
                    // survives rebuilds thanks to the keyed Positioned above.
                    final double pauseDip = playing ? 1.0 : 0.72;
                    return TweenAnimationBuilder<double>(
                      tween: Tween<double>(end: pauseDip),
                      duration: const Duration(milliseconds: 400),
                      curve: Curves.easeOutCubic,
                      builder: (BuildContext _, double dip, Widget? child) =>
                          Transform.scale(
                        // Resolve the dip to full size in lockstep with the
                        // morph `t` (280ms modeAnim), so opening lyrics from a
                        // paused state doesn't rubber-band between the 400ms dip
                        // tween and the morph clock — at t==1 the cover is
                        // always full-size regardless of play/pause.
                        scale: lerpDouble(dip, 1.0, t)!,
                        child: child,
                      ),
                      child: ArtworkImage(
                        url: artworkUrl,
                        size: coverSize,
                        radius: AppDimens.albumRadius(coverSize),
                        heroTag: (suppressed || t > 0.01)
                            ? null
                            : 'album_art',
                        shadow: t < 0.5
                            ? const <BoxShadow>[
                                BoxShadow(
                                  color: Color(0x33000000),
                                  blurRadius: 28,
                                  offset: Offset(0, 16),
                                ),
                              ]
                            : null,
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Song name + artist column shown next to the small cover in lyrics mode.
class _LyricsTitleColumn extends StatelessWidget {
  const _LyricsTitleColumn();

  @override
  Widget build(BuildContext context) {
    final String name = context.select<PlayerProvider, String>(
        (p) => p.currentSong?.name ?? '');
    final String artist = context.select<PlayerProvider, String>(
        (p) => p.currentSong?.artistNames ?? '');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        Text(name,
            style: AppTypography.titleL.copyWith(fontSize: 15, height: 1.2),
            maxLines: 1,
            overflow: TextOverflow.ellipsis),
        Text(artist,
            style: AppTypography.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis),
      ],
    );
  }
}

/// AMLL-style circular return button: tap → close lyrics, show player.
class _ReturnButton extends StatelessWidget {
  final VoidCallback onTap;
  const _ReturnButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 36,
        height: 36,
        alignment: Alignment.center,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: Color(0x1FFFFFFF),
        ),
        child: const Icon(
          Icons.keyboard_arrow_down_rounded,
          size: 24,
          color: Colors.white,
        ),
      ),
    );
  }
}

/// Title (marquee when it overflows, else ellipsis) + muted artist, with a like
/// (heart) toggle and a circular translucent "···" overflow button on the
/// trailing edge.
class _TitleRow extends StatelessWidget {
  final VoidCallback onLike;
  final VoidCallback onMore;

  const _TitleRow({
    required this.onLike,
    required this.onMore,
  });

  @override
  Widget build(BuildContext context) {
    final String title = context.select<PlayerProvider, String>(
      (PlayerProvider p) => p.currentSong?.name ?? '',
    );
    final String artist = context.select<PlayerProvider, String>(
      (PlayerProvider p) => p.currentSong?.artistNames ?? '',
    );
    final bool isLiked =
        context.select<PlayerProvider, bool>((PlayerProvider p) => p.isLiked);
    final Color accent = context.select<PlayerProvider, Color>(
      (PlayerProvider p) => p.dynamicAccent,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _MarqueeText(
                text: title,
                style: AppTypography.displayM.copyWith(
                  fontSize: 26,
                  height: 1.15,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.4,
                  color: Colors.white.withValues(alpha: 0.9),
                ),
              ),
              const SizedBox(height: AppDimens.space4),
              Text(
                artist,
                style: AppTypography.label.copyWith(
                  color: Colors.white.withValues(alpha: 0.45),
                  fontWeight: FontWeight.w400,
                  letterSpacing: 0.4,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        IconButton(
          onPressed: onLike,
          icon: Icon(
            isLiked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
            color: isLiked ? accent : Colors.white.withValues(alpha: 0.55),
            size: 26,
          ),
        ),
        const SizedBox(width: AppDimens.space8),
        GestureDetector(
          onTap: onMore,
          child: Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Color(0x1FFFFFFF),
            ),
            child: const Icon(
              Icons.more_horiz_rounded,
              size: 22,
              color: Colors.white,
            ),
          ),
        ),
      ],
    );
  }
}

/// Single-line text that scrolls horizontally (seamless two-copy loop) only
/// when it would overflow the available width; otherwise a plain ellipsised
/// [Text]. The ticker is parked whenever the text fits.
class _MarqueeText extends StatefulWidget {
  final String text;
  final TextStyle style;
  final double gap = 56;

  const _MarqueeText({
    required this.text,
    required this.style,
  });

  @override
  State<_MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<_MarqueeText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: _durationFor(widget.text));

  // Constant-ish speed: scale the loop duration with the text length. Tuned for
  // a calm, readable crawl — a generous base plus a generous per-char term
  // (≈half the previous speed) so long titles glide instead of whipping past.
  Duration _durationFor(String text) =>
      Duration(milliseconds: 5200 + text.length * 260);

  @override
  void didUpdateWidget(covariant _MarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      final bool wasAnimating = _controller.isAnimating;
      _controller
        ..stop()
        ..duration = _durationFor(widget.text)
        ..value = 0;
      if (wasAnimating) _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final TextPainter tp = TextPainter(
          text: TextSpan(text: widget.text, style: widget.style),
          maxLines: 1,
          textDirection: Directionality.of(context),
        )..layout();
        final double textWidth = tp.width;
        final bool overflow = textWidth > c.maxWidth + 0.5;

        // Match the ticker to the overflow state (post-frame, so we never mutate
        // the controller during layout).
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (overflow && !_controller.isAnimating) {
            _controller.repeat();
          } else if (!overflow && _controller.isAnimating) {
            _controller.stop();
          }
        });

        if (!overflow) {
          return Text(
            widget.text,
            style: widget.style,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
          );
        }

        final double span = textWidth + widget.gap;
        return ClipRect(
          child: SizedBox(
            height: tp.height,
            width: c.maxWidth,
            child: AnimatedBuilder(
              animation: _controller,
              builder: (BuildContext context, _) {
                final double dx = -_controller.value * span;
                return Stack(
                  clipBehavior: Clip.none,
                  children: <Widget>[
                    _copy(dx, textWidth),
                    _copy(dx + span, textWidth),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  // Positioned with an explicit width so the text lays out at its full
  // intrinsic width (a non-positioned Stack child would be clipped to the
  // Stack width, defeating the scroll).
  Widget _copy(double dx, double width) => Positioned(
        left: dx,
        top: 0,
        width: width,
        child: Text(widget.text,
            style: widget.style, maxLines: 1, softWrap: false),
      );
}

/// AMLL transport row: shuffle · rewind · play/pause · forward · repeat, every
/// control a monochrome-white [MediaButton] (transparent → white @ 13.3 % on
/// press, with the 700 ms press-bounce). The play/pause button is the focal
/// 72-dp control; shuffle / repeat dim to white @ 50 % when inactive.
class _Transport extends StatelessWidget {
  const _Transport();

  // AMLL's transport is monochrome: active toggles are pure white, inactive
  // ones dim to white @ 50 % (no dynamic accent).
  static const Color _white = Color(0xFFFFFFFF);
  static const Color _dim = Color(0x80FFFFFF);

  @override
  Widget build(BuildContext context) {
    final bool isPlaying =
        context.select<PlayerProvider, bool>((PlayerProvider p) => p.isPlaying);
    final bool isBuffering = context
        .select<PlayerProvider, bool>((PlayerProvider p) => p.isBuffering);
    final bool shuffleEnabled = context
        .select<PlayerProvider, bool>((PlayerProvider p) => p.shuffleEnabled);
    final int repeatModeIndex = context
        .select<PlayerProvider, int>((PlayerProvider p) => p.repeatMode.index);
    final PlayerProvider player = context.read<PlayerProvider>();
    final IconData repeatIcon =
        repeatModeIndex == 2 ? Icons.repeat_one_rounded : Icons.repeat_rounded;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: <Widget>[
        MediaButton(
          size: 44,
          onPressed: player.toggleShuffle,
          child: Icon(
            Icons.shuffle_rounded,
            size: 22,
            color: shuffleEnabled ? _white : _dim,
          ),
        ),
        MediaButton(
          size: 56,
          onPressed: player.previous,
          child: const Icon(Icons.fast_rewind_rounded, size: 34, color: _white),
        ),
        MediaButton(
          size: 72,
          onPressed: player.togglePlay,
          child: isBuffering
              ? const SizedBox(
                  width: 26,
                  height: 26,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: _white),
                )
              : Icon(
                  isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  size: 40,
                  color: _white,
                ),
        ),
        MediaButton(
          size: 56,
          onPressed: player.next,
          child:
              const Icon(Icons.fast_forward_rounded, size: 34, color: _white),
        ),
        MediaButton(
          size: 44,
          onPressed: player.cycleRepeat,
          child: Icon(
            repeatIcon,
            size: 22,
            color: repeatModeIndex != 0 ? _white : _dim,
          ),
        ),
      ],
    );
  }
}

/// Knob-less volume bar, a sibling of [PlayerScrubber]'s track: an 8-px white
/// rail (white @ 15 %) with a left-anchored white fill that brightens while
/// dragging. Writes through to [PlayerProvider.setVolume] via [onChanged].
class _VolumeBar extends StatefulWidget {
  final double value;
  final ValueChanged<double> onChanged;

  const _VolumeBar({required this.value, required this.onChanged});

  @override
  State<_VolumeBar> createState() => _VolumeBarState();
}

class _VolumeBarState extends State<_VolumeBar> {
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final double w = c.maxWidth;
        void update(double dx) =>
            widget.onChanged((dx / w).clamp(0.0, 1.0));

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (TapDownDetails d) => update(d.localPosition.dx),
          onHorizontalDragStart: (DragStartDetails d) {
            setState(() => _dragging = true);
            update(d.localPosition.dx);
          },
          onHorizontalDragUpdate: (DragUpdateDetails d) =>
              update(d.localPosition.dx),
          onHorizontalDragEnd: (_) => setState(() => _dragging = false),
          onHorizontalDragCancel: () => setState(() => _dragging = false),
          child: SizedBox(
            height: 24,
            child: Center(
              child: SizedBox(
                height: 8,
                width: double.infinity,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(100),
                  child: Stack(
                    fit: StackFit.expand,
                    children: <Widget>[
                      const ColoredBox(color: Color(0x26FFFFFF)),
                      FractionallySizedBox(
                        widthFactor: widget.value.clamp(0.0, 1.0),
                        alignment: Alignment.centerLeft,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          curve: const Cubic(0.2, 0.2, 0, 1),
                          color: Colors.white
                              .withValues(alpha: _dragging ? 0.9 : 0.4),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Glass bottom sheet listing the active queue; tap a row to jump to it.
///
/// Opens scrolled to the now-playing track instead of the top: a one-shot
/// post-frame [ScrollController.jumpTo] drops the viewport onto the row at
/// [PlayerProvider.currentIndex] (centred, clamped to the scroll range), so the
/// active song is in view the instant the sheet settles.
class _QueueSheet extends StatefulWidget {
  final PlayerProvider player;

  const _QueueSheet({required this.player});

  @override
  State<_QueueSheet> createState() => _QueueSheetState();
}

class _QueueSheetState extends State<_QueueSheet> {
  // Fixed geometry of one [SongTile]: a 56-px artwork (which dominates the row;
  // the title/artist column is only ~42 px) + 8-px vertical padding top &
  // bottom = 72 px. Maps a queue index → scroll offset for the open-on-current
  // jump. Const-folded from the same tokens SongTile lays out with.
  static const double _kRowExtent = AppDimens.tileArtwork + AppDimens.space8 * 2;

  final ScrollController _controller = ScrollController();

  @override
  void initState() {
    super.initState();
    // After the first layout the controller is attached and metrics are final,
    // so we can land the viewport on the active row exactly once on open.
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrent());
  }

  void _scrollToCurrent() {
    if (!mounted || !_controller.hasClients) return;
    final int? index = widget.player.currentIndex;
    if (index == null) return; // nothing playing → leave parked at the top
    final ScrollPosition position = _controller.position;
    // Centre the active row in the viewport, then clamp into the scrollable
    // range so head/tail tracks pin to the top / bottom instead of overscroll.
    final double target =
        index * _kRowExtent - (position.viewportDimension - _kRowExtent) / 2;
    _controller.jumpTo(target.clamp(0.0, position.maxScrollExtent));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final PlayerProvider player = widget.player;
    final double maxHeight = MediaQuery.of(context).size.height * 0.6;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(AppDimens.space12),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: GlassContainer(
            blur: AppDimens.blurPanel,
            padding: const EdgeInsets.symmetric(vertical: AppDimens.space12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: AppDimens.space16),
                  child: Row(
                    children: <Widget>[
                      Text('Up next', style: AppTypography.titleM),
                      const Spacer(),
                      Text('${player.queue.length} tracks',
                          style: AppTypography.caption),
                    ],
                  ),
                ),
                const SizedBox(height: AppDimens.space8),
                Flexible(
                  child: ListView.builder(
                    controller: _controller,
                    shrinkWrap: true,
                    itemCount: player.queue.length,
                    itemBuilder: (BuildContext context, int index) {
                      final Song song = player.queue[index];
                      return RepaintBoundary(
                        key: ValueKey<int>(song.id),
                        child: SongTile.fromSong(
                          song,
                          isActive: index == player.currentIndex,
                          onTap: () {
                            // Pop the sheet, then jump in-place on the next frame
                            // (native seek-to-index — no ConcatenatingAudioSource
                            // rebuild / reload). jumpTo() optimistically flips
                            // _currentIndex + notifies, but the rebuild surface is
                            // now narrowed (field-level selects) and _onIndexChanged
                            // no longer double-notifies, so the old 250 ms band-aid
                            // is gone; deferring a single frame past Navigator.pop
                            // just keeps the switch off the sheet's close-animation
                            // frame. [player] is the long-lived provider — safe to
                            // call after this row's element is gone.
                            Navigator.of(context).pop();
                            WidgetsBinding.instance.addPostFrameCallback(
                              (_) => player.jumpTo(index),
                            );
                          },
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Glass bottom sheet that adds the current [song] to one of the signed-in
/// user's playlists. Fires [LibraryProvider.loadUserPlaylists] on open when the
/// list is cold, then renders loading / empty / list states.
class _AddToPlaylistSheet extends StatefulWidget {
  final Song song;

  const _AddToPlaylistSheet({required this.song});

  @override
  State<_AddToPlaylistSheet> createState() => _AddToPlaylistSheetState();
}

class _AddToPlaylistSheetState extends State<_AddToPlaylistSheet> {
  late final LibraryProvider _lib;

  @override
  void initState() {
    super.initState();
    _lib = context.read<LibraryProvider>();
    if (_lib.userPlaylists.isEmpty && !_lib.userPlaylistsLoading) {
      _lib.loadUserPlaylists();
    }
  }

  Future<void> _add(BuildContext context, Playlist playlist) async {
    final Song song = widget.song;
    // Capture the messenger before popping — this element is gone after pop.
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    try {
      await _lib.addSongToPlaylist(playlist.id, song);
      _snack(messenger, '已添加到「${playlist.name}」');
    } catch (_) {
      _snack(messenger, '添加失败');
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

  @override
  Widget build(BuildContext context) {
    final double maxHeight = MediaQuery.of(context).size.height * 0.6;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(AppDimens.space12),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: GlassContainer(
            blur: AppDimens.blurPanel,
            padding: const EdgeInsets.symmetric(vertical: AppDimens.space12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: AppDimens.space16),
                  child: Row(
                    children: <Widget>[
                      Text('添加到歌单', style: AppTypography.titleM),
                    ],
                  ),
                ),
                const SizedBox(height: AppDimens.space8),
                Flexible(
                  child: Consumer<LibraryProvider>(
                    builder: (BuildContext context, LibraryProvider lib,
                        Widget? _) {
                      if (lib.userPlaylistsLoading) {
                        return const Padding(
                          padding: EdgeInsets.all(AppDimens.space32),
                          child: Center(child: CircularProgressIndicator()),
                        );
                      }
                      if (lib.createdPlaylists.isEmpty) {
                        return Padding(
                          padding: const EdgeInsets.all(AppDimens.space24),
                          child: Text(
                            '暂无可用歌单（请登录网易云账号）',
                            style: AppTypography.label,
                            textAlign: TextAlign.center,
                          ),
                        );
                      }
                      return ListView.builder(
                        shrinkWrap: true,
                        itemCount: lib.createdPlaylists.length,
                        itemBuilder: (BuildContext context, int index) {
                          final Playlist pl = lib.createdPlaylists[index];
                          return ListTile(
                            leading: ArtworkImage(
                              url: pl.coverUrl,
                              size: 48,
                              radius: AppDimens.radiusSm,
                            ),
                            title: Text(
                              pl.name,
                              style: AppTypography.body,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              '${pl.trackCount} 首',
                              style: AppTypography.caption,
                            ),
                            onTap: () => _add(context, pl),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Glass bottom sheet that adds the current [song] to a LOCAL "共同歌单". Lists the
/// user's local playlists (with a ✓ where the song is already present) plus a
/// "新建歌单并添加" shortcut. Works for songs from ANY backend (that's the point —
/// a Kugou track can join a list seeded from a Netease import).
class _AddToLocalPlaylistSheet extends StatelessWidget {
  final Song song;

  const _AddToLocalPlaylistSheet({required this.song});

  Future<void> _createAndAdd(BuildContext context) async {
    // Capture across the awaits so we never touch a possibly-unmounted context.
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
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('已创建「${pl.name}」并添加')));
  }

  Future<void> _add(BuildContext context, LocalPlaylist pl) async {
    final NavigatorState navigator = Navigator.of(context);
    final LocalPlaylistProvider prov = context.read<LocalPlaylistProvider>();
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool added = await prov.addSong(pl.id, song);
    navigator.pop();
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(added ? '已添加到「${pl.name}」' : '「${pl.name}」已有这首歌'),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final List<LocalPlaylist> playlists =
        context.watch<LocalPlaylistProvider>().playlists;
    final double maxHeight = MediaQuery.of(context).size.height * 0.6;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(AppDimens.space12),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: GlassContainer(
            blur: AppDimens.blurPanel,
            padding: const EdgeInsets.symmetric(vertical: AppDimens.space12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: AppDimens.space16),
                  child: Row(
                    children: <Widget>[
                      Text('添加到本地歌单', style: AppTypography.titleM),
                    ],
                  ),
                ),
                const SizedBox(height: AppDimens.space8),
                ListTile(
                  leading:
                      const Icon(Icons.add_rounded, color: AppColors.onSurface),
                  title: Text('新建歌单并添加', style: AppTypography.body),
                  onTap: () => _createAndAdd(context),
                ),
                Flexible(
                  child: playlists.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.all(AppDimens.space24),
                          child: Text(
                            '还没有本地歌单，点上方「新建歌单并添加」',
                            style: AppTypography.label,
                            textAlign: TextAlign.center,
                          ),
                        )
                      : ListView.builder(
                          shrinkWrap: true,
                          itemCount: playlists.length,
                          itemBuilder: (BuildContext context, int index) {
                            final LocalPlaylist pl = playlists[index];
                            final bool has = pl.contains(song.id);
                            return ListTile(
                              leading: ArtworkImage(
                                url: pl.coverUrl,
                                size: 48,
                                radius: AppDimens.radiusSm,
                              ),
                              title: Text(
                                pl.name,
                                style: AppTypography.body,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
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
        ),
      ),
    );
  }
}

/// Minimal name-entry dialog owning its own controller (disposed with the dialog).
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
