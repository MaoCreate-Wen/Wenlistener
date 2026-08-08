import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/cookie_account.dart';
import '../../models/kugou_account.dart';
import '../../models/song.dart';
import '../../state/auth_provider.dart';
import '../../state/kugou_auth_provider.dart';
import '../../state/kuwo_auth_provider.dart';
import '../../state/qqcn_auth_provider.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_dimens.dart';
import '../../theme/app_typography.dart';
import '../../widgets/entrance.dart';
import '../login/login_dialog.dart';
import '../playlist/desktop_kit.dart';

/// Multi-account manager body (账号管理), hosted by [showAccountsDialog]. One card
/// per source; each lists the saved accounts with switch / remove and an "添加账号"
/// action that opens the per-source login dialog. Consumes the four auth
/// providers — no logic re-implemented.
class AccountsBody extends StatelessWidget {
  const AccountsBody({super.key});

  @override
  Widget build(BuildContext context) {
    // 源卡片自上而下「向下展开」逐张落位（统一入场，见 widgets/entrance.dart）。
    return const DownwardReveal(
      spacing: AppDimens.sectionGap,
      children: <Widget>[
        _NeteaseCard(),
        _QqcnCard(),
        _KugouCard(),
        _KuwoCard(),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Shared card shell + tile
// ---------------------------------------------------------------------------

class _SourceCard extends StatelessWidget {
  final MusicSource source;
  final String addLabel;
  final List<Widget> children;

  const _SourceCard({
    required this.source,
    required this.children,
    this.addLabel = '添加账号',
  });

  @override
  Widget build(BuildContext context) {
    return DkGlass(
      padding: const EdgeInsets.all(AppDimens.space20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(dkSourceIcon(source), color: AppColors.onSurface, size: 22),
              const SizedBox(width: AppDimens.space12),
              Text(dkSourceLabel(source), style: AppTypography.titleM),
              const Spacer(),
              DkSecondaryButton(
                icon: Icons.add_rounded,
                label: addLabel,
                onPressed: () => showLoginDialog(context, source),
              ),
            ],
          ),
          const SizedBox(height: AppDimens.space16),
          // 账号行逐行「向下展开」落位（空态单项也走同一入场）。
          DownwardReveal(children: children),
        ],
      ),
    );
  }
}

class _EmptyAccounts extends StatelessWidget {
  final String message;
  const _EmptyAccounts(this.message);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppDimens.space16),
      child: Row(
        children: <Widget>[
          const Icon(Icons.person_off_outlined,
              color: AppColors.onFaint, size: 20),
          const SizedBox(width: AppDimens.space12),
          Text(message, style: AppTypography.label),
        ],
      ),
    );
  }
}

/// One account row. [active] shows the accent badge; [onSwitch] is null when the
/// tile is already active.
class _AccountTile extends StatelessWidget {
  final String? avatarUrl;
  final String nickname;
  final String? vipLabel;
  final bool active;
  final VoidCallback? onSwitch;
  final VoidCallback onRemove;

  const _AccountTile({
    required this.avatarUrl,
    required this.nickname,
    required this.active,
    required this.onSwitch,
    required this.onRemove,
    this.vipLabel,
  });

