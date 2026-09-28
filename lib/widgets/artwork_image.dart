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

  /// Mark this as one of the shared `album_art` hero endpoints (mini-player ↔
  /// player ↔ morph ↔ lyrics), which all decode at one fixed, bounded size
  /// ([_kHeroCoverDecodeLogicalPx]) regardless of their own display [size] or
  /// whether [heroTag] is currently null.
  ///
  /// This does two things at once:
  /// - **No skeleton flash across the morph.** The player cover flips [heroTag]
  ///   to null the instant the player→lyrics morph starts. Keying the decode off
  ///   `heroTag == null` (the thumbnail path) would swap it to a *per-frame*
  ///   [ResizeImage] as `size` shrinks 380→44, changing the ImageCache key every
  ///   frame → cache miss → [SkeletonBox]. A fixed size keeps the key constant,
  ///   so the remounted frame resolves synchronously from cache.
  /// - **Bounded raster/memory.** A full-resolution decode is the raw cover
  ///   (routinely 2000–3000 px ⇒ 25–36 MB RGBA). Sampling that giant texture
  ///   into the shrinking morph box every frame (plus the default
  ///   FilterQuality.medium generating a full mip chain for it) stalls the
  ///   raster thread — the whole lyrics page freezes. Decoding at ~380·dpr
  ///   (~1140 px, ~5 MB) is a fraction of the 60 MiB imageCache cap and cheap to
  ///   sample. All hero endpoints request the *same* fixed size, so they share
  ///   one ResizeImage key and the Hero flight stays pixel-identical.
  final bool heroCover;

  const ArtworkImage({
    super.key,
    required this.url,
    required this.size,
    this.radius,
    this.heroTag,
    this.fit = BoxFit.cover,
    this.shadow,
    this.heroCover = false,
  });

  /// The logical size every [heroCover] endpoint decodes at — the largest hero
  /// display size (the full player cover, `playerCoverSize` clamps to 380). Kept
  /// constant across all endpoints and across the morph so they resolve one
  /// shared ImageCache key. Multiplied by the device pixel ratio at decode time.
  static const double _kHeroCoverDecodeLogicalPx = 380;

  @override
  Widget build(BuildContext context) {
    final double r = radius ?? AppDimens.albumRadius(size);
    final double dpr = MediaQuery.devicePixelRatioOf(context);
    // Decode-size policy, three cases:
    // - [heroCover]: a fixed, bounded size shared by every `album_art` endpoint
    //   (see [heroCover] doc) — constant across the morph and identical across
    //   endpoints, so one shared ImageCache key (no flash, pixel-identical
    //   flight) at ~5 MB instead of the 25–36 MB raw cover (no raster stall).
    // - standalone thumbnail (heroTag == null, not a hero cover): downsample to
    //   its own display size — the list / grid / carousel covers dominate the
    //   startup and scroll high-water; a full-res decode per ~56 px cell is
    //   pure waste.
    // - a resting hero endpoint with a live tag but not flagged: full-res
    //   (legacy path; all real hero covers now pass [heroCover]).
    final int? decodeSize = heroCover
        ? (_kHeroCoverDecodeLogicalPx * dpr).round()
        : (heroTag == null ? (size * dpr).round() : null);
    final Widget child = _ArtworkHeroChild(
      url: url,
      size: size,
      resolvedRadius: r,
      fit: fit,
      shadow: shadow,
      decodeSize: decodeSize,
      // Hero covers sample a bounded texture down into a shrinking morph box
      // every frame; FilterQuality.low skips the mip-chain generation that the
      // default (medium) forces on the texture the instant it is scaled below
      // native size — the per-frame raster cost behind the lyrics-page freeze.
      filterQuality: heroCover ? FilterQuality.low : FilterQuality.medium,
    );
    if (heroTag == null) {
      // During the morph the cover drops its tag (no Hero to isolate it). Wrap
      // it in its own layer so its per-frame repaint doesn't dirty the lyrics
      // mesh background compositing with it. Plain thumbnails skip the boundary
      // (they don't animate and there are many of them).
      return heroCover ? RepaintBoundary(child: child) : child;
    }
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
            // Inherit the destination endpoint's bounded decode key so the
            // flight paints the SAME ImageCache entry as both ends (no re-decode
            // / skeleton on settle) and stays pixel-identical.
            decodeSize: b.decodeSize,
            filterQuality: FilterQuality.low,
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
    this.filterQuality = FilterQuality.medium,
    this.expand = false,
  });

  final String? url;
  final double size;
  final double resolvedRadius;
  final BoxFit fit;
  final List<BoxShadow>? shadow;

  /// When non-null, decode the cover at this pixel size (via [ResizeImage])
  /// instead of the network original. Standalone thumbnails pass their display
  /// size; every `album_art` hero endpoint passes one shared bounded size so
  /// they resolve the same ImageCache key and the flight stays pixel-identical.
  final int? decodeSize;

  /// Sampling quality when the decoded bitmap is scaled to fit. Hero covers use
  /// [FilterQuality.low] to skip mip-chain generation during the morph/flight.
  final FilterQuality filterQuality;
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
            filterQuality: filterQuality,
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
