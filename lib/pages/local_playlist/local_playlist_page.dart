import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../models/local_playlist.dart';
import '../../models/song.dart';
import '../../state/library_provider.dart';
import '../../state/local_playlist_provider.dart';
import '../../state/player_provider.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_dimens.dart';
import '../../theme/app_typography.dart';
import '../../widgets/artwork_image.dart';
import '../../widgets/song_tile.dart';

/// Detail for a LOCAL "共同歌单" — a cross-source, on-device playlist. Its tracks
/// may each come from a different backend (网易 / 咪咕 / 酷狗); the router plays and
/// lyrics them per-song, so a mixed list plays end to end. Tracks are removed here
/// (long-press or the trailing ✕); they're added from the player's ··· menu or by
/// importing a source playlist ("导入到本地歌单").
class LocalPlaylistPage extends StatelessWidget {
  final String playlistId;

  const LocalPlaylistPage({required this.playlistId, super.key});

  @override
  Widget build(BuildContext context) {
    // Select the single playlist: a mutation replaces its instance (copy-on-write),
    // so this rebuilds only when THIS list changes; byId → null once it's deleted.
    final LocalPlaylist? pl =
        context.select<LocalPlaylistProvider, LocalPlaylist?>(
      (LocalPlaylistProvider p) => p.byId(playlistId),
    );

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          tooltip: 'Back',
          icon: const Icon(Icons.arrow_back_ios_new_rounded,
              color: AppColors.onSurface, size: 20),
          onPressed: () {
            if (context.canPop()) context.pop();
          },
        ),
        title: Text(pl?.name ?? '歌单', style: AppTypography.titleM),
        actions: <Widget>[
          // Re-sync against the source playlist — only for imported (forked) lists.
          if (pl != null && pl.isSyncable) _SyncButton(playlist: pl),
          if (pl != null)
            IconButton(
              tooltip: '导入本地音乐',
              icon: const Icon(Icons.library_music_outlined,
                  color: AppColors.onSurfaceMuted, size: 22),
              onPressed: () => _importLocal(context, pl),
            ),
          if (pl != null)
            IconButton(
              tooltip: '重命名',
              icon: const Icon(Icons.drive_file_rename_outline_rounded,
                  color: AppColors.onSurfaceMuted, size: 22),
              onPressed: () => _rename(context, pl),
            ),
        ],
      ),
      body: pl == null ? const _Missing() : _Body(playlist: pl),
    );
  }

  /// Imports on-device audio files into this playlist. Asks 文件 vs 文件夹 first,
  /// then delegates to [LocalPlaylistProvider.importLocalFiles] and reports the
  /// count added.
  Future<void> _importLocal(BuildContext context, LocalPlaylist pl) async {
    final bool? scanDir = await pickLocalImportMode(context);
    if (scanDir == null || !context.mounted) return;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final LocalPlaylistProvider prov = context.read<LocalPlaylistProvider>();
    final int n = await prov.importLocalFiles(pl.id, scanDir: scanDir);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(n > 0 ? '已导入 $n 首本地音乐' : '未导入（已取消或都已存在）'),
      ));
  }

  Future<void> _rename(BuildContext context, LocalPlaylist pl) async {
    final String? name = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => _RenameDialog(initial: pl.name),
    );
    if (name == null || name.isEmpty || !context.mounted) return;
    context.read<LocalPlaylistProvider>().rename(pl.id, name);
  }
}

/// AppBar action that re-syncs an imported list against its source playlist:
/// fetches the remote's current tracks and hands them to
/// [LocalPlaylistProvider.resync] (the comparator), showing a spinner while it
/// runs and a `新增/移除` summary afterwards. Stateful only for the busy spinner.
class _SyncButton extends StatefulWidget {
  final LocalPlaylist playlist;

  const _SyncButton({required this.playlist});

  @override
  State<_SyncButton> createState() => _SyncButtonState();
}

class _SyncButtonState extends State<_SyncButton> {
  bool _busy = false;

