import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import '../models/image_url.dart';
import '../services/resource_cache.dart';
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

  /// Decode-cache dimension for a cover displayed at [logicalSize].
  ///
  /// Small art (thumbnails, grid cards, ≤256px) decodes at its exact display
  /// resolution — the mobile memory lesson (a grid of full-res decodes balloons
  /// memory) unchanged. LARGE covers bucket up to the next 64px step so the
  /// Hero flight shuttle, the destination `/player` cover and the
  /// [_MeshPrewarmer]-style precache all resolve the SAME [ResizeImage] cache
  /// key (equal width/height ⇒ equal key ⇒ one decode) even as window resizes
  /// nudge the ideal size by a few pixels. Decoding ≤63px above display size
  /// then minifying is visually identical; sharing the key is what kills the
  /// mid-flight re-decode churn.
  static int cachePxFor(double logicalSize, double devicePixelRatio) {
    final int px = (logicalSize * devicePixelRatio).round().clamp(64, 640);
    if (px <= 256) return px;
    return math.min(((px + 63) ~/ 64) * 64, 640);
  }

  /// The exact provider an [ArtworkImage] of this url/decode-size resolves —
  /// exposed so callers can [precacheImage] the DESTINATION resolution before a
  /// Hero flight (equal construction ⇒ equal cache key ⇒ the flight and the
  /// settled cover paint from the already-decoded texture).
  ///
  /// The inner provider is [DiskCachedImage] (the app's bounded, LRU-evicted
  /// disk cache under the temp dir) — same `(url)`-keyed equality as the
  /// `CachedNetworkImageProvider` it replaced, so the [ResizeImage] bucketing
  /// above and the in-memory `imageCache` keying are byte-for-byte unchanged.
  static ImageProvider providerFor(String url, int cachePx) =>
      ResizeImage.resizeIfNeeded(
        cachePx,
        cachePx,
        DiskCachedImage(url, headers: kNeteaseImageHeaders),
      );

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
    // The in-flight image decodes at the LARGER endpoint's resolution — on push
    // that is exactly the destination cover's provider (precached by the shell's
    // prewarmer), on pop it is the big cover's provider that is still in the
    // image cache from the open. Either way the flight resolves an
    // ALREADY-DECODED texture; the old fixed 512·dpr flight size was a third
    // cache key no end state ever used, so every first open decoded a full
    // cover MID-FLIGHT (the shuttle visibly flew an empty skeleton).
    final double flightSize = math.max(a.size, b.size);
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
            size: flightSize,
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
    // The Hero flight passes the larger endpoint's size here, so the in-flight
    // provider is cache-identical to that endpoint's (no mid-flight decode).
    final double dpr = MediaQuery.devicePixelRatioOf(context);
    final int cachePx = ArtworkImage.cachePxFor(size, dpr);
    final Widget inner = hasUrl
        ? Image(
            image: ArtworkImage.providerFor(url!, cachePx),
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
