import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import '../models/image_url.dart';
import '../services/resource_cache.dart' show DiskCachedImage;
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
/// [DiskCachedImage]) so the hand-off is pixel-identical — no
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
    // Downsample the decode for standalone (non-Hero) thumbnails — the list /
    // grid / carousel covers that dominate the startup and scroll high-water:
    // dozens of them decode a full-resolution (often ~1000²≈4 MB) bitmap just to
    // paint a ~56 px cell. Cap the decode at the display size in device pixels.
    // Hero covers (mini-player ↔ player ↔ lyrics share the `album_art` tag) are
    // deliberately LEFT at full resolution: their seamless, pixel-identical
    // flight relies on all three endpoints resolving the *same*
    // DiskCachedImage key, which a per-size ResizeImage would break
    // (re-decode + skeleton flash mid-flight). One full-res decode for the
    // current song, shared across the trio, is not a peak driver.
    final int? decodeSize = heroTag == null
        ? (size * MediaQuery.devicePixelRatioOf(context)).round()
        : null;
    final Widget child = _ArtworkHeroChild(
      url: url,
      size: size,
      resolvedRadius: r,
      fit: fit,
      shadow: shadow,
      decodeSize: decodeSize,
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
          // No drop shadow DURING the flight: a blurRadius-28 BoxShadow is a
          // Gaussian blur of the cover silhouette re-rasterized every frame over a
          // rect growing to ~380px — the dominant per-frame raster cost of the
          // ~340ms flight (the old code faded only the alpha, `color.a * t`, while
          // still paying the full blur even when it was invisible). The shadow
          // reappears the instant the flight settles: the static _ArtworkHeroChild
          // built by ArtworkImage carries player_page's shadow, so only the
          // mid-zoom frames — where a fading, half-scaled shadow is barely visible
          // — are exempt.
          return _ArtworkHeroChild(
            url: b.url,
            size: b.size,
            resolvedRadius: r,
            fit: b.fit,
            shadow: null,
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
    this.decodeSize,
    this.expand = false,
  });

  final String? url;
  final double size;
  final double resolvedRadius;
  final BoxFit fit;
  final List<BoxShadow>? shadow;

  /// When non-null, decode the cover at this pixel size (via [ResizeImage])
  /// instead of the network original. Set only for standalone thumbnails; left
  /// null for Hero covers so the shared-provider flight stays pixel-identical.
  final int? decodeSize;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final bool hasUrl = url != null && url!.isNotEmpty;
    ImageProvider? provider;
    if (hasUrl) {
      provider = DiskCachedImage(url!, headers: kNeteaseImageHeaders);
      if (decodeSize != null && decodeSize! > 0) {
        provider = ResizeImage(
          provider,
          width: decodeSize,
          height: decodeSize,
          allowUpscaling: false,
        );
      }
    }
    final Widget inner = hasUrl
        ? Image(
            image: provider!,
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
      // Antialiased rounded clip runs an AA edge pass that scales with area and
      // repaints every flight frame over a rect growing to ~380px. Hard-edge
      // skips the AA saveLayer during the fast 340ms zoom (aliased corners are
      // imperceptible in motion); static endpoints keep antiAlias for crisp
      // resting corners.
      clipBehavior: expand ? Clip.hardEdge : Clip.antiAlias,
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
