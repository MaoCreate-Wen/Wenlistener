import 'package:flutter/material.dart';

/// Reports pointer-hover state to a [builder] and shows the click cursor.
/// Pointer-first desktop interactions build on this (DESKTOP_UI_PLAN §1).
class HoverBuilder extends StatefulWidget {
  final Widget Function(BuildContext context, bool hovering) builder;
  final MouseCursor cursor;
  final ValueChanged<bool>? onHoverChanged;

  const HoverBuilder({
    super.key,
    required this.builder,
    this.cursor = SystemMouseCursors.click,
    this.onHoverChanged,
  });

  @override
  State<HoverBuilder> createState() => _HoverBuilderState();
}

class _HoverBuilderState extends State<HoverBuilder> {
  bool _hover = false;

  void _set(bool v) {
    if (_hover == v) return;
    setState(() => _hover = v);
    widget.onHoverChanged?.call(v);
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: widget.cursor,
      onEnter: (_) => _set(true),
      onExit: (_) => _set(false),
      child: widget.builder(context, _hover),
    );
  }
}

/// A tap target that presses in with a small [Transform] scale (no reflow — the
/// press never shifts surrounding layout, per DESIGN_SPEC §5) and offers a hover
/// callback. Use for cards / icon buttons.
class HoverScale extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onSecondaryTap;
  final double pressedScale;
  final MouseCursor cursor;
  final Duration duration;

  const HoverScale({
    super.key,
    required this.child,
    this.onTap,
    this.onSecondaryTap,
    this.pressedScale = 0.96,
    this.cursor = SystemMouseCursors.click,
    this.duration = const Duration(milliseconds: 120),
  });

  @override
  State<HoverScale> createState() => _HoverScaleState();
}

class _HoverScaleState extends State<HoverScale> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: widget.cursor,
      child: GestureDetector(
        onTap: widget.onTap,
        onSecondaryTap: widget.onSecondaryTap,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        child: AnimatedScale(
          scale: _pressed ? widget.pressedScale : 1.0,
          duration: widget.duration,
          curve: Curves.easeOut,
          child: widget.child,
        ),
      ),
    );
  }
}
