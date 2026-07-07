import 'package:flutter/material.dart';

import '../theme/app_dimens.dart';

/// A pulsing placeholder block used to reserve space while content loads.
class SkeletonBox extends StatefulWidget {
  final double? width;
  final double? height;
  final double? radius;

  const SkeletonBox({super.key, this.width, this.height, this.radius});

  @override
  State<SkeletonBox> createState() => _SkeletonBoxState();
}

class _SkeletonBoxState extends State<SkeletonBox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (BuildContext context, Widget? child) {
        final double alpha = 0.05 + (_controller.value * 0.07);
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: alpha),
            borderRadius:
                BorderRadius.circular(widget.radius ?? AppDimens.radiusSm),
          ),
        );
      },
    );
  }
}
