import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/kugou_account.dart';
import '../../models/kugougn_account.dart';
import '../../models/qqcn_login.dart';
import '../../models/qr_login.dart';
import '../../state/auth_provider.dart';
import '../../state/kugou_auth_provider.dart';
import '../../state/kugougn_auth_provider.dart';
import '../../state/kuwo_auth_provider.dart';
import '../../state/qqcn_auth_provider.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_dimens.dart';
import '../../theme/app_typography.dart';
import '../playlist/desktop_kit.dart';

/// Per-source login body, hosted by [showLoginDialog]. QR for netease / qq /
/// kugou; a password + captcha form for kuwo. The QR auto-starts on mount and is
/// cancelled on dispose; on success the dialog closes automatically. [source] is
/// the token (`netease` / `qq` / `kugou` / `kuwo`).
class LoginPanel extends StatelessWidget {
  final String source;
  const LoginPanel({super.key, required this.source});

  @override
  Widget build(BuildContext context) {
    Widget body;
    switch (source) {
      case 'qqcn':
        body = const _QqcnLogin();
      case 'kugou':
        body = const _KugouLogin();
      case 'kugougn':
        body = const _KugougnLogin();
      case 'kuwo':
        body = const _KuwoLogin();
      case 'netease':
      default:
        body = const _NeteaseLogin();
    }
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: body,
      ),
    );
  }
}

/// A success panel shown once the source reports logged-in; auto-closes the login
/// dialog after a beat so the user lands back where they started.
class _LoginSuccess extends StatefulWidget {
  const _LoginSuccess();

  @override
  State<_LoginSuccess> createState() => _LoginSuccessState();
}

class _LoginSuccessState extends State<_LoginSuccess> {
  @override
  void initState() {
    super.initState();
    Future<void>.delayed(const Duration(milliseconds: 900), () {
      if (mounted) Navigator.of(context).maybePop();
    });
  }

  @override
  Widget build(BuildContext context) {
    final Color accent = AppColors.accentOf(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(Icons.check_circle_rounded, color: accent, size: 56),
        const SizedBox(height: AppDimens.space16),
        Text('登录成功', style: AppTypography.titleL),
        const SizedBox(height: AppDimens.space8),
        Text('正在返回…', style: AppTypography.label),
      ],
    );
  }
}

/// Common QR column: title + card + status + refresh.
class _QrColumn extends StatelessWidget {
  final String title;
  final String? content;
  final Uint8List? bytes;
  final bool loading;
  final String status;
  final VoidCallback onRefresh;
  final Widget? extraTop;

  const _QrColumn({
    required this.title,
    required this.content,
    required this.bytes,
    required this.loading,
    required this.status,
    required this.onRefresh,
    this.extraTop,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(title, style: AppTypography.titleM),
        const SizedBox(height: AppDimens.space20),
        if (extraTop != null) ...<Widget>[
          extraTop!,
          const SizedBox(height: AppDimens.space20),
        ],
        DkQrCard(
          content: content,
          bytes: bytes,
          loading: loading,
          size: 220,
        ),
        const SizedBox(height: AppDimens.space20),
        Text(status, style: AppTypography.label, textAlign: TextAlign.center),
        const SizedBox(height: AppDimens.space16),
        DkSecondaryButton(
          icon: Icons.refresh_rounded,
          label: '刷新二维码',
          onPressed: onRefresh,
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Netease
// ---------------------------------------------------------------------------

class _NeteaseLogin extends StatefulWidget {
  const _NeteaseLogin();

  @override
  State<_NeteaseLogin> createState() => _NeteaseLoginState();
}

class _NeteaseLoginState extends State<_NeteaseLogin> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AuthProvider>().startQrLogin();
    });
  }

  @override
  void dispose() {
    context.read<AuthProvider>().cancelQrLogin();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AuthProvider auth = context.watch<AuthProvider>();
    if (auth.isLoggedIn) return const _LoginSuccess();
    return _QrColumn(
      title: '网易云音乐扫码登录',
      content: auth.qrContent,
      bytes: null,
      loading: auth.qrLoading,
      status: _neteaseStatus(auth.qrStatus),
      onRefresh: () => context.read<AuthProvider>().startQrLogin(),
    );
  }
}

String _neteaseStatus(QrStatus s) {
  switch (s) {
    case QrStatus.waitingScan:
      return '请使用网易云音乐 App 扫描上方二维码';
    case QrStatus.scanned:
      return '已扫描，请在手机上确认登录';
    case QrStatus.authorized:
      return '登录成功';
    case QrStatus.expired:
      return '二维码已过期，请点击刷新';
    case QrStatus.invalidated:
      return '二维码已失效，请点击刷新';
    case QrStatus.unknown:
      return '正在生成二维码…';
  }
}


