import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/kugou_account.dart';
import '../../models/qq_login.dart';
import '../../models/qr_login.dart';
import '../../models/song.dart';
import '../../services/netease_api.dart' show NeteaseAccount;
import '../../state/auth_provider.dart';
import '../../state/kugou_auth_provider.dart';
import '../../state/kuwo_auth_provider.dart';
import '../../state/qq_auth_provider.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_dimens.dart';
import '../../theme/app_typography.dart';
import '../accounts/accounts_dialog.dart';
import '../login/login_dialog.dart';
import '../playlist/desktop_kit.dart';

/// Inline account panel for the settings 账号 section. Switches on the selected
/// [source] and drives the matching auth provider. Logged in → a summary with
/// 退出登录 / 管理账号; logged out → an inline QR (Netease/QQ/Kugou) or password
/// form (Kuwo).
class AccountSection extends StatelessWidget {
  final MusicSource source;
  const AccountSection({super.key, required this.source});

  @override
  Widget build(BuildContext context) {
    switch (source) {
      case MusicSource.netease:
        return const _NeteasePanel();
      case MusicSource.migu:
        return const _QqPanel();
      case MusicSource.kugou:
        return const _KugouPanel();
      case MusicSource.kuwo:
        return const _KuwoPanel();
      case MusicSource.local:
        return Text('本地音乐无需登录', style: AppTypography.label);
    }
  }
}

// ---------------------------------------------------------------------------
// Shared building blocks
// ---------------------------------------------------------------------------

/// Signed-in summary: avatar + nickname + membership, with logout + manage.
class _AccountSummary extends StatelessWidget {
  final String? avatarUrl;
  final String nickname;
  final String? vipLabel;
  final VoidCallback onLogout;
  final bool showManage;

  const _AccountSummary({
    required this.avatarUrl,
    required this.nickname,
    required this.onLogout,
    this.vipLabel,
    this.showManage = true,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        DkArt(
          url: avatarUrl,
          size: 52,
          circle: true,
          placeholder: Icons.person_rounded,
        ),
        const SizedBox(width: AppDimens.space16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Flexible(
                    child: Text(
                      nickname.isEmpty ? '已登录' : nickname,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.titleM,
                    ),
                  ),
                  if (vipLabel != null) ...<Widget>[
                    const SizedBox(width: AppDimens.space8),
                    DkVipPill(label: vipLabel!),
                  ],
                ],
              ),
              const SizedBox(height: 2),
              Text('已登录', style: AppTypography.caption),
            ],
          ),
        ),
        if (showManage) ...<Widget>[
          DkSecondaryButton(
            icon: Icons.manage_accounts_rounded,
            label: '管理账号',
            onPressed: () => showAccountsDialog(context),
          ),
          const SizedBox(width: AppDimens.space12),
        ],
        DkSecondaryButton(
          icon: Icons.logout_rounded,
          label: '退出登录',
          onPressed: onLogout,
        ),
      ],
    );
  }
}

/// Logged-out prompt with a "扫码登录 / 登录" reveal button + a full-page link.
class _LoginPrompt extends StatelessWidget {
  final String message;
  final String actionLabel;
  final IconData actionIcon;
  final VoidCallback onReveal;
  final MusicSource fullPageSource;

  const _LoginPrompt({
    required this.message,
    required this.onReveal,
    required this.fullPageSource,
    this.actionLabel = '扫码登录',
    this.actionIcon = Icons.qr_code_2_rounded,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        const Icon(Icons.account_circle_outlined,
            color: AppColors.onFaint, size: 40),
        const SizedBox(width: AppDimens.space16),
        Expanded(child: Text(message, style: AppTypography.label)),
        const SizedBox(width: AppDimens.space16),
        DkSecondaryButton(
          icon: Icons.open_in_new_rounded,
          label: '登录页',
          onPressed: () => showLoginDialog(context, fullPageSource),
        ),
        const SizedBox(width: AppDimens.space12),
        DkPrimaryButton(
          icon: actionIcon,
          label: actionLabel,
          onPressed: onReveal,
        ),
      ],
    );
  }
}

/// Inline QR block: the card + a status line + a refresh action.
class _QrInline extends StatelessWidget {
  final String? content;
  final Uint8List? bytes;
  final bool loading;
  final String statusText;
  final VoidCallback onRefresh;
  final VoidCallback onCancel;

