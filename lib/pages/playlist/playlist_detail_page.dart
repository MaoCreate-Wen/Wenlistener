import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../models/local_playlist.dart';
import '../../models/playlist.dart';
import '../../models/song.dart';
import '../../shell/window_drag_region.dart';
import '../../state/library_provider.dart';
import '../../state/local_playlist_provider.dart';
import '../../state/player_provider.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_dimens.dart';
import '../../theme/app_typography.dart';
import 'desktop_kit.dart';

/// Desktop playlist detail (route `/playlist/:id`).
///
/// A large blurred-cover header (crisp cover + title + creator + Play-all /
/// 收藏 / 导入到共同歌单) over a dense [DkTrackTable]. Tracks come from
/// [LibraryProvider.loadPlaylist]; the page never re-implements fetching.
class PlaylistDetailPage extends StatefulWidget {
  final int playlistId;

  /// When true this same page renders an ALBUM (route `/album/:id`) — loads via
  /// [LibraryProvider.loadAlbum], labels 专辑, and hides the 收藏 action.
  final bool isAlbum;
  const PlaylistDetailPage({
    super.key,
    required this.playlistId,
    this.isAlbum = false,
  });

  @override
  State<PlaylistDetailPage> createState() => _PlaylistDetailPageState();
}

class _PlaylistDetailPageState extends State<PlaylistDetailPage> {
  late Future<Playlist> _future;

  @override
  void initState() {
    super.initState();
    final LibraryProvider lib = context.read<LibraryProvider>();
    _future = widget.isAlbum
        ? lib.loadAlbum(widget.playlistId)
        : lib.loadPlaylist(widget.playlistId);
  }

  @override
  Widget build(BuildContext context) {
    // No standalone header bar: the page is a single blurred-cover surface that
    // runs to the very top, with the back affordance floating over it. The whole
    // page sits on the OLED background so the empty area below the cover blends
    // in rather than showing a separate colored strip.
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Stack(
        children: <Widget>[
          Positioned.fill(
            child: FutureBuilder<Playlist>(
              future: _future,
              builder:
                  (BuildContext context, AsyncSnapshot<Playlist> snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Center(
                    child:
                        CircularProgressIndicator(color: AppColors.accentPlay),
                  );
                }
                if (snap.hasError || !snap.hasData) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        const Icon(Icons.error_outline_rounded,
                            color: AppColors.onFaint, size: 40),
                        const SizedBox(height: AppDimens.space12),
                        Text(widget.isAlbum ? '专辑加载失败' : '歌单加载失败',
                            style: AppTypography.body),
                        if (snap.hasError) ...<Widget>[
                          const SizedBox(height: AppDimens.space4),
                          Text('${snap.error}', style: AppTypography.caption),
                        ],
                      ],
                    ),
                  );
                }
                return _PlaylistBody(
                    playlist: snap.data!, isAlbum: widget.isAlbum);
              },
            ),
          ),
          // Window-drag band over the header's top edge (this route covers the
          // shell, so its drag bar is unreachable): drag-to-move + double-click
          // maximize, fullscreen-guarded. NOT full-height — just the top strip —
          // and stacked UNDER the back button so the button wins hit-testing.
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 48,
            child: WindowDragRegion(),
          ),
          // Floating back button, overlaid on the blurred-cover header's top-left
          // corner so it reads as part of the page — no separate solid header
          // strip. Guarded by canPop() exactly as the old DkScaffold header was.
          if (context.canPop())
            Positioned(
              top: AppDimens.space16,
              left: AppDimens.space16,
              child: DkHoverIcon(
                icon: Icons.arrow_back_rounded,
                tooltip: '返回',
                onTap: () => context.pop(),
              ),
            ),
        ],
      ),
    );
  }
}

class _PlaylistBody extends StatelessWidget {
  final Playlist playlist;
  final bool isAlbum;
  const _PlaylistBody({required this.playlist, this.isAlbum = false});

  Future<void> _playAll(BuildContext context, {int index = 0}) async {
    if (playlist.tracks.isEmpty) {
      dkToast(context, '歌单暂无可播放曲目');
      return;
    }
    await context
        .read<PlayerProvider>()
        .playQueue(playlist.tracks, index: index);
  }

  Future<void> _collect(BuildContext context) async {
    try {
      await context.read<LibraryProvider>().collectPlaylist(playlist.id, true);
      if (context.mounted) dkToast(context, '已收藏歌单');
    } catch (e) {
      if (context.mounted) dkToast(context, '收藏失败：$e');
    }
  }

