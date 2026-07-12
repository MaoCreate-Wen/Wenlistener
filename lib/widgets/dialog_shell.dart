import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../pages/playlist/desktop_kit.dart';
import '../theme/app_colors.dart';
import '../theme/app_dimens.dart';
import '../theme/app_typography.dart';

/// Shared glass dialog shell for the desktop overlays (账号管理 / 设置 / 登录).
///
/// A centered [DkGlass] panel (max [width], max-height 85% viewport, scrollable
/// body) with a `title …… ✕` header, `barrierDismissible: true` (click-away) and
/// **Esc-to-close** via a [CallbackShortcuts] + autofocused [Focus]. Replaces the
/// old dead-end full-screen routes so every overlay is dismissible with a clear
/// affordance.
Future<T?> showWenDialog<T>(
  BuildContext context, {
  required String title,
  required Widget child,
  double width = 720,
}) {
  return showDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    builder: (BuildContext ctx) {
      final double maxH = MediaQuery.of(ctx).size.height * 0.85;
      return Center(
        child: CallbackShortcuts(
          bindings: <ShortcutActivator, VoidCallback>{
            const SingleActivator(LogicalKeyboardKey.escape): () =>
                Navigator.of(ctx).maybePop(),
          },
          child: Focus(
            autofocus: true,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: width, maxHeight: maxH),
              child: DkGlass(
                blur: AppDimens.blurPanel,
                padding: EdgeInsets.zero,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        AppDimens.space24,
                        AppDimens.space16,
                        AppDimens.space12,
                        AppDimens.space12,
                      ),
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(title, style: AppTypography.titleL),
                          ),
                          DkHoverIcon(
                            icon: Icons.close_rounded,
                            tooltip: '关闭 (Esc)',
                            onTap: () => Navigator.of(ctx).maybePop(),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1, color: AppColors.glassBorder),
                    Flexible(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(AppDimens.space24),
                        child: child,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}
