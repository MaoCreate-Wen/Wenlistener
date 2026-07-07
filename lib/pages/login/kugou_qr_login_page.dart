import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../models/kugou_account.dart';
import '../../state/kugou_auth_provider.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_dimens.dart';
import '../../theme/app_typography.dart';

/// Kugou (酷狗) QR-login page. Starts [KugouAuthProvider.startQrLogin] on init,
/// renders the server-drawn QR PNG (`data:image/png;base64,…`) with Image.memory,
/// reflects the poll lifecycle, and on confirmation adds the account (unlocking
/// full-song playback) and pops.
class KugouQrLoginPage extends StatefulWidget {
  const KugouQrLoginPage({super.key});

  @override
  State<KugouQrLoginPage> createState() => _KugouQrLoginPageState();
}

class _KugouQrLoginPageState extends State<KugouQrLoginPage> {
  static const double _qrSize = 220;

  KugouAuthProvider? _auth;
  bool _handledConfirmed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<KugouAuthProvider>().startQrLogin();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _auth = context.read<KugouAuthProvider>();
  }

  @override
  void dispose() {
    _auth?.cancelQrLogin();
    super.dispose();
  }

  void _refresh() {
    _handledConfirmed = false;
    context.read<KugouAuthProvider>().startQrLogin();
  }

  void _onConfirmed() {
    if (_handledConfirmed) return;
    _handledConfirmed = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await Future<void>.delayed(const Duration(milliseconds: 900));
      if (mounted && context.canPop()) context.pop();
    });
  }

  @override
  Widget build(BuildContext context) {
    final KugouAuthProvider auth = context.watch<KugouAuthProvider>();
    if (auth.qrStatus == KugouQrStatus.confirmed) {
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
                const Text('扫码登录酷狗', style: AppTypography.displayM),
                const SizedBox(height: AppDimens.space12),
                Text(
                  '打开酷狗音乐 App，扫一扫，登录后即可播放完整歌曲',
                  style: AppTypography.label,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppDimens.space32),
                _QrPanel(size: _qrSize, auth: auth, onRefresh: _refresh),
                const SizedBox(height: AppDimens.space24),
                _StatusLine(
                  status: auth.qrStatus,
                  loading: auth.qrLoading,
                  nickname: auth.active?.nickname,
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
  final KugouAuthProvider auth;
  final VoidCallback onRefresh;

  const _QrPanel({
    required this.size,
    required this.auth,
    required this.onRefresh,
  });

  bool get _expired => auth.qrStatus == KugouQrStatus.expired;

  /// Decodes the `data:image/png;base64,…` url to bytes (null when absent/bad).
  Uint8List? get _bytes {
    final String? url = auth.qrImage;
    if (url == null || url.isEmpty) return null;
    final int comma = url.indexOf(',');
    final String b64 = comma >= 0 ? url.substring(comma + 1) : url;
    try {
      return base64Decode(b64);
    } catch (_) {
      return null;
    }
  }

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
      child: _buildContent(),
    );
  }

  Widget _buildContent() {
    if (auth.qrStatus == KugouQrStatus.confirmed) {
      return const _SuccessOverlay();
    }
    if (_expired) {
      return _RefreshOverlay(onRefresh: onRefresh);
    }
    final Uint8List? bytes = _bytes;
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

class _RefreshOverlay extends StatelessWidget {
  final VoidCallback onRefresh;

  const _RefreshOverlay({required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onRefresh,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(Icons.refresh_rounded, color: AppColors.bg, size: 40),
          const SizedBox(height: AppDimens.space8),
          Text('点击刷新二维码',
              style: AppTypography.label.copyWith(color: AppColors.bg)),
        ],
      ),
    );
  }
}

class _SuccessOverlay extends StatelessWidget {
  const _SuccessOverlay();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const Icon(Icons.check_circle_rounded,
            color: AppColors.accentPlay, size: 48),
        const SizedBox(height: AppDimens.space8),
        Text('已登录', style: AppTypography.label.copyWith(color: AppColors.bg)),
      ],
    );
  }
}

class _StatusLine extends StatelessWidget {
  final KugouQrStatus status;
  final bool loading;
  final String? nickname;

  const _StatusLine({
    required this.status,
    required this.loading,
    this.nickname,
  });

  @override
  Widget build(BuildContext context) {
    final bool confirmed = status == KugouQrStatus.confirmed;
    return Text(
      _label(),
      style: AppTypography.body.copyWith(
        color: confirmed ? AppColors.accentPlay : AppColors.onSurfaceMuted,
      ),
      textAlign: TextAlign.center,
    );
  }

  String _label() {
    if (loading) return '正在生成二维码…';
    switch (status) {
      case KugouQrStatus.waiting:
        return '等待扫描';
      case KugouQrStatus.scanned:
        return '已扫描 — 请在手机上确认';
      case KugouQrStatus.confirmed:
        final String? name = nickname;
        return (name != null && name.isNotEmpty) ? '已登录：$name' : '已登录';
      case KugouQrStatus.expired:
        return '二维码已失效';
      case KugouQrStatus.unknown:
        return '正在生成二维码…';
    }
  }
}
