# WenListener Desktop — UI System & Build Plan

> A **separate, desktop-native** Windows client. It reuses the mobile app's *logic only*
> (`lib/{services,models,state,animation}` — same crypto/API/login/providers/AMLL engine) and
> builds a **fresh desktop UI**: persistent left **Sidebar** (not bottom tabs), frameless custom
> **title bar**, docked bottom **mini-player**, multi-column/denser layouts, mouse **hover**
> states, compact track **rows** with columns, responsive to window width.
>
> **Hard rule:** pages consume the existing `ChangeNotifier` providers via `provider` /
> `context.select`. **Never** rewrite service/state logic. **Never** hardcode colors — go through
> `AppTheme` / the token classes. Flutter = `C:\flutter\bin\flutter.bat` (3.38.9). **Never run git.**

---

## 0. Sources of truth (read before building)

| Reference | What we take from it |
|---|---|
| `wenlistener-pc/design/mockup.html` | Desktop shell geometry: sidebar 230px, title bar 38px, mini-player 72px, card 150px, glass blur 18, accent pill nav. |
| `wenlistener-pc/design/DESIGN_SPEC.md` | Token values, z-index scale, screen list, motion (150–300ms, springs consumed from AMLL, wash freeze). |
| `wenlistener-pc/design/target.png` | The player/lyrics **code-level target**: cover+controls LEFT, lyrics RIGHT, one bright active line + blur-by-distance, top-center grabber, NO back-arrow/mic. |
| `wenlistener/docs/specs/DESIGN_SYSTEM.md` | Color/type tokens, component specs, Flutter rules, anti-patterns. |
| `wenlistener/lib/{main,app}.dart` (read-only) | Service-graph wiring **order** + the 15-arg `WenListenerApp` constructor. We write NEW desktop versions with `window_manager` init and Android-only bits guarded off. |

---

## 1. Design language (desktop, not scaled mobile)

**Direction:** OLED true-black canvas, frosted **glassmorphism** chrome (sidebar / title bar /
mini-player), **dynamic accent extracted from album art** driving progress/active-nav/lyric
highlight, high contrast (7:1 text on black). The desktop personality vs. mobile:

- **Left rail, not bottom tabs.** Navigation is a persistent 230px glass sidebar with a pill
  active-indicator in the dynamic accent; collapsible to a 72px icon rail on narrow windows.
- **Density.** Track lists are **multi-column tables** (`# · title · artist · album · duration`)
  with per-row hover reveal, not fat mobile tiles. Home carousels are horizontal scroll strips of
  hover-scale cards; "recommended" is a responsive `Wrap`/`GridView` that reflows with width.
- **Pointer-first.** Every interactive element has a `MouseRegion` hover state (bg/opacity/shadow
  shift, **no layout-shifting scale**), `SystemMouseCursors.click`, and right-click context menus
  where natural (track row → play / add to playlist / add to 共同歌单).
- **Window is a first-class surface.** Frameless: our own drag region + min/max/close, blended
  Apple-Music style into the top of the content.

### 1.1 Color tokens — `lib/theme/app_colors.dart`

Static dark base (from DESIGN_SYSTEM §2 / mockup `:root`):

| Token | Value | Use |
|---|---|---|
| `bg` | `#000000` | scaffold (OLED true black) |
| `surface` | `#0E0E14` | base cards/sheets |
| `surface2` | `#0F0F23` | raised panels |
| `glass` | `white @ 8%` | glass fill (over blur) |
| `glassStrong` | `white @ 12%` | denser glass (mini-player) |
| `glassBorder` | `white @ 14%` | 1px hairline on glass |
| `onSurface` | `#F8FAFC` | primary text |
| `onMuted` | `white @ 60%` | secondary text |
| `onFaint` | `white @ 38%` | tertiary / disabled |
| `accent` | `#22C55E` | default accent (overridden at runtime) |
| `seedA / seedB` | `#4338CA → #1E1B4B` | fallback gradient when no art |
| `hover` | `white @ 6%` | row/card hover fill |
| `pressed` | `white @ 10%` | pressed fill |
| `rowSelected` | `white @ 9%` | selected/active track row |

