import 'dart:math' as math;

/// Tuning for [Spring]. Mirrors the AMLL `SpringParams` shape
/// (`utils/spring.ts`). The presets transfer 1:1 from the reference player.
///
/// Positional order is `(mass, damping, stiffness)` so the preset shorthand in
/// the spec reads naturally: `posY(0.9, 15, 90)`.
class SpringParams {
  final double mass;
  final double damping;
  final double stiffness;
  final bool soft;

  const SpringParams(
    this.mass,
    this.damping,
    this.stiffness, {
    this.soft = false,
  });

  /// Vertical line movement — underdamped (ζ ≈ 0.833), settles with a slight
  /// overshoot.
  static const SpringParams posY = SpringParams(0.9, 15, 90);

  /// Line scale — underdamped (ζ ≈ 0.884).
  static const SpringParams scale = SpringParams(2.0, 25, 100);

  /// Background-line scale — overdamped (ζ ≈ 1.414), no bounce.
  static const SpringParams bgScale = SpringParams(1.0, 20, 50);

  SpringParams copyWith({
    double? mass,
    double? damping,
    double? stiffness,
    bool? soft,
  }) =>
      SpringParams(
        mass ?? this.mass,
        damping ?? this.damping,
        stiffness ?? this.stiffness,
        soft: soft ?? this.soft,
      );

  @override
  String toString() =>
      'SpringParams(mass: $mass, damping: $damping, stiffness: $stiffness, soft: $soft)';
}

enum _SpringMode { underdamped, critical, overdamped }

/// A closed-form damped-harmonic-oscillator solver, ported from the AMLL
/// `Spring` class (`utils/spring.ts`).
///
/// Solves `m·x'' + c·x' + k·x = 0` analytically and re-seeds from the current
/// position **and velocity** whenever [setTarget] is called, so retargeting a
/// moving line carries its momentum (no visual hitch). Advanced in **seconds**
/// via [update].
class Spring {
  /// Convergence threshold for [arrived] (matches AMLL's `0.01`).
  static const double _precision = 0.01;

  double _position;
  double _velocity = 0;
  double _target;
  SpringParams _params;

  // Elapsed time since the last re-seed (the analytic solution is evaluated at
  // this absolute offset each frame).
  double _elapsed = 0;

  // Solver coefficients, rebuilt on every re-seed.
  _SpringMode _mode = _SpringMode.critical;
  double _coefA = 0; // underdamped: A / critical: A / overdamped: c1
  double _coefB = 0; // underdamped: B / critical: B / overdamped: c2
  double _rate = 0; // decay rate (ζω₀ underdamped, ω₀ critical)
  double _omegaD = 0; // damped angular frequency (underdamped)
  double _r1 = 0; // overdamped root 1
  double _r2 = 0; // overdamped root 2

  Spring({double initial = 0, SpringParams params = SpringParams.posY})
      : _position = initial,
        _target = initial,
        _params = params {
    _reseed();
  }

  /// Current solved value.
  double get position => _position;

  /// Current solved velocity (units / second).
  double get velocity => _velocity;

  /// The value the spring is converging toward.
  double get target => _target;

  SpringParams get params => _params;

  /// Swap the physics tuning, keeping the current position + velocity.
  set params(SpringParams value) {
    _params = value;
    _reseed();
  }

  /// True once the spring has effectively reached its target and stopped.
  bool get arrived =>
      (_target - _position).abs() < _precision && _velocity.abs() < _precision;

  /// Re-aim the spring, carrying the current velocity into the new solution.
  void setTarget(double target) {
    if (target == _target) return;
    _target = target;
    _reseed();
  }

  /// Hard-set the position (zeroing velocity) **without** moving the target —
  /// the spring will travel from here back toward [target]. Used to seed a
  /// freshly created line offscreen before it flies into view.
  void setPosition(double value) {
    _position = value;
    _velocity = 0;
    _reseed();
  }

