import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../models/qr_login.dart';
import '../../state/auth_provider.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_dimens.dart';
import '../../theme/app_typography.dart';

/// QR-login page. Starts [AuthProvider.startQrLogin] on init, renders
/// [AuthProvider.qrContent] with `qr_flutter`, reflects the [QrStatus] lifecycle
/// (waiting / scanned / expired) with a refresh on expiry, and on authorization
/// refreshes the login state and pops.
class QrLoginPage extends StatefulWidget {
  const QrLoginPage({super.key});

  @override
  State<QrLoginPage> createState() => _QrLoginPageState();
}

class _QrLoginPageState extends State<QrLoginPage> {
  static const double _qrSize = 220;

  AuthProvider? _auth;
  bool _handledAuthorized = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<AuthProvider>().startQrLogin();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _auth = context.read<AuthProvider>();
  }

  @override
  void dispose() {
    _auth?.cancelQrLogin();
    super.dispose();
  }

  void _refresh() {
    _handledAuthorized = false;
    context.read<AuthProvider>().startQrLogin();
  }

  void _onAuthorized() {
    if (_handledAuthorized) return;
    _handledAuthorized = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      // Reconcile cookie/login state (populates auth.account for the success
      // line) before leaving the page.
      await context.read<AuthProvider>().refreshLoginState();
      if (!mounted) return;
      // Brief beat so the "Logged in" confirmation is actually visible.
      await Future<void>.delayed(const Duration(milliseconds: 900));
      if (mounted && context.canPop()) context.pop();
    });
  }

  @override
  Widget build(BuildContext context) {
    final AuthProvider auth = context.watch<AuthProvider>();
    if (auth.qrStatus == QrStatus.authorized) {
      _onAuthorized();
    }

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          tooltip: 'Close',
          icon: const Icon(
            Icons.arrow_back_ios_new_rounded,
            color: AppColors.onSurface,
            size: 20,
          ),
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
                const Text('Scan to log in', style: AppTypography.displayM),
                const SizedBox(height: AppDimens.space12),
                Text(
                  'Open NetEase Cloud Music, then Scan',
                  style: AppTypography.label,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppDimens.space32),
                _QrPanel(
                  size: _qrSize,
                  auth: auth,
                  onRefresh: _refresh,
                ),
                const SizedBox(height: AppDimens.space24),
                _StatusLine(
                  status: auth.qrStatus,
                  loading: auth.qrLoading,
                  nickname: auth.account?.nickname,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The bordered QR surface: spinner while creating, the QR code while live, or a
/// refresh affordance once expired / invalidated.
class _QrPanel extends StatelessWidget {
  final double size;
  final AuthProvider auth;
  final VoidCallback onRefresh;

  const _QrPanel({
    required this.size,
    required this.auth,
    required this.onRefresh,
  });

  bool get _expired =>
      auth.qrStatus == QrStatus.expired ||
      auth.qrStatus == QrStatus.invalidated;

  @override
  Widget build(BuildContext context) {
    final double side = size + AppDimens.space24;
    return Container(
      width: side,
      height: side,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        // QR codes need a light, opaque field for reliable scanning.
        color: AppColors.onSurface,
        borderRadius: BorderRadius.circular(AppDimens.radiusLg),
        boxShadow: AppDimens.glassShadow,
      ),
      child: _buildContent(),
    );
  }

  Widget _buildContent() {
    if (auth.qrStatus == QrStatus.authorized) {
      return const _SuccessOverlay();
    }
    if (_expired) {
      return _RefreshOverlay(onRefresh: onRefresh);
    }
    final String? content = auth.qrContent;
    if (auth.qrLoading || content == null || content.isEmpty) {
      return const SizedBox(
        width: 28,
        height: 28,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    return QrImageView(
      data: content,
      size: size,
      backgroundColor: AppColors.onSurface,
    );
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
          Text(
            'Tap to refresh',
            style: AppTypography.label.copyWith(color: AppColors.bg),
          ),
        ],
      ),
    );
  }
}

/// The green success affordance shown on the (otherwise QR) panel once the scan
/// is authorized, just before the page pops.
class _SuccessOverlay extends StatelessWidget {
  const _SuccessOverlay();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const Icon(
          Icons.check_circle_rounded,
          color: AppColors.accentPlay,
          size: 48,
        ),
        const SizedBox(height: AppDimens.space8),
        Text(
          'Logged in',
          style: AppTypography.label.copyWith(color: AppColors.bg),
        ),
      ],
    );
  }
}

class _StatusLine extends StatelessWidget {
  final QrStatus status;
  final bool loading;
  final String? nickname;

  const _StatusLine({
    required this.status,
    required this.loading,
    this.nickname,
  });

  @override
  Widget build(BuildContext context) {
    final bool authorized = status == QrStatus.authorized;
    return Text(
      _label(),
      style: AppTypography.body.copyWith(
        color: authorized ? AppColors.accentPlay : AppColors.onSurfaceMuted,
      ),
      textAlign: TextAlign.center,
    );
  }

  String _label() {
    if (loading) return 'Preparing QR code…';
    switch (status) {
      case QrStatus.waitingScan:
        return 'Waiting for scan';
      case QrStatus.scanned:
        return 'Scanned — confirm on your phone';
      case QrStatus.authorized:
        final String? name = nickname;
        return (name != null && name.isNotEmpty)
            ? 'Logged in as $name'
            : 'Logged in';
      case QrStatus.expired:
        return 'QR code expired';
      case QrStatus.invalidated:
        return 'QR code invalidated';
      case QrStatus.unknown:
        return 'Preparing QR code…';
    }
  }
}
