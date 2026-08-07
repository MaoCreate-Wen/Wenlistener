import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../models/local_playlist.dart';
import '../../models/playlist.dart';
import '../../models/song.dart';
import '../../router/routes.dart';
import '../../state/auth_provider.dart';
import '../../state/kugou_auth_provider.dart';
import '../../state/kugougn_auth_provider.dart';
import '../../state/library_provider.dart';
import '../../state/local_playlist_provider.dart';
import '../../state/player_provider.dart';
import '../../state/qqcn_auth_provider.dart';
import '../../state/settings_provider.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_dimens.dart';
import '../../theme/app_typography.dart';
import '../../widgets/app_scaffold.dart';
import '../../widgets/artwork_image.dart';
import '../../widgets/glass_container.dart';
import '../../widgets/skeleton_box.dart';
import '../local_playlist/local_playlist_page.dart' show pickLocalImportMode;

/// Library tab: the login entry (reflecting [AuthProvider.isLoggedIn]) plus a
/// lean "your music" section. Logged out shows a scan-to-log-in CTA that pushes
/// the QR login route; logged in shows the account row, a sign-out action and a
/// "我的歌单" list of the user's own playlists (fetched once per sign-in).
class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  // Guards the one-shot user-playlist fetch per sign-in. Reset on logout so a
  // later sign-in re-fetches; deliberately NOT keyed off emptiness (a user with
  // zero playlists would otherwise re-fetch forever).
  bool _requestedPlaylists = false;

  void _maybeLoadUserPlaylists(bool isLoggedIn) {
    if (!isLoggedIn) {
      _requestedPlaylists = false;
      return;
    }
    if (_requestedPlaylists) return;
    _requestedPlaylists = true;
    // Defer: loadUserPlaylists() calls notifyListeners synchronously and we are
    // inside build, so schedule it after this frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<LibraryProvider>().loadUserPlaylists();
    });
  }

  /// Prompts for a name, then creates a new playlist via [LibraryProvider].
  /// Surfaces success/failure through a SnackBar. The dialog is a dedicated
  /// [_CreatePlaylistDialog] so its TextEditingController is owned and disposed
  /// by that widget's own lifecycle — disposing it synchronously after
  /// `showDialog` returned crashed the still-animating TextField ("used after
  /// being disposed").
  Future<void> _promptCreatePlaylist() async {
    final String? name = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => const _CreatePlaylistDialog(),
    );
    if (name == null || name.isEmpty || !mounted) return;
    final LibraryProvider library = context.read<LibraryProvider>();
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      await library.createUserPlaylist(name);
      messenger.showSnackBar(SnackBar(content: Text('已创建「$name」')));
    } catch (e) {
      debugPrint('createUserPlaylist failed: $e');
      messenger.showSnackBar(const SnackBar(content: Text('创建失败，请重试')));
    }
  }

  /// Creates a LOCAL "共同歌单" (cross-source, on-device — no login needed). Reuses
  /// the same name dialog as the Netease create flow.
  Future<void> _promptCreateLocalPlaylist() async {
    final String? name = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => const _CreatePlaylistDialog(),
    );
    if (name == null || name.isEmpty || !mounted) return;
    final LocalPlaylist pl =
        await context.read<LocalPlaylistProvider>().create(name);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('已创建「${pl.name}」')));
  }

  /// "导入本地音乐": pick/scan on-device audio files into a NEW local "共同歌单"
  /// (login-independent, cross-source — local files sit next to any 网易/酷狗
  /// tracks the user later adds).
  Future<void> _promptImportLocalMusic() async {
    final bool? scanDir = await pickLocalImportMode(context);
    if (scanDir == null || !mounted) return;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final LocalPlaylistProvider prov = context.read<LocalPlaylistProvider>();
    final LocalPlaylist? pl =
        await prov.createFromLocalFiles('本地音乐', scanDir: scanDir);
    if (!mounted) return;
    messenger.showSnackBar(SnackBar(
      content: Text(pl != null
          ? '已导入 ${pl.trackCount} 首到「${pl.name}」'
          : '未选择音乐文件'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final MusicSource source =
        context.select<SettingsProvider, MusicSource>((s) => s.source);
    // Account is shown for the CURRENT source. Netease's provider is always in the
    // tree; QQ/Kugou are read only when their source is active (so the widget test,
    // which runs on the Netease source without those providers, never reads them).
    final _AccountView acc = _accountFor(context, source);
    final bool isLoggedIn = acc.isLoggedIn;
    _maybeLoadUserPlaylists(isLoggedIn);
    final Color accent = context.select<PlayerProvider, Color>(
      (PlayerProvider p) => p.dynamicAccent,
    );

    return AppScaffold(
      body: SafeArea(
        bottom: false,
        child: CustomScrollView(
          slivers: <Widget>[
            SliverList(
              delegate: SliverChildListDelegate(<Widget>[
                const SizedBox(height: AppDimens.space8),
                Row(
                  children: <Widget>[
                    const Text('Library', style: AppTypography.displayM),
                    const Spacer(),
                    IconButton(
                      tooltip: '设置',
                      icon: const Icon(Icons.settings_outlined,
                          color: AppColors.onSurfaceMuted, size: 24),
                      onPressed: () => context.push(Routes.settings),
                    ),
                  ],
                ),
                const SizedBox(height: AppDimens.space20),
                if (isLoggedIn)
                  _AccountCard(
                    accent: accent,
                    avatarUrl: acc.avatarUrl,
                    nickname: acc.nickname,
                    fallbackName: acc.fallbackName,
                    subtitle: acc.subtitle,
                    isVip: acc.isVip,
                    onTap: () => context.push(Routes.accounts),
                    onSignOut: acc.onSignOut,
                  )
                else
                  _LoginCard(
                    accent: accent,
                    title: acc.loginTitle,
                    subtitle: acc.loginSubtitle,
                    onTap: () => context.push(acc.loginRoute),
                  ),
                const SizedBox(height: AppDimens.space24),
                const Text('Your music', style: AppTypography.label),
                const SizedBox(height: AppDimens.space8),
                _LibraryEntry(
                  icon: Icons.favorite_rounded,
                  accent: accent,
                  title: 'Liked Songs',
                  subtitle: isLoggedIn
                      ? 'Songs you like appear here'
                      : 'Sign in to sync your likes',
                ),
                _LibraryEntry(
                  icon: Icons.history_rounded,
                  accent: accent,
                  title: 'Recently Played',
                  subtitle: 'Tracks you played recently',
                ),
                const SizedBox(height: AppDimens.space24),
                Row(
                  children: <Widget>[
                    const Text('共同歌单', style: AppTypography.label),
                    const Spacer(),
                    IconButton(
                      tooltip: '导入本地音乐',
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: AppDimens.minTouch,
                        minHeight: AppDimens.minTouch,
                      ),
                      icon: Icon(Icons.library_music_outlined, color: accent),
                      onPressed: _promptImportLocalMusic,
                    ),
                    const SizedBox(width: AppDimens.space8),
                    IconButton(
                      tooltip: '新建共同歌单',
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: AppDimens.minTouch,
                        minHeight: AppDimens.minTouch,
                      ),
                      icon: Icon(Icons.add_rounded, color: accent),
                      onPressed: _promptCreateLocalPlaylist,
                    ),
                  ],
                ),
                Text(
                  '把网易 / QQ / 酷狗的歌整合进一个本地歌单，或导入本地音乐文件',
                  style: AppTypography.caption,
                ),
                const SizedBox(height: AppDimens.space8),
                if (isLoggedIn) ...<Widget>[
                  const SizedBox(height: AppDimens.space24),
                  Row(
                    children: <Widget>[
                      const Text('创建的歌单', style: AppTypography.label),
                      const Spacer(),
                      IconButton(
                        tooltip: '新建歌单',
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: AppDimens.minTouch,
                          minHeight: AppDimens.minTouch,
                        ),
                        icon: Icon(Icons.add_rounded, color: accent),
                        onPressed: _promptCreatePlaylist,
                      ),
                    ],
                  ),
                  const SizedBox(height: AppDimens.space8),
                ],
              ]),
            ),
            _localPlaylistsSliver(),
            if (isLoggedIn) _createdPlaylistsSliver(),
            if (isLoggedIn) _collectedPlaylistsSliver(),
            const SliverToBoxAdapter(
              child: SizedBox(height: AppDimens.space32),
            ),
          ],
        ),
      ),
    );
  }

  /// Resolves the CURRENT source's login/account into a view-model. Reads the
  /// source's auth provider (Netease via `select` — always present; QQ/Kugou via
  /// `watch`, only when that source is active — so the widget test, which lacks
  /// those providers, never touches them). Local has no account.
  _AccountView _accountFor(BuildContext context, MusicSource source) {
    switch (source) {
      case MusicSource.migu: // dormant web-QQ slot (not user-selectable)
      case MusicSource.qqcn: // QQ 音乐 (Android) — the real selectable QQ source
        final QqcnAuthProvider qq =
            context.watch<QqcnAuthProvider>();
        return _AccountView(
          isLoggedIn: qq.isLoggedIn,
          avatarUrl: qq.account?.avatarUrl,
          nickname: qq.account?.nickname,
          isVip: false,
          fallbackName: 'QQ音乐用户',
          subtitle: '账号管理',
          loginTitle: '登录 QQ音乐',
          loginSubtitle: 'QQ / 微信 扫码登录',
          loginRoute: Routes.qqLogin,
          onSignOut: () => context.read<QqcnAuthProvider>().logout(),
        );
      case MusicSource.kugou:
        final KugouAuthProvider kg = context.watch<KugouAuthProvider>();
        return _AccountView(
          isLoggedIn: kg.isLoggedIn,
          avatarUrl: kg.active?.avatarUrl,
          nickname: kg.active?.nickname,
          isVip: kg.active?.isVip ?? false,
          fallbackName: '酷狗用户',
          subtitle: '账号管理',
          loginTitle: '登录酷狗',
          loginSubtitle: '扫码登录酷狗账号',
          loginRoute: Routes.kugouLogin,
          onSignOut: () {
            final String? id = kg.activeUserId;
            if (id != null) {
              context.read<KugouAuthProvider>().removeAccount(id);
            }
          },
        );
      case MusicSource.kugougn:
        // 概念版 is a separate source with its own SMS login (in settings).
        final KugougnAuthProvider gn = context.watch<KugougnAuthProvider>();
        return _AccountView(
          isLoggedIn: gn.isLoggedIn,
          avatarUrl: gn.active?.avatarUrl,
          nickname: gn.active?.nickname,
          isVip: gn.active?.isVip ?? false,
          fallbackName: '概念版用户',
          subtitle: '账号',
          loginTitle: '登录酷狗概念版',
          loginSubtitle: '手机号验证码登录',
          loginRoute: Routes.settings,
          onSignOut: () => context.read<KugougnAuthProvider>().logout(),
        );
      case MusicSource.kuwo:
        // Kuwo has no multi-account state yet — show anonymous/hint.
        return _AccountView(
          isLoggedIn: false,
          avatarUrl: null,
          nickname: null,
          isVip: false,
          fallbackName: '酷我音乐',
          subtitle: '匿名模式',
          loginTitle: '酷我音乐',
          loginSubtitle: '登录功能即将上线',
          loginRoute: Routes.settings,
          onSignOut: () {},
        );
      case MusicSource.local:
        return _AccountView(
          isLoggedIn: false,
          avatarUrl: null,
          nickname: null,
          isVip: false,
          fallbackName: '本地音乐',
          subtitle: '',
          loginTitle: '本地音乐',
          loginSubtitle: '本地音乐无需登录',
          loginRoute: Routes.settings,
          onSignOut: () {},
        );
      case MusicSource.netease:
        return _AccountView(
          isLoggedIn: context
              .select<AuthProvider, bool>((AuthProvider a) => a.isLoggedIn),
          avatarUrl: context.select<AuthProvider, String?>(
              (AuthProvider a) => a.account?.avatarUrl),
          nickname: context.select<AuthProvider, String?>(
              (AuthProvider a) => a.account?.nickname),
          isVip: context.select<AuthProvider, int>(
                  (AuthProvider a) => a.account?.vipType ?? 0) >
              0,
          fallbackName: '网易云用户',
          subtitle: '账号管理',
          loginTitle: '登录网易云',
          loginSubtitle: '用网易云音乐 App 扫码登录',
          loginRoute: Routes.login,
          onSignOut: () => context.read<AuthProvider>().logout(),
        );
    }
  }

  /// The "创建的歌单" body: virtualized list of the user's OWN playlists. The
  /// loading skeleton / "暂无歌单" empty hint keys off the COMBINED [userPlaylists]
  /// (shown once here, never under 收藏的歌单) — when logged in and loaded there is
  /// always at least 我喜欢的音乐, so a non-empty combined list implies a non-empty
  /// created list.
  Widget _createdPlaylistsSliver() {
    final bool empty = context.select<LibraryProvider, bool>(
      (LibraryProvider l) => l.userPlaylists.isEmpty,
    );
    if (empty) {
      final bool loading = context.select<LibraryProvider, bool>(
        (LibraryProvider l) => l.userPlaylistsLoading,
      );
      return SliverToBoxAdapter(
        child:
            loading ? const _PlaylistListSkeleton() : const _EmptyPlaylists(),
      );
    }
    final List<Playlist> playlists =
        context.select<LibraryProvider, List<Playlist>>(
      (LibraryProvider l) => l.createdPlaylists,
    );
    return SliverList.builder(
      itemCount: playlists.length,
      itemBuilder: (BuildContext context, int index) =>
          _PlaylistRow(playlist: playlists[index]),
    );
  }

  /// The "共同歌单" body: the user's local cross-source playlists (always shown —
  /// they're login-independent). Selecting only [LocalPlaylistProvider.playlists]
  /// keeps this off unrelated notifies.
  Widget _localPlaylistsSliver() {
    final List<LocalPlaylist> playlists =
        context.select<LocalPlaylistProvider, List<LocalPlaylist>>(
      (LocalPlaylistProvider p) => p.playlists,
    );
    if (playlists.isEmpty) {
      return const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: AppDimens.space8),
          child: Text('还没有共同歌单，点 + 新建', style: AppTypography.label),
        ),
      );
    }
    return SliverList.builder(
      itemCount: playlists.length,
      itemBuilder: (BuildContext context, int index) =>
          _LocalPlaylistRow(playlist: playlists[index]),
    );
  }

  /// The "收藏的歌单" section: its own header + virtualized list of subscribed
  /// playlists. Rendered ONLY when there are collected playlists — otherwise it
  /// vanishes entirely (no header, no "+" button: you can't create into it).
  Widget _collectedPlaylistsSliver() {
    final List<Playlist> playlists =
        context.select<LibraryProvider, List<Playlist>>(
      (LibraryProvider l) => l.collectedPlaylists,
    );
    if (playlists.isEmpty) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    return SliverMainAxisGroup(
      slivers: <Widget>[
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.only(
              top: AppDimens.space24,
              bottom: AppDimens.space8,
            ),
            child: Text('收藏的歌单', style: AppTypography.label),
          ),
        ),
        SliverList.builder(
          itemCount: playlists.length,
          itemBuilder: (BuildContext context, int index) =>
              _PlaylistRow(playlist: playlists[index]),
        ),
      ],
    );
  }
}

