import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../models/kugou_account.dart';
import '../../models/kugougn_account.dart';
import '../../models/play_url.dart';
import '../../models/qr_login.dart';
import '../../models/qqcn_login.dart';
import '../../models/song.dart';
import '../../router/routes.dart';
import '../../state/auth_provider.dart';
import '../../state/kugou_auth_provider.dart';
import '../../state/kugougn_auth_provider.dart';
import '../../state/kuwo_auth_provider.dart';
import '../../state/qqcn_auth_provider.dart';
import '../../state/settings_provider.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_dimens.dart';
import '../../theme/app_typography.dart';
import '../../widgets/app_scaffold.dart';
import '../../widgets/artwork_image.dart';
import '../../widgets/glass_container.dart';

/// App settings: the music source (音源), the login/account for the current
/// source (a scannable QR right under the selector when it isn't signed in), and
/// the lyrics-page background 律动 toggle. Both source + 律动 persist via
/// [SettingsProvider]; the source also switches the live backend.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final SettingsProvider settings = context.watch<SettingsProvider>();
    return AppScaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        title: const Text('设置', style: AppTypography.titleM),
        leading: IconButton(
          tooltip: 'Back',
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
            top: kToolbarHeight + AppDimens.space24,
            bottom: AppDimens.space32,
          ),
          children: <Widget>[
            const _SectionLabel('音源'),
            const SizedBox(height: AppDimens.space12),
            _SourceSelector(
              source: settings.source,
              onChanged: settings.setSource,
            ),
            const SizedBox(height: AppDimens.space8),
            Text(
              _sourceCaption(settings.source),
              style: AppTypography.caption,
            ),
            const SizedBox(height: AppDimens.space16),

            // Login / account for the CURRENTLY-selected source — a QR right here
            // when it isn't signed in (per request: 音源未登录时在音源下方加登录二维码).
            _SourceAccountSection(source: settings.source),

            const SizedBox(height: AppDimens.space12),
            // The full multi-account manager (both 网易 + 酷狗, 酷狗 switchable).
            _AccountsManagerTile(),

            const SizedBox(height: AppDimens.space32),
            const _SectionLabel('音质'),
            const SizedBox(height: AppDimens.space12),
            _QualitySelector(
              quality: settings.audioQuality,
              onChanged: settings.setAudioQuality,
            ),
            const SizedBox(height: AppDimens.space8),
            Text(
              '高品质 / 无损需要对应会员（网易黑胶 · QQ绿钻），无授权时自动降级到可用音质；'
              '切换后从下一首开始生效。',
              style: AppTypography.caption,
            ),
            const SizedBox(height: AppDimens.space32),
            const _SectionLabel('歌词页'),
            const SizedBox(height: AppDimens.space12),
            GlassContainer(
              padding: const EdgeInsets.symmetric(
                horizontal: AppDimens.space16,
                vertical: AppDimens.space4,
              ),
              child: SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('背景律动', style: AppTypography.body),
                subtitle: Text(
                  '歌词页背景跟随音乐节奏流动（需要麦克风权限）',
                  style: AppTypography.caption,
                ),
                value: settings.rhythmEnabled,
                onChanged: settings.setRhythmEnabled,
                activeThumbColor: AppColors.accentPlay,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _sourceCaption(MusicSource source) {
    switch (source) {
      case MusicSource.netease:
        return '网易云：扫码登录后可用每日推荐 / 我的歌单 / 逐字歌词，并解锁会员曲。';
      case MusicSource.migu:
      case MusicSource.qqcn:
        return 'QQ音乐：搜索与歌词免登录；完整播放需扫码登录（微信 / QQ），未登录时会员曲会自动跳过。';
      case MusicSource.kugou:
        return '酷狗：扫码登录后可播放完整歌曲（未登录时酷狗歌曲会自动跳过）。'
            '暂不支持歌单功能（酷狗无歌单接口），仅可搜索与播放。';
      case MusicSource.kugougn:
        return '酷狗概念版：酷狗手机端签名接口，搜索/歌词免登录。'
            '播放完整歌曲需在下方用【手机号 + 短信验证码】登录本源（独立账号，'
            '与「酷狗」网页版不共用，也不能用酷狗扫码代替）。暂不支持歌单功能。';
      case MusicSource.kuwo:
        return '酷我：搜索与歌词免登录；完整播放需要账号登录。';
      case MusicSource.local:
        return '本地音乐'; // not selectable as a source; keeps the switch exhaustive
    }
  }
}

/// A small uppercase section header above a settings group.
class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: AppTypography.label.copyWith(
        color: AppColors.onSurfaceMuted,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.6,
      ),
    );
  }
}

