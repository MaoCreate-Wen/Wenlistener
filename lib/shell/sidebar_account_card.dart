import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/song.dart';
import '../pages/accounts/accounts_dialog.dart';
import '../state/auth_provider.dart';
import '../state/kugou_auth_provider.dart';
import '../state/kuwo_auth_provider.dart';
import '../state/qq_auth_provider.dart';
import '../state/settings_provider.dart';
import '../theme/app_colors.dart';
import '../theme/app_dimens.dart';
import '../theme/app_typography.dart';
import '../widgets/artwork_image.dart';
import '../widgets/source_badge.dart';

/// Summary of a source's login state, shared by the sidebar account card and the
/// top-bar [AccountMenuButton] dropdown.
class AccountView {
  final bool loggedIn;
  final String? name;
  final String? avatarUrl;
  final String subtitle;
  const AccountView({
    required this.loggedIn,
    this.name,
    this.avatarUrl,
    required this.subtitle,
  });
}

/// Resolves the login summary for [source] by watching the matching auth provider
/// (they notify only on auth changes, never per playback tick). Call from a
/// widget's `build` so the caller rebuilds on login/logout.
AccountView accountViewFor(BuildContext context, MusicSource source) {
  switch (source) {
    case MusicSource.netease:
      final AuthProvider a = context.watch<AuthProvider>();
      return AccountView(
        loggedIn: a.isLoggedIn,
        name: a.account?.nickname,
        avatarUrl: a.account?.avatarUrl,
        subtitle: a.isLoggedIn
            ? ((a.account?.vipType ?? 0) > 0 ? '黑胶 VIP' : '网易云')
            : '点此登录',
      );
    case MusicSource.migu:
      final QqAuthProvider a = context.watch<QqAuthProvider>();
      return AccountView(
        loggedIn: a.isLoggedIn,
        name: a.account?.nickname,
        avatarUrl: a.account?.avatarUrl,
        subtitle: a.isLoggedIn ? 'QQ音乐' : '点此登录',
      );
    case MusicSource.kugou:
      final KugouAuthProvider a = context.watch<KugouAuthProvider>();
      return AccountView(
        loggedIn: a.isLoggedIn,
        name: a.active?.nickname,
        avatarUrl: a.active?.avatarUrl,
        subtitle: a.isLoggedIn ? '酷狗' : '点此登录',
      );
    case MusicSource.kuwo:
      final KuwoAuthProvider a = context.watch<KuwoAuthProvider>();
      return AccountView(
        loggedIn: a.isLoggedIn,
        subtitle: a.isLoggedIn ? '酷我' : '账号密码登录',
      );
    case MusicSource.local:
      return const AccountView(loggedIn: false, subtitle: '本地音乐 · 免登录');
  }
}

/// The bottom-of-sidebar account card: avatar + login summary for the current
/// source (未登录 / 已登录 · <source> + membership). Tapping opens the accounts
/// manager dialog ([showAccountsDialog]). Watches the auth providers (they notify
/// only on auth changes, never per playback tick) + [SettingsProvider.source].
class SidebarAccountCard extends StatelessWidget {
  final bool collapsed;
  const SidebarAccountCard({super.key, this.collapsed = false});

  @override
  Widget build(BuildContext context) {
    final MusicSource source =
        context.select((SettingsProvider s) => s.source);
    final AccountView v = accountViewFor(context, source);
    final double av = 32;

    final Widget avatar = (v.loggedIn && v.avatarUrl != null)
        ? ArtworkImage(url: v.avatarUrl, size: av, radius: av / 2)
        : Container(
            width: av,
            height: av,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: <Color>[AppColors.seedA, AppColors.seed],
              ),
            ),
            child: Icon(
              v.loggedIn ? Icons.person_rounded : Icons.login_rounded,
              size: 18,
              color: AppColors.onSurface,
            ),
          );

    return _HoverCard(
      onTap: () => showAccountsDialog(context),
      collapsed: collapsed,
      child: collapsed
          ? Center(child: avatar)
          : Row(
              children: <Widget>[
                avatar,
                const SizedBox(width: AppDimens.space12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        v.loggedIn
                            ? (v.name?.isNotEmpty == true
                                ? v.name!
                                : '已登录')
                            : '未登录',
                        style: AppTypography.body.copyWith(fontSize: 13),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        '${sourceLabel(source)} · ${v.subtitle}',
                        style: AppTypography.caption,
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

class _HoverCard extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  final bool collapsed;
  const _HoverCard({
    required this.child,
    required this.onTap,
    required this.collapsed,
  });

  @override
  State<_HoverCard> createState() => _HoverCardState();
}

class _HoverCardState extends State<_HoverCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: EdgeInsets.all(widget.collapsed ? 8 : 10),
          decoration: BoxDecoration(
            color: _hover ? AppColors.pressed : AppColors.glass,
            borderRadius: BorderRadius.circular(AppDimens.radiusMd),
            border: Border.all(color: AppColors.glassBorder, width: 1),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}
