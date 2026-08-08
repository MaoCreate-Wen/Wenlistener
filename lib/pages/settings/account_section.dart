import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/kugou_account.dart';
import '../../models/kugougn_account.dart';
import '../../models/qqcn_login.dart';
import '../../models/qr_login.dart';
import '../../models/song.dart';
import '../../services/netease_api.dart' show NeteaseAccount;
import '../../state/auth_provider.dart';
import '../../state/kugou_auth_provider.dart';
import '../../state/kugougn_auth_provider.dart';
import '../../state/kuwo_auth_provider.dart';
import '../../state/qqcn_auth_provider.dart';
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
      case MusicSource.migu: // web QQ 已移除（墓碑枚举，不会作为源出现）。
        return const SizedBox.shrink();
      case MusicSource.kugou:
        return const _KugouPanel();
      case MusicSource.kugougn:
        return const _KugougnPanel();
      case MusicSource.kuwo:
        return const _KuwoPanel();
      case MusicSource.qqcn:
        return const _QqcnPanel();
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
// QQ 音乐（安卓客户端）— independent qqcn source (own provider, own session)
// ---------------------------------------------------------------------------

class _QqcnPanel extends StatefulWidget {
  const _QqcnPanel();

  @override
  State<_QqcnPanel> createState() => _QqcnPanelState();
}

class _QqcnPanelState extends State<_QqcnPanel> {
  bool _expanded = false;

  @override
  void dispose() {
    if (_expanded) {
      context.read<QqcnAuthProvider>().cancelLogin();
    }
    super.dispose();
  }

  void _start(QqcnLoginMethod method) {
    setState(() => _expanded = true);
    context.read<QqcnAuthProvider>().startLogin(method);
  }

  void _cancel() {
    context.read<QqcnAuthProvider>().cancelLogin();
    setState(() => _expanded = false);
  }

  @override
  Widget build(BuildContext context) {
    final QqcnAuthProvider auth = context.watch<QqcnAuthProvider>();
    if (auth.isLoggedIn) {
      final QqcnAccount? a = auth.account;
      return _AccountSummary(
        avatarUrl: a?.avatarUrl,
        nickname: a?.nickname ?? 'QQ音乐用户',
        vipLabel: (a?.isVip ?? false) ? '绿钻' : null,
        onLogout: () => auth.logout(),
      );
    }
    if (!_expanded) {
      return _LoginPrompt(
        message: '登录 QQ音乐（安卓客户端，支持 QQ / 微信 扫码）以解锁会员曲目。',
        onReveal: () => _start(QqcnLoginMethod.qq),
        fullPageSource: MusicSource.qqcn,
      );
    }
    // 两条路：QQ = ptlogin（手机QQ），微信 = 微信开放平台 OAuth。
    final bool wx = auth.method == QqcnLoginMethod.wechat;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _QqcnMethodToggle(method: auth.method, onChanged: _start),
        const SizedBox(height: AppDimens.space16),
        _QrInline(
          content: null,
          bytes: auth.qrImage,
          loading: auth.qrLoading,
          statusText: auth.finishingLogin
              ? '正在登录…'
              : _qqcnStatus(auth.qrStatus, wechat: wx),
          onRefresh: () => _start(auth.method),
          onCancel: _cancel,
        ),
      ],
    );
  }
}