**Dynamic accent (core mechanic):** read from `PlayerProvider.dynamicAccent` /
`dynamicGradient` (already extracted via `palette_generator` in the logic layer). It drives:
progress fill, active nav pill, lyric highlight, like button, hero glow. `washGradient` (frozen
after the session's first song) tints the shell/home background. **We consume — we do not
re-extract.** Helper: `AppColors.accentOf(context)` = `context.select((PlayerProvider p) => p.dynamicAccent)`.

### 1.2 Typography — `lib/theme/app_typography.dart`

- **Display face `AlimamaDongFangDaKai`** (bundled `fonts/`): page hero titles, section headers,
  song title on player, **lyrics**. Never for body/lists.
- **UI sans** = system stack (`Segoe UI`/Roboto): all body, list rows, metadata, buttons.
- Desktop scale (logical px, slightly larger heads than mobile for wide canvas):
  `displayXL 34 / displayL 30 / displayM 26 / titleL 22 / titleM 18 / body 15 / label 13 / caption 11`.
  Line-height 1.4–1.5 multi-line. Lyrics active line ~30–34, inactive ~26.
- Exposed as `AppTypography` (raw `TextStyle`s) + baked into `ThemeData.textTheme`.

### 1.3 Spacing / radius / elevation — `lib/theme/app_dimens.dart`

- **Spacing** (4-pt): `4 8 12 16 20 24 32 48`. Desktop screen padding 24–26; section gap 18–22.
- **Radius:** `sm 10 / md 16 / lg 22 / xl 28 / pill 999`; album art radius = `size/20`.
- **Blur (σ):** panels 24; full-screen player bg 30; sidebar + mini-player 18.
- **Elevation:** blur + 1px `glassBorder` hairline + `BoxShadow(black@40%, blur 16, y 8)`.
- **Shell metrics** (from mockup): titleBar 38, sidebar 230 (rail 72), miniPlayer 72,
  card 150, cover(player) ~330, min window 1024×680, default 1180×760, max content ~1200.
- **z-index:** base 0 · sticky/nav 10 · mini-player 20 · overlays 30 · player/lyrics 40 · toasts 50.

### 1.4 Motion — `lib/theme/app_motion.dart`

- Micro-interactions 150–300ms, `transform`/`opacity` only. Ease-out enter, ease-in exit.
- Hover = color/opacity/shadow shift, **no layout-shifting scale** (press-scale via `Transform`
  only). Curves: `fast 160ms`, `standard 240ms`, `emphasized cubic(.38,1.625,.62,.995)` for the
  slider bounce.
- **Springs are consumed from AMLL** (`lib/animation`) — never re-tuned. Only our page chrome
  (sidebar collapse, mini→full player, player→lyrics) is ours.
- Wash cross-fades ~600ms on song change; **shell wash freezes on the session's first song**.

---

## 2. Shell (window frame · sidebar · mini-player)

### 2.1 `shell/window_title_bar.dart` — frameless chrome
- 38px `DragToMoveArea` (window_manager). Left: `WenListener` wordmark (display font, accent
  "Listener"). Right: min / max-restore / close `WindowCaptionButton`s (`no-drag`, hover tint;
  close hover = red). Blends into the content top (transparent over the wash), Apple-Music style.
- Guards: all `windowManager` calls behind `Platform.isWindows` (pure code-path safety though
  this build is Windows-only).

### 2.2 `shell/app_shell.dart` — `StatefulShellRoute.indexedStack` scaffold
Column: **title bar** (top) → Row[ **Sidebar** | **IndexedStack content** ] → **mini-player** (bottom).
Background = `bg` + `washGradient` overlay (from PlayerProvider, `context.select`). Content area
scrolls; sidebar + mini-player are fixed. This is the equivalent of the mobile shell's
bottom-nav + mini-player, re-laid-out for desktop.

### 2.3 `shell/sidebar.dart` — persistent left rail (glass, blur 18)
- Brand wordmark (display) at top.
- Nav items: **首页 / 搜索 / 音乐库 / 设置** (`SidebarNavItem`: icon + label, active = accent pill
  `color-mix(accent 22%)`, hover = `hover` fill, `cursor: click`). Uses `flutter_svg_icons` /
  Material icons (no emoji). Active index from the shell's `navigationShell.currentIndex`.
- `Spacer`, then **account card** (`SidebarAccountCard`): avatar + "已登录 · <source>" / "未登录",
  membership sub-line; tap → `/settings` (account section) or `/accounts`. Reads `AuthProvider` /
  the per-source auth providers + `SettingsProvider.source` via `context.select`.
- Collapsible to 72px icon rail below a width threshold (`LayoutBuilder`).

### 2.4 `shell/mini_player.dart` — docked bottom bar (72px, glass blur 18)
Layout (mockup ③): 2px accent progress line on the top edge (fraction = `PlayerProvider.progress`)
→ art(48, `md` radius) + title(display)/artist(marquee) → **centered transport** (prev · white
round play/pause · next) → right cluster (like · queue · **open lyrics/expand**) + volume slider on
hover. Click art/title → push `/player`. All state via `context.select` on `PlayerProvider`
(currentSong, isPlaying, progress, isLiked) so the bar doesn't rebuild every position tick beyond
the progress line. `MiniPlayer` is `const`-friendly and split so only the progress sliver watches
`position`.

---

## 3. Reusable widgets — `lib/widgets/`

Build once; pages consume (mirrors DESIGN_SYSTEM §5, desktop-tuned):

- `glass_container.dart` — `GlassContainer({blur, opacity, border, radius, child})`: the frosted
  surface primitive (`BackdropFilter` + fill + hairline + shadow).
- `artwork_image.dart` — `ArtworkImage({url, size, radius, hero, shadow})`: `cached_network_image`
  with placeholder + reserved size; runs Netease covers through `httpsImageUrl()` +
  `kNeteaseImageHeaders` (from `models/image_url.dart`). Shared `album_art` Hero + `flightShuttleBuilder`.
- `hover_scale.dart` — `HoverBuilder`/`HoverScale`: `MouseRegion` → hover flag; press-scale via
  `Transform` (no reflow), pointer cursor.
- `track_row.dart` — **`TrackRow`**: the desktop compact list row. Columns:
  `index/▶ · title+source-badge · artist · album · ♥(hover) · duration · ⋯(hover)`. Hover fill,
  double-click / play-button → `PlayerProvider.playQueue`, right-click → `TrackContextMenu`.
  Active row (currentSong) = accent index + `rowSelected` fill.
- `track_table.dart` — `TrackTable`: header row (`# TITLE ARTIST ALBUM ⏱`) + `ListView.builder`
  of `TrackRow` (virtualized). Responsive: hides album column under ~900px width.
- `media_card.dart` — `MediaCard({art, title, subtitle, onTap})`: 150px hover-scale carousel/grid
  card (playlist/album).
- `section_header.dart` — `SectionHeader({title, onMore})`: display-font title + "更多 ›".
- `carousel_row.dart` — horizontal scroll strip of `MediaCard` with scrollbar on hover + edge fades.
- `progress_bar.dart` — `WenProgressBar` = AMLL `BouncingSlider` port (white track @15%, fill
  @40%/pressed 90%, no thumb, 8→15px bounce on press). Draggable → `PlayerProvider.seek`.
- `transport_controls.dart` — `MediaButton` set (shuffle · prev · big play/pause · next · repeat),
  transparent, monochrome white, 700ms press bounce (AMLL feel).
- `volume_control.dart` — speaker icon + `BouncingSlider` → `PlayerProvider.setVolume`.
- `like_button.dart`, `context_menu.dart` (right-click affordances), `skeleton.dart` (loading
  placeholders, reserve space), `empty_state.dart`, `source_badge.dart` (per-song source chip).
- `qr_login_panel.dart` — shared QR block (`qr_flutter` for Netease / `Image.memory` for Kugou),
  auto-start on mount, cancel on unmount; consumes the source's auth provider.

---

## 4. Pages — `lib/pages/` (concrete desktop layouts)

Each page imports only `models/ theme/ widgets/ state/ router/routes.dart` (+ `animation/` for
lyrics). Behavior comes from providers.

### 4.1 `pages/home/home_page.dart`
`CustomScrollView`: hero greeting (`SectionHeader`-style, display font — "晚上好" + "当前音源：<source>·今天想听点什么") →
horizontal **每日推荐** carousel → **推荐歌单** carousel → responsive **推荐** grid (`Wrap` /
`SliverGrid`, hover-scale `MediaCard`s). Data: `LibraryProvider.homeSections` (`context.select`),
`homeLoading` → skeleton carousels. Card tap → `/playlist/:id`; card ▶ hover-button →
`PlayerProvider.playQueue`. Logged-in adds 每日推荐/我的歌单 rows (already provided by `homeSections`).

### 4.2 `pages/search/search_page.dart`
Pinned glass search **pill** (`TextField` + clear, `SearchProvider.setQuery`/`search`) + type
**chips** (Songs/Albums/Artists/Playlists → `SearchProvider.setType`). Body = **`TrackTable`** for
songs (compact multi-column, hover, virtualized), grid of `MediaCard` for album/playlist/artist
types. `isLoading` → skeleton table (reserve rows). Infinite scroll → `loadMore()` on
`hasMore`. History chips when query empty.

### 4.3 `pages/library/library_page.dart`
Two sections: **共同歌单** (cross-source local, `LocalPlaylistProvider.playlists`) with a "＋建单 /
导入本地音乐" header, then **我的歌单** (`LibraryProvider.userPlaylists`, source-aware). Both as
`MediaCard` grids with hover actions (open / delete-context-menu). Create/import via
`LocalPlaylistProvider` + `pickLocalImportMode()`. Empty/unauth → `EmptyState` prompting login.

### 4.4 `pages/playlist/playlist_detail_page.dart` (top-level route `/playlist/:id`)
Large **blurred-cover header**: `Stack` [ blurred cover fill (σ30) + scrim ] over Row[ crisp cover
+ (display-font title + creator + count + **Play-all** CTA in accent + 收藏/导入到共同歌单 buttons) ].
Below: dense **`TrackTable`** (index/title/artist/album/duration, hover row actions, right-click →
add to playlist / 共同歌单). Data from `LibraryProvider.loadPlaylist(id)`; local playlists route to
`pages/library/local_playlist_detail_page.dart` (`/local/:id`) with a source-badge column +
remove/rename/resync. Virtualized `ListView.builder`.

### 4.5 `pages/settings/settings_page.dart`
Sectioned form: **音源** selector (网易云 / QQ音乐 / 酷狗 / 酷我 → `SettingsProvider.setSource`) →
**账号** (per current source: inline `QrLoginPanel` for Netease/Kugou/QQ, password form for Kuwo,
"免登录" note where anon; summary + logout when signed in; link to `/accounts`) → **背景律动** toggle
(`SettingsProvider.rhythmEnabled`) → 音质 → 关于. Desktop two-column form rows (label left, control
right).

### 4.6 `pages/accounts/accounts_page.dart` (`/accounts`)
Multi-account manager: Netease (single cookie account), Kugou (multi, switchable), QQ, Kuwo —
each a card with avatar/nickname/membership + add/switch/remove, consuming the respective auth
provider. Kugou/Netease/QQ "add" opens the QR route; Kuwo opens password login.

### 4.7 `pages/login/*` (full-screen, `/login/:source`)
`login_netease.dart` / `login_qq.dart` (微信+QQ chips) / `login_kugou.dart` = `QrLoginPanel`
centered on a glass card; `login_kuwo.dart` = username/password(+captcha) form. Auto-start QR on
mount, cancel on dispose (per the source's auth provider state machine).

---

## 5. Player + Lyrics — code-level match of `target.png`

Two **top-level full-screen routes** (`/player`, `/lyrics`) over the shell (z40), pushed on
`rootNavigatorKey`. Dynamic art-driven background (`animation/art_background.dart` for player,
`animation/neon_flow_background.dart` + FFT for lyrics). Top-center **grabber** (`SheetGrabber`);
**NO back-arrow, NO mic** — matches target.png.

### 5.1 `pages/player/player_page.dart` — horizontal split (target.png left half)
`Row`:
- **LEFT column** (fixed ~46% / ~470px): grabber (top-center) → large **cover** (~330, radius
  size/20, soft shadow, `album_art` Hero) → song **title** (display) + "artist · album" + **⋯**
  menu (top-right of the meta block, per target) → **`WenProgressBar`** + times (`0:27` /
  `-3:34`) → **transport row** (shuffle · prev · big white round play/pause · next · repeat) →
  **volume** row (speaker · slider · speaker-loud). All via `context.select` on `PlayerProvider`
  (currentSong, isPlaying, progress, position, duration, shuffleEnabled, repeatMode, volume).
- **RIGHT column** (flex): the **lyrics view** — `pages/lyrics/widgets/lyrics_view.dart` driven by
  the reused AMLL engine (`animation/lyric_player_controller.dart`): Stack absolute-positioned
  cascading lines, **one bright active line**, **blur/scale/opacity by distance**, word-by-word
  karaoke + emphasis glow when YRC present, interlude dots. Fed `PlayerProvider.lyrics` +
  `activeLyricIndex`; scrolling the lyrics area browses (`beginUserScroll`/`updateUserScroll`/
  `endUserScroll`, 5s snap-back).

> `target.png` is exactly this: cover + title + ⋯ + progress + transport + volume on the LEFT,
> lyrics with one bright line + blur-by-distance on the RIGHT, grabber top-center. On desktop the
> player and lyrics are the **two halves of one screen** (`/player`), and `/lyrics` is the
> lyrics-focused full-bleed variant (grabber-only dismiss) for when the user wants lyrics maximized.

### 5.2 `pages/lyrics/lyrics_page.dart` — lyrics-maximized variant
Full-bleed `LyricsView` over the reactive `NeonFlowBackground` (FFT 律动, started in
`initState`/stopped in `dispose`; sentinel `<0` → synthetic pulse on Windows where the native
Visualizer channel is absent — guard the platform channel, degrade cleanly). Top-center grabber
dismiss; mini art + title header. Reuses the exact AMLL numbers — no re-tuning.

---

## 6. Router — `lib/router/`
- `routes.dart` — frozen route-name constants (`home, search, library, settings, player, lyrics,
  playlist, local, accounts, login*`).
- `app_router.dart` — `go_router` 14.x, `StatefulShellRoute.indexedStack` with 4 branches
  (Home/Search/Library/Settings) inside `AppShell`; full-screen `/player`, `/lyrics`,
  `/playlist/:id`, `/local/:id`, `/accounts`, `/login/:source` on `rootNavigatorKey` with
  slide-up/`DismissibleSheet` transitions. `router.refresh()` on source/login change (from the
  providers) — no source flip.

---

## 7. `app.dart` + `main.dart` (new desktop versions)

Mirror the mobile wiring **order** exactly (read-only ref `wenlistener/lib/{main,app}.dart`) but:
- **`main.dart`**: `window_manager.ensureInitialized()` + frameless `WindowOptions`
  (1180×760, min 1024×680, `TitleBarStyle.hidden`) before `runApp`. **Guard off Android-only
  bits**: skip `AudioService.init(WenAudioHandler)` (no `audio_service` Windows impl) and
  `Permission.notification` (Android 13 only) — degrade to foreground-only playback. Keep the
  service graph identical: `cookieStore → dio → crypto → neteaseApi + qqApi(+qqCookies) +
  kugouApi + kuwoApi(+kuwoCookies) → MusicApiRouter(initial: settings.source) → PlaybackStore +
  AudioService(player) → SettingsProvider → audio.init()/restore() → ArtworkPalette + FftService`.
  `just_audio_windows` provides the Media Foundation backend (already in pubspec). FFT: construct
  `FftService(player)` but the native Visualizer `EventChannel` is Android-only → on Windows it
  stays at the `<0` sentinel and the lyrics bg uses the synthetic pulse.
- **`app.dart`**: same `MultiProvider` graph and the 15-arg `WenListenerApp` constructor
  (`cookieStore, dio, crypto, neteaseApi, qqApi, qqCookies, kugouApi, kuwoApi, kuwoCookies,
  musicApi, audio, palette, fft, settings`), same eager/lazy flags
  (`AuthProvider`/`KugouAuthProvider`/`QqAuthProvider` `lazy:false`; `KuwoAuthProvider` lazy),
  same `_LikedSeeder` wrap. `MaterialApp.router(theme: AppTheme.dark(), routerConfig:
  AppRouter.router)` with a `builder:` that wraps every route in the desktop title-bar frame
  (`shell/window_title_bar.dart` pinned above shell + pushed routes so window controls stay
  reachable). **We do not touch service/state code** — only new UI + these two wiring files.

---

## 8. Exact file tree to create under `lib/`

```
lib/
├── main.dart                         # window_manager init + service graph (Android bits guarded)
├── app.dart                          # MultiProvider (15-arg ctor) + MaterialApp.router + title-bar frame
├── theme/
│   ├── app_colors.dart               # static tokens + accentOf(context)
│   ├── app_typography.dart           # AlimamaDongFangDaKai display + sans scale
│   ├── app_dimens.dart               # spacing / radius / blur / shell metrics / z-index
│   ├── app_motion.dart               # durations + curves (springs come from animation/)
│   └── app_theme.dart                # AppTheme.dark() — M3 dark, OLED, tokens wired into ThemeData
├── router/
│   ├── routes.dart                   # frozen route-name constants
│   └── app_router.dart               # go_router StatefulShellRoute.indexedStack + full-screen routes
├── shell/
│   ├── window_title_bar.dart         # frameless drag region + min/max/close
│   ├── app_shell.dart                # title bar + sidebar + IndexedStack content + mini-player
│   ├── sidebar.dart                  # brand + nav items + account card (collapsible rail)
│   ├── sidebar_nav_item.dart         # hover/active pill nav row
│   ├── sidebar_account_card.dart     # login state summary → /settings|/accounts
│   └── mini_player.dart              # docked bottom bar (art + centered transport + progress + volume)
├── widgets/
│   ├── glass_container.dart
│   ├── artwork_image.dart
│   ├── hover_scale.dart
│   ├── track_row.dart
│   ├── track_table.dart
│   ├── media_card.dart
│   ├── carousel_row.dart
│   ├── section_header.dart
│   ├── progress_bar.dart             # AMLL BouncingSlider port
│   ├── transport_controls.dart       # AMLL MediaButton set
│   ├── volume_control.dart
│   ├── like_button.dart
│   ├── source_badge.dart
│   ├── context_menu.dart             # right-click affordances
│   ├── qr_login_panel.dart
│   ├── skeleton.dart
│   └── empty_state.dart
└── pages/
    ├── home/home_page.dart
    ├── search/search_page.dart
    ├── library/
    │   ├── library_page.dart
    │   └── local_playlist_detail_page.dart      # /local/:id
    ├── playlist/playlist_detail_page.dart       # /playlist/:id
    ├── settings/settings_page.dart
    ├── accounts/accounts_page.dart              # /accounts
    ├── player/
    │   ├── player_page.dart                     # /player (LEFT: cover+controls, RIGHT: lyrics)
    │   └── widgets/player_background.dart        # wraps animation/art_background.dart
    ├── lyrics/
    │   ├── lyrics_page.dart                      # /lyrics (lyrics-maximized + FFT bg)
    │   └── widgets/lyrics_view.dart              # drives animation/lyric_player_controller.dart
    └── login/
        ├── login_netease.dart
        ├── login_qq.dart
        ├── login_kugou.dart
        └── login_kuwo.dart
```

*(existing, untouched: `lib/{services,models,state,animation}` — the copied logic layer.)*

---

## 9. Provider consumption map (consume, never rewrite)

| Provider | Read (via `context.select`) | Call |
|---|---|---|
| `PlayerProvider` | `currentSong, isPlaying, isBuffering, progress, position, duration, shuffleEnabled, repeatMode, volume, dynamicAccent, dynamicGradient, washGradient, lyrics, activeLyricIndex, lyricsLoading, lyricsSettled, isLiked, queue, playbackError` | `playQueue/playSong, togglePlay, next/previous, seek, jumpTo, cycleRepeat, toggleShuffle, setVolume, toggleLike/setLiked, retryLyrics, clearPlaybackError` |
| `SearchProvider` | `query, activeType, result, isLoading, isLoadingMore, hasError, hasMore, history` | `setQuery, setType, search, loadMore, clearHistory, reset` |
| `LibraryProvider` | `homeSections, homeLoading, homeError, userPlaylists, userPlaylistsLoading, createdPlaylists, collectedPlaylists, source` | `loadHome, loadUserPlaylists, loadPlaylist, fetchPlaylistFresh, add/removeSongToPlaylist, create/deleteUserPlaylist, collectPlaylist` |
| `SettingsProvider` | `source, rhythmEnabled, audioQuality` | `setSource, setRhythmEnabled, setAudioQuality` |
| `LocalPlaylistProvider` | `playlists` + detail | `create/import/resync/rename/remove` etc. |
| `AuthProvider` / `Kugou/Qq/KuwoAuthProvider` | login state, account, QR image, poll status | `startQrLogin/cancelQrLogin, login (kuwo), logout, switch/add account` |
| `MusicApiRouter` | `source` (active backend) | (source switch goes through `SettingsProvider`) |

**Rebuild-cost rule (from mobile lesson):** `PlayerProvider` notifies every position tick. Never
`context.watch` the whole `PlayerProvider` in an always-mounted/heavy widget (mini-player,
sidebar). Use `context.select` for the specific field; isolate the progress line/scrubber into its
own small widget that watches `position`/`progress`.

---

## 10. Build order

1. `theme/*` (tokens + `AppTheme.dark()`), `pubspec` fonts already wired.
2. `widgets/` primitives (`glass_container`, `artwork_image`, `hover_scale`, `track_row/table`,
   `media_card`, `progress_bar`, `transport_controls`).
3. `shell/*` + `router/*` + `app.dart`/`main.dart` → app boots to an empty shell.
4. Pages: Home → Search → Library → Playlist detail → Settings/Accounts/Login.
5. Player + Lyrics (wire the reused `animation/` engine last).
6. `C:\flutter\bin\flutter.bat analyze` clean, then `run -d windows`.
</content>
</invoke>