  /// Instantly settle at [value]: position == target, velocity zero, [arrived].
  /// Used for hard cuts (seek / resize) where no animation is wanted.
  void snapTo(double value) {
    _position = value;
    _target = value;
    _velocity = 0;
    _reseed();
  }

  /// Advance the analytic solution by [dtSeconds].
  void update(double dtSeconds) {
    if (dtSeconds <= 0) return;
    _elapsed += dtSeconds;
    final double t = _elapsed;
    _position = _target + _solveX(t);
    _velocity = _solveV(t);
    // Snap once we are inside the noise floor to avoid endless micro-jitter.
    if ((_target - _position).abs() < 1e-4 && _velocity.abs() < 1e-4) {
      _position = _target;
      _velocity = 0;
    }
  }

  // --- solver ---------------------------------------------------------------

  void _reseed() {
    _elapsed = 0;
    final double m = _params.mass;
    final double c = _params.damping;
    final double k = _params.stiffness;
    final double x0 = _position - _target; // displacement from equilibrium
    final double v0 = _velocity;

    if (m <= 0 || k <= 0) {
      // Degenerate config — behave as an instant snap.
      _mode = _SpringMode.critical;
      _rate = 1e6;
      _coefA = x0;
      _coefB = 0;
      return;
    }

    final double omega0 = math.sqrt(k / m);
    final double disc = c * c - 4 * m * k; // sign selects the regime
    final double rel = (c * c).abs() + 4 * m * k;

    if (_params.soft || disc.abs() <= rel * 1e-9) {
      // Critically damped: x(t) = (A + B·t)·e^(-ω₀·t)
      _mode = _SpringMode.critical;
      _rate = omega0;
      _coefA = x0;
      _coefB = v0 + omega0 * x0;
    } else if (disc > 0) {
      // Overdamped: x(t) = c1·e^(r1·t) + c2·e^(r2·t)
      _mode = _SpringMode.overdamped;
      final double sq = math.sqrt(disc);
      _r1 = (-c + sq) / (2 * m);
      _r2 = (-c - sq) / (2 * m);
      _coefA = (v0 - _r2 * x0) / (_r1 - _r2);
      _coefB = x0 - _coefA;
    } else {
      // Underdamped: x(t) = e^(-ζω₀·t)·(A·cos(ω_d·t) + B·sin(ω_d·t))
      _mode = _SpringMode.underdamped;
      final double zeta = c / (2 * math.sqrt(k * m));
      _rate = zeta * omega0;
      _omegaD = omega0 * math.sqrt(1 - zeta * zeta);
      _coefA = x0;
      _coefB = (v0 + _rate * x0) / _omegaD;
    }
  }

  double _solveX(double t) {
    switch (_mode) {
      case _SpringMode.critical:
        return (_coefA + _coefB * t) * math.exp(-_rate * t);
      case _SpringMode.overdamped:
        return _coefA * math.exp(_r1 * t) + _coefB * math.exp(_r2 * t);
      case _SpringMode.underdamped:
        final double e = math.exp(-_rate * t);
        return e * (_coefA * math.cos(_omegaD * t) + _coefB * math.sin(_omegaD * t));
    }
  }

  double _solveV(double t) {
    switch (_mode) {
      case _SpringMode.critical:
        final double e = math.exp(-_rate * t);
        return e * (_coefB - _rate * (_coefA + _coefB * t));
      case _SpringMode.overdamped:
        return _coefA * _r1 * math.exp(_r1 * t) +
            _coefB * _r2 * math.exp(_r2 * t);
      case _SpringMode.underdamped:
        final double e = math.exp(-_rate * t);
        final double cos = math.cos(_omegaD * t);
        final double sin = math.sin(_omegaD * t);
        return e *
            ((_coefB * _omegaD - _rate * _coefA) * cos -
                (_coefA * _omegaD + _rate * _coefB) * sin);
    }
  }
}
