import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../models/cookie_account.dart';
import '../../models/kugou_account.dart';
import '../../router/routes.dart';
import '../../state/auth_provider.dart';
import '../../state/kugou_auth_provider.dart';
import '../../state/qqcn_auth_provider.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_dimens.dart';
import '../../theme/app_typography.dart';
import '../../widgets/app_scaffold.dart';
import '../../widgets/artwork_image.dart';
import '../../widgets/glass_container.dart';

/// Multi-account manager (多账号管理系统). One section per backend that supports a
/// login — 网易云 (single cookie-based account) and 酷狗 (a switchable set of
/// accounts). Kugou's section is the real multi-account hub: add via QR, tap to
/// switch the active credential (which unlocks full-song playback), swipe/✕ to
/// remove. Netease keeps its existing single-account model, surfaced here too.
class AccountsPage extends StatelessWidget {
  const AccountsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        title: const Text('账号管理', style: AppTypography.titleM),
        leading: IconButton(
          tooltip: '返回',
          icon: const Icon(Icons.arrow_back_ios_new_rounded,
              color: AppColors.onSurface, size: 20),
          onPressed: () {
            if (context.canPop()) context.pop();
          },
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(
            top: kToolbarHeight + AppDimens.space16,
            bottom: AppDimens.space32,
          ),
          children: const <Widget>[
            _SectionHeader('网易云音乐'),
            _NeteaseSection(),
            SizedBox(height: AppDimens.space24),
            _SectionHeader('QQ音乐'),
            _QqSection(),
            SizedBox(height: AppDimens.space24),
            _SectionHeader('酷狗音乐'),
            _KugouSection(),
            SizedBox(height: AppDimens.space24),
            _SectionHeader('酷我音乐'),
            _KuwoSection(),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppDimens.space12),
      child: Text(title, style: AppTypography.titleM),
    );
  }
}

// --- Netease + QQ (cookie-based, multi-account) ------------------------------

/// Confirms removing/signing-out an account; returns true if confirmed.
Future<bool> _confirmRemove(BuildContext context, String name) async {
  final bool? ok = await showDialog<bool>(
    context: context,
    builder: (BuildContext ctx) => AlertDialog(
      backgroundColor: AppColors.surface,
      title: const Text('移除账号', style: AppTypography.titleM),
      content: Text('移除账号「$name」？', style: AppTypography.body),
      actions: <Widget>[
        TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消')),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          style: TextButton.styleFrom(foregroundColor: AppColors.accentPlay),
          child: const Text('移除'),
        ),
      ],
    ),
  );
  return ok == true;
}

class _NeteaseSection extends StatelessWidget {
  const _NeteaseSection();

  @override
  Widget build(BuildContext context) {
    final AuthProvider auth = context.watch<AuthProvider>();
    return _CookieAccountSection(
      accounts: auth.accounts,
      activeId: auth.activeId,
      fallback: '网易云用户',
      emptyHint: '登录网易云账号后可用每日推荐 / 我的歌单 / 逐字歌词',
      addLabel: auth.accounts.isEmpty ? '登录网易云账号' : '添加网易云账号',
      onSwitch: (String id) => context.read<AuthProvider>().switchAccount(id),
      onRemove: (CookieAccount a) async {
        final String name = a.nickname.isEmpty ? '网易云用户 ${a.id}' : a.nickname;
        if (await _confirmRemove(context, name) && context.mounted) {
          await context.read<AuthProvider>().removeAccount(a.id);
        }
      },
      onAdd: () => context.push(Routes.login),
    );
  }
}

class _QqSection extends StatelessWidget {
  const _QqSection();

  @override
  Widget build(BuildContext context) {
    final QqcnAuthProvider qq = context.watch<QqcnAuthProvider>();
    // QqcnAuthProvider already exposes its accounts as CookieAccount rows.
    final List<CookieAccount> rows = qq.accounts;
    return _CookieAccountSection(
      accounts: rows,
      activeId: qq.activeId,
      fallback: 'QQ音乐用户',
      emptyHint: 'QQ音乐需登录后才能播放完整歌曲（QQ / 微信 扫码，同一二维码）',
      addLabel: rows.isEmpty ? '登录 QQ音乐' : '添加 QQ音乐账号',
      onSwitch: (String id) =>
          context.read<QqcnAuthProvider>().switchAccount(id),
      onRemove: (CookieAccount a) async {
        final String name = a.nickname.isEmpty ? 'QQ音乐用户 ${a.id}' : a.nickname;
        if (await _confirmRemove(context, name) && context.mounted) {
          await context.read<QqcnAuthProvider>().removeAccount(a.id);
        }
      },
      onAdd: () => context.push(Routes.qqLogin),
    );
  }
}

/// Shared multi-account section for the cookie-based sources (网易/QQ): the saved
/// accounts (tap to switch, ✕ to remove) + an add-account tile.
class _CookieAccountSection extends StatelessWidget {
  final List<CookieAccount> accounts;
  final String? activeId;
  final String fallback;
  final String emptyHint;
  final String addLabel;
  final void Function(String id) onSwitch;
  final Future<void> Function(CookieAccount a) onRemove;
  final VoidCallback onAdd;

