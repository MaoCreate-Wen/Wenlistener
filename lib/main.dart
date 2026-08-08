import 'dart:io' show Platform;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:just_audio/just_audio.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'router/app_router.dart';
import 'router/routes.dart';
import 'services/artwork_palette.dart';
import 'services/audio_service.dart';
import 'services/cookie_store.dart';
import 'services/dio_factory.dart';
import 'services/fft_service.dart';
import 'services/kugou_api.dart';
import 'services/kugougn_api.dart';
import 'services/kuwo_api.dart';
import 'services/kuwo_cookie_store.dart';
import 'services/mem_probe.dart';
import 'services/music_api_router.dart';
import 'services/netease_api.dart';
import 'services/netease_crypto.dart';
import 'services/playback_store.dart';
import 'services/qqcn_api.dart';
import 'services/qqcn_cookie_store.dart';
import 'services/settings_store.dart';
import 'shell/tray_controller.dart';
import 'state/settings_provider.dart';

/// Desktop (Windows) entry point. Builds the service graph ONCE — identical to
/// the mobile order minus the Android-only isolates — then hands it to
/// [WenListenerApp].
///
/// Android-only bits are guarded OFF on desktop (DESKTOP_WIRING §1):
///  - NO `AudioService.init(WenAudioHandler)` — `audio_service` has no Windows
///    platform impl (`init` throws `MissingPluginException`); `just_audio`
///    (+ `just_audio_windows` Media Foundation) plays directly, foreground-only.
///  - NO `Permission.notification` request — no desktop notification concept.
///  - `FftService` is constructed but inert on Windows — its native Visualizer
///    `EventChannel` is Android-only, so `start()` self-guards to the `< 0`
///    sentinel and the lyrics background falls back to its synthetic pulse.
/// Debug memory-profiling switch. `false` = normal app; `true` = enable the
/// [MemProbe] trace + the home→player→lyrics→home auto-driver in [main]. Only
/// has any effect in debug builds. Leave `false` for normal use.
const bool _kMemProfiling = false;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Cap the in-memory image cache so a library full of album covers can't balloon the working set
  // (default is 1000 images / 100 MB). 64 MB: every now-playing-path decode is display/analysis
  // sized (ResizeImage buckets ≤ 640² ≈ 1.6 MB, palette/mesh analysis 128² ≈ 64 KB), so 64 MB
  // holds ~40 big-bucket covers — while any stray full-resolution decode (a 2000-3000px Netease
  // cover is a 25-36 MB RGBA entry; several such paths used to pin the old 150 MB cap forever,
  // measured as the #1 driver of the 400-500 MB lyrics-page working set) is now evicted quickly
  // instead of parking ~150 MB in the working set for the rest of the session.
  PaintingBinding.instance.imageCache.maximumSizeBytes = 64 << 20;

  // DEBUG memory profiling — OFF by default. Flip [_kMemProfiling] to true to
  // (a) stream a working-set + imageCache trace via [MemProbe] and (b) auto-drive
  // home→player→lyrics→home so the trace captures the navigation peaks with no
  // mouse input. Both are additionally kDebugMode-guarded (fully out of release).
  if (_kMemProfiling) MemProbe.instance.start();

  // (A) DESKTOP WINDOW — frameless, min 1024x680, centered, shown BEFORE runApp.
  // window_manager's APIs throw on non-desktop platforms, so this is guarded to
  // Windows. Custom title bar / controls are drawn by DesktopWindowFrame
  // (app.dart's MaterialApp builder). Sizing mirrors mockup.html.
  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    const WindowOptions opts = WindowOptions(
      size: Size(1180, 760),
      minimumSize: Size(1024, 680),
      center: true,
      title: 'WenListener',
      titleBarStyle: TitleBarStyle.hidden,
      windowButtonVisibility: false,
    );
    await windowManager.waitUntilReadyToShow(opts, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  // (B) SHARED PLAYER — one AudioPlayer feeds AudioService + FftService.
  // (C)/(D) skipped on desktop: no AudioService.init(WenAudioHandler), no
  // Permission.notification (both Android-only — see doc-comment above).
  final AudioPlayer player = AudioPlayer();

  // (E) FFT — constructed but inert on desktop (start() self-guards to the
  // sentinel). Kept in the graph so PlayerProvider(lowFreqVolume:) and the lyrics
  // page compile and behave identically to mobile.
  final FftService fft = FftService(player: player);

  // (F) COOKIES -> DIO -> CRYPTO -> APIS (identical to mobile).
  final CookieStore cookieStore = await CookieStore.create();
  final Dio dio = DioFactory.create(cookieStore);
  const NeteaseCrypto crypto = NeteaseCrypto();
  final NeteaseApi neteaseApi =
      NeteaseApi(dio: dio, crypto: crypto, cookies: cookieStore);
  // QQ 音乐（安卓客户端）— the QQ source (its own qqcn_* session + jar). The old
  // web QQ (`migu` slot) was removed; only this Android QQ remains.
  final QqcnCookieStore qqcnCookies = await QqcnCookieStore.create();
  final QqcnApi qqcnApi = QqcnApi(cookies: qqcnCookies);
  // Anonymous Kugou (酷狗 web) — signs each request; a full login unlocks play.
  final KugouApi kugouApi = KugouApi();
  // Kugou 概念版 (FreeListen/Lite Android) — a SEPARATE source; its own phone-login
  // account and Android play/lyric/签到 endpoints.
  final KugougnApi kugougnApi = KugougnApi();
  // Kuwo (酷我) — anonymous search + lyrics; play URL best with login cookies.
  final KuwoCookieStore kuwoCookies = KuwoCookieStore();
  await kuwoCookies.load();
  final KuwoApi kuwoApi = KuwoApi(cookieStore: kuwoCookies);

  // (G) SETTINGS (persisted source + 律动 + audioQuality) — before the router.
  final SettingsStore settingsStore = SettingsStore();
  final SettingsData settingsData = await settingsStore.load();

  // (H) ROUTER — multiplex the four backends; initial source from settings.
  final MusicApiRouter musicApi = MusicApiRouter(
    netease: neteaseApi,
    kugou: kugouApi,
    kugougn: kugougnApi,
    kuwo: kuwoApi,
    qqcn: qqcnApi,
    initial: settingsData.source,
  );

  // (I) AUDIO — playbackStore + the app's own AudioService (owns queue/seek/
  // loop/shuffle). Built BEFORE SettingsProvider so the latter can push the
  // restored audio-quality preference into it.
  final PlaybackStore playbackStore = PlaybackStore();
  final AudioService audio = AudioService(
    api: musicApi,
    player: player,
    store: playbackStore,
  );

  // (J) SETTINGS PROVIDER — pushes restored audioQuality into audio at ctor.
  final SettingsProvider settingsProvider = SettingsProvider(
    router: musicApi,
    store: settingsStore,
    audio: audio,
    source: settingsData.source,
    rhythmEnabled: settingsData.rhythmEnabled,
    audioQuality: settingsData.audioQuality,
    closeBehavior: settingsData.closeBehavior,
  );

  // (K) INIT + RESTORE (paused, zero-network cold start) + PALETTE.
  await audio.init();
  final PlaybackSession? saved = await playbackStore.load();
  if (saved != null) await audio.restore(saved);
  const ArtworkPalette palette = ArtworkPalette();

  // (K2) SYSTEM TRAY + close-behavior + 轻量模式 — lives outside the widget
  // tree (like the rest of the service graph) so tray playback controls and
  // the ✕ setting keep working while 轻量模式 has the UI tree disposed.
  // Windows-only, same guard as the window bootstrap above.
  if (Platform.isWindows) {
    final TrayController tray = TrayController(
      audio: audio,
      settings: settingsProvider,
    );
    await tray.init();
  }

  // (L) run the app with the full service graph.
  runApp(
    WenListenerApp(
      cookieStore: cookieStore,
      dio: dio,
      crypto: crypto,
      neteaseApi: neteaseApi,
      qqcnApi: qqcnApi,
      qqcnCookies: qqcnCookies,
      kugouApi: kugouApi,
      kugougnApi: kugougnApi,
      kuwoApi: kuwoApi,
      kuwoCookies: kuwoCookies,
      musicApi: musicApi,
      audio: audio,
      palette: palette,
      fft: fft,
      settings: settingsProvider,
    ),
  );

  _debugAutoDriveMemProbe();
}

