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
import '../playlist/desktop_kit.dart';

/// Desktop "共同歌单" (local, cross-source playlist) detail — route `/local/:id`.
///
/// Mirrors [PlaylistDetailPage]'s language (a blurred-cover header with a
/// floating back button over a dense [DkTrackTable], no separate solid bar) but
/// drives the on-device [LocalPlaylistProvider] instead of a backend playlist.
/// It listens to that provider (via `context.select` on this one list) so any
/// edit — import / resync / rename / remove — refreshes live, and copes with the
/// list being absent (deleted elsewhere, or a bad deep-link id).
class LocalPlaylistDetailPage extends StatelessWidget {
  final String playlistId;
  const LocalPlaylistDetailPage({super.key, required this.playlistId});

  @override
  Widget build(BuildContext context) {
    // Rebuild only when THIS list changes (copy-on-write ⇒ new instance), not on
    // every unrelated playlist mutation.
    final LocalPlaylist? pl = context.select<LocalPlaylistProvider, LocalPlaylist?>(
      (LocalPlaylistProvider p) => p.byId(playlistId),
    );
    final bool loaded =
        context.select<LocalPlaylistProvider, bool>((LocalPlaylistProvider p) => p.loaded);

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Stack(
        children: <Widget>[
          Positioned.fill(
            child: !loaded
                ? const Center(
                    child: CircularProgressIndicator(color: AppColors.accentPlay),
                  )
                : (pl == null
                    ? const _Missing()
                    : _LocalBody(playlist: pl)),
          ),
          // Window-drag band over the header's top edge, exactly like the
          // playlist page: top strip only, stacked UNDER the back button so the
          // button wins hit-testing; fullscreen-guarded by [WindowDragRegion].
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 48,
            child: WindowDragRegion(),
          ),
          // Floating back button overlaid on the header's top-left, exactly like
          // the playlist page — no separate solid header strip.
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

class _Missing extends StatelessWidget {
  const _Missing();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(Icons.playlist_remove_rounded,
              color: AppColors.onFaint, size: 44),
          const SizedBox(height: AppDimens.space12),
          Text('共同歌单不存在或已删除', style: AppTypography.body),
          const SizedBox(height: AppDimens.space16),
          DkSecondaryButton(
            icon: Icons.arrow_back_rounded,
            label: '返回',
            onPressed: context.canPop() ? () => context.pop() : null,
          ),
        ],
      ),
    );
  }
}

class _LocalBody extends StatelessWidget {
  final LocalPlaylist playlist;
  const _LocalBody({required this.playlist});

  Future<void> _playAll(BuildContext context, {int index = 0}) async {
    if (playlist.tracks.isEmpty) {
      dkToast(context, '歌单暂无可播放曲目');
      return;
    }
    await context.read<PlayerProvider>().playQueue(playlist.tracks, index: index);
  }

  /// "导入本地音乐": asks 文件 vs 文件夹, then imports on-device audio into this
  /// list via [LocalPlaylistProvider.importLocalFiles].
  Future<void> _importLocal(BuildContext context) async {
    final bool? scanDir = await _pickImportMode(context);
    if (scanDir == null || !context.mounted) return;
    final LocalPlaylistProvider lp = context.read<LocalPlaylistProvider>();
    final int n = await lp.importLocalFiles(playlist.id, scanDir: scanDir);
    if (context.mounted) {
      dkToast(context, n > 0 ? '已导入 $n 首本地音乐' : '未导入（已取消或都已存在）');
    }
  }

  Future<void> _rename(BuildContext context) async {
    final String? name = await dkPromptText(
      context,
      title: '重命名共同歌单',
      hint: '歌单名称',
      initial: playlist.name,
    );
    if (name == null || name.trim().isEmpty || !context.mounted) return;
    await context.read<LocalPlaylistProvider>().rename(playlist.id, name.trim());
  }

