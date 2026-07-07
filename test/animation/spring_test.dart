import 'package:flutter_test/flutter_test.dart';
import 'package:wenlistener/animation/emphasis.dart';
import 'package:wenlistener/animation/spring.dart';
import 'package:wenlistener/models/lyric_line.dart';

/// Drives a spring forward in fixed steps until it settles (or the step budget
/// is exhausted) and returns the number of steps taken.
int _settle(Spring s, {double dt = 1 / 60, int maxSteps = 6000}) {
  int steps = 0;
  while (!s.arrived && steps < maxSteps) {
    s.update(dt);
    steps++;
  }
  return steps;
}

void main() {
  group('SpringParams presets', () {
    test('match the AMLL constants (mass, damping, stiffness)', () {
      expect(SpringParams.posY.mass, 0.9);
      expect(SpringParams.posY.damping, 15);
      expect(SpringParams.posY.stiffness, 90);

      expect(SpringParams.scale.mass, 2.0);
      expect(SpringParams.scale.damping, 25);
      expect(SpringParams.scale.stiffness, 100);

      expect(SpringParams.bgScale.mass, 1.0);
      expect(SpringParams.bgScale.damping, 20);
      expect(SpringParams.bgScale.stiffness, 50);
    });

    test('default Spring uses the posY preset', () {
      final Spring s = Spring();
      expect(s.params.mass, SpringParams.posY.mass);
      expect(s.params.stiffness, SpringParams.posY.stiffness);
    });
  });

  group('Spring settling', () {
    test('posY spring converges to its target', () {
      final Spring s = Spring(initial: 0, params: SpringParams.posY);
      s.setTarget(100);
      final int steps = _settle(s);
      expect(s.arrived, isTrue, reason: 'settled in $steps steps');
      expect(s.position, closeTo(100, 0.01));
      expect(s.velocity, closeTo(0, 0.01));
    });

    test('scale spring (underdamped) converges', () {
      final Spring s = Spring(initial: 100, params: SpringParams.scale);
      s.setTarget(97);
      _settle(s);
      expect(s.arrived, isTrue);
      expect(s.position, closeTo(97, 0.01));
    });

    test('bgScale spring (overdamped) converges without overshoot', () {
      final Spring s = Spring(initial: 75, params: SpringParams.bgScale);
      s.setTarget(100);
      // Overdamped: position must never exceed the target.
      double maxSeen = double.negativeInfinity;
      for (int i = 0; i < 2000 && !s.arrived; i++) {
        s.update(1 / 60);
        if (s.position > maxSeen) maxSeen = s.position;
      }
      expect(s.arrived, isTrue);
      expect(s.position, closeTo(100, 0.01));
      expect(maxSeen, lessThanOrEqualTo(100.0001),
          reason: 'overdamped spring should not overshoot');
    });

    test('underdamped posY overshoots its target at least once', () {
      final Spring s = Spring(initial: 0, params: SpringParams.posY);
      s.setTarget(100);
      bool overshot = false;
      for (int i = 0; i < 2000 && !s.arrived; i++) {
        s.update(1 / 60);
        if (s.position > 100.05) overshot = true;
      }
      expect(overshot, isTrue,
          reason: 'underdamped spring (ζ≈0.83) should overshoot');
    });
  });

  group('Spring retargeting', () {
    test('setTarget mid-flight carries velocity (no reset to rest)', () {
      final Spring s = Spring(initial: 0, params: SpringParams.posY);
      s.setTarget(100);
      for (int i = 0; i < 10; i++) {
        s.update(1 / 60);
      }
      final double vBefore = s.velocity;
      expect(vBefore.abs(), greaterThan(0.0));
      s.setTarget(200);
      // Velocity is preserved across the re-seed (continuous, not zeroed).
      expect(s.velocity, closeTo(vBefore, 1e-9));
      _settle(s);
      expect(s.position, closeTo(200, 0.01));
    });

    test('setPosition moves position + zeroes velocity but keeps the target', () {
      final Spring s = Spring(initial: 0, params: SpringParams.posY);
      s.setTarget(100);
      _settle(s);
      s.setPosition(500);
      expect(s.position, 500);
      expect(s.velocity, 0);
      // Target is still 100, so it is NOT arrived and springs back.
      expect(s.arrived, isFalse);
      _settle(s);
      expect(s.position, closeTo(100, 0.01));
    });

    test('snapTo settles instantly at the value (position == target)', () {
      final Spring s = Spring(initial: 0, params: SpringParams.posY);
      s.setTarget(100);
      _settle(s);
      s.snapTo(500);
      expect(s.position, 500);
      expect(s.velocity, 0);
      expect(s.arrived, isTrue);
    });

    test('already at target reports arrived immediately', () {
      final Spring s = Spring(initial: 42, params: SpringParams.scale);
      expect(s.arrived, isTrue);
      s.update(1 / 60);
      expect(s.position, closeTo(42, 1e-9));
    });
  });

  group('emphasis', () {
    LyricWord word(int durMs, {String text = 'oh'}) => LyricWord(
          text: text,
          start: Duration.zero,
          end: Duration(milliseconds: durMs),
        );

    test('shouldEmphasize: short words are excluded', () {
      expect(shouldEmphasize(word(400)), isFalse);
    });

    test('shouldEmphasize: long latin word in [2,7] chars qualifies', () {
      expect(shouldEmphasize(word(1500, text: 'forever')), isTrue);
      expect(shouldEmphasize(word(1500, text: 'a')), isFalse);
      expect(shouldEmphasize(word(1500, text: 'extraordinary')), isFalse);
    });

    test('shouldEmphasize: long CJK glyph qualifies regardless of length', () {
      expect(shouldEmphasize(word(1200, text: '爱')), isTrue);
    });

    test('emphasisEase is a 0→1→0 pulse', () {
      expect(emphasisEase(0), 0);
      expect(emphasisEase(1), 0);
      expect(emphasisEase(0.5), greaterThan(0.8));
    });

    test('last word boosts amount and duration', () {
      final LyricWord w = word(2000, text: 'shine');
      final WordEmphasis normal = WordEmphasis.forWord(w, isLastWord: false);
      final WordEmphasis last = WordEmphasis.forWord(w, isLastWord: true);
      expect(last.amount, greaterThan(normal.amount));
      expect(last.durationMs, greaterThan(normal.durationMs));
    });

    test('char emphasis peaks mid-window then returns to rest', () {
      final WordEmphasis e =
          WordEmphasis.forWord(word(2000, text: 'shine'), isLastWord: false);
      final CharEmphasis mid = e.charAt(0, e.durationMs * 0.5);
      final CharEmphasis end = e.charAt(0, e.durationMs * 1.2);
      expect(mid.scale, greaterThan(1.0));
      expect(end.scale, 1.0); // outside the window → rest
    });
  });
}