  const _CookieAccountSection({
    required this.accounts,
    required this.activeId,
    required this.fallback,
    required this.emptyHint,
    required this.addLabel,
    required this.onSwitch,
    required this.onRemove,
    required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (accounts.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: AppDimens.space8),
            child: Text(emptyHint,
                style: AppTypography.caption
                    .copyWith(color: AppColors.onSurfaceMuted)),
          )
        else
          ...accounts.map((CookieAccount a) => _AccountRow(
                avatarUrl: a.avatarUrl,
                title: a.nickname.isEmpty ? '$fallback ${a.id}' : a.nickname,
                subtitle: a.id == activeId
                    ? '当前使用'
                    : (a.isVip ? '会员' : '点击切换'),
                active: a.id == activeId,
                onSwitch: () => onSwitch(a.id),
                onRemove: () => onRemove(a),
              )),
        const SizedBox(height: AppDimens.space8),
        _AddAccountTile(label: addLabel, onTap: onAdd),
      ],
    );
  }
}

// --- Kugou -------------------------------------------------------------------

class _KugouSection extends StatelessWidget {
  const _KugouSection();

  @override
  Widget build(BuildContext context) {
    final KugouAuthProvider kugou = context.watch<KugouAuthProvider>();
    final List<KugouAccount> accounts = kugou.accounts;
    final String? activeId = kugou.activeUserId;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (accounts.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: AppDimens.space8),
            child: Text(
              '登录酷狗账号后即可播放酷狗完整歌曲（未登录时酷狗歌曲会自动跳过）',
              style: AppTypography.caption
                  .copyWith(color: AppColors.onSurfaceMuted),
            ),
          )
        else
          ...accounts.map((KugouAccount a) => _AccountRow(
                avatarUrl: a.avatarUrl,
                title: a.nickname.isEmpty ? '酷狗用户 ${a.userId}' : a.nickname,
                subtitle: a.userId == activeId
                    ? '当前使用'
                    : (a.isVip ? '酷狗会员' : '点击切换'),
                active: a.userId == activeId,
                onSwitch: () =>
                    context.read<KugouAuthProvider>().switchTo(a.userId),
                onRemove: () async {
                  final String name =
                      a.nickname.isEmpty ? '酷狗用户 ${a.userId}' : a.nickname;
                  if (await _confirmRemove(context, name) && context.mounted) {
                    await context
                        .read<KugouAuthProvider>()
                        .removeAccount(a.userId);
                  }
                },
              )),
        const SizedBox(height: AppDimens.space8),
        _AddAccountTile(
          label: accounts.isEmpty ? '扫码登录酷狗' : '添加酷狗账号',
          onTap: () => context.push(Routes.kugouLogin),
        ),
      ],
    );
  }
}

/// One account row (shared by 网易/QQ/酷狗): tap the body to switch (a ✓ marks the
/// active one), ✕ to remove.
class _AccountRow extends StatelessWidget {
  final String? avatarUrl;
  final String title;
  final String subtitle;
  final bool active;
  final VoidCallback onSwitch;
  final VoidCallback onRemove;

  const _AccountRow({
    required this.avatarUrl,
    required this.title,
    required this.subtitle,
    required this.active,
    required this.onSwitch,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppDimens.space8),
      child: GlassContainer(
        padding: const EdgeInsets.all(AppDimens.space8),
        child: Row(
          children: <Widget>[
            Expanded(
              child: InkWell(
                onTap: active ? null : onSwitch,
                borderRadius: BorderRadius.circular(AppDimens.radiusSm),
                child: Padding(
                  padding: const EdgeInsets.all(AppDimens.space4),
                  child: Row(
                    children: <Widget>[
                      _Avatar(url: avatarUrl, size: 44),
                      const SizedBox(width: AppDimens.space12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Text(
                              title,
                              style: AppTypography.body
                                  .copyWith(fontWeight: FontWeight.w700),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              subtitle,
                              style: AppTypography.caption.copyWith(
                                color: active
                                    ? AppColors.accentPlay
                                    : AppColors.onSurfaceMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (active)
                        const Icon(Icons.check_circle_rounded,
                            color: AppColors.accentPlay, size: 20),
                    ],
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: '移除',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close_rounded,
                  color: AppColors.onSurfaceFaint, size: 20),
              onPressed: onRemove,
            ),
          ],
        ),
      ),
    );
  }
}

// --- Kuwo (anonymous / login coming later) -----------------------------------

class _KuwoSection extends StatelessWidget {
  const _KuwoSection();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppDimens.space8),
      child: GlassContainer(
        padding: const EdgeInsets.all(AppDimens.space12),
        child: Row(
          children: <Widget>[
            const Icon(Icons.info_outline_rounded,
                size: 18, color: AppColors.onSurfaceMuted),
            const SizedBox(width: AppDimens.space12),
            Expanded(
              child: Text(
                '酷我音乐：搜索与歌词匿名可用；完整播放需要账号（登录功能即将上线）。',
                style: AppTypography.caption
                    .copyWith(color: AppColors.onSurfaceMuted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// --- shared bits -------------------------------------------------------------

class _AddAccountTile extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _AddAccountTile({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GlassContainer(
      padding: EdgeInsets.zero,
      child: ListTile(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppDimens.radiusMd),
        ),
        leading: const Icon(Icons.add_circle_outline_rounded,
            color: AppColors.onSurface),
        title: Text(label,
            style: AppTypography.body.copyWith(fontWeight: FontWeight.w600)),
        trailing: const Icon(Icons.qr_code_scanner_rounded,
            color: AppColors.onSurfaceMuted, size: 20),
        onTap: onTap,
      ),
    );
  }
}

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
      child: Icon(Icons.person_rounded,
          color: AppColors.onSurfaceFaint, size: size * 0.5),
    );
  }
}
