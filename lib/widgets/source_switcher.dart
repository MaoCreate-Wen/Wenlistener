import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/song.dart';
import '../services/music_api_router.dart';
import '../theme/app_colors.dart';
import '../theme/app_dimens.dart';

/// Compact segmented control for the active music backend (音源). **Migu** is the
/// free anonymous default; **网易云** can be selected manually and is also chosen
/// automatically on login (see `AuthProvider`). Rebuilds on [MusicApiRouter]
/// changes; switching clears stale search results / reloads the home feed via
/// the providers that listen to the router.
class SourceSwitcher extends StatelessWidget {
  const SourceSwitcher({super.key});

  @override
  Widget build(BuildContext context) {
    final MusicApiRouter router = context.watch<MusicApiRouter>();
    final bool isMigu = router.isMigu;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: AppColors.surfaceGlass,
        borderRadius: BorderRadius.circular(AppDimens.radiusPill),
        border: Border.all(color: AppColors.onSurface.withValues(alpha: 0.06)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _segment(
            label: '咪咕',
            active: isMigu,
            onTap: () => router.setSource(MusicSource.migu),
          ),
          _segment(
            label: '网易云',
            active: !isMigu,
            onTap: () => router.setSource(MusicSource.netease),
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
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        decoration: BoxDecoration(
          color: active
              ? AppColors.onSurface.withValues(alpha: 0.16)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(AppDimens.radiusPill),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            color: active ? AppColors.onSurface : AppColors.onSurfaceMuted,
            letterSpacing: 0.2,
          ),
        ),
      ),
    );
  }
}