// ---------------------------------------------------------------------------
// QQ 音乐（安卓客户端）— independent qqcn source
// ---------------------------------------------------------------------------

class _QqcnLogin extends StatefulWidget {
  const _QqcnLogin();

  @override
  State<_QqcnLogin> createState() => _QqcnLoginState();
}

class _QqcnLoginState extends State<_QqcnLogin> {
  // Cached in didChangeDependencies so dispose() never does an unsafe
  // context.read on a deactivated element (that throws "ancestor is unsafe").
  QqcnAuthProvider? _auth;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<QqcnAuthProvider>().startLogin(QqcnLoginMethod.qq);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _auth = context.read<QqcnAuthProvider>();
  }

  @override
  void dispose() {
    _auth?.cancelLogin();
    super.dispose();
  }

  void _start(QqcnLoginMethod m) =>
      context.read<QqcnAuthProvider>().startLogin(m);

  @override
  Widget build(BuildContext context) {
    final QqcnAuthProvider auth = context.watch<QqcnAuthProvider>();
    if (auth.isLoggedIn) return const _LoginSuccess();
    // 桌面端两条路（QQmusic_Android/analysis/progress.md L266-288）：
    // QQ = ptlogin（手机QQ 扫码），微信 = 微信开放平台 OAuth（微信 App 扫码）。
    final bool wx = auth.method == QqcnLoginMethod.wechat;
    return _QrColumn(
      title: 'QQ音乐(安卓)扫码登录',
      content: null,
      bytes: auth.qrImage,
      loading: auth.qrLoading,
      status: auth.finishingLogin
          ? '正在登录…'
          : _qqcnStatus(auth.qrStatus, wechat: wx),
      onRefresh: () => _start(auth.method),
      extraTop: _QqcnMethodToggle(method: auth.method, onChanged: _start),
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
      mainAxisSize: MainAxisSize.min,
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
      return wechat ? '请使用微信扫描上方二维码' : '请使用手机 QQ 扫描上方二维码';
    case QqcnQrStatus.scanned:
      return '已扫描，请在手机上确认';
    case QqcnQrStatus.confirmed:
      return '登录成功';
    case QqcnQrStatus.expired:
      return '二维码已过期，请点击刷新';
    case QqcnQrStatus.canceled:
      return '已取消，请点击刷新重试';
    case QqcnQrStatus.unknown:
      return '正在生成二维码…';
  }
}

// ---------------------------------------------------------------------------
// Kugou
// ---------------------------------------------------------------------------

class _KugouLogin extends StatefulWidget {
  const _KugouLogin();

  @override
  State<_KugouLogin> createState() => _KugouLoginState();
}

class _KugouLoginState extends State<_KugouLogin> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<KugouAuthProvider>().startQrLogin();
    });
  }

  @override
  void dispose() {
    context.read<KugouAuthProvider>().cancelQrLogin();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final KugouAuthProvider auth = context.watch<KugouAuthProvider>();
    if (auth.isLoggedIn) return const _LoginSuccess();
    return _QrColumn(
      title: '酷狗音乐扫码登录',
      content: null,
      bytes: dkDecodeDataUrl(auth.qrImage),
      loading: auth.qrLoading,
      status: _kugouStatus(auth.qrStatus),
      onRefresh: () => context.read<KugouAuthProvider>().startQrLogin(),
    );
  }
}

String _kugouStatus(KugouQrStatus s) {
  switch (s) {
    case KugouQrStatus.waiting:
      return '请使用酷狗音乐 App 扫描上方二维码';
    case KugouQrStatus.scanned:
      return '已扫描，请在手机上确认';
    case KugouQrStatus.confirmed:
      return '登录成功';
    case KugouQrStatus.expired:
      return '二维码已过期，请点击刷新';
    case KugouQrStatus.unknown:
      return '正在生成二维码…';
  }
}

// ---------------------------------------------------------------------------
// Kugou 概念版 (phone + SMS verify code)
// ---------------------------------------------------------------------------

class _KugougnLogin extends StatefulWidget {
  const _KugougnLogin();

  @override
  State<_KugougnLogin> createState() => _KugougnLoginState();
}

