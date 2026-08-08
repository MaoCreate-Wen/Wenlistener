import 'dart:io' show Platform;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:audio_service/audio_service.dart' as asvc;
import 'package:just_audio/just_audio.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'services/artwork_palette.dart';
import 'services/audio_handler.dart';
import 'services/audio_service.dart';
import 'services/cookie_store.dart';
import 'services/dio_factory.dart';
import 'services/fft_service.dart';
import 'services/kugou_api.dart';
import 'services/kugougn_api.dart';
import 'services/kuwo_api.dart';
import 'services/kuwo_cookie_store.dart';
import 'services/music_api_router.dart';
import 'services/netease_api.dart';
import 'services/netease_crypto.dart';
import 'services/playback_store.dart';
import 'services/qq_api.dart';
import 'services/qq_cookie_store.dart';
import 'services/qqcn_api.dart';
import 'services/qqcn_cookie_store.dart';
import 'services/settings_store.dart';
import 'state/settings_provider.dart';

/// App entry point. Initializes the audio-background isolate, builds the
/// service graph (cookies -> dio -> crypto -> api -> audio + palette) and hands
/// it to [WenListenerApp].
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Cap the global decoded-image cache. Flutter defaults to 1000 objects /
  // 100 MiB; combined with the cover art being decoded at a bounded resolution
  // (see ArtworkImage / ArtworkPalette), a tighter byte cap keeps the resident
  // decode set — the biggest startup / background-playback high-water lever — in
  // check. LRU eviction handles the rest; too-low would only cause harmless
  // re-decode jank, never a crash.
  PaintingBinding.instance.imageCache.maximumSizeBytes = 60 << 20; // 60 MiB

  // Desktop window (Windows). Frameless, min 1024x680, centered, shown BEFORE
  // runApp. window_manager's APIs throw on non-desktop platforms, so this is
  // guarded to Windows — the Android path never enters here. Reuses the
  // mockup.html sidebar + mini-player layout sizing.
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

  // Android 13+ (SDK 33+) gates the media notification behind the runtime
  // POST_NOTIFICATIONS permission — without it just_audio_background's
  // foreground service still runs, but its notification is silently suppressed
  // (the real reason the notification "vanished" on newer devices). Request it up
  // front; it auto-grants below Android 13 and the call is guarded so a denied
  // prompt (or a platform without the plugin) never blocks startup. Desktop has
  // no POST_NOTIFICATIONS concept (permission_handler_windows doesn't implement
  // notification), so the request is Android-only.
  // Fire-and-forget — do NOT await. Awaiting suspends main() (and thus the first
  // frame / runApp) behind an unbounded system permission dialog on Android 13+
  // first launch. The permission only gates the background media notification,
  // which isn't needed for the first frame; request it in the background and let
  // it resolve whenever the user taps. `.ignore()` fire-and-forgets and swallows
  // any error (e.g. plugin missing).
  if (Platform.isAndroid) {
    Permission.notification.request().ignore();
  }

  // Background audio: a custom passive audio_service handler ([WenAudioHandler])
  // mirrors the shared just_audio player into the system media notification /
  // lock screen. We drive audio_service DIRECTLY (not just_audio_background) so the
  // notification shows ONLY previous / play-pause / next — no stop button — with a
  // monochrome icon. The player is created FIRST and handed to the handler builder
  // (plain audio_service installs no player factory, unlike just_audio_background,
  // so player-before-init is correct). A background-init failure must not blank the
  // app: degrade to foreground-only playback.
  final AudioPlayer player = AudioPlayer();
  // audio_service has NO Windows platform implementation — AudioService.init
  // would throw MissingPluginException. Guard it (and the WenAudioHandler wiring)
  // to Android; desktop degrades cleanly to foreground-only playback. The app's
  // own AudioService (services/audio_service.dart) drives queue/play/seek/loop/
  // shuffle regardless — the passive handler only mirrors the system media
  // notification, which desktop simply lacks (SMTC is a future non-MVP add).
  if (Platform.isAndroid) {
    try {
      await asvc.AudioService.init(
        builder: () => WenAudioHandler(player),
        config: const asvc.AudioServiceConfig(
          androidNotificationChannelId: 'com.wenlistener.audio',
          androidNotificationChannelName: 'WenListener',
          // Keep the notification up across play AND pause (ongoing) while detaching
          // the foreground service on pause (the config asserts these two pair).
          androidNotificationOngoing: true,
          androidStopForegroundOnPause: true,
          // Monochrome white status-bar / notification icon — replaces the colourful
          // launcher icon that otherwise showed at the album-art slot.
          androidNotificationIcon: 'drawable/ic_stat_music',
        ),
      );
    } catch (e, st) {
      debugPrint(
          'AudioService.init failed (continuing foreground-only): $e\n$st');
    }
  }

  // Real-time FFT for the lyrics-page background "律动". Created here but STARTED
  // lazily (only while the lyrics page is open — see LyricsPage) so the mic is
  // held only when the reactive background is actually on screen.
  final FftService fft = FftService(player: player);

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );

  // Independent persisted stores loaded CONCURRENTLY (start all, then await) so
  // the cold-start path isn't a serial await chain before the first frame — these
  // four don't depend on each other.
  final SettingsStore settingsStore = SettingsStore();
  final KuwoCookieStore kuwoCookies = KuwoCookieStore();
  final Future<CookieStore> cookieF = CookieStore.create();
  final Future<QqCookieStore> qqCookiesF = QqCookieStore.create();
  final Future<QqcnCookieStore> qqcnCookiesF = QqcnCookieStore.create();
  final Future<void> kuwoF = kuwoCookies.load();
  final Future<SettingsData> settingsF = settingsStore.load();
  final CookieStore cookieStore = await cookieF;
  final QqCookieStore qqCookies = await qqCookiesF;
  final QqcnCookieStore qqcnCookies = await qqcnCookiesF;
  await kuwoF;
  final SettingsData settingsData = await settingsF;

  final Dio dio = DioFactory.create(cookieStore);
  const NeteaseCrypto crypto = NeteaseCrypto();
  final NeteaseApi neteaseApi =
      NeteaseApi(dio: dio, crypto: crypto, cookies: cookieStore);

  // QQ 音乐: the web [QqApi] occupies the `migu` slot (dormant rollback). The real
  // selectable QQ is the **Android client** [QqcnApi] in its own `qqcn` slot, with
  // its own cookie session — mirrors the desktop wiring.
  final QqApi qqApi = QqApi(cookies: qqCookies);
  final QqcnApi qqcnApi = QqcnApi(cookies: qqcnCookies);

  // Kugou: web [KugouApi] (`kugou`) + 酷狗概念版 [KugougnApi] (`kugougn`, the
  // FreeListen/Lite Android signed surface with fuller playback + SMS login).
  final KugouApi kugouApi = KugouApi();
  final KugougnApi kugougnApi = KugougnApi();

  // Kuwo (酷我音乐). Anonymous search + lyrics; play URL via anti.s.
  final KuwoApi kuwoApi = KuwoApi(cookieStore: kuwoCookies);

  final MusicApiRouter musicApi = MusicApiRouter(
    migu: qqApi,
    netease: neteaseApi,
    kugou: kugouApi,
    kugougn: kugougnApi,
    qqcn: qqcnApi,
    kuwo: kuwoApi,
    initial: settingsData.source,
  );

  // Persisted playback session (last queue / track / position). Restored
  // **paused** below so a cold start never auto-plays or hits the network until
  // the user presses play. Built BEFORE SettingsProvider so the latter can push
  // the restored audio-quality preference into it.
  final PlaybackStore playbackStore = PlaybackStore();
  final AudioService audio = AudioService(
    api: musicApi,
    player: player,
    store: playbackStore,
  );

  final SettingsProvider settingsProvider = SettingsProvider(
    router: musicApi,
    store: settingsStore,
    audio: audio,
    source: settingsData.source,
    rhythmEnabled: settingsData.rhythmEnabled,
    audioQuality: settingsData.audioQuality,
    cacheMaxBytes: settingsData.cacheMaxBytes,
  );

  await audio.init();
  final PlaybackSession? saved = await playbackStore.load();
  if (saved != null) await audio.restore(saved);
  const ArtworkPalette palette = ArtworkPalette();

  runApp(
    WenListenerApp(
      cookieStore: cookieStore,
      dio: dio,
      crypto: crypto,
      neteaseApi: neteaseApi,
      qqApi: qqApi,
      qqCookies: qqCookies,
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
}