  @override
  Widget build(BuildContext context) {
    final Color accent = AppColors.accentOf(context);
    return Container(
      margin: const EdgeInsets.only(bottom: AppDimens.space8),
      padding: const EdgeInsets.all(AppDimens.space12),
      decoration: BoxDecoration(
        color: active ? AppColors.rowSelected : AppColors.glass,
        borderRadius: BorderRadius.circular(AppDimens.radiusMd),
        border: Border.all(
          color: active ? accent : AppColors.glassBorder,
          width: active ? 1.5 : 1,
        ),
      ),
      child: Row(
        children: <Widget>[
          DkArt(
            url: avatarUrl,
            size: 44,
            circle: true,
            placeholder: Icons.person_rounded,
          ),
          const SizedBox(width: AppDimens.space12),
          Expanded(
            child: Row(
              children: <Widget>[
                Flexible(
                  child: Text(
                    nickname.isEmpty ? '未命名账号' : nickname,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.body,
                  ),
                ),
                if (vipLabel != null) ...<Widget>[
                  const SizedBox(width: AppDimens.space8),
                  DkVipPill(label: vipLabel!),
                ],
              ],
            ),
          ),
          if (active)
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(AppDimens.radiusPill),
              ),
              child: Text('当前',
                  style: AppTypography.caption.copyWith(color: accent)),
            )
          else if (onSwitch != null)
            DkHoverIcon(
              icon: Icons.swap_horiz_rounded,
              tooltip: '切换到此账号',
              onTap: onSwitch,
            ),
          const SizedBox(width: AppDimens.space4),
          DkHoverIcon(
            icon: Icons.delete_outline_rounded,
            tooltip: '移除账号',
            onTap: onRemove,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Netease
// ---------------------------------------------------------------------------

class _NeteaseCard extends StatelessWidget {
  const _NeteaseCard();

  @override
  Widget build(BuildContext context) {
    final AuthProvider auth = context.watch<AuthProvider>();
    final List<CookieAccount> accounts = auth.accounts;
    return _SourceCard(
      source: MusicSource.netease,
      children: accounts.isEmpty
          ? <Widget>[const _EmptyAccounts('尚未登录任何网易云账号')]
          : <Widget>[
              for (final CookieAccount a in accounts)
                _AccountTile(
                  avatarUrl: a.avatarUrl,
                  nickname: a.nickname,
                  vipLabel: a.isVip ? '黑胶' : null,
                  active: a.id == auth.activeId,
                  onSwitch:
                      a.id == auth.activeId ? null : () => auth.switchAccount(a.id),
                  onRemove: () => auth.removeAccount(a.id),
                ),
            ],
    );
  }
}

// ---------------------------------------------------------------------------
// QQ 音乐（安卓客户端）— independent qqcn source
// ---------------------------------------------------------------------------

class _QqcnCard extends StatelessWidget {
  const _QqcnCard();

  @override
  Widget build(BuildContext context) {
    final QqcnAuthProvider auth = context.watch<QqcnAuthProvider>();
    final List<CookieAccount> accounts = auth.accounts;
    return _SourceCard(
      source: MusicSource.qqcn,
      children: accounts.isEmpty
          ? <Widget>[const _EmptyAccounts('尚未登录任何 QQ音乐(安卓) 账号')]
          : <Widget>[
              for (final CookieAccount a in accounts)
                _AccountTile(
                  avatarUrl: a.avatarUrl,
                  nickname: a.nickname,
                  vipLabel: a.isVip ? '绿钻' : null,
                  active: a.id == auth.activeId,
                  onSwitch:
                      a.id == auth.activeId ? null : () => auth.switchAccount(a.id),
                  onRemove: () => auth.removeAccount(a.id),
                ),
            ],
    );
  }
}

// ---------------------------------------------------------------------------
// Kugou
// ---------------------------------------------------------------------------

class _KugouCard extends StatelessWidget {
  const _KugouCard();

  @override
  Widget build(BuildContext context) {
    final KugouAuthProvider auth = context.watch<KugouAuthProvider>();
    final List<KugouAccount> accounts = auth.accounts;
    return _SourceCard(
      source: MusicSource.kugou,
      children: accounts.isEmpty
          ? <Widget>[const _EmptyAccounts('尚未登录任何酷狗账号')]
          : <Widget>[
              for (final KugouAccount a in accounts)
                _AccountTile(
                  avatarUrl: a.avatarUrl,
                  nickname: a.nickname,
                  vipLabel: a.isVip ? '酷狗VIP' : null,
                  active: a.userId == auth.activeUserId,
                  onSwitch: a.userId == auth.activeUserId
                      ? null
                      : () => auth.switchTo(a.userId),
                  onRemove: () => auth.removeAccount(a.userId),
                ),
            ],
    );
  }
}

// ---------------------------------------------------------------------------
// Kuwo (single account)
// ---------------------------------------------------------------------------

class _KuwoCard extends StatelessWidget {
  const _KuwoCard();

  @override
  Widget build(BuildContext context) {
    final KuwoAuthProvider auth = context.watch<KuwoAuthProvider>();
    return _SourceCard(
      source: MusicSource.kuwo,
      addLabel: auth.isLoggedIn ? '重新登录' : '登录',
      children: auth.isLoggedIn
          ? <Widget>[
              _AccountTile(
                avatarUrl: null,
                nickname: '酷我账号',
                active: true,
                onSwitch: null,
                onRemove: () => auth.logout(),
              ),
            ]
          : <Widget>[const _EmptyAccounts('尚未登录酷我账号')],
    );
  }
}