class _KugougnLoginState extends State<_KugougnLogin> {
  final TextEditingController _phone = TextEditingController();
  final TextEditingController _code = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Fresh flow each visit (the 概念版 backend uses a phone number + SMS verify
    // code, not a scannable QR).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<KugougnAuthProvider>().resetLogin();
    });
  }

  @override
  void dispose() {
    _phone.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _sendCode() async {
    final String phone = _phone.text.trim();
    if (phone.isEmpty) return;
    await context.read<KugougnAuthProvider>().sendMobileCode(phone);
  }

  Future<void> _submit() async {
    await context
        .read<KugougnAuthProvider>()
        .loginWithVerifyCode(_phone.text.trim(), _code.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final KugougnAuthProvider auth = context.watch<KugougnAuthProvider>();
    if (auth.isLoggedIn) return const _LoginSuccess();
    final bool sending = auth.loginStage == KugougnLoginStage.sendingCode;
    final bool loggingIn = auth.loginStage == KugougnLoginStage.loggingIn;
    final bool codeReady = auth.awaitingCode;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text('酷狗概念版登录',
            style: AppTypography.titleM, textAlign: TextAlign.center),
        const SizedBox(height: AppDimens.space8),
        Text('输入手机号获取短信验证码登录',
            style: AppTypography.label, textAlign: TextAlign.center),
        const SizedBox(height: AppDimens.space20),
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
              textAlign: TextAlign.center,
              style: AppTypography.caption
                  .copyWith(color: const Color(0xFFEF4444))),
        ],
        const SizedBox(height: AppDimens.space20),
        Center(
          child: DkPrimaryButton(
            icon: Icons.login_rounded,
            label: loggingIn ? '登录中…' : '登录',
            onPressed: (loggingIn || !codeReady) ? null : _submit,
          ),
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
      onSubmitted: (_) => _submit(),
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

class _KuwoLogin extends StatefulWidget {
  const _KuwoLogin();

  @override
  State<_KuwoLogin> createState() => _KuwoLoginState();
}

class _KuwoLoginState extends State<_KuwoLogin> {
  final TextEditingController _user = TextEditingController();
  final TextEditingController _pass = TextEditingController();
  final TextEditingController _code = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<KuwoAuthProvider>().loadCaptcha();
    });
  }

  @override
  void dispose() {
    _user.dispose();
    _pass.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final KuwoAuthProvider auth = context.read<KuwoAuthProvider>();
    final bool ok = await auth.login(
      username: _user.text.trim(),
      password: _pass.text,
      verifyCode: _code.text.trim(),
    );
    if (!mounted) return;
    if (!ok) {
      _code.clear();
      auth.loadCaptcha();
    }
  }

  @override
  Widget build(BuildContext context) {
    final KuwoAuthProvider auth = context.watch<KuwoAuthProvider>();
    if (auth.isLoggedIn) return const _LoginSuccess();
    final bool busy = auth.step == KuwoLoginStep.loggingIn;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text('酷我音乐登录', style: AppTypography.titleM, textAlign: TextAlign.center),
        const SizedBox(height: AppDimens.space20),
        _field(_user, '账号（手机号）', Icons.person_outline_rounded),
        const SizedBox(height: AppDimens.space12),
        _field(_pass, '密码', Icons.lock_outline_rounded, obscure: true),
        const SizedBox(height: AppDimens.space12),
        Row(
          children: <Widget>[
            Expanded(child: _field(_code, '验证码', Icons.verified_outlined)),
            const SizedBox(width: AppDimens.space12),
            GestureDetector(
              onTap: () => auth.loadCaptcha(),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Container(
                  width: 130,
                  height: 52,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(AppDimens.radiusMd),
                  ),
                  clipBehavior: Clip.antiAlias,
                  alignment: Alignment.center,
                  child: auth.step == KuwoLoginStep.loadingCaptcha
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.black54))
                      : (auth.captchaBytes == null
                          ? const Text('点击获取',
                              style: TextStyle(
                                  color: Colors.black54, fontSize: 12))
                          : Image.memory(auth.captchaBytes!,
                              fit: BoxFit.contain, gaplessPlayback: true)),
                ),
              ),
            ),
          ],
        ),
        if (auth.errorMsg != null) ...<Widget>[
          const SizedBox(height: AppDimens.space12),
          Text(auth.errorMsg!,
              textAlign: TextAlign.center,
              style: AppTypography.caption
                  .copyWith(color: const Color(0xFFEF4444))),
        ],
        const SizedBox(height: AppDimens.space20),
        Center(
          child: DkPrimaryButton(
            icon: Icons.login_rounded,
            label: busy ? '登录中…' : '登录',
            onPressed: busy ? null : _submit,
          ),
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
      onSubmitted: (_) => _submit(),
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
