import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../animation/neon_flow_background.dart';
import '../../router/routes.dart';
import '../../services/fft_service.dart';
import '../../state/player_provider.dart';
import '../../state/settings_provider.dart';
import '../../theme/app_dimens.dart';
import '../../theme/app_typography.dart';
import '../../widgets/artwork_image.dart';
import '../../widgets/dismissible_sheet.dart';
import 'widgets/lyrics_view.dart';

/// Synced full-screen lyrics: a neon-flow background, a compact header (artwork
/// hero + title + close) and the reusable [LyricsView] stack (which owns the
/// lyric engine and feeds it from [PlayerProvider]). Tap a line to seek.
///
/// Stateful only to bracket the real-time FFT: [FftService.start] on open (so
/// the lyrics-page background reacts to the bass) and [FftService.stop] on close
/// — the native Visualizer (and the mic permission it needs) is therefore held
/// ONLY while this page is on screen, not for the whole app session.
class LyricsPage extends StatefulWidget {
  const LyricsPage({super.key});

  @override
  State<LyricsPage> createState() => _LyricsPageState();
}

class _LyricsPageState extends State<LyricsPage> {
  late final FftService _fft;

  @override
  void initState() {
    super.initState();
    _fft = context.read<FftService>();
    // Only run the Visualizer (and hold the mic) when 律动 is enabled in settings.
    // Begins the feed (requests RECORD_AUDIO on first use); if denied/unsupported
    // it self-degrades to the synthetic pulse — never throws.
    if (context.read<SettingsProvider>().rhythmEnabled) _fft.start();
  }

  @override
  void dispose() {
    _fft.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Field-level selects, not a whole-provider watch: the lyric position tick
    // is consumed inside LyricsView; this page rebuilds only when the artwork,
    // palette or play-state changes, so the heavy NeonFlowBackground shader
    // isn't reconfigured on every frame.
    final String? artworkUrl = context.select<PlayerProvider, String?>(
      (PlayerProvider p) => p.currentSong?.artworkUrl,
    );
    final List<Color> colors = context.select<PlayerProvider, List<Color>>(
      (PlayerProvider p) => p.paletteColors,
    );
    final bool playing =
        context.select<PlayerProvider, bool>((PlayerProvider p) => p.isPlaying);
    final bool rhythmEnabled = context.select<SettingsProvider, bool>(
      (SettingsProvider s) => s.rhythmEnabled,
    );

    return Scaffold(
      // Transparent so the non-opaque route reveals /player behind the slide.
      backgroundColor: Colors.transparent,
      body: DismissibleSheet(
        // Grabber-only: a downward swipe over the lyrics browse-scrolls them (see
        // [LyricsView]); only the 顶部小横条 pull-down dismisses the page. This slide
        // is the ONE place a slide animation runs, and it returns to HOME (not the
        // player — that's the 返回键's job). The DismissibleSheet suppresses the
        // album_art Hero so the cover slides DOWN with the page.
        dragAnywhere: false,
        onDismiss: () => context.go(Routes.home),
        builder: (BuildContext context, VoidCallback dismiss,
                ValueListenable<bool> heroSuppressed) =>
            Stack(
          fit: StackFit.expand,
          children: <Widget>[
            Positioned.fill(
              child: NeonFlowBackground(
                imageUrl: artworkUrl,
                colors: colors,
                playing: playing,
                lowFreqVolume: _fft.lowFreqVolume,
                reactive: rhythmEnabled,
              ),
            ),
            SafeArea(
              child: Column(
                children: <Widget>[
                  // 顶部小横条 (grabber): tap or pull-down to dismiss to the player.
                  SheetGrabber(onTap: dismiss),
                  // Header: album cover + title, with the AMLL 返回键 on the right
                  // at the SAME height as the cover. The 返回键 pops (Hero flies).
                  _Header(
                    heroSuppressed: heroSuppressed,
                    onReturn: () {
                      if (context.canPop()) context.pop();
                    },
                  ),
                  const Expanded(child: LyricsView()),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// AMLL-style circular return button (translucent white field + white glyph — the
/// AMLL `MenuButton` look). A down-chevron reads as "collapse the full-screen
/// lyrics back to the player".
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

class _Header extends StatelessWidget {
  /// Drops the album_art Hero (so the cover slides DOWN with the page on a
  /// grabber dismiss instead of flying); the 返回键 / system back keep the Hero.
  final ValueListenable<bool> heroSuppressed;

  /// The AMLL 返回键 tap — pops to the player (Hero flies the cover down).
  final VoidCallback onReturn;

  const _Header({required this.heroSuppressed, required this.onReturn});

  @override
  Widget build(BuildContext context) {
    final String? artworkUrl = context.select<PlayerProvider, String?>(
      (PlayerProvider p) => p.currentSong?.artworkUrl,
    );
    final String name = context.select<PlayerProvider, String>(
      (PlayerProvider p) => p.currentSong?.name ?? '',
    );
    final String artist = context.select<PlayerProvider, String>(
      (PlayerProvider p) => p.currentSong?.artistNames ?? '',
    );
    // Row: cover (with the album_art Hero) + title/artist + the AMLL 返回键 — all
    // in one row, so the 返回键 sits at the SAME height as the cover.
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppDimens.space16,
        AppDimens.space4,
        AppDimens.space16,
        AppDimens.space8,
      ),
      child: Row(
        children: <Widget>[
          ValueListenableBuilder<bool>(
            valueListenable: heroSuppressed,
            builder: (BuildContext context, bool suppressed, Widget? _) =>
                ArtworkImage(
              url: artworkUrl,
              size: 44,
              radius: AppDimens.radiusSm,
              heroTag: suppressed ? null : 'album_art',
            ),
          ),
          const SizedBox(width: AppDimens.space12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  name,
                  style: AppTypography.titleL.copyWith(fontSize: 17, height: 1.2),
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
          const SizedBox(width: AppDimens.space12),
          _ReturnButton(onTap: onReturn),
        ],
      ),
    );
  }
}
