# DESKTOP_WIRING.md — WenListener Desktop (Windows) service graph + provider API

> How the fresh **desktop-native UI** consumes the **reused logic layer**
> (`lib/{services,models,state,animation}` — the same crypto/API/login/AMLL engine as
> the mobile app). This doc is the contract for the page agents: it fixes the
> `main.dart` construction order, the `MultiProvider` list, and a per-provider
> "what the desktop UI reads / calls" map. **Do NOT rewrite logic** — consume the
> `ChangeNotifier` providers via `provider` / `context.select`.

Flutter is NOT on PATH → `C:\flutter\bin\flutter.bat` (3.38.9).

---

## 0. What already exists vs. what the UI agents build

**Present (reuse, do not touch):** `lib/models/**`, `lib/services/**`, `lib/state/**`,
`lib/animation/**` (AMLL engine: `spring.dart`, `lyric_player_controller.dart`,
`lyric_line_render.dart`, `emphasis.dart`, `interlude_dots.dart`, `neon_flow_background.dart`
+ `mesh_gradient/`, `art_background.dart`).

**Missing — must be built fresh for desktop (blockers to first compile):**
- `lib/theme/**` — **the reused services import `../theme/app_colors.dart` and will not
  compile without it.** `artwork_palette.dart`, `neon_flow_background.dart`,
  `art_background.dart` reference exactly these `AppColors` static `Color` members:
  **`bg`, `seed`, `seedDeep`, `accentPlay`** (only these four are required by the logic
  layer; add `surface`, `surfaceGlass`, `surfaceGlassBorder`, `onSurface`,
  `onSurfaceMuted`, `onSurfaceFaint` for the UI per DESIGN_SYSTEM.md §2). Also build
  `app_typography.dart` (display = `AlimamaDongFangDaKai`, bundled in pubspec),
  `app_dimens.dart`, `app_theme.dart` (`AppTheme.dark()` → M3 OLED dark).
- `lib/main.dart` — desktop entry (spec in §2 below). **Does not exist yet.**
- `lib/app.dart` — root `MultiProvider` widget (spec in §3). **Does not exist yet.**
- `lib/router/**`, `lib/shell/**` (sidebar + docked mini-player + custom title bar),
  `lib/pages/**`, `lib/widgets/**` — all fresh desktop-native UI.

**pubspec already has** `window_manager: ^0.5.2`, `just_audio_windows: ^0.2.3`,
`audio_service`, `just_audio`, `provider`, `go_router`, `qr_flutter`,
`palette_generator`, `cached_network_image`, `file_picker`, `permission_handler`.

---

## 1. Desktop guards — the four Android-only bits, disabled cleanly on Windows

The mobile `main.dart` does four things that MUST be neutralised on desktop. All are
guarded by `Platform.isAndroid` / `Platform.isWindows` (import `dart:io show Platform`):

| Mobile bit | Desktop treatment |
|---|---|
| `asvc.AudioService.init(builder: WenAudioHandler…)` (system media notification isolate) | **SKIP** — `audio_service` has no Windows platform impl; `init` throws `MissingPluginException`. Do NOT build `WenAudioHandler`. `just_audio` (+`just_audio_windows` Media Foundation) plays directly. SMTC is a future non-MVP add. `audio_handler.dart` stays unimported. |
| `Permission.notification.request()` (Android 13 POST_NOTIFICATIONS) | **SKIP** — no notification concept on desktop; `permission_handler_windows` doesn't implement it. |
| `FftService.start()` (native `wenlistener/fft` Visualizer EventChannel + RECORD_AUDIO) | **Construct `FftService(player: player)` normally, but it is inert on desktop by design.** `FftService.start()` already short-circuits to the sentinel `lowFreqVolume = -1.0` when `!Platform.isAndroid` (never touches the EventChannel or `permission_handler`). So the lyrics page's `NeonFlowBackground` runs its **synthetic pulse** — the mesh still flows, it just never beat-reacts. No extra guard needed at the call site; still gate `fft.start()`/`fft.stop()` to the lyrics page lifecycle. |
| `SystemChrome.setSystemUIOverlayStyle(...)` (status bar) | Harmless no-op on desktop; may keep or drop. |