  Future<void> _delete(BuildContext context) async {
    final bool ok = await _confirmDelete(context, playlist.name);
    if (!ok || !context.mounted) return;
    await context.read<LocalPlaylistProvider>().delete(playlist.id);
    if (context.mounted && context.canPop()) context.pop();
  }

  @override
  Widget build(BuildContext context) {
    // DkTrackPageBody owns the scroll view + in-playlist search / 定位 wiring
    // (identical to the remote playlist page); row taps receive the ORIGINAL
    // index even while filtered, so the queue is always the full playlist.
    return DkTrackPageBody(
      tracks: playlist.tracks,
      headerBuilder: (BuildContext ctx, Widget toolbar) => _Header(
        playlist: playlist,
        toolbar: toolbar,
        onPlayAll: () => _playAll(context),
        onImport: () => _importLocal(context),
        onRename: () => _rename(context),
        onDelete: () => _delete(context),
      ),
      onPlayIndex: (int i) => _playAll(context, index: i),
      onMenu: (Song s, Offset pos) => dkShowSongMenu(
        context,
        s,
        pos,
        onRemove: () =>
            context.read<LocalPlaylistProvider>().removeSong(playlist.id, s.id),
      ),
      emptyPlaceholder: _EmptyTracks(onImport: () => _importLocal(context)),
    );
  }
}

class _EmptyTracks extends StatelessWidget {
  final VoidCallback onImport;
  const _EmptyTracks({required this.onImport});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AppDimens.space48),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.library_music_outlined,
                color: AppColors.onFaint, size: 44),
            const SizedBox(height: AppDimens.space12),
            Text('这个共同歌单还没有曲目', style: AppTypography.body),
            const SizedBox(height: AppDimens.space4),
            Text('从任意音源的歌单 ⋯ 添加，或导入本地音乐', style: AppTypography.label),
            const SizedBox(height: AppDimens.space20),
            DkPrimaryButton(
              icon: Icons.folder_open_rounded,
              label: '导入本地音乐',
              onPressed: onImport,
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final LocalPlaylist playlist;
  final Widget toolbar;
  final VoidCallback onPlayAll;
  final VoidCallback onImport;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  const _Header({
    required this.playlist,
    required this.toolbar,
    required this.onPlayAll,
    required this.onImport,
    required this.onRename,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final LocalPlaylistOrigin? origin = playlist.origin;
    final String? cover = playlist.coverUrl;

    return SizedBox(
      height: 300,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          if (cover != null)
            ImageFiltered(
              imageFilter: ui.ImageFilter.blur(sigmaX: 40, sigmaY: 40),
              child: DkArt(url: cover, size: 900, radius: 0),
            ),
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
                  decoration: const BoxDecoration(boxShadow: AppDimens.albumShadow),
                  child: DkArt(url: cover, size: 200),
                ),
                const SizedBox(width: AppDimens.space24),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text('共同歌单', style: AppTypography.caption),
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
                          '${playlist.trackCount} 首',
                          if (origin != null)
                            '来自${dkSourceLabel(origin.source)}·${origin.remoteName}',
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.label,
                      ),
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
                          DkSecondaryButton(
                            icon: Icons.folder_open_rounded,
                            label: '导入本地音乐',
                            onPressed: onImport,
                          ),
                          if (origin != null)
                            _ResyncButton(playlist: playlist, origin: origin),
                          DkSecondaryButton(
                            icon: Icons.drive_file_rename_outline_rounded,
                            label: '重命名',
                            onPressed: onRename,
                          ),
                          DkSecondaryButton(
                            icon: Icons.delete_outline_rounded,
                            label: '删除',
                            onPressed: onDelete,
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

/// "重新同步": fetches the origin playlist FRESH via
/// [LibraryProvider.fetchPlaylistFresh] and diffs it into this list via
/// [LocalPlaylistProvider.resync] (add/remove-delta, order preserved). Stateful
/// only for the in-flight spinner; renders as a [DkSecondaryButton] otherwise.
class _ResyncButton extends StatefulWidget {
  final LocalPlaylist playlist;
  final LocalPlaylistOrigin origin;

  const _ResyncButton({required this.playlist, required this.origin});

  @override
  State<_ResyncButton> createState() => _ResyncButtonState();
}

class _ResyncButtonState extends State<_ResyncButton> {
  bool _busy = false;

  Future<void> _sync() async {
    if (_busy) return;
    // Capture before the awaits — the widget may unmount across the network gap.
    final LibraryProvider library = context.read<LibraryProvider>();
    final LocalPlaylistProvider local = context.read<LocalPlaylistProvider>();
    setState(() => _busy = true);
    try {
      final Playlist remote = await library.fetchPlaylistFresh(
        widget.origin.source,
        widget.origin.remoteId,
      );
      final ({int added, int removed}) diff =
          await local.resync(widget.playlist.id, remote.tracks);
      if (!mounted) return;
      dkToast(
        context,
        (diff.added == 0 && diff.removed == 0)
            ? '已是最新'
            : '已同步 · 新增 ${diff.added} · 移除 ${diff.removed}',
      );
    } catch (e) {
      if (!mounted) return;
      dkToast(context, '同步失败，请检查网络后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_busy) {
      return Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppDimens.space20,
          vertical: AppDimens.space12,
        ),
        decoration: BoxDecoration(
          color: AppColors.glass,
          borderRadius: BorderRadius.circular(AppDimens.radiusPill),
          border: Border.all(color: AppColors.glassBorder),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.accentPlay,
              ),
            ),
            const SizedBox(width: AppDimens.space8),
            Text('同步中…',
                style: AppTypography.label.copyWith(color: AppColors.onSurface)),
          ],
        ),
      );
    }
    return DkSecondaryButton(
      icon: Icons.sync_rounded,
      label: '重新同步',
      onPressed: _sync,
    );
  }
}

