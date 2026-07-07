import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../models/qq_login.dart';
import '../../state/qq_auth_provider.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_dimens.dart';
import '../../theme/app_typography.dart';

/// Full-screen QQ Music scan-login. Offers BOTH methods (微信 / QQ, per
/// QQMUSIC_API.md) via a toggle; auto-starts on init, and on confirmation the
/// [QqAuthProvider] finishes the OAuth handoff and this pops.
class QqQrLoginPage extends StatefulWidget {
  const QqQrLoginPage({super.key});

  @override
  State<QqQrLoginPage> createState() => _QqQrLoginPageState();
}

class _QqQrLoginPageState extends State<QqQrLoginPage> {
  static const double _qrSize = 220;

  QqAuthProvider? _auth;
  QqLoginMethod _method = QqLoginMethod.wechat;
  bool _handled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<QqAuthProvider>().startLogin(_method);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _auth = context.read<QqAuthProvider>();
  }

  @override
  void dispose() {
    _auth?.cancelLogin();
    super.dispose();
  }

  void _setMethod(QqLoginMethod m) {
    if (m == _method) return;
    setState(() {
      _method = m;
      _handled = false;
    });
    context.read<QqAuthProvider>().startLogin(m);
  }

  void _onConfirmed() {
    if (_handled) return;
    _handled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await Future<void>.delayed(const Duration(milliseconds: 900));
      if (mounted && context.canPop()) context.pop();
    });
  }

  @override
  Widget build(BuildContext context) {
    final QqAuthProvider auth = context.watch<QqAuthProvider>();
    if (auth.qrStatus == QqQrStatus.confirmed && auth.isLoggedIn) {
      _onConfirmed();
    }

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          tooltip: '关闭',
          icon: const Icon(Icons.arrow_back_ios_new_rounded,
              color: AppColors.onSurface, size: 20),
          onPressed: () {
            if (context.canPop()) context.pop();
          },
        ),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppDimens.space24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Text('扫码登录 QQ音乐', style: AppTypography.displayM),
                const SizedBox(height: AppDimens.space12),
                Text(
                  _method == QqLoginMethod.wechat
                      ? '用微信「扫一扫」，登录后可搜索与播放'
                      : '打开手机 QQ「扫一扫」，登录后可搜索与播放',
                  style: AppTypography.label,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppDimens.space20),
                _MethodToggle(method: _method, onChanged: _setMethod),
                const SizedBox(height: AppDimens.space24),
                _QrPanel(size: _qrSize, auth: auth, method: _method),
                const SizedBox(height: AppDimens.space20),
                _StatusLine(
                  status: auth.qrStatus,
                  loading: auth.qrLoading,
                  isLoggedIn: auth.isLoggedIn,
                  finishing: auth.finishingLogin,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _QrPanel extends StatelessWidget {
  final double size;
  final QqAuthProvider auth;
  final QqLoginMethod method;

  const _QrPanel({required this.size, required this.auth, required this.method});

  @override
  Widget build(BuildContext context) {
    final double side = size + AppDimens.space24;
    return Container(
      width: side,
      height: side,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.onSurface,
        borderRadius: BorderRadius.circular(AppDimens.radiusLg),
        boxShadow: AppDimens.glassShadow,
      ),
      child: _content(context),
    );
  }

  Widget _content(BuildContext context) {
    if (auth.qrStatus == QqQrStatus.confirmed && auth.isLoggedIn) {
      return const Icon(Icons.check_circle_rounded,
          color: AppColors.accentPlay, size: 48);
    }
    if (auth.qrStatus == QqQrStatus.expired ||
        auth.qrStatus == QqQrStatus.canceled) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => context.read<QqAuthProvider>().startLogin(method),
        child: const Icon(Icons.refresh_rounded, color: AppColors.bg, size: 40),
      );
    }
    final Uint8List? bytes = auth.qrImage;
    if (auth.qrLoading || bytes == null) {
      return const SizedBox(
        width: 28,
        height: 28,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    return Image.memory(bytes, width: size, height: size, gaplessPlayback: true);
  }
}

class _MethodToggle extends StatelessWidget {
  final QqLoginMethod method;
  final ValueChanged<QqLoginMethod> onChanged;

  const _MethodToggle({required this.method, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.surfaceGlass,
        borderRadius: BorderRadius.circular(AppDimens.radiusPill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _seg('微信扫码', QqLoginMethod.wechat),
          _seg('QQ扫码', QqLoginMethod.qq),
        ],
      ),
    );
  }

  Widget _seg(String label, QqLoginMethod m) {
    final bool active = m == method;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onChanged(m),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 9),
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
          ),
        ),
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  final QqQrStatus status;
  final bool loading;
  final bool isLoggedIn;
  final bool finishing;

  const _StatusLine({
    required this.status,
    required this.loading,
    required this.isLoggedIn,
    required this.finishing,
  });

  @override
  Widget build(BuildContext context) {
    return Text(
      _label(),
      style: AppTypography.body.copyWith(
        color: isLoggedIn ? AppColors.accentPlay : AppColors.onSurfaceMuted,
      ),
      textAlign: TextAlign.center,
    );
  }

  String _label() {
    if (loading) return '正在生成二维码…';
    if (finishing) return '扫码成功，正在完成登录…';
    switch (status) {
      case QqQrStatus.waiting:
        return '等待扫描';
      case QqQrStatus.scanned:
        return '已扫描 — 请在手机上确认';
      case QqQrStatus.confirmed:
        // Scan confirmed but the OAuth handoff didn't land a session cookie.
        return isLoggedIn ? '登录成功' : '登录未完成（未获取到会话），请重试';
      case QqQrStatus.expired:
        return '二维码已过期，点击刷新';
      case QqQrStatus.canceled:
        return '已取消，点击刷新';
      case QqQrStatus.unknown:
        return '正在生成二维码…';
    }
  }
}