**New desktop-only bit (replaces the mobile status-bar / SafeArea concerns):**
`window_manager.ensureInitialized()` + frameless hidden-title-bar + min-size, awaited
**before** `runApp`. This is the mobile `main.dart`'s existing `if (Platform.isWindows)`
block — keep it verbatim (`Size(1180, 760)`, `minimumSize: Size(1024, 680)`,
`center: true`, `titleBarStyle: TitleBarStyle.hidden`, `windowButtonVisibility: false`).
The custom frameless title bar (window controls) is drawn by a `shell/` widget wired in
`app.dart`'s `MaterialApp.router` `builder:` (see §3). Add `window_manager` drag/close/
minimize/maximize handlers there.

---

## 2. `lib/main.dart` — exact desktop construction order

Build the graph ONCE in `main()`, in this order (mirrors the mobile order minus the
Android isolates), then hand it to `WenListenerApp`:

```
WidgetsFlutterBinding.ensureInitialized();

// (A) DESKTOP WINDOW — before runApp, Windows-guarded.
if (Platform.isWindows) {
  await windowManager.ensureInitialized();
  const opts = WindowOptions(size: Size(1180,760), minimumSize: Size(1024,680),
      center: true, title: 'WenListener',
      titleBarStyle: TitleBarStyle.hidden, windowButtonVisibility: false);
  await windowManager.waitUntilReadyToShow(opts, () async {
    await windowManager.show(); await windowManager.focus();
  });
}

// (B) SHARED PLAYER — one AudioPlayer feeds AudioService + FftService.
final AudioPlayer player = AudioPlayer();

// (C) NO AudioService.init on desktop (guarded to Android → skipped). No WenAudioHandler.
// (D) NO Permission.notification.request() on desktop (guarded to Android → skipped).

// (E) FFT — construct but inert on desktop (start() self-guards to the sentinel).
final FftService fft = FftService(player: player);

// (F) COOKIES → DIO → CRYPTO → APIS  (identical to mobile)
final CookieStore cookieStore = await CookieStore.create();
final Dio dio = DioFactory.create(cookieStore);
const NeteaseCrypto crypto = NeteaseCrypto();
final NeteaseApi neteaseApi = NeteaseApi(dio: dio, crypto: crypto, cookies: cookieStore);
final QqCookieStore qqCookies = await QqCookieStore.create();
final QqApi qqApi = QqApi(cookies: qqCookies);         // occupies the router `migu` slot
final KugouApi kugouApi = KugouApi();
final KuwoCookieStore kuwoCookies = KuwoCookieStore();
await kuwoCookies.load();
final KuwoApi kuwoApi = KuwoApi(cookieStore: kuwoCookies);

// (G) SETTINGS (persisted source + 律动 + audioQuality) — load before the router.
final SettingsStore settingsStore = SettingsStore();
final SettingsData settingsData = await settingsStore.load();

// (H) ROUTER — multiplex the 4 backends; initial source from persisted settings.
final MusicApiRouter musicApi = MusicApiRouter(
  migu: qqApi, netease: neteaseApi, kugou: kugouApi, kuwo: kuwoApi,
  initial: settingsData.source,          // local: defaults to const LocalMusicApi()
);

// (I) AUDIO — playbackStore + the app's own AudioService (owns queue/seek/loop/shuffle).
final PlaybackStore playbackStore = PlaybackStore();
final AudioService audio = AudioService(api: musicApi, player: player, store: playbackStore);

// (J) SETTINGS PROVIDER — pushes restored audioQuality into audio at construction.
final SettingsProvider settingsProvider = SettingsProvider(
  router: musicApi, store: settingsStore, audio: audio,
  source: settingsData.source, rhythmEnabled: settingsData.rhythmEnabled,
  audioQuality: settingsData.audioQuality);

// (K) INIT + RESTORE (paused, zero-network cold start) + PALETTE
await audio.init();
final PlaybackSession? saved = await playbackStore.load();
if (saved != null) await audio.restore(saved);
const ArtworkPalette palette = ArtworkPalette();

// (L) runApp(WenListenerApp(...))  — pass every service (see §3 ctor).
```

Ordering rules that matter: **player before FftService** (FFT needs its session id — inert
on desktop but keep the shape); **settings loaded before the router** (router `initial`
source); **audio built before SettingsProvider** (the provider pushes `audioQuality` into
`audio` in its ctor); **`audio.init()` then `restore()` before runApp** (mini-player shows
the restored, paused track immediately). No `AudioService.init`, no `WenAudioHandler`, no
notification permission on this path.

