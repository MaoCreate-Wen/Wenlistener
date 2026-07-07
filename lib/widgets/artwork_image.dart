import 'dart:ui' show lerpDouble;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/image_url.dart';
import '../theme/app_colors.dart';
import '../theme/app_dimens.dart';
import 'skeleton_box.dart';

/// Cached, rounded album art with placeholder/error fallbacks and optional
/// [Hero] support.
///
/// When [heroTag] is set the artwork participates in a shared-element flight
/// driven by [_shuttle], which morphs the corner radius and fades the [shadow]
/// in/out so the cover never pops between endpoints. Both the static tree and
/// the flight render through the same [_ArtworkHeroChild] (backed by a shared
/// [CachedNetworkImageProvider]) so the hand-off is pixel-identical — no
/// placeholder flash, no corner jump.
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

  /// Drive the flight rect with a plain linear [RectTween] instead of the
  /// Material default ([MaterialRectArcTween]). The default arcs the top-left
  /// and bottom-right corners along *separate* curves, so between two squares
  /// of different size/position the rect goes non-square mid-flight — the cover
  /// reads as changing one dimension before the other. Every [ArtworkImage] is
  /// square, and lerping a square begin/end rect linearly keeps width == height
  /// on every frame: the cover scales uniformly (a clean simultaneous zoom)
  /// with a straight-line center move. Preferred over [MaterialRectCenterArcTween]
  /// (which also keeps size linear but bows the center along an arc) because a
  /// direct path reads as a cleaner zoom between the mini-player thumbnail and
  /// the full-screen art. The Hero's own fastOutSlowIn flight curve still eases
  /// the motion in/out.
  static RectTween _rectTween(Rect? begin, Rect? end) =>
      RectTween(begin: begin, end: end);

  /// Custom flight shuttle: lerps the corner radius and fades the drop shadow
  /// between the two endpoints, painting both ends through the identical
  /// [_ArtworkHeroChild] so the image stays put while the chrome morphs. Falls
  /// back to the destination child if either endpoint isn't one of ours.
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
                    s.copyWith(
                      color: s.color.withValues(alpha: s.color.a * t),
                    ),
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

/// The visual payload of an [ArtworkImage]: a clipped, cached cover with an
/// optional drop [shadow]. Shared verbatim by the static tree and the Hero
/// flight shuttle. When [expand] is set the cover fills its parent (used during
/// the flight, where the Hero overlay sizes the rect for us).
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
    final Widget inner = hasUrl
        ? Image(
            image: CachedNetworkImageProvider(
              url!,
              headers: kNeteaseImageHeaders,
            ),
            fit: fit,
            width: expand ? null : size,
            height: expand ? null : size,
            // Keep the previous frame while a new URL decodes; a cached cover
            // then paints on frame 1 (no skeleton flash mid-flight).
            gaplessPlayback: true,
            frameBuilder: (
              BuildContext context,
              Widget child,
              int? frame,
              bool wasSynchronouslyLoaded,
            ) =>
                (wasSynchronouslyLoaded || frame != null)
                    ? child
                    : SkeletonBox(
                        width: size,
                        height: size,
                        radius: resolvedRadius,
                      ),
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
