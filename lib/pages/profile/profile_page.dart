import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../router/routes.dart';
import '../../state/auth_provider.dart';
import '../../state/player_provider.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_dimens.dart';
import '../../theme/app_typography.dart';
import '../../widgets/app_scaffold.dart';
import '../../widgets/artwork_image.dart';
import '../../widgets/glass_container.dart';

/// Full-screen account page, pushed on the root navigator from the Library
/// account card. Shows the signed-in user's avatar, nickname, membership and
/// uid, plus a sign-out action.
///
/// [AuthProvider] is watched reactively; the account itself is read via
/// inference (`final account = auth.account`) so the type — which lives in
/// services/ — is never named here, keeping this page off the services layer.
/// When there's no account it shows a friendly loading / logged-out prompt
/// instead of blank fields.
class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});

  /// Signs out then leaves the page. [AuthProvider.logout] clears the cookies
  /// and notifies; we then route to Home, which both dismisses this full-screen
  /// route and lands the user back in the app. The router is captured BEFORE the
  /// await so we never touch [context] across the async gap.
  Future<void> _signOut(BuildContext context) async {
    final GoRouter router = GoRouter.of(context);
    await context.read<AuthProvider>().logout();
    router.go(Routes.home);
  }

  /// Confirms before signing out — a mis-tap on the sign-out button shouldn't log
  /// the user out. Only proceeds to [_signOut] when the user confirms.
  Future<void> _confirmSignOut(BuildContext context) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('退出登录', style: AppTypography.titleM),
        content: Text('确定要退出当前网易云账号吗？', style: AppTypography.body),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.accentPlay),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) await _signOut(context);
  }

  @override
  Widget build(BuildContext context) {
    final AuthProvider auth = context.watch<AuthProvider>();
    // Inferred NeteaseAccount? — deliberately never named (services/ stays out
    // of pages/). Promoted to non-null in the `_ProfileBody` branch below.
    final account = auth.account;
    final Color accent = context.select<PlayerProvider, Color>(
      (PlayerProvider p) => p.dynamicAccent,
    );

    return AppScaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        title: const Text('Profile', style: AppTypography.titleM),
        leading: IconButton(
          tooltip: 'Back',
          icon: const Icon(
            Icons.arrow_back_ios_new_rounded,
            color: AppColors.onSurface,
            size: 20,
          ),
          onPressed: () {
            if (context.canPop()) context.pop();
          },
        ),
        actions: <Widget>[
          IconButton(
            tooltip: '设置',
            icon: const Icon(Icons.settings_outlined,
                color: AppColors.onSurface, size: 22),
            onPressed: () => context.push(Routes.settings),
          ),
        ],
      ),
      body: SafeArea(
        child: account == null
            ? _EmptyState(
                isLoggedIn: auth.isLoggedIn,
                onSignIn: () => context.push(Routes.login),
              )
            : _ProfileBody(
                avatarUrl: account.avatarUrl,
                nickname: account.nickname,
                uid: account.uid,
                vipType: account.vipType,
                accent: accent,
                onSignOut: () => _confirmSignOut(context),
              ),
      ),
    );
  }
}

/// The populated profile: large avatar, nickname, a membership pill, an info
/// card (uid + membership) and a full-width sign-out button. All inputs are
/// plain values, so no services type leaks into this widget's API.
class _ProfileBody extends StatelessWidget {
  final String? avatarUrl;
  final String nickname;
  final int uid;
  final int vipType;
  final Color accent;
  final VoidCallback onSignOut;

  const _ProfileBody({
    required this.avatarUrl,
    required this.nickname,
    required this.uid,
    required this.vipType,
    required this.accent,
    required this.onSignOut,
  });

  @override
  Widget build(BuildContext context) {
    final bool isVip = vipType > 0;
    final bool hasName = nickname.isNotEmpty;
    return SingleChildScrollView(
      // Clear the (transparent, behind-content) app bar; AppScaffold supplies
      // the horizontal screen padding and SafeArea the status-bar inset.
      padding: const EdgeInsets.only(
        top: kToolbarHeight + AppDimens.space24,
        bottom: AppDimens.space32,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Center(child: _BigAvatar(url: avatarUrl, size: 112)),
          const SizedBox(height: AppDimens.space20),
          Text(
            hasName ? nickname : 'NetEase user',
            style: AppTypography.displayM,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: AppDimens.space12),
          Center(child: _MembershipPill(isVip: isVip, accent: accent)),
          const SizedBox(height: AppDimens.space24),
          GlassContainer(
            padding: const EdgeInsets.symmetric(
              horizontal: AppDimens.space16,
              vertical: AppDimens.space4,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _InfoRow(label: 'User ID', value: '$uid'),
                const Divider(height: 1, color: AppColors.surfaceGlassBorder),
                _InfoRow(
                  label: 'Membership',
                  value: isVip ? 'VIP · type $vipType' : 'Standard',
                ),
              ],
            ),
          ),
          const SizedBox(height: AppDimens.space32),
          _SignOutButton(onPressed: onSignOut),
        ],
      ),
    );
  }
}

