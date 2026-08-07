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
import '../../widgets/playlist_search.dart';
import '../../widgets/song_tile.dart';

/// Detail for a LOCAL "共同歌单" — a cross-source, on-device playlist. Its tracks
/// may each come from a different backend (网易 / 咪咕 / 酷狗); the router plays and
/// lyrics them per-song, so a mixed list plays end to end. Tracks are removed here
/// (long-press or the trailing ✕); they're added from the player's ··· menu or by
/// importing a source playlist ("导入到本地歌单").
/// Thin stateless shell: selects the single playlist (copy-on-write, so this
/// rebuilds only when THIS list mutates) and hands it to the stateful view,
/// which owns the search/scroll UI state so those survive list mutations.
class LocalPlaylistPage extends StatelessWidget {
  final String playlistId;

  const LocalPlaylistPage({required this.playlistId, super.key});

  @override
  Widget build(BuildContext context) {
    final LocalPlaylist? pl =
        context.select<LocalPlaylistProvider, LocalPlaylist?>(
      (LocalPlaylistProvider p) => p.byId(playlistId),
    );
    return _LocalPlaylistView(playlistId: playlistId, playlist: pl);
  }
}

/// Owns the in-page UI state (search box, scroll controller) so that a list
/// mutation from the provider — which hands down a fresh [playlist] instance —
/// doesn't reset the user's open search / scroll offset.
class _LocalPlaylistView extends StatefulWidget {
  final String playlistId;
  final LocalPlaylist? playlist;

  const _LocalPlaylistView({required this.playlistId, required this.playlist});

  @override
  State<_LocalPlaylistView> createState() => _LocalPlaylistViewState();
}

class _LocalPlaylistViewState extends State<_LocalPlaylistView> {
  final ScrollController _scroll = ScrollController();
  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  /// Measures the (variable-height) header sliver so locate can offset past it —
  /// there's no fixed-height SliverAppBar here.
  final GlobalKey _headerKey = GlobalKey();
  double _headerExtent = 176; // sensible default until first measured

  bool _searching = false;
  String _query = '';

  @override
  void dispose() {
    _scroll.dispose();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _enterSearch() {
    setState(() => _searching = true);
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _searchFocus.requestFocus());
  }

  void _exitSearch() {
    _searchCtrl.clear();
    setState(() {
      _searching = false;
      _query = '';
    });
  }

  void _cacheHeaderExtent() {
    final Size? s = _headerKey.currentContext?.size;
    if (s != null && s.height > 0) _headerExtent = s.height;
  }