/// DEBUG-only profiling driver. With NO mouse input, cycles
/// home→player→lyrics→home a few times so [MemProbe] captures the navigation
/// memory peaks the user reports (opening the heavy now-playing surface, and
/// returning home). Relies on a restored/paused session so `/player` has a song.
/// Compiled out of release; remove once profiling is done.
Future<void> _debugAutoDriveMemProbe() async {
  if (!kDebugMode || !_kMemProfiling) return;
  final GoRouter r = AppRouter.router;
  await Future<void>.delayed(const Duration(seconds: 8)); // let restore settle
  MemProbe.instance.mark('drive.begin (baseline=home)');
  for (int i = 0; i < 3; i++) {
    MemProbe.instance.mark('drive[$i].open.player');
    r.push(Routes.player);
    await Future<void>.delayed(const Duration(seconds: 5));
    MemProbe.instance.mark('drive[$i].open.lyrics');
    r.push(Routes.lyrics);
    await Future<void>.delayed(const Duration(seconds: 5));
    MemProbe.instance.mark('drive[$i].pop.lyrics(->player)');
    r.pop();
    await Future<void>.delayed(const Duration(seconds: 3));
    MemProbe.instance.mark('drive[$i].pop.player(->home)');
    r.pop();
    await Future<void>.delayed(const Duration(seconds: 5));
  }
  MemProbe.instance.mark('drive.done (settled=home)');
}