  Future<void> _sync() async {
    final LocalPlaylistOrigin? origin = widget.playlist.origin;
    if (origin == null || _busy) return;
    // Capture before the awaits (the widget may unmount across the network gap).
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final LibraryProvider library = context.read<LibraryProvider>();
    final LocalPlaylistProvider local = context.read<LocalPlaylistProvider>();
    setState(() => _busy = true);
    try {
      final remote =
          await library.fetchPlaylistFresh(origin.source, origin.remoteId);
      final ({int added, int removed}) diff =
          await local.resync(widget.playlist.id, remote.tracks);
      if (!mounted) return;
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text((diff.added == 0 && diff.removed == 0)
              ? '已是最新'
              : '已同步 · 新增 ${diff.added} · 移除 ${diff.removed}'),
        ));
    } catch (e) {
      debugPrint('local playlist resync failed: $e');
      if (!mounted) return;
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
            const SnackBar(content: Text('同步失败，请检查网络后重试')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_busy) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: AppDimens.space12),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    return IconButton(
      tooltip: '同步歌单',
      icon: const Icon(Icons.sync_rounded,
          color: AppColors.onSurfaceMuted, size: 22),
      onPressed: _sync,
    );
  }
}

class _Body extends StatelessWidget {
  final LocalPlaylist playlist;

  const _Body({required this.playlist});

  @override
  Widget build(BuildContext context) {
    final List<Song> tracks = playlist.tracks;
    return CustomScrollView(
      slivers: <Widget>[
        SliverToBoxAdapter(child: _Header(playlist: playlist)),
        if (tracks.isEmpty)
          const SliverToBoxAdapter(child: _EmptyTracks())
        else
          SliverList.builder(
            itemCount: tracks.length,
            itemBuilder: (BuildContext context, int index) => _LocalTrackRow(
              playlistId: playlist.id,
              song: tracks[index],
              index: index,
              onTap: () =>
                  context.read<PlayerProvider>().playQueue(tracks, index: index),
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: AppDimens.space32)),
      ],
    );
  }
}

/// Cover + name + "N首 · 共同歌单" + a big play button.
class _Header extends StatelessWidget {
  final LocalPlaylist playlist;

  const _Header({required this.playlist});