/// Create-playlist dialog. A [StatefulWidget] so it OWNS its
/// [TextEditingController] and disposes it in [dispose] — only once the dialog
/// (and its [TextField]) is unmounted, never mid pop-animation. Disposing the
/// controller right after `showDialog` returned crashed the still-animating
/// TextField ("A TextEditingController was used after being disposed").
class _CreatePlaylistDialog extends StatefulWidget {
  const _CreatePlaylistDialog();

  @override
  State<_CreatePlaylistDialog> createState() => _CreatePlaylistDialogState();
}

class _CreatePlaylistDialogState extends State<_CreatePlaylistDialog> {
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
      title: const Text('新建歌单', style: AppTypography.titleM),
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
        TextButton(
          onPressed: _submit,
          child: const Text('创建'),
        ),
      ],
    );
  }
}

/// Logged-out CTA: tap to open the QR login page.
class _LoginCard extends StatelessWidget {
  final Color accent;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _LoginCard({
    required this.accent,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: GlassContainer(
        padding: const EdgeInsets.all(AppDimens.space16),
        child: Row(
          children: <Widget>[
            _IconChip(icon: Icons.qr_code_2_rounded, color: accent),
            const SizedBox(width: AppDimens.space16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(title, style: AppTypography.titleM),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: AppTypography.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const Icon(
              Icons.chevron_right_rounded,
              color: AppColors.onSurfaceFaint,
            ),
          ],
        ),
      ),
    );
  }
}

/// Source-agnostic view of the current source's account, computed in
/// [_LibraryPageState._accountFor] from whichever auth provider owns the source.
class _AccountView {
  final bool isLoggedIn;
  final String? avatarUrl;
  final String? nickname;
  final bool isVip;
  final String fallbackName;
  final String subtitle;
  final String loginTitle;
  final String loginSubtitle;
  final String loginRoute;
  final VoidCallback onSignOut;

