import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import '../../../theme/app_dimens.dart';
import '../../../theme/app_typography.dart';
import '../../../widgets/artwork_image.dart';

/// Collapsing playlist header: a blurred full-bleed cover backdrop with a dark
/// scrim, the crisp cover art, title (display face), creator, track count and an
/// accent-tinted play-all CTA. Lives inside the [FlexibleSpaceBar] background.
class PlaylistHeader extends StatelessWidget {
  final String? coverUrl;
  final String title;
  final String? creatorName;
  final int trackCount;
  final int playCount;
  final Color accent;
  final VoidCallback onPlayAll;

  const PlaylistHeader({
    super.key,
    required this.coverUrl,
    required this.title,
    required this.trackCount,
    required this.accent,
    required this.onPlayAll,
    this.creatorName,
    this.playCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    final double topInset = MediaQuery.of(context).padding.top;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        Positioned.fill(child: _Backdrop(coverUrl: coverUrl, accent: accent)),
        const Positioned.fill(child: _Scrim()),
        Positioned(
          left: AppDimens.screenPadding,
          right: AppDimens.screenPadding,
          bottom: AppDimens.space20,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SizedBox(height: topInset + AppDimens.space48),
              DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppDimens.radiusMd),
                  boxShadow: AppDimens.glassShadow,
                ),
                child: ArtworkImage(
                  url: coverUrl,
                  size: 132,
                  radius: AppDimens.radiusMd,
                ),
              ),
              const SizedBox(height: AppDimens.space16),
              Text(
                title,
                style: AppTypography.titleL,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: AppDimens.space4),
              Text(
                _subtitle(),
                style: AppTypography.label,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: AppDimens.space16),
              _PlayAllButton(accent: accent, onTap: onPlayAll),
            ],
          ),
        ),
      ],
    );
  }

  String _subtitle() {
    final List<String> parts = <String>[];
    final String? creator = creatorName?.trim();
    if (creator != null && creator.isNotEmpty) parts.add(creator);
    parts.add('$trackCount首');
    if (playCount > 0) parts.add('播放 ${_compactCount(playCount)}');
    return parts.join('  ·  ');
  }
}

/// Compact CN count: 1234 → "1234", 12345 → "1.2万", 1.2e8 → "1.2亿".
String _compactCount(int n) {
  if (n >= 100000000) return '${_oneDecimal(n / 100000000)}亿';
  if (n >= 10000) return '${_oneDecimal(n / 10000)}万';
  return '$n';
}

String _oneDecimal(double v) {
  final String s = v.toStringAsFixed(1);
  return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
}

/// Blurred, scaled cover used as the header backdrop; falls back to an accent
/// gradient when there is no artwork.
class _Backdrop extends StatelessWidget {
  final String? coverUrl;
  final Color accent;

  const _Backdrop({required this.coverUrl, required this.accent});

  @override
  Widget build(BuildContext context) {
    if (coverUrl == null || coverUrl!.isEmpty) {
      return _fallback();
    }
    return ImageFiltered(
      imageFilter: ImageFilter.blur(sigmaX: 36, sigmaY: 36),
      child: Image(
        image: CachedNetworkImageProvider(coverUrl!),
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        errorBuilder: (BuildContext context, Object error, StackTrace? stack) =>
            _fallback(),
      ),
    );
  }

  Widget _fallback() => DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[
              accent.withValues(alpha: 0.45),
              AppColors.bg,
            ],
          ),
        ),
      );
}

/// Dark vertical scrim so the title/controls stay legible over any artwork and
/// the header fades into the (black) track list below.
class _Scrim extends StatelessWidget {
  const _Scrim();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            Color(0x4D000000),
            Color(0xB3000000),
            AppColors.bg,
          ],
          stops: <double>[0.0, 0.55, 1.0],
        ),
      ),
    );
  }
}

class _PlayAllButton extends StatelessWidget {
  final Color accent;
  final VoidCallback onTap;

  const _PlayAllButton({required this.accent, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final Color onAccent =
        ThemeData.estimateBrightnessForColor(accent) == Brightness.dark
            ? AppColors.onSurface
            : AppColors.bg;
    return Material(
      color: accent,
      borderRadius: BorderRadius.circular(AppDimens.radiusPill),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppDimens.radiusPill),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppDimens.space24,
            vertical: AppDimens.space12,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.play_arrow_rounded, color: onAccent, size: 22),
              const SizedBox(width: AppDimens.space8),
              Text(
                'Play All',
                style: AppTypography.body.copyWith(
                  color: onAccent,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