  Future<void> _importToLocal(BuildContext context) async {
    final LibraryProvider lib = context.read<LibraryProvider>();
    final LocalPlaylistProvider lp = context.read<LocalPlaylistProvider>();
    if (playlist.tracks.isEmpty) {
      dkToast(context, '歌单为空，无法导入');
      return;
    }
    await lp.create(
      playlist.name,
      tracks: playlist.tracks,
      origin: LocalPlaylistOrigin(
        source: lib.source,
        remoteId: playlist.id,
        remoteName: playlist.name,
      ),
    );
    if (context.mounted) {
      dkToast(context, '已导入到共同歌单「${playlist.name}」');
    }
  }

  @override
  Widget build(BuildContext context) {
    // DkTrackPageBody owns the scroll view + in-playlist search / 定位 wiring;
    // this page only supplies its header and the play/menu actions. Row taps
    // receive the ORIGINAL index even while filtered, so the queue is always
    // the full playlist.
    return DkTrackPageBody(
      tracks: playlist.tracks,
      headerBuilder: (BuildContext ctx, Widget toolbar) => _Header(
        playlist: playlist,
        isAlbum: isAlbum,
        toolbar: toolbar,
        onPlayAll: () => _playAll(context),
        onCollect: () => _collect(context),
        onImport: () => _importToLocal(context),
      ),
      onPlayIndex: (int i) => _playAll(context, index: i),
      onMenu: (Song s, Offset pos) => dkShowSongMenu(context, s, pos),
      emptyPlaceholder: Padding(
        padding: const EdgeInsets.only(top: AppDimens.space48),
        child: Center(
          child: Text(isAlbum ? '该专辑没有曲目' : '该歌单没有曲目',
              style: AppTypography.label),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final Playlist playlist;
  final bool isAlbum;
  final Widget toolbar;
  final VoidCallback onPlayAll;
  final VoidCallback onCollect;
  final VoidCallback onImport;

  const _Header({
    required this.playlist,
    required this.toolbar,
    required this.onPlayAll,
    required this.onCollect,
    required this.onImport,
    this.isAlbum = false,
  });

  @override
  Widget build(BuildContext context) {
    // 封面兜底：歌单/专辑自身无封面时，用第一首歌的封面（专辑详情 + 歌单详情通吃）。
    final String? cover =
        (playlist.coverUrl != null && playlist.coverUrl!.isNotEmpty)
            ? playlist.coverUrl
            : (playlist.tracks.isNotEmpty
                ? playlist.tracks.first.artworkUrl
                : null);
    return SizedBox(
      height: 300,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          // Blurred cover fill.
          if (cover != null)
            ImageFiltered(
              imageFilter: ui.ImageFilter.blur(sigmaX: 40, sigmaY: 40),
              child: DkArt(
                url: cover,
                size: 900,
                radius: 0,
              ),
            ),
          // Scrim.
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: <Color>[Color(0x66000000), Color(0xE6000000)],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppDimens.space32,
              AppDimens.space20,
              AppDimens.space32,
              AppDimens.space24,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Container(
                  decoration: const BoxDecoration(
                    boxShadow: AppDimens.albumShadow,
                  ),
                  child: DkArt(url: cover, size: 200),
                ),
                const SizedBox(width: AppDimens.space24),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(isAlbum ? '专辑' : '歌单',
                          style: AppTypography.caption),
                      const SizedBox(height: AppDimens.space4),
                      Text(
                        playlist.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.displayL,
                      ),
                      const SizedBox(height: AppDimens.space8),
                      Text(
                        <String>[
                          if ((playlist.creatorName ?? '').isNotEmpty)
                            playlist.creatorName!,
                          '${playlist.trackCount} 首',
                        ].join(' · '),
                        style: AppTypography.label,
                      ),
                      if ((playlist.description ?? '').isNotEmpty) ...<Widget>[
                        const SizedBox(height: AppDimens.space8),
                        Text(
                          playlist.description!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AppTypography.caption,
                        ),
                      ],
                      const SizedBox(height: AppDimens.space20),
                      Wrap(
                        spacing: AppDimens.space12,
                        runSpacing: AppDimens.space8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: <Widget>[
                          DkPrimaryButton(
                            icon: Icons.play_arrow_rounded,
                            label: '播放全部',
                            onPressed: onPlayAll,
                          ),
                          // 专辑无「收藏」（kugougn collectPlaylist 对 albumid 无意义）。
                          if (!isAlbum)
                            DkSecondaryButton(
                              icon: Icons.favorite_border_rounded,
                              label: '收藏',
                              onPressed: onCollect,
                            ),
                          DkSecondaryButton(
                            icon: Icons.library_add_rounded,
                            label: '导入到共同歌单',
                            onPressed: onImport,
                          ),
                          toolbar,
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