/// Segmented 网易云 / 咪咕 / 酷狗 selector — the same visual as the old top-bar
/// `SourceSwitcher`, driven by the persisted [SettingsProvider] value.
class _SourceSelector extends StatelessWidget {
  final MusicSource source;
  final ValueChanged<MusicSource> onChanged;

  const _SourceSelector({required this.source, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.surfaceGlass,
        borderRadius: BorderRadius.circular(AppDimens.radiusPill),
        border: Border.all(color: AppColors.onSurface.withValues(alpha: 0.06)),
      ),
      child: Row(
        children: <Widget>[
          _segment(
            label: '网易云',
            active: source == MusicSource.netease,
            onTap: () => onChanged(MusicSource.netease),
          ),
          _segment(
            label: 'QQ音乐',
            active: source == MusicSource.qqcn,
            onTap: () => onChanged(MusicSource.qqcn),
          ),
          _segment(
            label: '酷狗',
            active: source == MusicSource.kugou,
            onTap: () => onChanged(MusicSource.kugou),
          ),
          _segment(
            label: '概念版',
            active: source == MusicSource.kugougn,
            onTap: () => onChanged(MusicSource.kugougn),
          ),
          _segment(
            label: '酷我',
            active: source == MusicSource.kuwo,
            onTap: () => onChanged(MusicSource.kuwo),
          ),
        ],
      ),
    );
  }

  Widget _segment({
    required String label,
    required bool active,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(vertical: 10),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active
                ? AppColors.onSurface.withValues(alpha: 0.16)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(AppDimens.radiusPill),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              color: active ? AppColors.onSurface : AppColors.onSurfaceMuted,
              letterSpacing: 0.2,
            ),
          ),
        ),
      ),
    );
  }
}

/// Segmented 标准 / 高品质 / 无损 audio-quality selector — maps to the
/// [AudioLevel] pushed into playback (each backend fetches the best it can grant).
class _QualitySelector extends StatelessWidget {
  final AudioLevel quality;
  final ValueChanged<AudioLevel> onChanged;

  const _QualitySelector({required this.quality, required this.onChanged});

  bool _isActive(AudioLevel seg) {
    switch (seg) {
      case AudioLevel.standard:
        return quality == AudioLevel.standard;
      case AudioLevel.exhigh:
        return quality == AudioLevel.higher || quality == AudioLevel.exhigh;
      case AudioLevel.lossless:
        return quality == AudioLevel.lossless || quality == AudioLevel.hires;
      default:
        return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.surfaceGlass,
        borderRadius: BorderRadius.circular(AppDimens.radiusPill),
        border: Border.all(color: AppColors.onSurface.withValues(alpha: 0.06)),
      ),
      child: Row(
        children: <Widget>[
          _seg('标准', AudioLevel.standard),
          _seg('高品质', AudioLevel.exhigh),
          _seg('无损', AudioLevel.lossless),
        ],
      ),
    );
  }

  Widget _seg(String label, AudioLevel level) {
    final bool active = _isActive(level);
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onChanged(level),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(vertical: 10),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active
                ? AppColors.onSurface.withValues(alpha: 0.16)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(AppDimens.radiusPill),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              color: active ? AppColors.onSurface : AppColors.onSurfaceMuted,
              letterSpacing: 0.2,
            ),
          ),
        ),
      ),
    );
  }
}

/// The account block under the source selector. Reflects the CURRENT source's
/// login: a signed-in summary, an inline scan-to-login QR when the source
/// supports login and isn't signed in, or an "anonymous" note for 咪咕.
class _SourceAccountSection extends StatelessWidget {
  final MusicSource source;

  const _SourceAccountSection({required this.source});