/// Large circular avatar with a soft drop shadow. Uses [ArtworkImage] (cache +
/// Netease image headers) when a URL is present, else a person glyph so an
/// avatar-less / still-loading account doesn't show the cover placeholder.
class _BigAvatar extends StatelessWidget {
  final String? url;
  final double size;

  const _BigAvatar({required this.url, required this.size});

  @override
  Widget build(BuildContext context) {
    final String? u = url;
    final Widget inner = (u != null && u.isNotEmpty)
        ? ArtworkImage(url: u, size: size, radius: size / 2)
        : Container(
            width: size,
            height: size,
            decoration: const BoxDecoration(
              color: AppColors.surfaceGlass,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.person_rounded,
              color: AppColors.onSurfaceFaint,
              size: size * 0.5,
            ),
          );
    return DecoratedBox(
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: AppDimens.glassShadow,
      ),
      child: inner,
    );
  }
}

/// Accent-tinted "VIP Member" / neutral "Standard" capsule.
class _MembershipPill extends StatelessWidget {
  final bool isVip;
  final Color accent;

  const _MembershipPill({required this.isVip, required this.accent});

  @override
  Widget build(BuildContext context) {
    final Color color = isVip ? accent : AppColors.onSurfaceFaint;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppDimens.space12,
        vertical: AppDimens.space4,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(AppDimens.radiusPill),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            isVip
                ? Icons.workspace_premium_rounded
                : Icons.person_outline_rounded,
            size: 16,
            color: color,
          ),
          const SizedBox(width: AppDimens.space4),
          Text(
            isVip ? 'VIP Member' : 'Standard',
            style: AppTypography.label.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// A label/value line inside the info card.
class _InfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppDimens.space12),
      child: Row(
        children: <Widget>[
          Text(label, style: AppTypography.label),
          const SizedBox(width: AppDimens.space16),
          Expanded(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: AppTypography.body.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

/// Full-width, glass-filled sign-out button.
class _SignOutButton extends StatelessWidget {
  final VoidCallback onPressed;

  const _SignOutButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          foregroundColor: AppColors.onSurface,
          backgroundColor: AppColors.surfaceGlass,
          minimumSize: const Size.fromHeight(AppDimens.minTouch),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppDimens.radiusMd),
          ),
        ),
        child: const Text('Sign out'),
      ),
    );
  }
}

/// Shown when there's no resolved account: a spinner while a logged-in profile
/// is still loading, otherwise a friendly "not signed in" prompt with a CTA to
/// open the QR login page.
class _EmptyState extends StatelessWidget {
  final bool isLoggedIn;
  final VoidCallback onSignIn;

  const _EmptyState({required this.isLoggedIn, required this.onSignIn});

  @override
  Widget build(BuildContext context) {
    if (isLoggedIn) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(height: AppDimens.space16),
            Text('Loading your profile…', style: AppTypography.label),
          ],
        ),
      );
    }
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(
            Icons.account_circle_outlined,
            size: 64,
            color: AppColors.onSurfaceFaint,
          ),
          const SizedBox(height: AppDimens.space16),
          const Text('Not signed in', style: AppTypography.titleM),
          const SizedBox(height: AppDimens.space8),
          Text(
            'Sign in to view your NetEase profile',
            style: AppTypography.label,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppDimens.space24),
          TextButton(
            onPressed: onSignIn,
            style: TextButton.styleFrom(
              foregroundColor: AppColors.onSurface,
              backgroundColor: AppColors.surfaceGlass,
              minimumSize: const Size(160, AppDimens.minTouch),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppDimens.radiusMd),
              ),
            ),
            child: const Text('Scan to log in'),
          ),
        ],
      ),
    );
  }
}