  const _QrInline({
    required this.content,
    required this.bytes,
    required this.loading,
    required this.statusText,
    required this.onRefresh,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        DkQrCard(
          content: content,
          bytes: bytes,
          loading: loading,
          size: 176,
        ),
        const SizedBox(width: AppDimens.space24),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('扫码登录', style: AppTypography.titleM),
              const SizedBox(height: AppDimens.space8),
              Text(statusText, style: AppTypography.label),
              const SizedBox(height: AppDimens.space16),
              Row(
                children: <Widget>[
                  DkSecondaryButton(
                    icon: Icons.refresh_rounded,
                    label: '刷新二维码',
                    onPressed: onRefresh,
                  ),
                  const SizedBox(width: AppDimens.space12),
                  DkSecondaryButton(
                    icon: Icons.close_rounded,
                    label: '收起',
                    onPressed: onCancel,
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Netease
// ---------------------------------------------------------------------------

class _NeteasePanel extends StatefulWidget {
  const _NeteasePanel();

  @override
  State<_NeteasePanel> createState() => _NeteasePanelState();
}

class _NeteasePanelState extends State<_NeteasePanel> {
  bool _expanded = false;

  @override
  void dispose() {
    if (_expanded) {
      context.read<AuthProvider>().cancelQrLogin();
    }
    super.dispose();
  }

  void _start() {
    setState(() => _expanded = true);
    context.read<AuthProvider>().startQrLogin();
  }

  void _cancel() {
    context.read<AuthProvider>().cancelQrLogin();
    setState(() => _expanded = false);
  }

  @override
  Widget build(BuildContext context) {
    final AuthProvider auth = context.watch<AuthProvider>();
    if (auth.isLoggedIn) {
      final NeteaseAccount? a = auth.account;
      return _AccountSummary(
        avatarUrl: a?.avatarUrl,
        nickname: a?.nickname ?? '网易云用户',
        vipLabel: (a?.vipType ?? 0) > 0 ? '黑胶VIP' : null,
        onLogout: () => auth.logout(),
      );
    }
    if (!_expanded) {
      return _LoginPrompt(
        message: '登录网易云账号以使用每日推荐、我的歌单与逐字歌词。',
        onReveal: _start,
        fullPageSource: MusicSource.netease,
      );
    }
    return _QrInline(
      content: auth.qrContent,
      bytes: null,
      loading: auth.qrLoading,
      statusText: _neteaseStatus(auth.qrStatus),
      onRefresh: _start,
      onCancel: _cancel,
    );
  }
}

String _neteaseStatus(QrStatus s) {
  switch (s) {
    case QrStatus.waitingScan:
      return '请使用网易云音乐 App 扫描二维码';
    case QrStatus.scanned:
      return '已扫描，请在手机上确认登录';
    case QrStatus.authorized:
      return '登录成功';
    case QrStatus.expired:
      return '二维码已过期，请刷新';
    case QrStatus.invalidated:
      return '二维码已失效，请刷新';
    case QrStatus.unknown:
      return '正在生成二维码…';
  }
}

// ---------------------------------------------------------------------------
// QQ (migu slot)
// ---------------------------------------------------------------------------

class _QqPanel extends StatefulWidget {
  const _QqPanel();

  @override
  State<_QqPanel> createState() => _QqPanelState();
}

class _QqPanelState extends State<_QqPanel> {
  bool _expanded = false;

  @override
  void dispose() {
    if (_expanded) {
      context.read<QqAuthProvider>().cancelLogin();
    }
    super.dispose();
  }

  void _start(QqLoginMethod method) {
    setState(() => _expanded = true);
    context.read<QqAuthProvider>().startLogin(method);
  }

  void _cancel() {
    context.read<QqAuthProvider>().cancelLogin();
    setState(() => _expanded = false);
  }

  @override
  Widget build(BuildContext context) {
    final QqAuthProvider auth = context.watch<QqAuthProvider>();
    if (auth.isLoggedIn) {
      final QqAccount? a = auth.account;
      return _AccountSummary(
        avatarUrl: a?.avatarUrl,
        nickname: a?.nickname ?? 'QQ音乐用户',
        vipLabel: (a?.isVip ?? false) ? '绿钻' : null,
        onLogout: () => auth.logout(),
      );
    }
    if (!_expanded) {
      return _LoginPrompt(
        message: '登录 QQ音乐（支持 微信 / QQ 扫码）以解锁会员曲目。',
        onReveal: () => _start(QqLoginMethod.qq),
        fullPageSource: MusicSource.migu,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _QqMethodToggle(
          method: auth.method,
          onChanged: _start,
        ),
        const SizedBox(height: AppDimens.space16),
        _QrInline(
          content: null,
          bytes: auth.qrImage,
          loading: auth.qrLoading,
          statusText: auth.finishingLogin
              ? '正在登录…'
              : _qqStatus(auth.qrStatus),
          onRefresh: () => _start(auth.method),
          onCancel: _cancel,
        ),
      ],
    );
  }
}

class _QqMethodToggle extends StatelessWidget {
  final QqLoginMethod method;
  final void Function(QqLoginMethod) onChanged;
  const _QqMethodToggle({required this.method, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        _chip('QQ 扫码', method == QqLoginMethod.qq,
            () => onChanged(QqLoginMethod.qq)),
        const SizedBox(width: AppDimens.space8),
        _chip('微信 扫码', method == QqLoginMethod.wechat,
            () => onChanged(QqLoginMethod.wechat)),
      ],
    );
  }

  Widget _chip(String label, bool sel, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: AppDimens.space16, vertical: AppDimens.space8),
          decoration: BoxDecoration(
            color: sel ? AppColors.accentPlay : AppColors.glass,
            borderRadius: BorderRadius.circular(AppDimens.radiusPill),
            border: Border.all(color: AppColors.glassBorder),
          ),
          child: Text(
            label,
            style: AppTypography.label.copyWith(
              color: sel ? Colors.black : AppColors.onMuted,
              fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

String _qqStatus(QqQrStatus s) {
  switch (s) {
    case QqQrStatus.waiting:
      return '请使用对应 App 扫描二维码';
    case QqQrStatus.scanned:
      return '已扫描，请在手机上确认';
    case QqQrStatus.confirmed:
      return '登录成功';
    case QqQrStatus.expired:
      return '二维码已过期，请刷新';
    case QqQrStatus.canceled:
      return '已取消，请刷新重试';
    case QqQrStatus.unknown:
      return '正在生成二维码…';
  }
}

// ---------------------------------------------------------------------------
// Kugou
// ---------------------------------------------------------------------------

class _KugouPanel extends StatefulWidget {
  const _KugouPanel();

  @override
  State<_KugouPanel> createState() => _KugouPanelState();
}

class _KugouPanelState extends State<_KugouPanel> {
  bool _expanded = false;

  @override
  void dispose() {
    if (_expanded) {
      context.read<KugouAuthProvider>().cancelQrLogin();
    }
    super.dispose();
  }

  void _start() {
    setState(() => _expanded = true);
    context.read<KugouAuthProvider>().startQrLogin();
  }

  void _cancel() {
    context.read<KugouAuthProvider>().cancelQrLogin();
    setState(() => _expanded = false);
  }

  @override
  Widget build(BuildContext context) {
    final KugouAuthProvider auth = context.watch<KugouAuthProvider>();
    if (auth.isLoggedIn) {
      final KugouAccount? a = auth.active;
      return _AccountSummary(
        avatarUrl: a?.avatarUrl,
        nickname: a?.nickname ?? '酷狗用户',
        vipLabel: (a?.isVip ?? false) ? '酷狗VIP' : null,
        onLogout: () {
          final String? id = auth.activeUserId;
          if (id != null) auth.removeAccount(id);
        },
      );
    }
    if (!_expanded) {
      return _LoginPrompt(
        message: '登录酷狗账号以解锁完整试听与下载（未登录仅 30 秒）。',
        onReveal: _start,
        fullPageSource: MusicSource.kugou,
      );
    }
    return _QrInline(
      content: null,
      bytes: dkDecodeDataUrl(auth.qrImage),
      loading: auth.qrLoading,
      statusText: _kugouStatus(auth.qrStatus),
      onRefresh: _start,
      onCancel: _cancel,
    );
  }
}

String _kugouStatus(KugouQrStatus s) {
  switch (s) {
    case KugouQrStatus.waiting:
      return '请使用酷狗音乐 App 扫描二维码';
    case KugouQrStatus.scanned:
      return '已扫描，请在手机上确认';
    case KugouQrStatus.confirmed:
      return '登录成功';
    case KugouQrStatus.expired:
      return '二维码已过期，请刷新';
    case KugouQrStatus.unknown:
      return '正在生成二维码…';
  }
}

// ---------------------------------------------------------------------------
// Kuwo (password + captcha)
// ---------------------------------------------------------------------------

class _KuwoPanel extends StatefulWidget {
  const _KuwoPanel();

  @override
  State<_KuwoPanel> createState() => _KuwoPanelState();
}

class _KuwoPanelState extends State<_KuwoPanel> {
  bool _expanded = false;
  final TextEditingController _user = TextEditingController();
  final TextEditingController _pass = TextEditingController();
  final TextEditingController _code = TextEditingController();

  @override
  void dispose() {
    _user.dispose();
    _pass.dispose();
    _code.dispose();
    super.dispose();
  }

  void _reveal() {
    setState(() => _expanded = true);
    context.read<KuwoAuthProvider>().loadCaptcha();
  }

  Future<void> _submit() async {
    final KuwoAuthProvider auth = context.read<KuwoAuthProvider>();
    final bool ok = await auth.login(
      username: _user.text.trim(),
      password: _pass.text,
      verifyCode: _code.text.trim(),
    );
    if (!mounted) return;
    if (ok) {
      dkToast(context, '登录成功');
    } else {
      _code.clear();
      auth.loadCaptcha();
    }
  }

  @override
  Widget build(BuildContext context) {
    final KuwoAuthProvider auth = context.watch<KuwoAuthProvider>();
    if (auth.isLoggedIn) {
      return _AccountSummary(
        avatarUrl: null,
        nickname: '酷我账号',
        onLogout: () => auth.logout(),
        showManage: false,
      );
    }
    if (!_expanded) {
      return _LoginPrompt(
        message: '登录酷我账号（账号密码 + 验证码）以解锁会员曲目。',
        actionLabel: '登录',
        actionIcon: Icons.login_rounded,
        onReveal: _reveal,
        fullPageSource: MusicSource.kuwo,
      );
    }
    final bool busy = auth.step == KuwoLoginStep.loggingIn;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _field(_user, '账号（手机号）', Icons.person_outline_rounded),
        const SizedBox(height: AppDimens.space12),
        _field(_pass, '密码', Icons.lock_outline_rounded, obscure: true),
        const SizedBox(height: AppDimens.space12),
        Row(
          children: <Widget>[
            Expanded(
                child:
                    _field(_code, '验证码', Icons.verified_outlined)),
            const SizedBox(width: AppDimens.space12),
            _CaptchaBox(
              bytes: auth.captchaBytes,
              loading: auth.step == KuwoLoginStep.loadingCaptcha,
              onTap: () => auth.loadCaptcha(),
            ),
          ],
        ),
        if (auth.errorMsg != null) ...<Widget>[
          const SizedBox(height: AppDimens.space12),
          Text(auth.errorMsg!,
              style: AppTypography.caption.copyWith(color: const Color(0xFFEF4444))),
        ],
        const SizedBox(height: AppDimens.space16),
        Row(
          children: <Widget>[
            DkPrimaryButton(
              icon: Icons.login_rounded,
              label: busy ? '登录中…' : '登录',
              onPressed: busy ? null : _submit,
            ),
            const SizedBox(width: AppDimens.space12),
            DkSecondaryButton(
              label: '收起',
              onPressed: () => setState(() => _expanded = false),
            ),
          ],
        ),
      ],
    );
  }

  Widget _field(
    TextEditingController c,
    String hint,
    IconData icon, {
    bool obscure = false,
  }) {
    return TextField(
      controller: c,
      obscureText: obscure,
      style: AppTypography.body,
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: AppTypography.label,
        prefixIcon: Icon(icon, color: AppColors.onFaint, size: 20),
        filled: true,
        fillColor: AppColors.glass,
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppDimens.radiusMd),
          borderSide: const BorderSide(color: AppColors.glassBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppDimens.radiusMd),
          borderSide: const BorderSide(color: AppColors.accentPlay),
        ),
      ),
    );
  }
}

class _CaptchaBox extends StatelessWidget {
  final Uint8List? bytes;
  final bool loading;
  final VoidCallback onTap;

  const _CaptchaBox({
    required this.bytes,
    required this.loading,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          width: 120,
          height: 48,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(AppDimens.radiusMd),
          ),
          clipBehavior: Clip.antiAlias,
          alignment: Alignment.center,
          child: loading
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.black54))
              : (bytes == null
                  ? const Text('点击获取',
                      style: TextStyle(color: Colors.black54, fontSize: 12))
                  : Image.memory(bytes!,
                      fit: BoxFit.contain, gaplessPlayback: true)),
        ),
      ),
    );
  }
}