  const _AccountView({
    required this.isLoggedIn,
    required this.avatarUrl,
    required this.nickname,
    required this.isVip,
    required this.fallbackName,
    required this.subtitle,
    required this.loginTitle,
    required this.loginSubtitle,
    required this.loginRoute,
    required this.onSignOut,
  });
}

/// Logged-in account row for the CURRENT source (网易/QQ/酷狗): the active
/// account's avatar, nickname and an optional VIP badge. The fields are computed
/// source-aware in [LibraryPage.build] and passed in (this widget is
/// source-agnostic). Tapping opens the account manager; the trailing button
/// signs out of the current source.
class _AccountCard extends StatelessWidget {
  final Color accent;
  final String? avatarUrl;
  final String? nickname;
  final String fallbackName;
  final String subtitle;
  final bool isVip;
  final VoidCallback onTap;
  final VoidCallback onSignOut;

  const _AccountCard({
    required this.accent,
    required this.avatarUrl,
    required this.nickname,
    required this.fallbackName,
    required this.subtitle,
    required this.isVip,
    required this.onTap,
    required this.onSignOut,
  });

  @override
  Widget build(BuildContext context) {
    final String name = nickname ?? '';
    final bool hasName = name.isNotEmpty;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: GlassContainer(
        padding: const EdgeInsets.all(AppDimens.space16),
        child: Row(
          children: <Widget>[
            _Avatar(url: avatarUrl, size: 48),
            const SizedBox(width: AppDimens.space16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Flexible(
                        child: Text(
                          hasName ? name : fallbackName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTypography.titleM,
                        ),
                      ),
                      if (isVip) ...<Widget>[
                        const SizedBox(width: AppDimens.space8),
                        _VipBadge(color: accent),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: AppTypography.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: onSignOut,
              style: TextButton.styleFrom(
                foregroundColor: AppColors.onSurface,
                minimumSize: const Size(AppDimens.minTouch, AppDimens.minTouch),
              ),
              child: const Text('退出'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Circular account avatar: the cached network image (via [ArtworkImage], which
/// already carries the Netease image headers) when a URL is present, else a
/// person glyph so a still-loading / avatar-less account doesn't fall back to
/// the music-note cover placeholder.
class _Avatar extends StatelessWidget {
  final String? url;
  final double size;

  const _Avatar({required this.url, required this.size});

  @override
  Widget build(BuildContext context) {
    final String? u = url;
    if (u != null && u.isNotEmpty) {
      return ArtworkImage(url: u, size: size, radius: size / 2);
    }
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        color: AppColors.surfaceGlass,
        shape: BoxShape.circle,
      ),
      child: Icon(
        Icons.person_rounded,
        color: AppColors.onSurfaceFaint,
        size: size * 0.56,
      ),
    );
  }
}

/// Small accent-tinted "VIP" pill, shown when the account holds any paid
/// membership (vipType > 0).
class _VipBadge extends StatelessWidget {
  final Color color;

  const _VipBadge({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppDimens.space8, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(AppDimens.radiusPill),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        'VIP',
        style: AppTypography.caption.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

/// A row in the "我的歌单" list: cover, name, "creator · N首 · play-count" and a
/// chevron. Tapping pushes the playlist detail route.
class _PlaylistRow extends StatelessWidget {
  final Playlist playlist;

  const _PlaylistRow({required this.playlist});

  /// Long-press action sheet: a subscribed playlist offers 取消收藏; an owned one
  /// offers 删除歌单 (with a confirm step). Errors surface via a SnackBar.
  Future<void> _onLongPress(BuildContext context) async {
    final bool subscribed = playlist.subscribed;
    final _PlaylistAction? action = await showModalBottomSheet<_PlaylistAction>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(AppDimens.radiusLg)),
      ),
      builder: (BuildContext sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: Icon(
                subscribed
                    ? Icons.bookmark_remove_rounded
                    : Icons.delete_outline_rounded,
                color: AppColors.onSurface,
              ),
              title: Text(
                subscribed ? '取消收藏' : '删除歌单',
                style: AppTypography.body,
              ),
              onTap: () => Navigator.of(sheetCtx).pop(
                subscribed ? _PlaylistAction.unsubscribe : _PlaylistAction.delete,
              ),
            ),
            ListTile(
              leading: const Icon(
                Icons.close_rounded,
                color: AppColors.onSurfaceFaint,
              ),
              title: const Text('取消', style: AppTypography.body),
              onTap: () => Navigator.of(sheetCtx).pop(),
            ),
          ],
        ),
      ),
    );
    if (action == null || !context.mounted) return;
    if (action == _PlaylistAction.delete) {
      final bool ok = await _confirmDelete(context);
      if (!ok || !context.mounted) return;
    }
    final LibraryProvider library = context.read<LibraryProvider>();
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      if (action == _PlaylistAction.unsubscribe) {
        await library.collectPlaylist(playlist.id, false);
        messenger.showSnackBar(const SnackBar(content: Text('已取消收藏')));
      } else {
        await library.deleteUserPlaylist(playlist.id);
        messenger.showSnackBar(const SnackBar(content: Text('已删除歌单')));
      }
    } catch (e) {
      debugPrint('playlist action failed: $e');
      messenger.showSnackBar(const SnackBar(content: Text('操作失败，请重试')));
    }
  }

  Future<bool> _confirmDelete(BuildContext context) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('删除歌单', style: AppTypography.titleM),
        content: Text('确定删除「${playlist.name}」吗？', style: AppTypography.body),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppDimens.space8),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => context.push(Routes.playlistPath(playlist.id)),
        onLongPress: () => _onLongPress(context),
        child: Row(
          children: <Widget>[
            ArtworkImage(
              url: playlist.coverUrl,
              size: AppDimens.tileArtwork,
              radius: AppDimens.radiusSm,
            ),
            const SizedBox(width: AppDimens.space12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    playlist.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.body
                        .copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _playlistSubtitle(playlist),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.label,
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppDimens.space8),
            const Icon(
              Icons.chevron_right_rounded,
              color: AppColors.onSurfaceFaint,
            ),
          ],
        ),
      ),
    );
  }
}