  @override
  Widget build(BuildContext context) {
    switch (source) {
      case MusicSource.netease:
        return const _NeteaseAccountBlock();
      case MusicSource.kugou:
        return const _KugouAccountBlock();
      // 概念版 is a SEPARATE source with its own SMS login + account.
      case MusicSource.kugougn:
        return const _KugouGnAccountBlock();
      case MusicSource.migu:
      case MusicSource.qqcn:
        return const _QqAccountBlock();
      case MusicSource.local:
        return const SizedBox.shrink();
      case MusicSource.kuwo:
        return const _KuwoAccountBlock();
    }
  }
}

class _NeteaseAccountBlock extends StatelessWidget {
  const _NeteaseAccountBlock();

  @override
  Widget build(BuildContext context) {
    final AuthProvider auth = context.watch<AuthProvider>();
    if (auth.isLoggedIn) {
      // Inferred NeteaseAccount? — never named (keeps pages off services/).
      final account = auth.account;
      return _AccountSummaryCard(
        avatarUrl: account?.avatarUrl,
        title: (account?.nickname.isNotEmpty ?? false)
            ? account!.nickname
            : '网易云用户',
        subtitle: (account?.vipType ?? 0) > 0 ? '黑胶会员' : '已登录',
        actionLabel: '退出',
        onAction: () => context.read<AuthProvider>().logout(),
      );
    }
    return const _InlineSourceLogin(
      source: MusicSource.netease,
      key: ValueKey<String>('login-netease'),
    );
  }
}

class _KugouAccountBlock extends StatelessWidget {
  const _KugouAccountBlock();

  @override
  Widget build(BuildContext context) {
    final KugouAuthProvider kugou = context.watch<KugouAuthProvider>();
    final active = kugou.active;
    if (active != null) {
      final int n = kugou.accounts.length;
      return _AccountSummaryCard(
        avatarUrl: active.avatarUrl,
        title: active.nickname.isEmpty ? '酷狗用户 ${active.userId}' : active.nickname,
        subtitle: n > 1 ? '当前使用 · 共 $n 个账号' : (active.isVip ? '酷狗会员' : '已登录'),
        actionLabel: '管理',
        onAction: () => context.push(Routes.accounts),
      );
    }
    return const _InlineSourceLogin(
      source: MusicSource.kugou,
      key: ValueKey<String>('login-kugou'),
    );
  }
}

// --- 酷狗概念版 (kugouGn) — SMS login, own account -------------------------

class _KugouGnAccountBlock extends StatelessWidget {
  const _KugouGnAccountBlock();

  @override
  Widget build(BuildContext context) {
    final KugougnAuthProvider gn = context.watch<KugougnAuthProvider>();
    final KugougnAccount? active = gn.active;
    if (active != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _AccountSummaryCard(
            avatarUrl: active.avatarUrl,
            title: active.nickname.isEmpty
                ? '概念版用户 ${active.userId}'
                : active.nickname,
            subtitle: active.isVip ? '酷狗会员' : '已登录',
            actionLabel: '退出',
            onAction: () => context.read<KugougnAuthProvider>().logout(),
          ),
          const SizedBox(height: AppDimens.space8),
          _SignInVipButton(),
        ],
      );
    }
    return const _InlineKugouGnLogin(key: ValueKey<String>('login-kugougn'));
  }
}

/// "签到领VIP" button for the 概念版 account (claims the daily free VIP).
class _SignInVipButton extends StatefulWidget {
  @override
  State<_SignInVipButton> createState() => _SignInVipButtonState();
}

class _SignInVipButtonState extends State<_SignInVipButton> {
  bool _busy = false;

  Future<void> _run() async {
    if (_busy) return;
    setState(() => _busy = true);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final KugougnAuthProvider gn = context.read<KugougnAuthProvider>();
    String msg;
    try {
      await gn.signInDaily();
      msg = gn.signInMessage ?? '签到完成';
    } catch (e) {
      msg = '签到失败：$e';
    }
    if (!mounted) return;
    setState(() => _busy = false);
    messenger.showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: _busy ? null : _run,
        icon: _busy
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.card_giftcard_rounded, size: 18),
        label: Text(_busy ? '签到中…' : '签到领VIP'),
      ),
    );
  }
}

/// Inline mobile-number + SMS-code login for 酷狗概念版 (the source's ONLY login).
class _InlineKugouGnLogin extends StatefulWidget {
  const _InlineKugouGnLogin({super.key});

  @override
  State<_InlineKugouGnLogin> createState() => _InlineKugouGnLoginState();
}

