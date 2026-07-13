import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../animation/neon_flow_background.dart';
import '../../router/routes.dart';
import '../../services/fft_service.dart';
import '../../services/mem_probe.dart';
import '../../shell/window_drag_region.dart';
import '../../state/player_provider.dart';
import '../../state/settings_provider.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_dimens.dart';
import '../../theme/app_typography.dart';
import '../../widgets/artwork_image.dart';
import 'widgets/lyrics_view.dart';

/// The lyrics-maximized full-bleed route (`/lyrics`): the AMLL [LyricsView] over
/// the reactive [NeonFlowBackground] (FFT 律动), with a compact now-playing
/// header (mini cover + title) and a single top-centre grabber to dismiss.
///
/// The native Visualizer channel is Android-only; on Windows [FftService.start]
/// short-circuits to the `< 0` sentinel and the background falls back to its
/// synthetic pulse — so this page degrades cleanly with no platform-channel
/// touch. FFT is started in [initState] (only when 律动 is enabled) and stopped
/// in [dispose].
class LyricsPage extends StatefulWidget {
  const LyricsPage({super.key});

  @override
  State<LyricsPage> createState() => _LyricsPageState();
}

class _LyricsPageState extends State<LyricsPage> {
  FftService? _fft;
  bool _fftRunning = false;

  bool _openMarked = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_openMarked) {
      _openMarked = true;
      MemProbe.instance.mark('lyrics.open');
    }
    _fft ??= context.read<FftService>();
    if (!_fftRunning && context.read<SettingsProvider>().rhythmEnabled) {
      _fft!.start();
      _fftRunning = true;
    }
  }

  @override
  void dispose() {
    MemProbe.instance.mark('lyrics.dispose (→home)');
    if (_fftRunning) _fft?.stop();
    // After the pop settles, un-pin live images so the 64MB imageCache cap can
    // reclaim the /lyrics-only large decodes (the 640² header cover, the mesh/
    // palette analysis clones) that no longer have a painting listener. This is
    // deliberately clearLiveImages() (un-pin), NOT clear() (evict): still-mounted
    // Home covers get re-pinned on their very next paint frame as Home uncovers,
    // so returning home shows no re-decode flicker. Scheduled post-frame so it
    // doesn't fight the concurrent-raster pop window.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      PaintingBinding.instance.imageCache.clearLiveImages();
    });
    super.dispose();
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
        context.select<PlayerProvider, bool>((p) => p.hasSong);
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          _Background(fft: _fft),
          SafeArea(
            child: Column(
              children: <Widget>[
                _Grabber(onTap: _dismiss),
                const _Header(),
                Expanded(
                  child: hasSong
                      ? const _MaximizedLyrics()
                      : _empty(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _empty() => Center(
        child: Text('当前没有播放', style: AppTypography.titleM),
      );
}

/// The reactive mesh-gradient field (AMLL `MeshGradientRenderer`), tinted by the
/// current album art and pulsing to the FFT low-frequency signal.
class _Background extends StatelessWidget {
  final FftService? fft;
  const _Background({required this.fft});

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
    return RepaintBoundary(
      child: NeonFlowBackground(
        imageUrl: artworkUrl,
        colors: colors,
        playing: playing,
        reactive: reactive,
        lowFreqVolume: fft?.lowFreqVolume,
      ),
    );
  }
}

/// Compact now-playing header: mini cover + title / artist.
class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    final String? artworkUrl =
        context.select<PlayerProvider, String?>((p) => p.currentSong?.artworkUrl);
    final String title =
        context.select<PlayerProvider, String>((p) => p.currentSong?.name ?? '');
    final String artist = context
        .select<PlayerProvider, String>((p) => p.currentSong?.artistNames ?? '');
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppDimens.space32,
        AppDimens.space8,
        AppDimens.space32,
        AppDimens.space16,
      ),
      child: Row(
        children: <Widget>[
          // Bucketed decode (ArtworkImage/ResizeImage) — the old PlayerArtwork
          // resolved the RAW provider here, decoding the full-resolution cover
          // (25-36 MB RGBA) for a 52px thumbnail on every /lyrics open.
          ArtworkImage(
            url: artworkUrl,
            size: 52,
            radius: AppDimens.radiusSm,
            shadow: AppDimens.albumShadow,
          ),
          const SizedBox(width: AppDimens.space16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Text(
                  title,
                  style: AppTypography.titleL.copyWith(fontSize: 18),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  artist,
                  style: AppTypography.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The full-bleed lyric column, larger than the two-pane variant and centred.
///
/// The top/bottom edge dissolve used to be a page-wide `ShaderMask(dstIn)`
/// around this whole subtree — one full-WINDOW `saveLayer` re-composited every
/// animated frame, the page's single biggest constant raster cost. It is now
/// [LyricsView]'s built-in per-line fade (`fadeTop/BottomFraction`, same
/// gradient stops): only the few lines whose pixels actually reach the 14%
/// bands go through a LINE-sized mask layer (see `LineEdgeFade`), everything
/// else paints layer-free. Visually identical; the full-window offscreen is
/// gone.
class _MaximizedLyrics extends StatelessWidget {
  const _MaximizedLyrics();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        // Constrain the lyric column so long lines stay readable on very wide
        // windows; centre it horizontally.
        final double maxW = c.maxWidth.clamp(0.0, 900.0);
        final double sidePad = (c.maxWidth - maxW) / 2 + AppDimens.space48;
        return LyricsView(
          padding: EdgeInsets.symmetric(horizontal: sidePad),
          alignPosition: 0.44,
          mainStyle: LyricsView.defaultMainStyle.copyWith(fontSize: 34),
          fadeTopFraction: 0.14,
          fadeBottomFraction: 0.14,
        );
      },
    );
  }
}

/// Top-centre pull handle. Tap dismisses the sheet.
///
/// As on the player page, the strip's EMPTY area is the route's window-drag
/// region: a [WindowDragRegion] (drag-to-move + double-click maximize,
/// fullscreen-guarded) fills the strip UNDER the pill, whose opaque hit test
/// keeps the close tap winning over the strip.
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
