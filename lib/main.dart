import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:audio_service/audio_service.dart' as asvc;
import 'package:just_audio/just_audio.dart';
import 'package:permission_handler/permission_handler.dart';

import 'app.dart';
import 'services/artwork_palette.dart';
import 'services/audio_handler.dart';
import 'services/audio_service.dart';
import 'services/cookie_store.dart';
import 'services/dio_factory.dart';
import 'services/fft_service.dart';
import 'services/kugou_api.dart';
import 'services/kuwo_api.dart';
import 'services/kuwo_cookie_store.dart';
import 'services/music_api_router.dart';
import 'services/netease_api.dart';
import 'services/netease_crypto.dart';
import 'services/playback_store.dart';
import 'services/qq_api.dart';
import 'services/qq_cookie_store.dart';
import 'services/settings_store.dart';
import 'state/settings_provider.dart';

/// App entry point. Initializes the audio-background isolate, builds the
/// service graph (cookies -> dio -> crypto -> api -> audio + palette) and hands
/// it to [WenListenerApp].
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Android 13+ (SDK 33+) gates the media notification behind the runtime
  // POST_NOTIFICATIONS permission — without it just_audio_background's
  // foreground service still runs, but its notification is silently suppressed
  // (the real reason the notification "vanished" on newer devices). Request it up
  // front; it auto-grants below Android 13 and the call is guarded so a denied
  // prompt (or a platform without the plugin) never blocks startup.
  try {
    await Permission.notification.request();
  } catch (_) {}

  // Background audio: a custom passive audio_service handler ([WenAudioHandler])
  // mirrors the shared just_audio player into the system media notification /
  // lock screen. We drive audio_service DIRECTLY (not just_audio_background) so the
  // notification shows ONLY previous / play-pause / next — no stop button — with a
  // monochrome icon. The player is created FIRST and handed to the handler builder
  // (plain audio_service installs no player factory, unlike just_audio_background,
  // so player-before-init is correct). A background-init failure must not blank the
  // app: degrade to foreground-only playback.
  final AudioPlayer player = AudioPlayer();
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
    debugPrint('AudioService.init failed (continuing foreground-only): $e\n$st');
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

  final CookieStore cookieStore = await CookieStore.create();
  final Dio dio = DioFactory.create(cookieStore);
  const NeteaseCrypto crypto = NeteaseCrypto();
  final NeteaseApi neteaseApi =
      NeteaseApi(dio: dio, crypto: crypto, cookies: cookieStore);
  // QQ Music replaces Migu as the third source (it occupies the router's `migu`
  // slot; MiguApi is kept dormant in the codebase for a one-line rollback). QQ
  // needs a login for everything — its own cookie jar backs search/play/lyric.
  final QqCookieStore qqCookies = await QqCookieStore.create();
  final QqApi qqApi = QqApi(cookies: qqCookies);
  // Anonymous Kugou (酷狗) — no login; signs each request. A third [MusicApi] the
  // router can dispatch to (per-song for play/lyric, so it mixes with the others).
  final KugouApi kugouApi = KugouApi();
  // Kuwo (酷我音乐) — fourth source. Anonymous search + lyrics; play URL via
  // anti.s (reliable with login cookies, best-effort anonymous).
  final KuwoCookieStore kuwoCookies = KuwoCookieStore();
  await kuwoCookies.load();
  final KuwoApi kuwoApi = KuwoApi(cookieStore: kuwoCookies);

  // Persisted user settings (music source + lyrics-background 律动 toggle). The
  // source DEFAULTS to Netease and is a settings choice now — login/logout no
  // longer flip it (see SettingsProvider / AuthProvider). (QQ Music exists as a
  // dormant backend in qq_api.dart, deferred until its endpoints are refreshed.)
  final SettingsStore settingsStore = SettingsStore();
  final SettingsData settingsData = await settingsStore.load();

  final MusicApiRouter musicApi = MusicApiRouter(
    migu: qqApi,
    netease: neteaseApi,
    kugou: kugouApi,
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
      kugouApi: kugouApi,
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