  @override
  Widget build(BuildContext context) {
    final Color accent = context.select<PlayerProvider, Color>(
      (PlayerProvider p) => p.dynamicAccent,
    );
    final List<Song> tracks = playlist.tracks;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppDimens.screenPadding,
        AppDimens.space8,
        AppDimens.screenPadding,
        AppDimens.space16,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          ArtworkImage(
            url: playlist.coverUrl,
            size: 96,
            radius: AppDimens.radiusMd,
          ),
          const SizedBox(width: AppDimens.space16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  playlist.name,
                  style: AppTypography.titleL,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: AppDimens.space4),
                Text(
                  '${playlist.trackCount}首  ·  共同歌单',
                  style: AppTypography.label,
                ),
                if (playlist.origin != null) ...<Widget>[
                  const SizedBox(height: AppDimens.space4),
                  Text(
                    '来自${_sourceLabel(playlist.origin!.source)}「${playlist.origin!.remoteName}」',
                    style: AppTypography.caption
                        .copyWith(color: AppColors.onSurfaceMuted),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                const SizedBox(height: AppDimens.space12),
                _PlayButton(
                  accent: accent,
                  enabled: tracks.isNotEmpty,
                  onTap: () => context
                      .read<PlayerProvider>()
                      .playQueue(tracks, index: 0),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PlayButton extends StatelessWidget {
  final Color accent;
  final bool enabled;
  final VoidCallback onTap;

  const _PlayButton({
    required this.accent,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? onTap : null,
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: AppDimens.space20, vertical: AppDimens.space8),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(AppDimens.radiusPill),
            border: Border.all(color: accent.withValues(alpha: 0.5)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.play_arrow_rounded, color: accent, size: 22),
              const SizedBox(width: 6),
              Text(
                '播放全部',
                style: AppTypography.label.copyWith(
                  color: accent,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One local-playlist row: the shared [SongTile] with a source tag (网易/咪咕/酷狗)
/// and a ✕ remove button trailing. Selects only its own active state so switching
/// tracks rebuilds just the rows whose highlight flips (mirrors the playlist page).
class _LocalTrackRow extends StatelessWidget {
  final String playlistId;
  final Song song;
  final int index;
  final VoidCallback onTap;

  const _LocalTrackRow({
    required this.playlistId,
    required this.song,
    required this.index,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bool isActive = context.select<PlayerProvider, bool>(
      (PlayerProvider p) => p.currentSong?.id == song.id,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppDimens.space8),
      child: SongTile.fromSong(
        song,
        isActive: isActive,
        onTap: onTap,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _SourceTag(source: song.source),
            IconButton(
              tooltip: '移除',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close_rounded,
                  color: AppColors.onSurfaceFaint, size: 20),
              onPressed: () {
                context
                    .read<LocalPlaylistProvider>()
                    .removeSong(playlistId, song.id);
                ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(
                    const SnackBar(content: Text('已从歌单移除')),
                  );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Small muted chip naming the track's backend, so a mixed list reads clearly.
class _SourceTag extends StatelessWidget {
  final MusicSource source;

  const _SourceTag({required this.source});

  @override
  Widget build(BuildContext context) {
    final String label = _sourceLabel(source);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.surfaceGlass,
        borderRadius: BorderRadius.circular(AppDimens.radiusSm),
      ),
      child: Text(
        label,
        style: AppTypography.caption.copyWith(color: AppColors.onSurfaceMuted),
      ),
    );
  }
}

/// Asks how to import local music: returns `false` for 选择音乐文件 (multi-pick),
/// `true` for 扫描文件夹 (recursive folder scan), or null if cancelled. Shared by
/// the local-playlist detail page and the Library "导入本地音乐" entry.
Future<bool?> pickLocalImportMode(BuildContext context) {
  return showModalBottomSheet<bool>(
    context: context,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius:
          BorderRadius.vertical(top: Radius.circular(AppDimens.radiusLg)),
    ),
    builder: (BuildContext ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const SizedBox(height: AppDimens.space8),
          Text('导入本地音乐', style: AppTypography.titleM),
          ListTile(
            leading: const Icon(Icons.audiotrack_rounded,
                color: AppColors.onSurface),
            title: Text('选择音乐文件', style: AppTypography.body),
            subtitle:
                Text('从系统里挑选一首或多首', style: AppTypography.caption),
            onTap: () => Navigator.of(ctx).pop(false),
          ),
          ListTile(
            leading: const Icon(Icons.folder_open_rounded,
                color: AppColors.onSurface),
            title: Text('扫描文件夹', style: AppTypography.body),
            subtitle: Text('选一个文件夹，递归查找里面的音乐',
                style: AppTypography.caption),
            onTap: () => Navigator.of(ctx).pop(true),
          ),
          const SizedBox(height: AppDimens.space8),
        ],
      ),
    ),
  );
}

/// Short backend label (网易/QQ/酷狗/本地) for the source tag + the "来自…" line.
/// (The `migu` enum value is the reused source slot now filled by QQ Music.)
String _sourceLabel(MusicSource source) => switch (source) {
      MusicSource.netease => '网易',
      MusicSource.migu => 'QQ',
      MusicSource.kugou => '酷狗',
      MusicSource.kuwo => '酷我',
      MusicSource.local => '本地',
    };

class _EmptyTracks extends StatelessWidget {
  const _EmptyTracks();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(AppDimens.space32),
      child: Column(
        children: <Widget>[
          Icon(Icons.library_add_check_outlined,
              size: 48, color: AppColors.onSurfaceFaint),
          SizedBox(height: AppDimens.space12),
          Text('还没有歌曲', style: AppTypography.titleM),
          SizedBox(height: AppDimens.space8),
          Text(
            '在播放页「···」→「添加到本地歌单」，或从任意歌单「导入到本地歌单」',
            style: AppTypography.label,
            textAlign: TextAlign.center,
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
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(AppDimens.space32),
        child: Text('歌单不存在或已删除', style: AppTypography.label),
      ),
    );
  }
}

/// Rename dialog owning its own controller (disposed with the dialog).
class _RenameDialog extends StatefulWidget {
  final String initial;

  const _RenameDialog({required this.initial});

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);

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
      title: const Text('重命名歌单', style: AppTypography.titleM),
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
        TextButton(onPressed: _submit, child: const Text('保存')),
      ],
    );
  }
}
