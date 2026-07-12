import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../models/song.dart';
import '../../../state/player_provider.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_dimens.dart';
import '../../../theme/app_typography.dart';
import 'player_artwork.dart';

/// Presents AMLL's `NowPlaylistCard` — the play-queue panel — as a public,
/// top-level entry point so both the full player page **and** the mini-player
/// bottom bar can open the same panel.
///
/// The card is a frosted-glass surface that **slides in from the right edge and
/// docks** there over a dim scrim, and slides back out on dismiss (spec §2). Tap
/// a row to jump; tap the scrim or the queue button again to close.
Future<void> showQueuePanel(BuildContext context) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '播放队列',
    barrierColor: const Color(0x66000000), // dim scrim
    transitionDuration: const Duration(milliseconds: 260),
    pageBuilder: (BuildContext _, __, ___) => const QueuePanel(),
    transitionBuilder:
        (BuildContext ctx, Animation<double> anim, _, Widget child) {
      final CurvedAnimation curved = CurvedAnimation(
        parent: anim,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return SlideTransition(
        position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
            .animate(curved),
        child: FadeTransition(opacity: curved, child: child),
      );
    },
  );
}

/// The right-docked frosted card holding the queue list.
///
/// Frosted-glass look kept intact (blur + hairline + deep shadow), but the fill
/// carries a **subtle dark scrim** behind the content so the light/white row
/// text stays legible on the translucent surface.
class QueuePanel extends StatelessWidget {
  const QueuePanel({super.key});

