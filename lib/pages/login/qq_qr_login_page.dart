import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../models/qqcn_login.dart';
import '../../state/qqcn_auth_provider.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_dimens.dart';
import '../../theme/app_typography.dart';

/// Full-screen QQ 音乐 (Android) scan-login. ONE ptlogin QR — mobile QQ AND WeChat
/// scan the SAME code (no method toggle). Auto-starts on init; on confirmation the
/// [QqcnAuthProvider] runs the OAuth → QQLogin → GetSession handoff and this
/// pops.
class QqQrLoginPage extends StatefulWidget {
  const QqQrLoginPage({super.key});

  @override
  State<QqQrLoginPage> createState() => _QqQrLoginPageState();
}

class _QqQrLoginPageState extends State<QqQrLoginPage> {
  static const double _qrSize = 220;

  QqcnAuthProvider? _auth;
  bool _handled = false;

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
    final QqcnAuthProvider auth = context.watch<QqcnAuthProvider>();
    if (auth.qrStatus == QqcnQrStatus.confirmed && auth.isLoggedIn) {
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
                const Text(
                  '用手机 QQ 或 微信「扫一扫」，登录后可播放完整歌曲',
                  style: AppTypography.label,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppDimens.space24),
                _QrPanel(size: _qrSize, auth: auth),
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
  final QqcnAuthProvider auth;

  const _QrPanel({required this.size, required this.auth});

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
    if (auth.qrStatus == QqcnQrStatus.confirmed && auth.isLoggedIn) {
      return const Icon(Icons.check_circle_rounded,
          color: AppColors.accentPlay, size: 48);
    }
    if (auth.qrStatus == QqcnQrStatus.expired ||
        auth.qrStatus == QqcnQrStatus.canceled) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => context.read<QqcnAuthProvider>().startLogin(QqcnLoginMethod.qq),
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

class _StatusLine extends StatelessWidget {
  final QqcnQrStatus status;
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
      case QqcnQrStatus.waiting:
        return '等待扫描';
      case QqcnQrStatus.scanned:
        return '已扫描 — 请在手机上确认';
      case QqcnQrStatus.confirmed:
        return isLoggedIn ? '登录成功' : '登录未完成（未获取到会话），请重试';
      case QqcnQrStatus.expired:
        return '二维码已过期，点击刷新';
      case QqcnQrStatus.canceled:
        return '已取消，点击刷新';
      case QqcnQrStatus.unknown:
        return '正在生成二维码…';
    }
  }
}