class _InlineKugouGnLoginState extends State<_InlineKugouGnLogin> {
  final TextEditingController _phone = TextEditingController();
  final TextEditingController _code = TextEditingController();
  Timer? _ticker;

  @override
  void dispose() {
    _ticker?.cancel();
    _phone.dispose();
    _code.dispose();
    super.dispose();
  }

  /// Seconds left in the 60s resend cooldown (0 when a resend is allowed).
  int _cooldownLeft(KugougnAuthProvider gn) {
    final DateTime? sentAt = gn.codeSentAt;
    if (sentAt == null) return 0;
    final int left = KugougnAuthProvider.resendCooldown.inSeconds -
        DateTime.now().difference(sentAt).inSeconds;
    return left > 0 ? left : 0;
  }

  void _ensureTicker(int left) {
    if (left > 0 && _ticker == null) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (Timer t) {
        if (!mounted) {
          t.cancel();
          return;
        }
        setState(() {}); // re-evaluate the countdown; cancels itself at 0 below
        if (_cooldownLeft(context.read<KugougnAuthProvider>()) <= 0) {
          t.cancel();
          _ticker = null;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final KugougnAuthProvider gn = context.watch<KugougnAuthProvider>();
    final bool sending = gn.loginStage == KugougnLoginStage.sendingCode;
    final bool loggingIn = gn.loginStage == KugougnLoginStage.loggingIn;
    final bool codeSent = gn.loginStage == KugougnLoginStage.codeSent ||
        gn.loginStage == KugougnLoginStage.loggingIn;
    final int cooldown = _cooldownLeft(gn);
    _ensureTicker(cooldown);
    final bool canSend = !sending && cooldown == 0;

    return GlassContainer(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('登录酷狗概念版',
              style: AppTypography.body
                  .copyWith(color: AppColors.onSurface, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text('输入手机号获取短信验证码登录（概念版仅支持此方式）',
              style:
                  AppTypography.caption.copyWith(color: AppColors.onSurfaceMuted)),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  maxLength: 11,
                  style: AppTypography.body.copyWith(color: AppColors.onSurface),
                  decoration: const InputDecoration(
                    counterText: '',
                    hintText: '手机号',
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: canSend
                    ? () =>
                        context.read<KugougnAuthProvider>().sendMobileCode(_phone.text)
                    : null,
                child: Text(sending
                    ? '发送中…'
                    : cooldown > 0
                        ? '重新获取(${cooldown}s)'
                        : '获取验证码'),
              ),
            ],
          ),
          if (codeSent) ...<Widget>[
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _code,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    style: AppTypography.body.copyWith(color: AppColors.onSurface),
                    decoration: const InputDecoration(
                      counterText: '',
                      hintText: '短信验证码',
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: loggingIn
                      ? null
                      : () =>
                          context.read<KugougnAuthProvider>().loginWithVerifyCode(gn.loginPhone, _code.text),
                  child: Text(loggingIn ? '登录中…' : '登录'),
                ),
              ],
            ),
          ],
          if (gn.loginError != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(gn.loginError!,
                style: AppTypography.caption
                    .copyWith(color: AppColors.accentPlay)),
          ],
        ],
      ),
    );
  }
}

// --- QQ Music (the `migu` source slot) -----------------------------------

class _QqAccountBlock extends StatelessWidget {
  const _QqAccountBlock();

  @override
  Widget build(BuildContext context) {
    final QqcnAuthProvider qq = context.watch<QqcnAuthProvider>();
    if (qq.isLoggedIn) {
      final QqcnAccount? acct = qq.account;
      return _AccountSummaryCard(
        avatarUrl: acct?.avatarUrl,
        title: (acct?.nickname.isNotEmpty ?? false)
            ? acct!.nickname
            : 'QQ音乐用户',
        subtitle: (acct != null && acct.uin.isNotEmpty && acct.uin != '0')
            ? 'QQ ${acct.uin}'
            : '已登录',
        actionLabel: '退出',
        onAction: () => context.read<QqcnAuthProvider>().logout(),
      );
    }
    return const _QqInlineLogin(key: ValueKey<String>('login-qq'));
  }
}

/// Kuwo account summary or login CTA.
class _KuwoAccountBlock extends StatelessWidget {
  const _KuwoAccountBlock();

