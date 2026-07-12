import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_dimens.dart';

/// A shimmering loading placeholder. Reserves exact space so async content
/// swaps in without layout jump (DESIGN_SPEC §6). Drives a single repeating
/// gradient sweep shared by every instance in a view.
class Skeleton extends StatefulWidget {
  final double? width;
  final double height;
  final double radius;

  const Skeleton({
    super.key,
    this.width,
    required this.height,
    this.radius = AppDimens.radiusSm,
  });

  /// Square art placeholder sized like a [MediaCard] / row thumbnail.
  const Skeleton.square(double size, {super.key, double? radius})
      : width = size,
        height = size,
        radius = radius ?? AppDimens.radiusMd;

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final BorderRadius br = BorderRadius.circular(widget.radius);
    return ClipRRect(
      borderRadius: br,
      child: SizedBox(
        width: widget.width,
        height: widget.height,
        child: AnimatedBuilder(
          animation: _c,
          builder: (BuildContext context, _) {
            final double t = _c.value;
            return DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment(-1 - 2 * (1 - t), 0),
                  end: Alignment(1 - 2 * (1 - t), 0),
                  colors: const <Color>[
                    AppColors.surface,
                    AppColors.surface2,
                    AppColors.surface,
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