  @override
  Widget build(BuildContext context) {
    final Size mq = MediaQuery.of(context).size;
    // AMLL width max(10vw, 50vh) capped 400. Height is TALLER than AMLL's 50vh
    // so ~10 rows (56px) + header (44px) = 604 are visible when the window is
    // tall enough (spec §5 "strict 10 visible"), shrinking on short windows.
    final double w = math.min(400.0, math.max(mq.width * 0.10, mq.height * 0.50));
    final double h = math.min(604.0, math.max(360.0, mq.height * 0.72));
    // Apple-Music frosted glass (spec §2): blur 28, hairline, radius, deep drop
    // shadow — with a dark scrim so the WHITE row text reads clearly.
    return SafeArea(
      child: Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: const EdgeInsets.all(AppDimens.space12),
          child: Material(
            type: MaterialType.transparency,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppDimens.radiusLg),
                boxShadow: const <BoxShadow>[
                  BoxShadow(
                    color: Color(0x59000000), // black α0.35
                    blurRadius: 30,
                    offset: Offset(0, 12),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppDimens.radiusLg),
                child: BackdropFilter(
                  filter: ui.ImageFilter.blur(sigmaX: 28, sigmaY: 28),
                  child: Container(
                    width: w,
                    height: h,
                    decoration: BoxDecoration(
                      // A glassy white sheen laid over the blur…
                      color: Colors.white.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(AppDimens.radiusLg),
                      border: Border.all(
                          color: Colors.white.withValues(alpha: 0.22),
                          width: 1),
                    ),
                    child: Stack(
                      children: <Widget>[
                        // …plus a subtle dark scrim behind the content so white
                        // text keeps contrast without killing the frosted look.
                        Positioned.fill(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius:
                                  BorderRadius.circular(AppDimens.radiusLg),
                              gradient: const LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: <Color>[
                                  Color(0x4D0E0E12), // black-ish α0.30
                                  Color(0x660E0E12), // black-ish α0.40
                                ],
                              ),
                            ),
                          ),
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            Padding(
                              padding: const EdgeInsets.fromLTRB(
                                  AppDimens.space16,
                                  AppDimens.space16,
                                  AppDimens.space16,
                                  AppDimens.space8),
                              child: Text(
                                '当前播放列表',
                                style: AppTypography.titleM.copyWith(
                                  color: Colors.white.withValues(alpha: 0.92),
                                ),
                              ),
                            ),
                            const Expanded(child: _QueueList()),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The queue list body: reuses [PlayerProvider.queue] / `currentSong` /
/// `jumpTo`; tap a row to jump to it and close the panel.
///
/// Stateful so the [ScrollController] can be created **once per panel open**
/// (the dialog builds a fresh [_QueueList] each time it is shown) with an
/// `initialScrollOffset` that centers the currently-playing row in the
/// viewport *before the first paint* — long queues open already scrolled to
/// the current track, with no jump animation.
class _QueueList extends StatefulWidget {
  const _QueueList();

  @override
  State<_QueueList> createState() => _QueueListState();
}

class _QueueListState extends State<_QueueList> {
  /// Fixed row height (spec §5: ~10 rows of 56px). Passed as `itemExtent` so
  /// the centering math below is exact, not an estimate.
  static const double _rowExtent = 56.0;

  ScrollController? _controller;

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  /// Lazily builds the list's controller on the first layout pass (when the
  /// viewport height is finally known), so the very first frame already shows
  /// the current track centered:
  ///
  ///   rowCenter = padTop + currentIndex * 56 + 28
  ///   offset    = clamp(rowCenter − viewport / 2,
  ///                     0, max(0, padTop + count * 56 + padBottom − viewport))
  ///
  /// Reuses the same controller on subsequent rebuilds (queue mutations while
  /// the panel is open must not yank the user's scroll position); re-centering
  /// happens naturally on the next open because the dialog recreates this
  /// state object.
  ScrollController _controllerFor({
    required double viewportHeight,
    required int currentIndex,
    required int itemCount,
  }) {
    final ScrollController? existing = _controller;
    if (existing != null) return existing;
    const double pad = AppDimens.space8; // list's vertical padding, both ends
    double offset = 0;
    if (itemCount > 0 && currentIndex >= 0 && currentIndex < itemCount) {
      final double rowCenter =
          pad + currentIndex * _rowExtent + _rowExtent / 2;
      final double maxScroll = math.max(
          0.0, pad + itemCount * _rowExtent + pad - viewportHeight);
      offset = (rowCenter - viewportHeight / 2).clamp(0.0, maxScroll);
    }
    return _controller = ScrollController(initialScrollOffset: offset);
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<PlayerProvider>(
      builder: (BuildContext ctx, PlayerProvider player, Widget? _) {
        final List<Song> queue = player.queue;
        final Song? current = player.currentSong;
        // Light text on the dark-scrimmed frosted surface: the title + artist are
        // WHITE / light so they stay legible; the active row uses the accent.
        final Color primaryText = Colors.white.withValues(alpha: 0.95);
        final Color secondaryText = Colors.white.withValues(alpha: 0.58);
        if (queue.isEmpty) {
          return Center(
            child: Text('队列为空',
                style: AppTypography.label.copyWith(color: secondaryText)),
          );
        }
        return LayoutBuilder(
            builder: (BuildContext ctx, BoxConstraints constraints) {
          return ListView.builder(
            controller: _controllerFor(
              viewportHeight: constraints.maxHeight,
              // Nothing playing (null index) → open at the top.
              currentIndex: player.currentIndex ?? -1,
              itemCount: queue.length,
            ),
            // Exact fixed row height: keeps the centering math above precise
            // and matches the ~56px rows the panel height was sized around.
            itemExtent: _rowExtent,
            padding: const EdgeInsets.symmetric(
                horizontal: AppDimens.space8, vertical: AppDimens.space8),
            itemCount: queue.length,
          itemBuilder: (BuildContext ctx, int index) {
            final Song song = queue[index];
            final bool isCurrent = current != null && song.id == current.id;
            return ListTile(
              // Row height ~56 (spec §5) so ~10 rows fill the taller panel.
              minVerticalPadding: 8,
              tileColor:
                  isCurrent ? Colors.white.withValues(alpha: 0.14) : null,
              leading: PlayerArtwork(
                url: song.artworkUrl,
                size: 44,
                radius: AppDimens.radiusSm,
              ),
              title: Text(
                song.name,
                style: AppTypography.body.copyWith(
                  color: isCurrent ? AppColors.accentPlay : primaryText,
                  fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w400,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                song.artistNames,
                style: AppTypography.caption.copyWith(color: secondaryText),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: isCurrent
                  ? const Icon(Icons.equalizer_rounded,
                      color: AppColors.accentPlay, size: 20)
                  : null,
              onTap: () {
                player.jumpTo(index);
                Navigator.of(ctx).pop();
              },
            );
            },
          );
        });
      },
    );
  }
}
