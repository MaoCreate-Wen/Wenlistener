import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenlistener_desktop/pages/lyrics/widgets/line_edge_fade.dart';

/// Pixel-parity proof for the lyrics edge-fade rework: rendering a stack of
/// absolutely-positioned "lyric lines" through the OLD page-wide
/// `ShaderMask(dstIn)` and through the NEW per-line [LineEdgeFade] shells must
/// produce the same pixels (± 8-bit premultiply rounding), including
///  • lines straddling the band boundaries,
///  • paint overflowing the line box (text shadows) into a band,
///  • lines fully inside the opaque middle (the layer-free pass-through), and
///  • the live background revealed through the faded band pixels.
void main() {
  const Size viewSize = Size(400, 300);
  const double fadeFrac = 0.14;
  const double topFadePx = 300 * fadeFrac; // 42
  const double bottomFadePx = 300 * fadeFrac;

  // Non-overlapping line boxes (pitch 60 > height 40 + 3σ shadow tails) so the
  // whole-layer-vs-per-line compositing-order term is exactly zero, matching
  // the real lyric stack's ≥44px inter-ink gaps.
  const List<double> lineTops = <double>[
    -25, // straddles the view top edge
    35, // straddles the top band boundary (42)
    105, // opaque middle (top-60 ≥ 42, bottom+60 ≤ 258 → pass-through)
    155, // opaque middle
    215, // straddles the bottom band boundary (258); shadows reach further in
    275, // straddles the view bottom edge
  ];
  const double lineHeight = 40;

  Widget line(int i) {
    // A translucent plate + shadowed text: exercises alpha content and paint
    // that escapes the layout box (blurRadius 3 → tail ≈ 7px).
    return RepaintBoundary(
      child: Container(
        height: lineHeight,
        color: const Color(0x6620E080),
        alignment: Alignment.centerLeft,
        child: Text(
          'Lyric line $i',
          style: const TextStyle(
            fontSize: 24,
            color: Color(0xE6FFFFFF),
            shadows: <Shadow>[
              Shadow(color: Color(0xFFFFFFFF), blurRadius: 3),
            ],
          ),
        ),
      ),
    );
  }

  Widget lyricArea({required bool perLine}) {
    final List<Widget> children = <Widget>[
      for (int i = 0; i < lineTops.length; i++)
        Positioned(
          top: lineTops[i],
          left: 16,
          right: 16,
          child: perLine
              ? LineEdgeFade(
                  lineTop: lineTops[i],
                  viewHeight: viewSize.height,
                  topFadePx: topFadePx,
                  bottomFadePx: bottomFadePx,
                  overflowMargin: 60,
                  child: line(i),
                )
              : line(i),
        ),
    ];
    final Widget stack = ClipRect(child: Stack(children: children));
    if (perLine) return stack;
    return ShaderMask(
      shaderCallback: (Rect bounds) => const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: <Color>[
          Colors.transparent,
          Colors.white,
          Colors.white,
          Colors.transparent,
        ],
        stops: <double>[0.0, fadeFrac, 1.0 - fadeFrac, 1.0],
      ).createShader(bounds),
      blendMode: BlendMode.dstIn,
      child: stack,
    );
  }

  Widget page({required bool perLine}) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: RepaintBoundary(
          key: const ValueKey<String>('cap'),
          child: SizedBox(
            width: viewSize.width,
            height: viewSize.height,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                // Live-background stand-in: the fade must reveal THIS, not tint
                // toward black.
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: <Color>[Color(0xFF204080), Color(0xFF80303F)],
                    ),
                  ),
                ),
                lyricArea(perLine: perLine),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<Uint8List> capture(WidgetTester tester) async {
    final RenderRepaintBoundary boundary =
        tester.renderObject(find.byKey(const ValueKey<String>('cap')));
    final Uint8List? bytes = await tester.runAsync<Uint8List?>(() async {
      final ui.Image image = await boundary.toImage();
      final ByteData? data =
          await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      return data?.buffer.asUint8List();
    });
    expect(bytes, isNotNull);
    return bytes!;
  }

  testWidgets('per-line LineEdgeFade == whole-view ShaderMask',
      (WidgetTester tester) async {
    await tester.pumpWidget(page(perLine: false));
    final Uint8List before = await capture(tester);

    await tester.pumpWidget(page(perLine: true));
    final Uint8List after = await capture(tester);

    expect(after.length, before.length);
    final int rowBytes = before.length ~/ viewSize.height.toInt();
    final int width = rowBytes ~/ 4;
    // The fade BANDS are where the gradient multiply happens — those pixels
    // must match to ±1 (premultiply rounding). The opaque middle is painted
    // through one FEWER 8-bit offscreen round-trip than the old whole-view
    // layer (the new path is the less-quantized one), so semi-transparent
    // content there may differ by a couple of 8-bit steps — far below
    // perception (the app's own background dither is ±2/255).
    int maxBandDiff = 0;
    int maxMidDiff = 0;
    int diffCount = 0;
    final List<String> samples = <String>[];
    for (int i = 0; i < before.length; i++) {
      final int d = (before[i] - after[i]).abs();
      if (d == 0) continue;
      final int px = i ~/ 4;
      final int y = px ~/ width;
      final bool inBand = y < topFadePx || y > viewSize.height - bottomFadePx;
      if (inBand) {
        if (d > maxBandDiff) maxBandDiff = d;
      } else if (d > maxMidDiff) {
        maxMidDiff = d;
      }
      if (d > 1) {
        diffCount++;
        if (samples.length < 12) {
          samples.add(
              '(${px % width},$y)c${i % 4} ${before[i]}→${after[i]}');
        }
      }
    }
    expect(maxBandDiff, lessThanOrEqualTo(1),
        reason: 'band pixels must be gradient-exact; $samples');
    expect(maxMidDiff, lessThanOrEqualTo(3),
        reason:
            'middle pass-through beyond quantization: $diffCount bytes >1: $samples');
  });

  testWidgets('out-of-band lines pass through without a mask layer',
      (WidgetTester tester) async {
    await tester.pumpWidget(page(perLine: true));
    final Iterable<RenderLineEdgeFade> fades =
        tester.renderObjectList<RenderLineEdgeFade>(
            find.byType(LineEdgeFade));
    final List<bool> composited =
        fades.map((RenderLineEdgeFade r) => r.alwaysNeedsCompositing).toList();
    // Lines 0/1 (top band), 4/5 (bottom band) masked; 2/3 (middle) layer-free.
    expect(composited, <bool>[true, true, false, false, true, true]);
  });
}
