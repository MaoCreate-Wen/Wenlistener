import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:permission_handler/permission_handler.dart';

/// Real-time low-frequency audio level for the lyrics-page background "律动",
/// sourced from a native [`android.media.audiofx.Visualizer`] over the
/// `wenlistener/fft` [EventChannel] (see `MainActivity.kt`) and shaped to AMLL's
/// `u_volume`.
///
/// **The Visualizer is attached to the app's OWN audio session** — just_audio's
/// [AudioPlayer.androidAudioSessionId] — NOT the global output mix (session 0).
/// Global-mix capture is privileged and is *silently zeroed* on real devices
/// (Android 10+/MIUI): the Visualizer constructs without throwing but delivers
/// all-zero bins, which pins `u_volume` at its baseline → the mesh only slowly
/// rotates and never pulses (the "律动 doesn't react" bug). The app's own session
/// only needs RECORD_AUDIO and always works. The session id is handed to native
/// as the broadcast-stream argument, and re-attached if it changes per track.
///
/// [lowFreqVolume] carries AMLL's `u_volume`: ≈0.1 at rest, swelling on a bass
/// hit. The **sentinel value `< 0`** means "no real signal" — mic permission
/// denied, no session id yet, or the device can't create/feed a Visualizer —
/// and tells [NeonFlowBackground] to fall back to its synthetic pulse so the
/// field never freezes.
///
/// AMLL parity: the native side sends a normalised low-band (≈30–300 Hz)
/// magnitude in [0,1]; here it is temporally smoothed (`cur += (target-cur)·k·dt`)
/// and mapped to `u_volume = baseline + level·span`.
class FftService {
  FftService({AudioPlayer? player}) : _player = player;

  /// The app's own audio player — its Android audio session id is what the
  /// native Visualizer attaches to. Null in tests / when no player is wired.
  final AudioPlayer? _player;

  static const EventChannel _channel = EventChannel('wenlistener/fft');

  /// AMLL `u_volume`: ≥0 is a real reading (≈0.1 baseline … loud); **`< 0` means
  /// no real signal** (use the synthetic fallback).
  final ValueNotifier<double> lowFreqVolume = ValueNotifier<double>(-1.0);

  StreamSubscription<dynamic>? _sub; // FFT data stream (bound to a session id)
  StreamSubscription<int?>? _sessionSub; // app audio-session-id changes
  int? _attachedSession; // session id the Visualizer is currently bound to
  final Stopwatch _clock = Stopwatch();
  double _smoothed = 0.0; // smoothed normalised level [0,1]
  bool _started = false;

  // Asymmetric envelope: fast ATTACK snaps up to a bass hit, slow RELEASE eases
  // back down — a "pump" that tracks beats punchily. A single symmetric filter
  // either lags the beat (subtle) or jitters; the pump gives obvious, musical
  // motion. (Per-ms coefficients, × dtMs, clamped; the render-rate glide adds only
  // light extra continuity now, so beats still punch through.)
  static const double _attackK = 0.012; // τ≈80ms up
  static const double _releaseK = 0.004; // τ≈250ms down
  // Map smoothed level [0,1] → u_volume: 0.1 baseline (AMLL rest) + reactive span.
  // Span 0.38 → peak u_volume ~0.35–0.45 on a strong bass hit (zoom in to ~0.1–0.3,
  // plus the rotation kick + flow surge) — clearly visible color-block motion.
  static const double _baseline = 0.1;
  static const double _span = 0.38;

  /// Requests RECORD_AUDIO and, if granted, attaches the native Visualizer to
  /// the app's own audio session and begins streaming the FFT. Idempotent. A
  /// denial / platform exception leaves [lowFreqVolume] at the sentinel so the
  /// background uses its synthetic pulse.
  Future<void> start() async {
    if (_started) return;
    _started = true;

    // Desktop (Windows etc.) has no native Visualizer, no `wenlistener/fft`
    // EventChannel (that's MainActivity.kt / Android-only), and no Android-style
    // microphone permission semantics. Short-circuit to the sentinel so
    // NeonFlowBackground uses its synthetic pulse. NEVER touch the EventChannel
    // or permission_handler here — both MissingPlugin/throw on desktop.
    if (!Platform.isAndroid) {
      lowFreqVolume.value = -1.0;
      return;
    }

    try {
      final PermissionStatus status = await Permission.microphone.request();
      if (!status.isGranted) {
        lowFreqVolume.value = -1.0;
        return;
      }
    } catch (_) {
      lowFreqVolume.value = -1.0;
      return;
    }
    _clock
      ..reset()
      ..start();

    // Attach to the app's OWN audio session id (never the global mix). It may be
    // null until the player is prepared and can change per track, so attach on
    // the current value if present and re-attach whenever it changes. While it
    // is still null the sentinel stands, so the background uses its synthetic
    // pulse until the id lands (usually already non-null: audio is playing when
    // the lyrics page opens).
    final int? initial = _player?.androidAudioSessionId;
    if (initial != null && initial > 0) {
      _attach(initial);
    }
    _sessionSub = _player?.androidAudioSessionIdStream.listen((int? sid) {
      if (sid != null && sid > 0 && sid != _attachedSession) _attach(sid);
    });
    // No player wired at all (tests) → last-resort global mix. Real devices will
    // trip the native all-zero fallback → synthetic pulse.
    if (_player == null) _attach(0);
  }

  /// (Re)opens the native FFT stream for [sessionId]. Canceling the previous
  /// subscription releases the old Visualizer (native `onCancel`); listening
  /// creates a fresh one bound to this session (native `onListen(arguments)`).
  void _attach(int sessionId) {
    if (_attachedSession == sessionId && _sub != null) return;
    _attachedSession = sessionId;
    _sub?.cancel();
    try {
      _sub = _channel.receiveBroadcastStream(sessionId).listen(
            _onEvent,
            onError: (Object _) => lowFreqVolume.value = -1.0,
          );
    } catch (_) {
      lowFreqVolume.value = -1.0;
    }
  }

  void _onEvent(dynamic event) {
    final double level = (event is num) ? event.toDouble() : -1.0;
    if (level < 0) {
      // Native couldn't create/feed the Visualizer (or its all-zero guard tripped)
      // → permanent synthetic fallback for this session.
      lowFreqVolume.value = -1.0;
      _sub?.cancel();
      _sub = null;
      return;
    }
    final double dtMs = _clock.elapsedMilliseconds.clamp(0, 100).toDouble();
    _clock
      ..reset()
      ..start();
    final double k = level > _smoothed ? _attackK : _releaseK;
    _smoothed += (level - _smoothed) * (k * dtMs).clamp(0.0, 1.0);
    lowFreqVolume.value = (_baseline + _smoothed * _span).clamp(0.0, 0.6);
  }

  /// Stops streaming (releases the native Visualizer via the channel's onCancel)
  /// and resets to the synthetic-fallback sentinel.
  void stop() {
    _sub?.cancel();
    _sub = null;
    _sessionSub?.cancel();
    _sessionSub = null;
    _attachedSession = null;
    _clock.stop();
    _started = false;
    _smoothed = 0.0;
    lowFreqVolume.value = -1.0;
  }

  void dispose() {
    stop();
    lowFreqVolume.dispose();
  }
}
