import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenlistener/animation/lyric_line_render.dart';
import 'package:wenlistener/animation/lyric_player_controller.dart';
import 'package:wenlistener/models/lyric_line.dart';

/// Hosts a [LyricPlayerController] inside a real [TickerProvider] so the test
/// binding drives its ticker on `pump`.
class _Host extends StatefulWidget {
  const _Host({required this.onReady});
  final void Function(LyricPlayerController) onReady;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> with SingleTickerProviderStateMixin {
  late final LyricPlayerController controller =
      LyricPlayerController(vsync: this);

  @override
  void initState() {
    super.initState();
    widget.onReady(controller);
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

List<LyricLine> _lines() => <LyricLine>[
      const LyricLine(
        start: Duration.zero,
        end: Duration(milliseconds: 2000),
        text: 'first line here',
      ),
      const LyricLine(
        start: Duration(milliseconds: 5000),
        end: Duration(milliseconds: 7000),
        text: 'second line here',
      ),
      const LyricLine(
        start: Duration(milliseconds: 10000),
        end: Duration(milliseconds: 12000),
        text: 'third line here',
      ),
    ];

Future<LyricPlayerController> _mount(WidgetTester tester) async {
  late LyricPlayerController controller;
  await tester.pumpWidget(
    MaterialApp(home: _Host(onReady: (LyricPlayerController c) => controller = c)),
  );
  controller
    ..resize(const Size(400, 800))
    ..setLineHeights(<double>[60, 60, 60])
    ..setPlaying(false)
    ..setLines(_lines());
  await tester.pump();
  return controller;
}

void main() {
  testWidgets('emits one render per line', (WidgetTester tester) async {
    final LyricPlayerController c = await _mount(tester);
    expect(c.renderLines.length, 3);
    await tester.pumpWidget(const SizedBox()); // dispose host
  });

  testWidgets(
      'upcoming line pre-shifts (anticipatory) while the ink waits for the sung line',
      (WidgetTester tester) async {
    final LyricPlayerController c = await _mount(tester);
    // Line 1 is sung at 5000ms. AMLL lifts/centres/brightens the upcoming line
    // up to ~earlyStartMs (800ms) early (base.ts:481-494), so partway into that
    // window the ACTIVE (centred/bright) line is already line 1 — the signature
    // anticipatory scroll.
    c.setCurrentTime(const Duration(milliseconds: 4500));
    await tester.pump();
    expect(c.activeIndex, 1);
    // ...but the karaoke ink must NOT lead: [singingIndex] tracks the *raw* sung
    // start, so at 4500ms it is still line 0 — words never ink a line early (the
    // guard against the old off-by-one). It realigns once the audio reaches the
    // line's real start.
    expect(c.singingIndex, 0);
    c.setCurrentTime(const Duration(milliseconds: 5000));
    await tester.pump();
    expect(c.activeIndex, 1);
    expect(c.singingIndex, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('active line scales to 100% and inactive to 97% (while playing)',
      (WidgetTester tester) async {
    final LyricPlayerController c = await _mount(tester);
    // The inactive-line shrink applies ONLY while playing (paused → every line
    // returns to full scale, AMLL base.ts:789-797). Interpolated time is clamped
    // to +200ms of the last push, so the active line stays line 1.
    c.setPlaying(true);
    c.setCurrentTime(const Duration(milliseconds: 5500));
    // Let the springs settle.
    for (int i = 0; i < 180; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final LyricLineRender active = c.renderLines[1];
    final LyricLineRender inactive = c.renderLines[2];
    expect(c.activeIndex, 1);
    expect(active.scale, greaterThan(0.995));
    expect(inactive.scale, closeTo(0.97, 0.01));
    // Active line is sharp (sub-pixel ≈ 0); neighbours are clearly blurred.
    expect(active.blur, lessThan(0.05));
    expect(inactive.blur, greaterThan(1.0));
  });

  testWidgets('active line opacity is 0.85; bright mask reaches ~1.0',
      (WidgetTester tester) async {
    final LyricPlayerController c = await _mount(tester);
    c.setCurrentTime(const Duration(milliseconds: 5500));
    for (int i = 0; i < 180; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final LyricLineRender active = c.renderLines[1];
    expect(active.opacity, closeTo(0.85, 0.02));
    expect(active.brightMaskAlpha, closeTo(1.0, 0.02));
    expect(active.darkMaskAlpha, closeTo(0.4, 0.02));
  });

  testWidgets('seekTo snaps instantly (no settle needed)',
      (WidgetTester tester) async {
    final LyricPlayerController c = await _mount(tester);
    c.seekTo(const Duration(milliseconds: 10500));
    await tester.pump(const Duration(milliseconds: 16));
    expect(c.activeIndex, 2);
    // One frame after a hard seek the active line is already at full scale.
    expect(c.renderLines[2].scale, greaterThan(0.99));
    await tester.pumpWidget(const SizedBox());
  });
}
