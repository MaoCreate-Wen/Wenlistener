import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_dimens.dart';
import '../../theme/app_typography.dart';

/// Slim custom frameless title bar (Apple-Music style) that blends into the
/// wash. Left = muted WenListener wordmark; the whole bar is an OS drag region
/// (double-click toggles maximize); right = minimize / maximize-restore / close.
///
/// Compiles on every platform but is only instantiated on desktop (behind
/// [DesktopWindowFrame]). All `windowManager` calls therefore only ever run on
/// a desktop OS.
class WindowTitleBar extends StatefulWidget {
  const WindowTitleBar({super.key});

  /// Matches the mockup's 38px chrome.
  static const double height = 38;

  @override
  State<WindowTitleBar> createState() => _WindowTitleBarState();
}

class _WindowTitleBarState extends State<WindowTitleBar> with WindowListener {
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _syncMaximized();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() => setState(() => _maximized = true);

  @override
  void onWindowUnmaximize() => setState(() => _maximized = false);

  Future<void> _syncMaximized() async {
    final bool m = await windowManager.isMaximized();
    if (mounted && m != _maximized) setState(() => _maximized = m);
  }

  Future<void> _toggleMaximize() async {
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: WindowTitleBar.height,
      child: Row(
        children: <Widget>[
          Expanded(
            child: DragToMoveArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppDimens.space16,
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'WenListener',
                    style: AppTypography.caption.copyWith(
                      letterSpacing: 0.5,
                      color: AppColors.onSurfaceMuted,
                    ),
                  ),
                ),
              ),
            ),
          ),
          _WindowButton(
            tooltip: 'Minimize',
            onPressed: () => windowManager.minimize(),
            builder: _buildMinimizeGlyph,
          ),
          _WindowButton(
            tooltip: _maximized ? 'Restore' : 'Maximize',
            onPressed: _toggleMaximize,
            builder: (Color c) =>
                _maximized ? _buildRestoreGlyph(c) : _buildMaximizeGlyph(c),
          ),
          _WindowButton(
            tooltip: 'Close',
            hoverColor: const Color(0xFFE81123),
            hoverGlyphColor: Colors.white,
            onPressed: () => windowManager.close(),
            builder: _buildCloseGlyph,
          ),
        ],
      ),
    );
  }

  Widget _buildMinimizeGlyph(Color c) =>
      CustomPaint(size: const Size(12, 12), painter: _GlyphPainter(_Glyph.min, c));

  Widget _buildMaximizeGlyph(Color c) =>
      CustomPaint(size: const Size(12, 12), painter: _GlyphPainter(_Glyph.max, c));

  Widget _buildRestoreGlyph(Color c) => CustomPaint(
      size: const Size(12, 12), painter: _GlyphPainter(_Glyph.restore, c));

  Widget _buildCloseGlyph(Color c) =>
      CustomPaint(size: const Size(12, 12), painter: _GlyphPainter(_Glyph.close, c));
}

class _WindowButton extends StatefulWidget {
  final String tooltip;
  final VoidCallback onPressed;
  final Widget Function(Color glyphColor) builder;
  final Color? hoverColor;
  final Color? hoverGlyphColor;

  const _WindowButton({
    required this.tooltip,
    required this.onPressed,
    required this.builder,
    this.hoverColor,
    this.hoverGlyphColor,
  });

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final Color glyphColor = _hovering
        ? (widget.hoverGlyphColor ?? AppColors.onSurface)
        : AppColors.onSurfaceMuted;
    final Color fill =
        _hovering ? (widget.hoverColor ?? AppColors.surfaceGlass) : Colors.transparent;
    return Semantics(
      button: true,
      label: widget.tooltip,
      child: Tooltip(
        message: widget.tooltip,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovering = true),
          onExit: (_) => setState(() => _hovering = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onPressed,
            child: Container(
              width: 46,
              height: WindowTitleBar.height,
              color: fill,
              alignment: Alignment.center,
              child: widget.builder(glyphColor),
            ),
          ),
        ),
      ),
    );
  }
}

enum _Glyph { min, max, restore, close }

class _GlyphPainter extends CustomPainter {
  final _Glyph glyph;
  final Color color;

  _GlyphPainter(this.glyph, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final Paint p = Paint()
      ..color = color
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true;
    final double w = size.width;
    final double h = size.height;
    switch (glyph) {
      case _Glyph.min:
        canvas.drawLine(Offset(0, h / 2), Offset(w, h / 2), p);
        break;
      case _Glyph.max:
        canvas.drawRect(Rect.fromLTWH(0.5, 0.5, w - 1, h - 1), p);
        break;
      case _Glyph.restore:
        // Two overlapped squares (Windows restore glyph).
        canvas.drawRect(Rect.fromLTWH(0.5, 2.5, w - 3, h - 3), p);
        final Path back = Path()
          ..moveTo(2.5, 2.5)
          ..lineTo(2.5, 0.5)
          ..lineTo(w - 0.5, 0.5)
          ..lineTo(w - 0.5, h - 2.5)
          ..lineTo(w - 2.5, h - 2.5);
        canvas.drawPath(back, p);
        break;
      case _Glyph.close:
        canvas.drawLine(const Offset(0, 0), Offset(w, h), p);
        canvas.drawLine(Offset(w, 0), Offset(0, h), p);
        break;
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter old) =>
      old.glyph != glyph || old.color != color;
}