  @override
  Widget build(BuildContext context) {
    final KuwoAuthProvider kuwo = context.watch<KuwoAuthProvider>();
    if (kuwo.isLoggedIn) {
      return _AccountSummaryCard(
        avatarUrl: null,
        title: '酷我用户 ${kuwo.cookies.userid}',
        subtitle: '已登录',
        actionLabel: '退出',
        onAction: () => context.read<KuwoAuthProvider>().logout(),
      );
    }
    return GlassContainer(
      padding: EdgeInsets.zero,
      child: ListTile(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppDimens.radiusMd),
        ),
        leading: const Icon(Icons.login_rounded, color: AppColors.onSurface),
        title: Text('登录酷我账号',
            style:
                AppTypography.body.copyWith(fontWeight: FontWeight.w600)),
        trailing: const Icon(Icons.chevron_right_rounded,
            color: AppColors.onSurfaceMuted, size: 20),
        onTap: () => context.push(Routes.kuwoLogin),
      ),
    );
  }
}

/// Inline QQ Music scan-login: ONE ptlogin QR — mobile QQ AND WeChat scan the same
/// code (no method toggle). Auto-starts on mount, cancels on unmount.
class _QqInlineLogin extends StatefulWidget {
  const _QqInlineLogin({super.key});

  @override
  State<_QqInlineLogin> createState() => _QqInlineLoginState();
}

class _QqInlineLoginState extends State<_QqInlineLogin> {
  static const double _qrSize = 168;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<QqcnAuthProvider>().startLogin(QqcnLoginMethod.qq);
    });
  }

  @override
  void dispose() {
    context.read<QqcnAuthProvider>().cancelLogin();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final QqcnAuthProvider qq = context.watch<QqcnAuthProvider>();
    return GlassContainer(
      padding: const EdgeInsets.symmetric(
        horizontal: AppDimens.space16,
        vertical: AppDimens.space16,
      ),
      child: Column(
        children: <Widget>[
          Text('扫码登录 QQ音乐',
              style: AppTypography.body.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: AppDimens.space4),
          Text('QQ / 微信 均可扫码',
              style: AppTypography.caption
                  .copyWith(color: AppColors.onSurfaceMuted)),
          const SizedBox(height: AppDimens.space16),
          _QrSurface(
            size: _qrSize,
            child: _qrChild(qq),
          ),
          const SizedBox(height: AppDimens.space12),
          _StatusText(
            _qqLabel(qq.qrStatus, qq.qrLoading, qq.finishingLogin),
            ok: false, // logged-in → the block shows the account summary instead
          ),
        ],
      ),
    );
  }

  Widget _qrChild(QqcnAuthProvider qq) {
    if (qq.qrStatus == QqcnQrStatus.expired) {
      return _RefreshQr(
          onTap: () => context.read<QqcnAuthProvider>().startLogin(QqcnLoginMethod.qq));
    }
    final Uint8List? bytes = qq.qrImage;
    if (qq.qrLoading || bytes == null) return const _QrSpinner();
    return Image.memory(bytes, width: _qrSize, height: _qrSize, gaplessPlayback: true);
  }

  static String _qqLabel(QqcnQrStatus s, bool loading, bool finishing) {
    if (loading) return '正在生成二维码…';
    if (finishing) return '扫码成功，正在完成登录…';
    switch (s) {
      case QqcnQrStatus.waiting:
        return '等待扫描';
      case QqcnQrStatus.scanned:
        return '已扫描 — 请在手机上确认';
      case QqcnQrStatus.confirmed:
        // Logged-in would show the summary instead, so here = handoff got no session.
        return '登录未完成（未获取到会话），请重试';
      case QqcnQrStatus.expired:
        return '二维码已过期，点击刷新';
      case QqcnQrStatus.canceled:
        return '已取消，点击刷新';
      case QqcnQrStatus.unknown:
        return '正在生成二维码…';
    }
  }
}

/// Signed-in summary row: avatar + name/subtitle + a trailing action button.
class _AccountSummaryCard extends StatelessWidget {
  final String? avatarUrl;
  final String title;
  final String subtitle;
  final String actionLabel;
  final VoidCallback onAction;