class _QqcnMethodToggle extends StatelessWidget {
  final QqcnLoginMethod method;
  final void Function(QqcnLoginMethod) onChanged;
  const _QqcnMethodToggle({required this.method, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        _chip('QQ 扫码', method == QqcnLoginMethod.qq,
            () => onChanged(QqcnLoginMethod.qq)),
        const SizedBox(width: AppDimens.space8),
        _chip('微信 扫码', method == QqcnLoginMethod.wechat,
            () => onChanged(QqcnLoginMethod.wechat)),
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

String _qqcnStatus(QqcnQrStatus s, {bool wechat = false}) {
  switch (s) {
    case QqcnQrStatus.waiting:
      return wechat ? '请使用微信扫描二维码' : '请使用手机 QQ 扫描二维码';
    case QqcnQrStatus.scanned:
      return '已扫描，请在手机上确认';
    case QqcnQrStatus.confirmed:
      return '登录成功';
    case QqcnQrStatus.expired:
      return '二维码已过期，请刷新';
    case QqcnQrStatus.canceled:
      return '已取消，请刷新重试';
    case QqcnQrStatus.unknown:
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
// Kugou 概念版 (phone + SMS login, with 每日签到)
// ---------------------------------------------------------------------------

class _KugougnPanel extends StatefulWidget {
  const _KugougnPanel();

  @override
  State<_KugougnPanel> createState() => _KugougnPanelState();
}

class _KugougnPanelState extends State<_KugougnPanel> {
  bool _expanded = false;
  final TextEditingController _phone = TextEditingController();
  final TextEditingController _code = TextEditingController();

  @override
  void dispose() {
    _phone.dispose();
    _code.dispose();
    super.dispose();
  }

  void _reveal() {
    setState(() => _expanded = true);
    context.read<KugougnAuthProvider>().resetLogin();
  }

  Future<void> _sendCode() async {
    final String phone = _phone.text.trim();
    if (phone.isEmpty) return;
    await context.read<KugougnAuthProvider>().sendMobileCode(phone);
  }

  Future<void> _submit() async {
    final KugougnAuthProvider auth = context.read<KugougnAuthProvider>();
    await auth.loginWithVerifyCode(_phone.text.trim(), _code.text.trim());
    if (!mounted) return;
    if (auth.isLoggedIn) dkToast(context, '登录成功');
  }

  @override
  Widget build(BuildContext context) {
    final KugougnAuthProvider auth = context.watch<KugougnAuthProvider>();
    if (auth.isLoggedIn) {
      final KugougnAccount? a = auth.active;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _AccountSummary(
            avatarUrl: a?.avatarUrl,
            nickname: a?.nickname ?? '概念版用户',
            vipLabel: (a?.isVip ?? false) ? '概念版VIP' : null,
            onLogout: () {
              final String? id = auth.activeUserId;
              if (id != null) auth.removeAccount(id);
            },
          ),
          const SizedBox(height: AppDimens.space12),
          Row(
            children: <Widget>[
              DkSecondaryButton(
                label: auth.signingIn ? '签到中…' : '每日签到领VIP',
                onPressed: auth.signingIn ? null : () => auth.signInDaily(),
              ),
              if (auth.signInMessage != null) ...<Widget>[
                const SizedBox(width: AppDimens.space12),
                Expanded(
                  child: Text(
                    auth.signInMessage!,
                    style: AppTypography.caption
                        .copyWith(color: AppColors.onFaint),
                  ),
                ),
              ],
            ],
          ),
        ],
      );
    }
    if (!_expanded) {
      return _LoginPrompt(
        message: '登录酷狗概念版（手机号+验证码）以解锁完整播放与每日签到。',
        onReveal: _reveal,
        actionLabel: '登录',
        actionIcon: Icons.login_rounded,
        fullPageSource: MusicSource.kugougn,
      );
    }
    final bool sending = auth.loginStage == KugougnLoginStage.sendingCode;
    final bool loggingIn = auth.loginStage == KugougnLoginStage.loggingIn;
    final bool codeReady = auth.awaitingCode;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _field(_phone, '手机号', Icons.smartphone_rounded,
            keyboardType: TextInputType.phone),
        const SizedBox(height: AppDimens.space12),
        Row(
          children: <Widget>[
            Expanded(
              child: _field(_code, '短信验证码', Icons.sms_outlined,
                  keyboardType: TextInputType.number),
            ),
            const SizedBox(width: AppDimens.space12),
            DkSecondaryButton(
              label: sending ? '发送中…' : '获取验证码',
              onPressed: sending ? null : _sendCode,
            ),
          ],
        ),
        if (auth.loginError != null) ...<Widget>[
          const SizedBox(height: AppDimens.space12),
          Text(auth.loginError!,
              style: AppTypography.caption
                  .copyWith(color: const Color(0xFFEF4444))),
        ],
        const SizedBox(height: AppDimens.space16),
        Row(
          children: <Widget>[
            DkPrimaryButton(
              icon: Icons.login_rounded,
              label: loggingIn ? '登录中…' : '登录',
              onPressed: (loggingIn || !codeReady) ? null : _submit,
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
    TextInputType? keyboardType,
  }) {
    return TextField(
      controller: c,
      keyboardType: keyboardType,
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
