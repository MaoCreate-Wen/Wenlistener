package com.example.wenlistener

import android.media.audiofx.Visualizer
import android.os.Handler
import android.os.Looper
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import kotlin.math.sqrt

/**
 * Hosts the AMLL background "律动" FFT feed. A [Visualizer] attached to the app's
 * OWN audio session (the id just_audio reports for its ExoPlayer, passed as the
 * [EventChannel] listen argument) captures the playing audio and, on each FFT
 * frame, emits a single normalised low-frequency (≈30–300 Hz "bass") magnitude
 * in [0,1] over the `wenlistener/fft` [EventChannel]. The Dart side
 * (`fft_service.dart`) smooths it into the mesh shader's `u_volume`.
 *
 * The app's own session is used deliberately: a [Visualizer] on the GLOBAL mix
 * (session 0) is privileged and is silently zeroed on real devices (Android
 * 10+/MIUI), which manifests as a background that never reacts to the music.
 * Own-session capture only needs RECORD_AUDIO (requested at runtime from Dart
 * before listening) and always works. If the Visualizer can't be created
 * (permission denied, or unsupported — e.g. the emulator's audio HAL exposes no
 * effect), or it only ever returns silence, the sentinel `-1.0` is emitted so
 * the Dart side falls back to its synthetic pulse instead of freezing the field.
 *
 * Events are marshalled to the main thread: a [Visualizer] invokes its capture
 * listener on its own measurement thread, but a Flutter [EventChannel.EventSink]
 * must only be touched on the platform main thread.
 *
 * Still an [AudioServiceActivity] (required by audio_service for the media
 * notification / background playback).
 */
class MainActivity : AudioServiceActivity() {
    private var visualizer: Visualizer? = null
    // A Visualizer calls onFftDataCapture on its own measurement thread, but an
    // EventSink must be used on the main thread — hop through this to deliver.
    private val mainHandler = Handler(Looper.getMainLooper())

    // All-zero-capture fallback bookkeeping (see onFftDataCapture): once the
    // Visualizer has delivered any real signal we stop watching; if it only ever
    // returns silence (a silenced/locked-down capture) we emit the -1 sentinel so
    // the Dart side switches to its synthetic pulse instead of a frozen field.
    private var seenSignal = false
    private var zeroFrames = 0

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, FFT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    // `arguments` is the app's OWN audio session id (from FftService
                    // via just_audio's androidAudioSessionId); 0/absent → global-mix
                    // fallback.
                    val sessionId = (arguments as? Number)?.toInt() ?: 0
                    startVisualizer(events, sessionId)
                }

                override fun onCancel(arguments: Any?) {
                    stopVisualizer()
                }
            })
    }

    private fun startVisualizer(events: EventChannel.EventSink?, sessionId: Int) {
        stopVisualizer()
        seenSignal = false
        zeroFrames = 0
        try {
            // Attach to the app's OWN audio session (just_audio's ExoPlayer) when we
            // have its id. Session 0 (global output mix) is privileged and silently
            // zeroed on real devices (Android 10+/MIUI), so only fall back to it when
            // no valid id was passed (e.g. the emulator / tests).
            val v = Visualizer(if (sessionId > 0) sessionId else 0) // needs RECORD_AUDIO
            v.captureSize = Visualizer.getCaptureSizeRange()[1] // max (better low-freq resolution)
            val captureSize = v.captureSize
            v.setDataCaptureListener(
                object : Visualizer.OnDataCaptureListener {
                    override fun onWaveFormDataCapture(
                        vis: Visualizer?,
                        waveform: ByteArray?,
                        samplingRate: Int
                    ) {
                    }

                    override fun onFftDataCapture(
                        vis: Visualizer?,
                        fft: ByteArray?,
                        samplingRate: Int
                    ) {
                        if (fft == null || fft.size < 4) return
                        // Android FFT byte layout: [0]=Re[0] (DC), [1]=Re[n/2] (Nyquist),
                        // then (Re[k], Im[k]) pairs for k=1..n/2-1.
                        // samplingRate is in milliHertz → Hz = samplingRate / 1000.
                        val hzPerBin = (samplingRate / 1000.0) / captureSize
                        var sum = 0.0
                        var count = 0
                        var k = 1
                        val half = fft.size / 2
                        while (k < half) {
                            val hz = k * hzPerBin
                            if (hz > LOW_HZ_MAX) break
                            if (hz >= LOW_HZ_MIN) {
                                val re = fft[2 * k].toDouble()
                                val im = fft[2 * k + 1].toDouble()
                                sum += sqrt(re * re + im * im)
                                count++
                            }
                            k++
                        }
                        val mag = if (count > 0) sum / count else 0.0
                        // Byte magnitudes run ~0..180; normalise to [0,1]. Divisor 96
                        // (not 128) so typical bass reaches the top of the range → the
                        // Dart side's u_volume swing is big enough to be obvious.
                        val level = (mag / 96.0).coerceIn(0.0, 1.0)
                        // All-zero guard: if the capture NEVER produces a signal for a
                        // while it is being silenced (e.g. a locked-down OEM even on our
                        // own session) — emit the -1 sentinel ONCE so Dart uses its
                        // synthetic pulse. Disabled the instant we see real audio, so a
                        // quiet intro can't false-trip it.
                        if (level > 0.005) {
                            seenSignal = true
                            zeroFrames = 0
                        } else if (!seenSignal && ++zeroFrames > ZERO_FRAME_LIMIT) {
                            // Silenced capture → tell Dart to use its synthetic pulse.
                            // Dart cancels the stream on the sentinel, which fires
                            // onCancel → stopVisualizer() on the main thread (releasing
                            // here, inside the capture callback, would be unsafe).
                            mainHandler.post { events?.success(-1.0) }
                            return
                        }
                        mainHandler.post { events?.success(level) }
                    }
                },
                Visualizer.getMaxCaptureRate(), // fastest the device allows (milliHz)
                false, // waveform off
                true // fft on
            )
            v.enabled = true
            visualizer = v
        } catch (e: Throwable) {
            // Permission denied / unsupported (emulator) → tell Dart to use the
            // synthetic fallback rather than a frozen field.
            visualizer = null
            events?.success(-1.0)
        }
    }

    private fun stopVisualizer() {
        try {
            visualizer?.enabled = false
            visualizer?.release()
        } catch (_: Throwable) {
        }
        visualizer = null
    }

    override fun onDestroy() {
        stopVisualizer()
        super.onDestroy()
    }

    companion object {
        private const val FFT_CHANNEL = "wenlistener/fft"
        private const val LOW_HZ_MIN = 30.0
        private const val LOW_HZ_MAX = 300.0
        // Consecutive all-silence FFT frames before falling back to the synthetic
        // pulse (~2–6 s at the device's max capture rate) — generous so a quiet
        // passage never trips it; only a genuinely silenced capture does.
        private const val ZERO_FRAME_LIMIT = 120
    }
}