  const _AccountSummaryCard({
    required this.avatarUrl,
    required this.title,
    required this.subtitle,
    required this.actionLabel,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return GlassContainer(
      padding: const EdgeInsets.all(AppDimens.space12),
      child: Row(
        children: <Widget>[
          _Avatar(url: avatarUrl, size: 44),
          const SizedBox(width: AppDimens.space12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(title,
                    style:
                        AppTypography.body.copyWith(fontWeight: FontWeight.w700),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text(subtitle,
                    style: AppTypography.caption
                        .copyWith(color: AppColors.onSurfaceMuted)),
              ],
            ),
          ),
          TextButton(onPressed: onAction, child: Text(actionLabel)),
        ],
      ),
    );
  }
}

/// Inline scan-to-login card for the current source: renders the QR right in the
/// settings page (Netease via `qr_flutter`, Kugou via the server-drawn PNG),
/// auto-starting the flow on mount and cancelling on unmount. Keyed by source so
/// switching the segment re-inits the correct flow.
class _InlineSourceLogin extends StatefulWidget {
  final MusicSource source;

  const _InlineSourceLogin({required this.source, super.key});

  @override
  State<_InlineSourceLogin> createState() => _InlineSourceLoginState();
}

class _InlineSourceLoginState extends State<_InlineSourceLogin> {
  static const double _qrSize = 168;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.source == MusicSource.netease) {
        context.read<AuthProvider>().startQrLogin();
      } else if (widget.source == MusicSource.kugou) {
        context.read<KugouAuthProvider>().startQrLogin();
      }
    });
  }

  @override
  void dispose() {
    // Stop the poll loop when leaving settings / switching source.
    if (widget.source == MusicSource.netease) {
      context.read<AuthProvider>().cancelQrLogin();
    } else if (widget.source == MusicSource.kugou) {
      context.read<KugouAuthProvider>().cancelQrLogin();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final String label =
        widget.source == MusicSource.netease ? '扫码登录网易云' : '扫码登录酷狗';
    final String hint = widget.source == MusicSource.netease
        ? '打开网易云音乐 App，扫一扫'
        : '打开酷狗音乐 App，扫一扫';
    return GlassContainer(
      padding: const EdgeInsets.symmetric(
        horizontal: AppDimens.space16,
        vertical: AppDimens.space16,
      ),
      child: Column(
        children: <Widget>[
          Text(label,
              style: AppTypography.body.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: AppDimens.space4),
          Text(hint,
              style: AppTypography.caption
                  .copyWith(color: AppColors.onSurfaceMuted),
              textAlign: TextAlign.center),
          const SizedBox(height: AppDimens.space16),
          _QrSurface(
            size: _qrSize,
            child: widget.source == MusicSource.netease
                ? const _NeteaseQr(size: _qrSize)
                : const _KugouQr(size: _qrSize),
          ),
          const SizedBox(height: AppDimens.space12),
          widget.source == MusicSource.netease
              ? const _NeteaseStatus()
              : const _KugouStatus(),
        ],
      ),
    );
  }
}

/// White rounded field the QR sits on (QR codes need a light, opaque background).
class _QrSurface extends StatelessWidget {
  final double size;
  final Widget child;

  const _QrSurface({required this.size, required this.child});

  @override
  Widget build(BuildContext context) {
    final double side = size + AppDimens.space16;
    return Container(
      width: side,
      height: side,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.onSurface,
        borderRadius: BorderRadius.circular(AppDimens.radiusMd),
      ),
      child: child,
    );
  }
}

class _NeteaseQr extends StatelessWidget {
  final double size;
  const _NeteaseQr({required this.size});

  @override
  Widget build(BuildContext context) {
    final AuthProvider auth = context.watch<AuthProvider>();
    final String? content = auth.qrContent;
    if (auth.qrStatus == QrStatus.expired ||
        auth.qrStatus == QrStatus.invalidated) {
      return _RefreshQr(onTap: () => context.read<AuthProvider>().startQrLogin());
    }
    if (auth.qrLoading || content == null || content.isEmpty) {
      return const _QrSpinner();
    }
    return QrImageView(
        data: content, size: size, backgroundColor: AppColors.onSurface);
  }
}

class _KugouQr extends StatelessWidget {
  final double size;
  const _KugouQr({required this.size});