/// Asks whether an import should pick individual files or scan a whole folder.
/// Returns `true` (folder scan) / `false` (files) / `null` (cancelled).
Future<bool?> _pickImportMode(BuildContext context) {
  return showDialog<bool>(
    context: context,
    builder: (BuildContext ctx) {
      return SimpleDialog(
        backgroundColor: AppColors.surface2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppDimens.radiusLg),
          side: const BorderSide(color: AppColors.glassBorder),
        ),
        title: Text('导入本地音乐', style: AppTypography.titleM),
        children: <Widget>[
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, false),
            child: Row(
              children: <Widget>[
                const Icon(Icons.audio_file_outlined, color: AppColors.onMuted),
                const SizedBox(width: AppDimens.space12),
                Text('选择音频文件…', style: AppTypography.body),
              ],
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, true),
            child: Row(
              children: <Widget>[
                const Icon(Icons.folder_open_outlined, color: AppColors.onMuted),
                const SizedBox(width: AppDimens.space12),
                Text('扫描文件夹…', style: AppTypography.body),
              ],
            ),
          ),
        ],
      );
    },
  );
}

/// Confirms deleting the whole local playlist. Returns whether the user confirmed.
Future<bool> _confirmDelete(BuildContext context, String name) async {
  final bool? ok = await showDialog<bool>(
    context: context,
    builder: (BuildContext ctx) {
      return AlertDialog(
        backgroundColor: AppColors.surface2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppDimens.radiusLg),
          side: const BorderSide(color: AppColors.glassBorder),
        ),
        title: Text('删除共同歌单', style: AppTypography.titleM),
        content: Text('确定删除「$name」？此操作不可撤销。', style: AppTypography.body),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消', style: AppTypography.label),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('删除',
                style: AppTypography.label.copyWith(color: AppColors.accentPlay)),
          ),
        ],
      );
    },
  );
  return ok ?? false;
}