/// Three placeholder rows shown while the user's playlists load.
class _PlaylistListSkeleton extends StatelessWidget {
  const _PlaylistListSkeleton();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: List<Widget>.generate(
        3,
        (_) => const Padding(
          padding: EdgeInsets.symmetric(vertical: AppDimens.space8),
          child: Row(
            children: <Widget>[
              SkeletonBox(
                width: AppDimens.tileArtwork,
                height: AppDimens.tileArtwork,
                radius: AppDimens.radiusSm,
              ),
              SizedBox(width: AppDimens.space12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    SkeletonBox(width: 150, height: 14, radius: AppDimens.radiusSm),
                    SizedBox(height: AppDimens.space8),
                    SkeletonBox(width: 90, height: 12, radius: AppDimens.radiusSm),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Friendly hint when the signed-in user has no playlists.
class _EmptyPlaylists extends StatelessWidget {
  const _EmptyPlaylists();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: AppDimens.space8),
      child: Text('暂无歌单', style: AppTypography.label),
    );
  }
}

/// Informational library row (no navigation target yet — surfaced as status).
class _LibraryEntry extends StatelessWidget {
  final IconData icon;
  final Color accent;
  final String title;
  final String subtitle;

  const _LibraryEntry({
    required this.icon,
    required this.accent,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppDimens.space8),
      child: Row(
        children: <Widget>[
          _IconChip(icon: icon, color: accent),
          const SizedBox(width: AppDimens.space16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(title, style: AppTypography.body.copyWith(
                  fontWeight: FontWeight.w600,
                )),
                const SizedBox(height: 2),
                Text(
                  subtitle,
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

/// Rounded translucent square holding a tinted icon.
class _IconChip extends StatelessWidget {
  final IconData icon;
  final Color color;

  const _IconChip({required this.icon, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(AppDimens.radiusMd),
      ),
      child: Icon(icon, color: color, size: 24),
    );
  }
}

/// "Creator · N首 · 1.2万次播放" — omits creator/play-count when absent.
String _playlistSubtitle(Playlist playlist) {
  final List<String> parts = <String>[];
  final String? creator = playlist.creatorName?.trim();
  if (creator != null && creator.isNotEmpty) parts.add(creator);
  parts.add('${playlist.trackCount}首');
  if (playlist.playCount > 0) {
    parts.add('${_compactCount(playlist.playCount)}次播放');
  }
  return parts.join('  ·  ');
}

/// Compact CN count: 1234 → "1234", 12345 → "1.2万", 1.2e8 → "1.2亿".
String _compactCount(int n) {
  if (n >= 100000000) return '${_oneDecimal(n / 100000000)}亿';
  if (n >= 10000) return '${_oneDecimal(n / 10000)}万';
  return '$n';
}

String _oneDecimal(double v) {
  final String s = v.toStringAsFixed(1);
  return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
}

/// A row in the "共同歌单" list: cover (first track), name, "N首 · 本地" and a
/// chevron. Tap opens the local detail route; long-press deletes (with confirm).
class _LocalPlaylistRow extends StatelessWidget {
  final LocalPlaylist playlist;

  const _LocalPlaylistRow({required this.playlist});

  Future<void> _confirmDelete(BuildContext context) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('删除歌单', style: AppTypography.titleM),
        content: Text('确定删除「${playlist.name}」吗？', style: AppTypography.body),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    await context.read<LocalPlaylistProvider>().delete(playlist.id);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('已删除歌单')));
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppDimens.space8),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => context.push(Routes.localPlaylistPath(playlist.id)),
        onLongPress: () => _confirmDelete(context),
        child: Row(
          children: <Widget>[
            ArtworkImage(
              url: playlist.coverUrl,
              size: AppDimens.tileArtwork,
              radius: AppDimens.radiusSm,
            ),
            const SizedBox(width: AppDimens.space12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    playlist.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.body
                        .copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${playlist.trackCount}首  ·  本地',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.label,
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppDimens.space8),
            const Icon(
              Icons.chevron_right_rounded,
              color: AppColors.onSurfaceFaint,
            ),
          ],
        ),
      ),
    );
  }
}

/// Long-press action chosen for a `_PlaylistRow`.
enum _PlaylistAction { unsubscribe, delete }
