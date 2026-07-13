import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../models/local_playlist.dart';
import '../../models/playlist.dart';
import '../../router/routes.dart';
import '../../state/library_provider.dart';
import '../../state/local_playlist_provider.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_dimens.dart';
import '../../theme/app_typography.dart';
import '../../widgets/entrance.dart';
import '../home/widgets/desktop_widgets.dart';
import '../settings/settings_dialog.dart';

/// Desktop **Library** (音乐库).
///
/// Two grids of hover-scale [MediaCard]s: the on-device cross-source **共同歌单**
/// ([LocalPlaylistProvider]) with a create / import-local header and inline
/// "＋新建" card, then the signed-in user's source-aware **我的歌单**
/// ([LibraryProvider] created + collected). Right-clicking a 共同歌单 card offers
/// rename / delete; an empty, logged-out 我的歌单 shows a login prompt routed to
/// settings. Loads the user playlists once on mount.
class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final LibraryProvider lib = context.read<LibraryProvider>();
      if (!lib.userPlaylistsLoading && lib.userPlaylists.isEmpty) {
        lib.loadUserPlaylists();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final List<LocalPlaylist> locals =
        context.select((LocalPlaylistProvider p) => p.playlists);
    final List<Playlist> created =
        context.select((LibraryProvider p) => p.createdPlaylists);
    final List<Playlist> collected =
        context.select((LibraryProvider p) => p.collectedPlaylists);
    final bool loadingUser =
        context.select((LibraryProvider p) => p.userPlaylistsLoading);

    return CustomScrollView(
      physics: const BouncingScrollPhysics(),
      slivers: <Widget>[
        SliverToBoxAdapter(child: _pageHeader()),

        // --- 共同歌单 -------------------------------------------------------
        _section(
          child: SectionHeader(title: '共同歌单'),
        ),
        _sliverWrap(<Widget>[
          _AddCard(
            label: '新建歌单',
            icon: Icons.add_rounded,
            onTap: _createPlaylist,
          ),
          _AddCard(
            label: '导入本地音乐',
            icon: Icons.folder_open_rounded,
            onTap: _importLocal,
          ),
          for (final LocalPlaylist p in locals)
            MediaCard(
              artUrl: p.coverUrl,
              title: p.name,
              subtitle: '${p.trackCount} 首'
                  '${p.isSyncable ? ' · 来自${sourceLabel(p.origin!.source)}' : ''}',
              onTap: () => context.push(Routes.localPlaylistPath(p.id)),
            ).withContext(
              context,
              onRename: () => _renamePlaylist(p),
              onDelete: () => _confirmDelete(p),
            ),
        ]),

        // --- 我的歌单 -------------------------------------------------------
        _section(
          child: SectionHeader(title: '我的歌单'),
        ),
        if (loadingUser && created.isEmpty && collected.isEmpty)
          _sliverWrap(<Widget>[
            for (int i = 0; i < 5; i++) const SkeletonCard(),
          ])
        else if (created.isEmpty && collected.isEmpty)
          SliverToBoxAdapter(
            child: SizedBox(
              height: 240,
              child: EmptyState(
                icon: Icons.login_rounded,
                title: '登录后同步你的歌单',
                message: '在设置中登录当前音源，即可看到你创建和收藏的歌单。',
                actionLabel: '去登录',
                onAction: () => showSettingsDialog(context),
              ),
            ),
          )
        else ...<Widget>[
          _sliverWrap(<Widget>[
            for (final Playlist p in created)
              MediaCard(
                artUrl: p.coverUrl,
                title: p.name,
                subtitle: '${p.trackCount} 首',
                onTap: () => context.push(Routes.playlistPath(p.id)),
              ),
          ]),
          if (collected.isNotEmpty) ...<Widget>[
            _section(child: SectionHeader(title: '收藏的歌单')),
            _sliverWrap(<Widget>[
              for (final Playlist p in collected)
                MediaCard(
                  artUrl: p.coverUrl,
                  title: p.name,
                  subtitle: p.creatorName ?? '${p.trackCount} 首',
                  onTap: () => context.push(Routes.playlistPath(p.id)),
                ),
            ]),
          ],
        ],
        const SliverToBoxAdapter(child: SizedBox(height: AppDimens.space48)),
      ],
    );
  }

  // --- layout helpers --------------------------------------------------------

  Widget _pageHeader() => Padding(
        padding: const EdgeInsets.fromLTRB(
          AppDimens.screenPadding,
          AppDimens.space32,
          AppDimens.screenPadding,
          AppDimens.space16,
        ),
        child: Text('音乐库', style: AppTypography.displayL),
      );

  Widget _section({required Widget child}) => SliverPadding(
        padding: const EdgeInsets.fromLTRB(
          AppDimens.screenPadding,
          AppDimens.space16,
          AppDimens.screenPadding,
          0,
        ),
        sliver: SliverToBoxAdapter(child: child),
      );

  Widget _sliverWrap(List<Widget> children) => SliverPadding(
        padding:
            const EdgeInsets.symmetric(horizontal: AppDimens.screenPadding),
        sliver: SliverToBoxAdapter(
          // 卡片网格「向下展开」逐个落位（统一入场，见 widgets/entrance.dart）。
          child: DownwardReveal(
            wrap: true,
            spacing: AppDimens.space16,
            runSpacing: AppDimens.space20,
            children: children,
          ),
        ),
      );

  // --- actions ---------------------------------------------------------------

  Future<void> _createPlaylist() async {
    final String? name = await _promptName('新建共同歌单', initial: '新建歌单');
    if (name == null || name.trim().isEmpty) return;
    if (!mounted) return;
    await context.read<LocalPlaylistProvider>().create(name.trim());
  }

  Future<void> _importLocal() async {
    final LocalPlaylistProvider local = context.read<LocalPlaylistProvider>();
    final LocalPlaylist? created =
        await local.createFromLocalFiles('本地音乐');
    if (!mounted || created == null) return;
    context.push(Routes.localPlaylistPath(created.id));
  }

  Future<void> _renamePlaylist(LocalPlaylist p) async {
    final String? name = await _promptName('重命名歌单', initial: p.name);
    if (name == null || name.trim().isEmpty) return;
    if (!mounted) return;
    await context.read<LocalPlaylistProvider>().rename(p.id, name.trim());
  }

  Future<void> _confirmDelete(LocalPlaylist p) async {
    final bool ok = await showDialog<bool>(
          context: context,
          builder: (BuildContext ctx) => AlertDialog(
            backgroundColor: AppColors.surface2,
            title: Text('删除「${p.name}」？', style: AppTypography.titleM),
            content: Text('该操作不可恢复。', style: AppTypography.label),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('删除',
                    style: TextStyle(color: Color(0xFFEF4444))),
              ),
            ],
          ),
        ) ??
        false;
    if (!ok || !mounted) return;
    await context.read<LocalPlaylistProvider>().delete(p.id);
  }

  Future<String?> _promptName(String title, {String initial = ''}) {
    final TextEditingController c = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: AppColors.surface2,
        title: Text(title, style: AppTypography.titleM),
        content: TextField(
          controller: c,
          autofocus: true,
          style: AppTypography.body,
          cursorColor: AppColors.accentPlay,
          decoration: const InputDecoration(hintText: '歌单名称'),
          onSubmitted: (String v) => Navigator.pop(ctx, v),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, c.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _AddCard — create/import affordance sized like a MediaCard
// ---------------------------------------------------------------------------

class _AddCard extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  const _AddCard({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    const double size = AppDimens.cardSize;
    return HoverBuilder(
      builder: (context, hovering) => GestureDetector(
        onTap: onTap,
        child: SizedBox(
          width: size,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                width: size,
                height: size,
                decoration: BoxDecoration(
                  color: hovering ? AppColors.hover : AppColors.glass,
                  borderRadius:
                      BorderRadius.circular(AppDimens.albumRadius(size)),
                  border: Border.all(
                    color: hovering
                        ? AppColors.onSurfaceMuted
                        : AppColors.glassBorder,
                    width: 1,
                  ),
                ),
                child: Icon(
                  icon,
                  size: 36,
                  color:
                      hovering ? Colors.white : AppColors.onSurfaceMuted,
                ),
              ),
              const SizedBox(height: AppDimens.space8),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.body
                    .copyWith(fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// right-click context wrapper for a local playlist card
// ---------------------------------------------------------------------------

extension _CardContext on MediaCard {
  Widget withContext(
    BuildContext context, {
    required VoidCallback onRename,
    required VoidCallback onDelete,
  }) {
    return GestureDetector(
      onSecondaryTapDown: (TapDownDetails d) async {
        final String? picked = await showTrackMenu<String>(
          context,
          d.globalPosition,
          const <PopupMenuEntry<String>>[
            PopupMenuItem<String>(value: 'rename', child: Text('重命名')),
            PopupMenuItem<String>(value: 'delete', child: Text('删除')),
          ],
        );
        if (picked == 'rename') onRename();
        if (picked == 'delete') onDelete();
      },
      child: this,
    );
  }
}