  void _toast(String m) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(m)));

  /// Scrolls to the currently-playing track. Reads [PlayerProvider] via `read`
  /// (on tap only) so the view never rebuilds on a track switch. If a filter is
  /// active it exits search first so the full list is laid out (real
  /// maxScrollExtent), then animates on the next frame.
  void _locate() {
    final List<Song> tracks = widget.playlist?.tracks ?? const <Song>[];
    final Object? currentId = context.read<PlayerProvider>().currentSong?.id;
    if (currentId == null) {
      _toast('还没有正在播放的歌曲');
      return;
    }
    final int i = tracks.indexWhere((Song s) => s.id == currentId);
    if (i < 0) {
      _toast('正在播放的歌曲不在此歌单');
      return;
    }
    if (_searching) _exitSearch();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _cacheHeaderExtent();
      final double target = (_headerExtent +
              i * kPlaylistRowExtent -
              AppDimens.space16)
          .clamp(0.0, _scroll.position.maxScrollExtent);
      _scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeInOutCubic,
      );
    });
  }

  Future<void> _importLocal(LocalPlaylist pl) async {
    final bool? scanDir = await pickLocalImportMode(context);
    if (scanDir == null || !mounted) return;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final LocalPlaylistProvider prov = context.read<LocalPlaylistProvider>();
    final int n = await prov.importLocalFiles(pl.id, scanDir: scanDir);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(n > 0 ? '已导入 $n 首本地音乐' : '未导入（已取消或都已存在）'),
      ));
  }

  Future<void> _rename(LocalPlaylist pl) async {
    final String? name = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => _RenameDialog(initial: pl.name),
    );
    if (name == null || name.isEmpty || !mounted) return;
    context.read<LocalPlaylistProvider>().rename(pl.id, name);
  }

  @override
  Widget build(BuildContext context) {
    final LocalPlaylist? pl = widget.playlist;
    // Refresh the cached header extent while it's on screen.
    WidgetsBinding.instance.addPostFrameCallback((_) => _cacheHeaderExtent());
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: _appBar(pl),
      body: pl == null ? const _Missing() : _body(pl),
    );
  }

  PreferredSizeWidget _appBar(LocalPlaylist? pl) {
    return AppBar(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      leading: IconButton(
        tooltip: 'Back',
        icon: const Icon(Icons.arrow_back_ios_new_rounded,
            color: AppColors.onSurface, size: 20),
        onPressed: () {
          if (_searching) {
            _exitSearch();
          } else if (context.canPop()) {
            context.pop();
          }
        },
      ),
      title: _searching
          ? TextField(
              controller: _searchCtrl,
              focusNode: _searchFocus,
              autofocus: true,
              textInputAction: TextInputAction.search,
              style: AppTypography.body,
              cursorColor: AppColors.onSurface,
              decoration: InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                hintText: '在歌单内搜索',
                hintStyle: AppTypography.label,
              ),
              onChanged: (String v) => setState(() => _query = v),
            )
          : Text(pl?.name ?? '歌单', style: AppTypography.titleM),
      actions: _searching
          ? <Widget>[
              IconButton(
                tooltip: '关闭搜索',
                icon: const Icon(Icons.close_rounded,
                    color: AppColors.onSurface, size: 22),
                onPressed: _exitSearch,
              ),
            ]
          : <Widget>[
              if (pl != null)
                IconButton(
                  tooltip: '定位到正在播放',
                  icon: const Icon(Icons.my_location_rounded,
                      color: AppColors.onSurfaceMuted, size: 22),
                  onPressed: _locate,
                ),
              if (pl != null)
                IconButton(
                  tooltip: '搜索歌单内歌曲',
                  icon: const Icon(Icons.search_rounded,
                      color: AppColors.onSurfaceMuted, size: 22),
                  onPressed: _enterSearch,
                ),
              // Re-sync against the source playlist — only imported (forked) lists.
              if (pl != null && pl.isSyncable) _SyncButton(playlist: pl),
              if (pl != null)
                PopupMenuButton<String>(
                  tooltip: '更多',
                  color: AppColors.surface,
                  icon: const Icon(Icons.more_vert_rounded,
                      color: AppColors.onSurfaceMuted, size: 22),
                  onSelected: (String v) {
                    if (v == 'import') _importLocal(pl);
                    if (v == 'rename') _rename(pl);
                  },
                  itemBuilder: (BuildContext ctx) => <PopupMenuEntry<String>>[
                    const PopupMenuItem<String>(
                      value: 'import',
                      child: Text('导入本地音乐'),
                    ),
                    const PopupMenuItem<String>(
                      value: 'rename',
                      child: Text('重命名'),
                    ),
                  ],
                ),
            ],
    );
  }

  Widget _body(LocalPlaylist pl) {
    final List<Song> all = pl.tracks;
    final String q = _query.trim();
    final List<int> visible = q.isEmpty
        ? List<int>.generate(all.length, (int i) => i)
        : <int>[
            for (int i = 0; i < all.length; i++)
              if (songMatchesQuery(all[i], q)) i,
          ];
    return CustomScrollView(
      controller: _scroll,
      slivers: <Widget>[
        SliverToBoxAdapter(
          child: KeyedSubtree(key: _headerKey, child: _Header(playlist: pl)),
        ),
        if (all.isEmpty)
          const SliverToBoxAdapter(child: _EmptyTracks())
        else if (visible.isEmpty)
          const SliverToBoxAdapter(child: _NoMatches())
        else
          SliverFixedExtentList(
            itemExtent: kPlaylistRowExtent,
            delegate: SliverChildBuilderDelegate(
              (BuildContext context, int index) {
                final int orig = visible[index];
                final Song song = all[orig];
                return _LocalTrackRow(
                  key: ValueKey<int>(song.id),
                  playlistId: pl.id,
                  song: song,
                  index: orig,
                  onTap: () => context
                      .read<PlayerProvider>()
                      .playQueue(all, index: orig),
                );
              },
              childCount: visible.length,
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: AppDimens.space32)),
      ],
    );
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
    super.key,
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
      MusicSource.qqcn => 'QQ',
      MusicSource.kugou => '酷狗',
      MusicSource.kugougn => '酷狗概念版',
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

/// Shown when an active in-playlist search matches nothing.
class _NoMatches extends StatelessWidget {
  const _NoMatches();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(AppDimens.space32),
      child: Column(
        children: <Widget>[
          Icon(Icons.search_off_rounded,
              size: 48, color: AppColors.onSurfaceFaint),
          SizedBox(height: AppDimens.space12),
          Text('没有匹配的歌曲', style: AppTypography.label),
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
