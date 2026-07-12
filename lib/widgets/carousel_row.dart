import 'package:flutter/material.dart';

import '../theme/app_dimens.dart';

/// Horizontal scroll strip of cards (home carousels). Shows a thin scrollbar on
/// hover and lets the trackpad / mouse wheel scroll horizontally. Reserves a
/// fixed [height] so async loads don't jump the page.
class CarouselRow extends StatefulWidget {
  final List<Widget> children;
  final double height;
  final double gap;

  const CarouselRow({
    super.key,
    required this.children,
    required this.height,
    this.gap = AppDimens.space16,
  });

  @override
  State<CarouselRow> createState() => _CarouselRowState();
}

class _CarouselRowState extends State<CarouselRow> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      child: Scrollbar(
        controller: _controller,
        thickness: 6,
        radius: const Radius.circular(3),
        child: ListView.separated(
          controller: _controller,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(vertical: AppDimens.space4),
          itemCount: widget.children.length,
          separatorBuilder: (_, __) => SizedBox(width: widget.gap),
          itemBuilder: (BuildContext context, int i) => widget.children[i],
        ),
      ),
    );
  }
}
