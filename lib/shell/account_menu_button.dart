import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/song.dart';
import '../pages/accounts/accounts_dialog.dart';
import '../pages/login/login_dialog.dart';
import '../pages/settings/settings_dialog.dart';
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
import 'sidebar_account_card.dart';

enum _AcctAction { login, logout, accounts, settings }

/// The top-bar account avatar. A circular avatar (reusing [accountViewFor]) that
/// opens a dropdown — 登录 / 退出登录 · 账号管理 · 设置 — instead of a full-page jump.
/// Every item is a dialog or a provider call, never a route push. Watches the
/// active source's auth provider so the avatar + items reflect login state.
class AccountMenuButton extends StatelessWidget {
  const AccountMenuButton({super.key});

  void _logout(BuildContext context, MusicSource source) {
    switch (source) {
      case MusicSource.netease:
        context.read<AuthProvider>().logout();
      case MusicSource.migu:
        context.read<QqAuthProvider>().logout();
      case MusicSource.kugou:
        final KugouAuthProvider k = context.read<KugouAuthProvider>();
        final String? id = k.activeUserId;
        if (id != null) k.removeAccount(id);
      case MusicSource.kuwo:
        context.read<KuwoAuthProvider>().logout();
      case MusicSource.local:
        break;
    }
  }

  PopupMenuItem<_AcctAction> _item(
    _AcctAction value,
    IconData icon,
    String label, {
    bool danger = false,
  }) {
    final Color color = danger ? const Color(0xFFEF4444) : AppColors.onSurface;
    return PopupMenuItem<_AcctAction>(
      value: value,
      height: 42,
      child: Row(
        children: <Widget>[
          Icon(icon, size: 18, color: color),
          const SizedBox(width: AppDimens.space12),
          Text(label, style: AppTypography.body.copyWith(color: color)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final MusicSource source =
        context.select((SettingsProvider s) => s.source);
    final AccountView v = accountViewFor(context, source);

    const double av = 30;
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
              size: 16,
              color: AppColors.onSurface,
            ),
          );

    return PopupMenuButton<_AcctAction>(
      tooltip: v.loggedIn ? (v.name ?? '账号') : '未登录',
      offset: const Offset(0, 44),
      color: AppColors.surface2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppDimens.radiusMd),
        side: const BorderSide(color: AppColors.glassBorder),
      ),
      itemBuilder: (BuildContext ctx) => <PopupMenuEntry<_AcctAction>>[
        if (!v.loggedIn)
          _item(_AcctAction.login, Icons.login_rounded,
              '登录 ${sourceLabel(source)}'),
        if (v.loggedIn)
          _item(_AcctAction.logout, Icons.logout_rounded, '退出登录',
              danger: true),
        const PopupMenuDivider(),
        _item(_AcctAction.accounts, Icons.manage_accounts_rounded, '账号管理'),
        _item(_AcctAction.settings, Icons.settings_rounded, '设置'),
      ],
      onSelected: (_AcctAction a) {
        switch (a) {
          case _AcctAction.login:
            showLoginDialog(context, source);
          case _AcctAction.logout:
            _logout(context, source);
          case _AcctAction.accounts:
            showAccountsDialog(context);
          case _AcctAction.settings:
            showSettingsDialog(context);
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppDimens.space8),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: avatar,
        ),
      ),
    );
  }
}