  @override
  Widget build(BuildContext context) {
    final KugouAuthProvider kugou = context.watch<KugouAuthProvider>();
    if (kugou.qrStatus == KugouQrStatus.expired) {
      return _RefreshQr(
          onTap: () => context.read<KugouAuthProvider>().startQrLogin());
    }
    final Uint8List? bytes = _decode(kugou.qrImage);
    if (kugou.qrLoading || bytes == null) return const _QrSpinner();
    return Image.memory(bytes, width: size, height: size, gaplessPlayback: true);
  }

  static Uint8List? _decode(String? dataUrl) {
    if (dataUrl == null || dataUrl.isEmpty) return null;
    final int comma = dataUrl.indexOf(',');
    final String b64 = comma >= 0 ? dataUrl.substring(comma + 1) : dataUrl;
    try {
      return base64Decode(b64);
    } catch (_) {
      return null;
    }
  }
}

class _QrSpinner extends StatelessWidget {
  const _QrSpinner();

  @override
  Widget build(BuildContext context) => const SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
}

class _RefreshQr extends StatelessWidget {
  final VoidCallback onTap;
  const _RefreshQr({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.refresh_rounded, color: AppColors.bg, size: 32),
          SizedBox(height: 4),
          Text('点击刷新', style: TextStyle(color: AppColors.bg, fontSize: 12)),
        ],
      ),
    );
  }
}

class _NeteaseStatus extends StatelessWidget {
  const _NeteaseStatus();

  @override
  Widget build(BuildContext context) {
    final QrStatus status = context.select<AuthProvider, QrStatus>(
        (AuthProvider a) => a.qrStatus);
    final bool loading =
        context.select<AuthProvider, bool>((AuthProvider a) => a.qrLoading);
    return _StatusText(_neteaseLabel(status, loading),
        ok: status == QrStatus.authorized);
  }

  static String _neteaseLabel(QrStatus status, bool loading) {
    if (loading) return '正在生成二维码…';
    switch (status) {
      case QrStatus.waitingScan:
        return '等待扫描';
      case QrStatus.scanned:
        return '已扫描 — 请在手机上确认';
      case QrStatus.authorized:
        return '登录成功';
      case QrStatus.expired:
        return '二维码已过期，点击刷新';
      case QrStatus.invalidated:
        return '二维码已失效，点击刷新';
      case QrStatus.unknown:
        return '正在生成二维码…';
    }
  }
}

class _KugouStatus extends StatelessWidget {
  const _KugouStatus();

  @override
  Widget build(BuildContext context) {
    final KugouQrStatus status = context.select<KugouAuthProvider, KugouQrStatus>(
        (KugouAuthProvider a) => a.qrStatus);
    final bool loading = context.select<KugouAuthProvider, bool>(
        (KugouAuthProvider a) => a.qrLoading);
    return _StatusText(_kugouLabel(status, loading),
        ok: status == KugouQrStatus.confirmed);
  }

  static String _kugouLabel(KugouQrStatus status, bool loading) {
    if (loading) return '正在生成二维码…';
    switch (status) {
      case KugouQrStatus.waiting:
        return '等待扫描';
      case KugouQrStatus.scanned:
        return '已扫描 — 请在手机上确认';
      case KugouQrStatus.confirmed:
        return '登录成功';
      case KugouQrStatus.expired:
        return '二维码已失效，点击刷新';
      case KugouQrStatus.unknown:
        return '正在生成二维码…';
    }
  }
}

class _StatusText extends StatelessWidget {
  final String text;
  final bool ok;

  const _StatusText(this.text, {required this.ok});

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: AppTypography.caption.copyWith(
          color: ok ? AppColors.accentPlay : AppColors.onSurfaceMuted),
      textAlign: TextAlign.center,
    );
  }
}

/// Prominent entry to the full multi-account manager (`/accounts`).
class _AccountsManagerTile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return GlassContainer(
      padding: EdgeInsets.zero,
      child: ListTile(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppDimens.radiusMd),
        ),
        leading: const Icon(Icons.manage_accounts_outlined,
            color: AppColors.onSurface),
        title: Text('账号管理', style: AppTypography.body),
        subtitle: Text('管理网易云 / 酷狗账号，酷狗支持多账号切换',
            style: AppTypography.caption),
        trailing: const Icon(Icons.chevron_right_rounded,
            color: AppColors.onSurfaceMuted),
        onTap: () => context.push(Routes.accounts),
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