---

## 3. `lib/app.dart` — `WenListenerApp` ctor + `MultiProvider` list

Constructor takes (same 15 params as mobile, minus nothing — desktop keeps them all;
`fft` is inert but still injected so `PlayerProvider(lowFreqVolume:)` and the lyrics page
compile identically):

`cookieStore, dio, crypto, neteaseApi, qqApi, qqCookies, kugouApi, kuwoApi, kuwoCookies,
musicApi, audio, palette, fft, settings`.

`MultiProvider` list (exact — replicate mobile wiring; lazy flags are load-bearing):

```
// plain services via Provider.value (UI reads, never rebuilds on them):
Provider<CookieStore>.value(value: cookieStore),
Provider<Dio>.value(value: dio),
Provider<NeteaseCrypto>.value(value: crypto),
Provider<NeteaseApi>.value(value: neteaseApi),
Provider<QqApi>.value(value: qqApi),
Provider<AudioService>.value(value: audio),
Provider<ArtworkPalette>.value(value: palette),
Provider<FftService>.value(value: fft),

// router is a ChangeNotifier (source switcher rebuilds on flip):
ChangeNotifierProvider<MusicApiRouter>.value(value: musicApi),
ChangeNotifierProvider<SettingsProvider>.value(value: settings),

// the page-facing providers:
ChangeNotifierProvider<PlayerProvider>(create: (_) => PlayerProvider(
    audio: audio, api: musicApi, palette: palette, lowFreqVolume: fft.lowFreqVolume)),
ChangeNotifierProvider<SearchProvider>(create: (_) => SearchProvider(api: musicApi)),
ChangeNotifierProvider<LibraryProvider>(create: (_) => LibraryProvider(api: musicApi)),
ChangeNotifierProvider<LocalPlaylistProvider>(create: (_) => LocalPlaylistProvider(
    store: LocalPlaylistStore(), scanner: const LocalMusicScanner())),

// auth — the lazy flags MUST match: eager providers validate/reinstall at startup.
ChangeNotifierProvider<AuthProvider>(lazy: false, create: (_) => AuthProvider(
    api: neteaseApi, cookies: cookieStore, router: musicApi)),          // eager
ChangeNotifierProvider<KugouAuthProvider>(lazy: false, create: (_) => KugouAuthProvider(
    api: kugouApi, store: KugouAccountStore(), router: musicApi)),      // eager
ChangeNotifierProvider<QqAuthProvider>(lazy: false, create: (_) => QqAuthProvider(
    api: qqApi, cookies: qqCookies, router: musicApi)),                 // eager
ChangeNotifierProvider<KuwoAuthProvider>(create: (_) => KuwoAuthProvider(
    api: kuwoApi, cookies: kuwoCookies, router: musicApi)),             // LAZY ok
```

**Why the lazy flags:** `AuthProvider` (net­ease), `KugouAuthProvider`, `QqAuthProvider`
must be `lazy:false` — they validate a restored session / reinstall the persisted active
credential at startup even if the user never opens a login page. `KuwoAuthProvider` is
password login (no startup credential push) → lazy is fine.

`child:` wrap a **`_LikedSeeder`** (needs both `LibraryProvider` + `PlayerProvider`) around
`MaterialApp.router` — it fetches the netease "我喜欢的音乐" playlist once per login and
`player.markLiked(ids)` so past likes show a filled heart. Copy the mobile `_LikedSeeder`
verbatim (it only touches the two providers, no Android bits).

`MaterialApp.router(theme: AppTheme.dark(), routerConfig: <desktop go_router>,
builder: (ctx, child) => DesktopWindowFrame(child: child))` — the `builder` pins the custom
frameless title bar above every route (see §1). `DesktopWindowFrame` is new desktop UI.

**Note — `LibraryProvider._onSourceChanged` comment vs. behavior:** the router routes
`userPlaylists`/`playlistDetail`/writes through **`active`** (the current UI source), not
forced to netease. Library shows the *current source's* playlists; 咪咕/酷狗 return `[]`.

---

## 4. Per-provider API — what the desktop UI reads / calls

