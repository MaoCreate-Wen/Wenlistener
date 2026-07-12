import 'dart:ui' show lerpDouble;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/image_url.dart';
import '../theme/app_colors.dart';
import '../theme/app_dimens.dart';
import 'skeleton.dart';

/// Cached, rounded album art with placeholder / error fallbacks and optional
/// shared-element [Hero] flight.
///
/// Netease CDN covers require a browser UA + Referer ([kNeteaseImageHeaders]) or
/// they 403 to placeholders; the headers are harmless on the other backends'
/// CDNs, so every cover is fetched with them (proven on mobile). When [heroTag]
/// is set the artwork morphs its corner radius and fades its [shadow] across a
/// flight via [_shuttle] so the mini-player thumbnail and the full player cover
/// hand off pixel-identically.
class ArtworkImage extends StatelessWidget {
  final String? url;
  final double size;
  final double? radius;
  final String? heroTag;
  final BoxFit fit;
  final List<BoxShadow>? shadow;

  const ArtworkImage({
    super.key,
    required this.url,
    required this.size,
    this.radius,
    this.heroTag,
    this.fit = BoxFit.cover,
    this.shadow,
  });

  @override
  Widget build(BuildContext context) {
    final double r = radius ?? AppDimens.albumRadius(size);
    final Widget child = _ArtworkHeroChild(
      url: url,
      size: size,
      resolvedRadius: r,
      fit: fit,
      shadow: shadow,
    );
    if (heroTag == null) return child;
    return Hero(
      tag: heroTag!,
      createRectTween: _rectTween,
      flightShuttleBuilder: _shuttle,
      child: child,
    );
  }

  static RectTween _rectTween(Rect? begin, Rect? end) =>
      RectTween(begin: begin, end: end);

  static Widget _shuttle(
    BuildContext flightContext,
    Animation<double> animation,
    HeroFlightDirection flightDirection,
    BuildContext fromHeroContext,
    BuildContext toHeroContext,
  ) {
    final Widget fromChild = (fromHeroContext.widget as Hero).child;
    final Widget toChild = (toHeroContext.widget as Hero).child;
    if (fromChild is! _ArtworkHeroChild || toChild is! _ArtworkHeroChild) {
      return toChild;
    }
    final _ArtworkHeroChild a = fromChild;
    final _ArtworkHeroChild b = toChild;
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: animation,
        builder: (BuildContext context, Widget? _) {
          final double t = Curves.easeInOut.transform(animation.value);
          final double r = lerpDouble(a.resolvedRadius, b.resolvedRadius, t)!;
          final List<BoxShadow>? base = b.shadow ?? a.shadow;
          final List<BoxShadow>? sh = base == null
              ? null
              : <BoxShadow>[
                  for (final BoxShadow s in base)
                    s.copyWith(color: s.color.withValues(alpha: s.color.a * t)),
                ];
          return _ArtworkHeroChild(
            url: b.url,
            size: b.size,
            resolvedRadius: r,
            fit: b.fit,
            shadow: sh,
            expand: true,
          );
        },
      ),
    );
  }
}

class _ArtworkHeroChild extends StatelessWidget {
  const _ArtworkHeroChild({
    required this.url,
    required this.size,
    required this.resolvedRadius,
    required this.fit,
    required this.shadow,
    this.expand = false,
  });

  final String? url;
  final double size;
  final double resolvedRadius;
  final BoxFit fit;
  final List<BoxShadow>? shadow;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final bool hasUrl = url != null && url!.isNotEmpty;
    // Decode covers at DISPLAY size, not their native ~1000px — netease covers are large and a
    // grid of full-res decodes balloons memory (each 1000² RGBA ≈ 4 MB). Cap the decode dimension.
    final double dpr = MediaQuery.devicePixelRatioOf(context);
    final int cachePx = ((expand ? 512.0 : size) * dpr).round().clamp(64, 640);
    final Widget inner = hasUrl
        ? Image(
            image: ResizeImage.resizeIfNeeded(
              cachePx,
              cachePx,
              CachedNetworkImageProvider(url!, headers: kNeteaseImageHeaders),
            ),
            fit: fit,
            width: expand ? null : size,
            height: expand ? null : size,
            gaplessPlayback: true,
            frameBuilder: (
              BuildContext context,
              Widget child,
              int? frame,
              bool wasSynchronouslyLoaded,
            ) =>
                (wasSynchronouslyLoaded || frame != null)
                    ? child
                    : Skeleton(
                        width: size, height: size, radius: resolvedRadius),
          )
        : _placeholder();

    Widget clipped = ClipRRect(
      borderRadius: BorderRadius.circular(resolvedRadius),
      child: expand
          ? SizedBox.expand(child: inner)
          : SizedBox(width: size, height: size, child: inner),
    );
    if (shadow != null) {
      clipped = DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(resolvedRadius),
          boxShadow: shadow,
        ),
        child: clipped,
      );
    }
    return clipped;
  }

  Widget _placeholder() => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(resolvedRadius),
        ),
        child: Icon(
          Icons.music_note_rounded,
          color: AppColors.onSurfaceFaint,
          size: size * 0.4,
        ),
      );
}
