import 'dart:async';
import 'dart:io' show ProcessInfo;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show PaintingBinding;

/// Debug-only memory probe. Samples the process working set + Flutter imageCache
/// at a fixed interval and prints a compact line whenever memory moves, so a
/// manual "open the heavy surface → return home" gesture produces a decisive
/// trace of WHICH pool spikes and WHEN.
///
/// It is fully compiled out of release ([kDebugMode] guards) and self-throttles
/// (prints only on a meaningful delta, a new peak, an explicit [mark], or a 2 s
/// heartbeat) so the console stays readable.
///
/// Wire-up: [start] once at app boot (debug), [mark] at lifecycle points you
/// care about (page open/dispose, transition begin/end).
///
/// Reading the line:
///   MEM t=+4.15s rss=248.3MB peak=402.1MB imgCache=41.0MB/58 live=22  [lyrics.open]
///   - rss   = ProcessInfo.currentRss   (current working set — what Task Manager's
///             "Memory" column shows). This is CPU-side memory; it does NOT include
///             dedicated GPU/VRAM (Skia textures, layer buffers). If your peak is a
///             GPU-memory peak, rss may barely move — say so and we switch tools.
///   - peak  = ProcessInfo.maxRss       (monotonic all-time high working set).
///   - imgCache = imageCache.currentSizeBytes / currentSize (entry count).
///   - live  = imageCache.liveImageCount (decodes pinned by a painting listener).
class MemProbe {
  MemProbe._();
  static final MemProbe instance = MemProbe._();

  Timer? _timer;
  final Stopwatch _sw = Stopwatch();
  int _lastPrintedRss = 0;
  int _lastPeak = 0;
  int _lastHeartbeatMs = 0;

  /// Starts periodic sampling (debug builds only). Safe to call more than once.
  void start({Duration interval = const Duration(milliseconds: 150)}) {
    if (!kDebugMode || _timer != null) return;
    _sw.start();
    _timer = Timer.periodic(interval, (_) => _sample(null));
    _sample('probe.start');
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _sw.stop();
  }

  /// Logs an immediate labelled snapshot (e.g. `mark('lyrics.open')`).
  void mark(String label) {
    if (!kDebugMode) return;
    _sample(label, force: true);
  }

  void _sample(String? label, {bool force = false}) {
    if (!kDebugMode) return;
    final int rss = ProcessInfo.currentRss;
    final int peak = ProcessInfo.maxRss;
    final int nowMs = _sw.elapsedMilliseconds;

    final bool bigDelta = (rss - _lastPrintedRss).abs() >= 3 * 1024 * 1024;
    final bool newPeak = peak > _lastPeak;
    final bool heartbeat = nowMs - _lastHeartbeatMs >= 2000;
    if (!force && !bigDelta && !newPeak && !heartbeat) {
      _lastPeak = peak;
      return;
    }

    final imgCache = PaintingBinding.instance.imageCache;
    final String line = 'MEM t=+${(nowMs / 1000).toStringAsFixed(2)}s '
        'rss=${_mb(rss)} peak=${_mb(peak)} '
        'imgCache=${_mb(imgCache.currentSizeBytes)}/${imgCache.currentSize} '
        'live=${imgCache.liveImageCount}'
        '${label != null ? '  [$label]' : ''}';
    debugPrint(line);

    _lastPrintedRss = rss;
    _lastPeak = peak;
    _lastHeartbeatMs = nowMs;
  }

  static String _mb(int bytes) =>
      '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
}