Access pattern: **`context.select((P p) => p.field)`** for reads (never
`context.watch` a whole heavy provider — `PlayerProvider` notifies every position tick,
so the mini-player / any always-mounted widget must `select` a single field, per the
mobile per-tick-rebuild lesson). Call mutators via `context.read<P>().method()`.

### PlayerProvider (`state/player_provider.dart`) — now-playing, queue, lyrics, accent
Reads: `currentSong` (`Song?`), `queue` (`List<Song>`), `currentIndex` (`int?`), `hasSong`,
`isPlaying`, `isBuffering`, `position` (`Duration`), `duration` (`Duration`, with
`Song.duration` fallback), `progress` (`0..1`), `repeatMode` (`RepeatMode.{off,all,one}`),
`shuffleEnabled`, `volume`, `dynamicAccent` (`Color` — drives scrubber/active/glow),
`dynamicGradient` (`Gradient` — live per-track), `washGradient` (`Gradient` — frozen after
first track, for shell/home bg), `paletteColors`, `lyrics` (`Lyrics`), `lyricsLoading`,
`lyricsSettled` (gate "No lyrics" empty state behind this), `activeLyricIndex` (`int`),
`isLiked`, `isLikedSong(song)`, `playbackError` (`String?`), `lowFreqVolume`
(`ValueListenable<double>?` → forward to `NeonFlowBackground`).
Calls: `playSong(song, {queue, index})`, `playQueue(songs, {index})`, `togglePlay()`,
`next()`, `previous()`, `seek(Duration)`, `jumpTo(index)` (tap a queue row — no reload
flash), `cycleRepeat()`, `toggleShuffle()`, `setVolume(0..1)`, `toggleLike()`,
`setLiked(song,bool)` (optimistic ♥ w/ captured song), `retryLyrics()`,
`clearPlaybackError()`.
Desktop use: mini-player (docked, always mounted → `select` per field), full player page
(cover+controls LEFT), lyrics view (RIGHT), queue panel, volume slider (desktop has a real
volume control — mobile largely didn't), like button.

### SearchProvider (`state/search_provider.dart`)
Reads: `query`, `activeType` (`SearchType`), `result` (`SearchResult` — `.songs/.albums/
.artists/.playlists/.total/.hasMore`), `isLoading`, `isLoadingMore`, `hasError`, `hasMore`,
`history` (`List<String>`).
Calls: `setQuery(q)`, `setType(SearchType)` (re-searches if query non-empty), `search([q])`,
`loadMore()` (infinite scroll / "load more" row), `clearHistory()`, `reset()`.
Auto-resets when the router source flips (listens to `MusicApiRouter`).
Desktop use: search page — pinned pill field in title bar or top of Search route, tab chips
(Songs/Albums/Artists/Playlists), multi-column results (`SongTile` rows with columns).

### LibraryProvider (`state/library_provider.dart`) — home feed + playlists + writes
Reads: `homeLoading`, `homeError`, `homeSections` (`List<HomeSection>` — kinds:
`dailySongs`, `playlistCarousel`, `recommendedGrid`), `userPlaylists` (`List<Playlist>`,
`.first` = 我喜欢的音乐), `userPlaylistsLoading`, `createdPlaylists`, `collectedPlaylists`
(memoized split — safe for `context.select` identity), `source` (`MusicSource`),
`isPlaylistLoading(id)`, `playlist(id)` (cached).
Calls: `loadHome()`, `loadUserPlaylists({force})`, `loadPlaylist(id)` → `Future<Playlist>`
(cached), `fetchPlaylistFresh(source, id)` (bypass cache, for local-playlist resync),
`addSongToPlaylist(pid, song)`, `removeSongFromPlaylist(pid, song)`,
`createUserPlaylist(name)` → `Future<int>`, `deleteUserPlaylist(id)`,
`collectPlaylist(id, collect)` (all NetEase-only, throw on other sources → surface error).
Desktop use: home/discovery route (multi-column carousels + grid), left-sidebar "我的歌单"
list, playlist detail route (dense track rows: index · title · artist · album · duration).

### SettingsProvider (`state/settings_provider.dart`) — source + 律动 + quality
Reads: `source` (`MusicSource`), `rhythmEnabled` (`bool`), `audioQuality` (`AudioLevel`).
Calls: `setSource(MusicSource)` (live router switch + persist — reloads feeds via router
listeners; do NOT call `router.setSource` directly), `setRhythmEnabled(bool)`,
`setAudioQuality(AudioLevel)`.
Desktop use: settings route — source picker (网易云 / QQ音乐 / 酷狗 / 酷我), 律动 toggle,
audio-quality dropdown, embedded account/login section (see auth providers).

### AuthProvider (`state/auth_provider.dart`) — NetEase QR login + multi-account
Reads: `isLoggedIn`, `account` (`NeteaseAccount?` — uid/nickname/avatar/vip), `qrStatus`
(`QrStatus`), `qrContent` (`String?` → render with `qr_flutter`'s `QrImageView`), `qrLoading`,
`accounts` (`List<CookieAccount>`), `activeId`.
Calls: `startQrLogin()` (enter login → begins polling), `cancelQrLogin()` (leave login),
`switchAccount(id)`, `removeAccount(id)`, `logout()`, `pollNow()`, `refreshLoginState()`.
**Desktop nuance:** the mobile background-resume `pollNow()` (user leaves to the NetEase
app) is irrelevant on desktop — the user scans a phone while the window stays foreground,
so the 2s timed poll loop drives it. `WidgetsBindingObserver` resume still fires harmlessly.
Desktop use: settings account section (inline auto-start QR keyed by source, like mobile),
accounts route (multi-account switch/remove), profile card.

### KugouAuthProvider (`state/kugou_auth_provider.dart`) — 酷狗 QR + multi-account
Reads: `accounts` (`List<KugouAccount>`), `loaded`, `active` (`KugouAccount?`), `activeUserId`,
`isLoggedIn`, `qrStatus` (`KugouQrStatus`), `qrImage` (`String?` `data:image/png;base64,…`
→ `Image.memory` after stripping the prefix), `qrLoading`.
Calls: `startQrLogin()`, `cancelQrLogin()`, `switchTo(userId)`, `removeAccount(userId)`,
`pollNow()`. Eager at startup: reinstalls the persisted active credential into `KugouApi`.

### QqAuthProvider (`state/qq_auth_provider.dart`) — QQ 微信/QQ 扫码 + multi-account
Reads: `isLoggedIn`, `account` (`QqAccount?`), `method` (`QqLoginMethod.{qq,wx}`), `qrImage`
(`Uint8List?` → `Image.memory`), `qrStatus` (`QqQrStatus`), `qrLoading`, `finishingLogin`
(show "正在登录…" during the OAuth handoff, not "登录成功"), `accounts`, `activeId`.
Calls: `startLogin(QqLoginMethod)` (toggle 微信↔QQ restarts cleanly), `cancelLogin()`,
`switchAccount(id)`, `removeAccount(id)`, `logout()`, `pollNow()`.

### KuwoAuthProvider (`state/kuwo_auth_provider.dart`) — 酷我 password + captcha
Reads: `isLoggedIn`, `step` (`KuwoLoginStep.{idle,loadingCaptcha,waitingInput,loggingIn,
done,failed}`), `captchaBytes` (`Uint8List?` → `Image.memory`), `errorMsg` (`String?`).
Calls: `loadCaptcha()` (on opening login), `login({username, password, verifyCode})`
→ `Future<bool>`, `logout()`, `reset()`. **Password form, not QR** — desktop renders a
proper text-field form (username/password/captcha image + code field).

### LocalPlaylistProvider (`state/local_playlist_provider.dart`) — 共同歌单 (cross-source)
Reads: `playlists` (`List<LocalPlaylist>`, newest first), `loaded`, `byId(id)`,
`containsSong(id, songId)` (✓/＋ affordance).
Calls: `create(name, {tracks, origin})`, `resync(id, remoteTracks)` →
`Future<({int added, int removed})>` (pair with `LibraryProvider.fetchPlaylistFresh`),
`rename(id, name)`, `delete(id)`, `addSong(id, song)` (top-insert), `removeSong(id, songId)`,
`importLocalFiles(id, {scanDir})` → count (needs `file_picker` — works on desktop),
`createFromLocalFiles(name, {scanDir})`.
Desktop use: sidebar 共同歌单 section, `/local/:id` detail (source-tagged rows + resync),
"add to local playlist" from player/track context menu, local-file import buttons.

### MusicApiRouter (`services/music_api_router.dart`) — read via providers mostly
The UI rarely touches it directly (go through SettingsProvider/LibraryProvider/SearchProvider).
Exposed getter `source`; the source switcher must call `SettingsProvider.setSource`, not the
router. Play/lyric dispatch is **per-song by `Song.source`** — a mixed-source local playlist
plays end to end regardless of the active UI source. `refresh()` (login/logout) re-notifies
without changing source.

### AudioService (`services/audio_service.dart`) — do NOT call from pages
Owned by `PlayerProvider`; pages go through the provider. `unplayableMessage` surfaces via
`PlayerProvider.playbackError`. On desktop the passive notification handler is absent (no
`WenAudioHandler`), so `AudioService` is the sole playback owner — nothing changes in its API.

---

## 5. Model quick-ref (what rows/cards render)

- **Song**: `id`, `name`, `artists` (`artistNames` → "A / B"), `album` (`album?.name`),
  `artworkUrl` (`album?.picUrl`), `duration`, `source` (`MusicSource`), `fee`, `playable`,
  `reason` (推荐理由). Row columns: index · `name` · `artistNames` · `album?.name` ·
  `duration` (format mm:ss).
- **Playlist**: `id`, `name`, `coverUrl`, `creatorName`, `description`, `trackCount`,
  `playCount`, `subscribed`, `tracks` (`List<Song>`).
- **HomeSection**: `title`, `subtitle?`, `kind` (`HomeSectionKind`), `playlists`, `songs`.
- **SearchResult**: `type`, `songs/albums/artists/playlists`, `total`, `hasMore`.
- **Lyrics**: `lines` (`List<LyricLine>` — `.start/.end/.text/.words/.translation/
  .isWordByWord`), `hasWordByWord`, `hasTranslation`, `indexAt(position)`.
- **AudioLevel** `{standard, higher, exhigh(default), lossless, hires}` — quality dropdown.
- **RepeatMode** `{off, all, one}` — repeat toggle.
- **MusicSource** `{migu(=QQ slot), netease, kugou, kuwo, local}`.
- Netease cover URLs must be rendered via `httpsImageUrl()` + `kNeteaseImageHeaders`
  (`models/image_url.dart`) or they 403 / fall back to placeholder. Use `ArtworkImage`
  (build it in `widgets/`) wrapping `cached_network_image` with those headers.

---

## 6. First-compile checklist for the shell/theme agent

1. Create `lib/theme/app_colors.dart` with at least `bg`, `seed`, `seedDeep`, `accentPlay`
   (const `Color`s) — **the logic layer won't compile otherwise** — plus the DESIGN_SYSTEM
   surface/text tokens. Then `app_typography.dart` (`AlimamaDongFangDaKai` display),
   `app_dimens.dart`, `app_theme.dart` (`AppTheme.dark()`).
2. Create `lib/main.dart` per §2 and `lib/app.dart` per §3.
3. Create `lib/router/**` (go_router 14.x — desktop can use a shell with a persistent LEFT
   sidebar instead of `StatefulShellRoute` bottom tabs; full-screen `/player`, `/lyrics`,
   `/playlist/:id`, `/local/:id`, `/settings`, `/accounts`, login routes on the root nav).
4. Create `lib/shell/**`: `DesktopWindowFrame` (frameless title bar + window controls via
   `window_manager`), left sidebar (Home/Search/Library nav + 我的歌单 + 共同歌单 + account
   card), docked mini-player (48px art + meta + prev/play/next + volume + right-side
   queue/lyrics), all glassmorphism per DESIGN_SYSTEM.md.
5. `flutter pub get` then `C:\flutter\bin\flutter.bat run -d windows`.

Design references: `wenlistener-pc/design/mockup.html` (sidebar + mini-player, real tokens),
`wenlistener-pc/design/DESIGN_SPEC.md` (motion), `wenlistener-pc/design/target.png` (AMLL
player: cover+controls LEFT, lyrics RIGHT, top-center grabber), `wenlistener/docs/specs/
DESIGN_SYSTEM.md` (color/type tokens), `wenlistener/docs/specs/AMLL_ANIMATION_SPEC.md`
(lyrics numbers — the `lib/animation` engine is already ported).
