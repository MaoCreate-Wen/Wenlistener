# WenListener Rebuild — Master Implementation Plan

> Coordination contract for 5 parallel work streams. The interface signatures in §3 are FROZEN —
> every stream codes against them. Companion specs: `AMLL_ANIMATION_SPEC.md`, `NETEASE_API_SPEC.md`,
> `DESIGN_SYSTEM.md`.

## 0. Operating principle (what makes 5 agents work)
One-directional layering:
```
pages/ ─▶ state/ (providers) ─▶ services/ ─▶ models/
  └────▶ widgets/ ─▶ theme/        animation/ (S2 only) ─▶ models/
```
**Hard rule:** page agents (Streams 2–5) import only `models/`, `theme/`, `widgets/`, `state/`,
`router/routes.dart`, and (S2 only) `animation/`. **Pages NEVER import `services/`** — all
networking/audio is reached through the four providers. Everything in §3 is FROZEN: names, fields,
method headers do not change once S1 publishes them. A missing contract is escalated to S1 (the
single owner), not invented by a page agent.

## 1. Tech decisions + pubspec
| Decision | Choice | Rationale |
|---|---|---|
| State | Keep **Provider** (MultiProvider, 4 ChangeNotifiers + Provider for services) | Continuity; ChangeNotifier suffices. |
| HTTP | **dio** + cookie_jar + dio_cookie_manager | weapi needs persistent cookie jar (MUSIC_U/__csrf), header injection, Set-Cookie capture on QR 803. |
| Routing | **go_router** + StatefulShellRoute.indexedStack | Persistent bottom-nav + mini-player shell = indexed-stack ShellRoute. |
| Crypto | **pointycastle** (AES-128-CBC/PKCS7) + `BigInt.modPow` (RSA textbook, no lib) | encrypt's RSA forces padding; weapi RSA is no-pad. |
| Spring | **Port AMLL closed-form solver** (`animation/spring.dart`) | Exact parity; one ticker drives all lines. Constants transfer 1:1. |
| JSON | Hand-written fromJson (no build_runner) | Avoids generated-file conflicts across agents. |
| Images | cached_network_image | DESIGN_SYSTEM §7. |
| QR | qr_flutter | QR login render. |
| Palette | Keep palette_generator | Dynamic accent. |
| Cookies | path_provider (PersistCookieJar) | Persist MUSIC_U. |
| Audio | Keep just_audio + just_audio_background | Already integrated. |
| Remove | amlv (unused) | Superseded by animation/. |

pubspec ADD: `dio ^5.7.0, cookie_jar ^4.0.8, dio_cookie_manager ^3.1.1, path_provider ^2.1.5,
pointycastle ^3.9.1, go_router ^13.2.5, cached_network_image ^3.3.1, qr_flutter ^4.1.0`; REMOVE
`amlv`; bump `flutter_lints ^3.0.0`. **SDK floor stays `>=3.2.3`** — S1 pins highest versions that
resolve against Dart 3.2.3; escalate if a floor bump is unavoidable. **Windows audio:**
just_audio_background lacks Windows support — verify audio on Android/web, or add
`just_audio_media_kit` if Windows playback is required.

## 2. Architecture (lib/ tree, [S#]=owning stream)
```
lib/
  main.dart [S1]  app.dart [S1]
  models/ [S1]   artist album song play_url playlist search_result lyric_line qr_login home_section
  services/ [S1] (pages never import) netease_crypto netease_api netease_endpoints dio_factory
                 cookie_store artwork_palette audio_service
  state/ [S1]    player_provider search_provider library_provider auth_provider
  theme/ [S1]    app_colors app_typography app_dimens app_theme
  router/        routes.dart [S1]   app_router.dart [S5]
  widgets/ [S1]  glass_container app_scaffold artwork_image song_tile section_header progress_bar
                 play_pause_button like_button skeleton_box placeholder_page
  shell/ [S1]    home_shell mini_player bottom_nav_bar
  animation/ [S2] spring lyric_player_controller lyric_line_render art_background interlude_dots emphasis
  pages/
    player/ [S2]   player_page + widgets/{player_background,player_controls,secondary_controls}
    lyrics/ [S2]   lyrics_page + widgets/{lyric_line_widget,karaoke_text}
    home/ [S3]     home_page + widgets/{greeting_header,carousel_section,playlist_card,recommended_grid}
    search/ [S4]   search_page search_results_page + widgets/{search_field,search_tab_chips,search_skeleton}
    library/ [S5]  library_page
    playlist/ [S5] playlist_page + widgets/playlist_header
    login/ [S5]    qr_login_page
test/ [S1 owns widget_test, crypto_test, models_test, netease_api_smoke_test; each stream adds test/<feature>/]
```

## 3. FROZEN INTERFACE CONTRACTS
(See the full signature listing kept verbatim below. Standard Dart naming; legacy PascalCase NOT carried over.)

### 3.1 Models (S1)
- **Artist**{id:int, name:String, picUrl:String?} +fromJson +listFromJson
- **Album**{id, name, picUrl?} +fromJson
- **Song**{id:int, name:String, artists:List<Artist>, album:Album?, duration:Duration(from dt ms), fee:int, playable:bool} +fromSearchJson +fromDetailJson; get artistNames("A / B"), artworkUrl, copyWith({playable})
- **AudioLevel** enum {standard,higher,exhigh,lossless,hires} ext: apiValue, encodeType("flac" if lossless/hires else "aac"), downloadBr(128000/192000/320000/999000)
- **PlayUrl**{id, url:String?, br, type, size, md5?, level} +fromJson(json, level); get isPlayable(url!=null)
- **Playlist**{id, name, coverUrl?, creatorName?, description?, trackCount, tracks:List<Song>} +fromJson +copyWith({tracks})
- **SearchType** enum {song,album,artist,playlist,lyric,comprehensive} ext: code(1/10/100/1000/1006/1018), label
- **SearchResult**{type, songs, albums, artists, playlists, total, hasMore} +fromJson(json,type); static empty
- **LyricWord**{text, start:Duration, end:Duration} get duration
- **LyricLine**{start, end, text, words:List<LyricWord>, translation?, isBackground} get isWordByWord(words.isNotEmpty)
- **Lyrics**{lines:List<LyricLine>, hasWordByWord, hasTranslation} +parse({lrc,tlyric,klyric}); static empty; indexAt(Duration)->int
- **QrCreateResult**{uniKey, qrContent(scanlogin URL incl chainId)}
- **QrStatus** enum {expired,waitingScan,scanned,authorized,invalidated,unknown}
- **QrPollResult**{status, code, musicU?, csrf?, message?}  (800→expired,801→waitingScan,802→scanned,803→authorized,860→invalidated)
- **HomeSectionKind** enum {playlistCarousel,albumCarousel,recommendedGrid}; **HomeSection**{title, kind, playlists, songs}

### 3.2 Services (S1, internal)
- **WeapiPayload**{params:String(base64), encSecKey:String(256 hex)} toForm()
- **NeteaseCrypto**: const fixedAesKey='0CoJUm6Qyw8W8jud', aesIv='0102030405060708', rsaPubExp=0x10001, rsaModulusHex=(1024-bit from spec). `WeapiPayload weapi(Map payload)` (6-step); static `randomBase62(int len=16)`.
- **CookieStore**{jar} +create(); get musicU, csrf, isLoggedIn; saveFromSetCookie(List<String>); clear()
- **NeteaseApiException**{message, statusCode?}
- **NeteaseApi**({dio, crypto, cookies}): search({keyword,type=song,limit=30,offset=0})->SearchResult; songDetail(id)->Song?; songDetails(ids)->List<Song>; songUrl(id,{level=exhigh})->PlayUrl?; lyric(id)->Lyrics; personalizedPlaylists({limit=12})->List<Playlist>; playlistDetail(id)->Playlist; qrCreate()->QrCreateResult; qrPoll(uniKey)->QrPollResult; accountStatus()->bool; postWeapi(path,payload,{needsCsrf=true})->Map (injects csrf_token BEFORE encryption).
- **RepeatMode** enum {off,all,one}; **PlaybackSnapshot**{playing,buffering,position,duration,index?}
- **AudioService**({api}): init(); snapshots:Stream; currentIndexStream; currentIndex; setQueue(songs,{initialIndex=0}); play/pause/togglePlay; seek(pos,{index}); next/previous; setRepeatMode; setShuffle; setVolume; dispose()
- **ArtworkPalette**.extract(url)->PaletteResult; **PaletteResult**{accent:Color, colors:List<Color>, gradient:Gradient} static fallback

### 3.3 State / providers (S1, page-facing API)
- **PlayerProvider** extends ChangeNotifier({audio,api,palette}): queue, currentIndex, currentSong, hasSong, isPlaying, isBuffering, position, duration, progress(0..1), repeatMode, shuffleEnabled, volume, dynamicAccent:Color, dynamicGradient:Gradient, paletteColors:List<Color>, lyrics:Lyrics, lyricsLoading, activeLyricIndex:int, isLiked; cmds: playSong(song,{queue,index=0}), playQueue(songs,{index=0}), togglePlay, next, previous, seek(pos), cycleRepeat, toggleShuffle, toggleLike.
- **SearchProvider**({api}): query, activeType, result, isLoading, isLoadingMore, hasError, hasMore, history; setQuery(q), setType(type), search([q]), loadMore(), clearHistory(), reset().
- **LibraryProvider**({api}): homeLoading, homeError, homeSections:List<HomeSection>; loadHome(); isPlaylistLoading(id), playlist(id)->Playlist?, loadPlaylist(id)->Playlist.
- **AuthProvider**({api,cookies}): isLoggedIn, qrStatus, qrContent?, qrLoading; refreshLoginState(), startQrLogin() (create+poll 2s/180s), cancelQrLogin(), logout().

### 3.4 Theme (S1)
- **AppColors**: bg#000000, surface#0E0E14, surfaceGlass(0x1FFFFFFF), surfaceGlassBorder(0x29FFFFFF), onSurface#F8FAFC, onSurfaceMuted(0x99FFFFFF), onSurfaceFaint(0x61FFFFFF), accentPlay#22C55E, seed#4338CA, seedDeep#1E1B4B.
- **AppTypography**: displayFont='AlimamaDongFangDaKai'; displayL32/displayM28/titleL22(display) titleM18/body15/label13/caption11(system); textTheme.
- **AppDimens**: space4..48, screenPadding16, radiusSm10/Md16/Lg22/Xl28/Pill999, albumRadius(size)=size/20, blurPanel24/blurPlayerBg30/blurNav18, miniPlayerHeight64/navHeight64/tileArtwork56/minTouch44, glassShadow.
- **AppTheme**.dark() -> ThemeData(M3, ColorScheme.fromSeed(seed,dark), surfaces→tokens).

### 3.5 Routing + shell + page ctors
- **Routes**: home'/', search'/search', searchResults'results', library'/library', player'/player', lyrics'/lyrics', login'/login', playlist'/playlist/:id'; playlistPath(id); name consts nHome..nPlaylist; tab order tabHome0/tabSearch1/tabLibrary2. `rootNavigatorKey`.
- **HomeShell**{navigationShell:StatefulNavigationShell}; **AppNavTab**{label,icon,activeIcon}; **AppBottomNav**{currentIndex,onTap, static tabs[Home,Search,Library]}; **MiniPlayer** (reads PlayerProvider, Hero('album_art')); **AppRouter**.router [S5].
- **Page ctors (FROZEN):** HomePage(), SearchPage(), SearchResultsPage(), LibraryPage(), PlaylistPage({required int playlistId}), PlayerPage(), LyricsPage(), QrLoginPage() — all const, all StatelessWidget.

### 3.6 Shared widgets (S1)
GlassContainer({child, blur=24, opacity=0.10, border=true, radius?, padding?}); AppScaffold({body, appBar?, showDynamicWash=false, padding?}); ArtworkImage({url, size, radius?=size/20, heroTag?, fit=cover}); SongTile({title, artist, artworkUrl?, leading?, trailing?, isActive=false, onTap?, onTrailingTap?}) +fromSong(song,{...}); SectionHeader({title, onMore?}); ProgressBar({position, duration, onChanged?, onSeek?, accent?, showTimeLabels=true}); PlayPauseButton({isPlaying, onPressed, isBuffering=false, size=56, color?}); LikeButton({liked, onPressed, size=24}); SkeletonBox({width?, height?, radius?}).

### 3.7 Animation (S2 internal)
- **SpringParams**{mass,damping,stiffness,soft=false} presets: posY(0.9,15,90), scale(2.0,25,100), bgScale(1.0,20,50).
- **Spring**({initial, params=posY}): position, velocity, arrived(|Δ|<0.01&&|v|<0.01), set params, setTarget(re-seed w/ velocity), setPosition, update(dtSeconds).
- **LyricPlayerController** extends ChangeNotifier({vsync}): tunables alignPosition0.35, wordFadeWidth0.5, enableScale/Blur/Spring/hidePassedLines; setLines, setCurrentTime(cascade), seekTo(instant), resize, renderLines:List<LyricLineRender>, activeIndex.
- **LyricLineRender**{index, y, scale, opacity, blur, brightMaskAlpha, darkMaskAlpha, delaySeconds}.
- **ArtBackground**{imageUrl?, paletteColors, flowSpeed=4}; **InterludeDots**{gapDuration (show if ≥4000ms)}.

## 4. Five work streams (disjoint ownership, dependency order)
Order: **S1 first (blocks all) → S2/S3/S4 parallel → S5 last**. (Execution waves: W1=S1, W2=S2+S3+S4, W3=S5.)

- **S1 FOUNDATION** — owns pubspec, main.dart, app.dart, models/, services/, state/, theme/, router/routes.dart, widgets/, shell/, S1 tests. Builds the entire §3 contract surface. Deletes legacy files LAST (data.dart, JustPlayer.dart, song.dart, lyrics.dart, playpage.dart, player_page.dart, main.net.dart, test.dart). Ends by running `flutter analyze` clean and publishing "contracts frozen".
- **S2 PLAYER+LYRICS** — owns animation/, pages/player/, pages/lyrics/, test/animation/. Implements AMLL spec (spring, cascade, blur/scale/opacity by distance, karaoke+emphasis, interlude dots, art background) + redesigned player & lyrics pages. Reads PlayerProvider.
- **S3 HOME** — owns pages/home/, test/home/. Discovery feed (greeting, carousels, recommended grid) via LibraryProvider; song tap→PlayerProvider.playQueue; card tap→push playlist.
- **S4 SEARCH** — owns pages/search/, test/search/. Pinned glass search + tab chips + paginated SongTile results via SearchProvider; tap→playQueue.
- **S5 PLAYLIST+INTEGRATION** — owns router/app_router.dart, pages/playlist/, pages/library/, pages/login/, test/integration/. Builds the GoRouter table (StatefulShellRoute.indexedStack + top-level player/lyrics/login/playlist), playlist detail (collapsing SliverAppBar), library + QR login pages, then the final swap to real pages and the e2e play flow.

## 5. End-to-end flow
SearchPage→SearchProvider.search→SearchResult→tap SongTile→PlayerProvider.playQueue→[AudioService.setQueue→songUrl lazy→just_audio.play] + [api.lyric→Lyrics] + [ArtworkPalette.extract→dynamicAccent/gradient]→notifyListeners→MiniPlayer (always mounted in HomeShell) → tap Hero('album_art') → PlayerPage (ArtBackground + ProgressBar accent) → tap artwork → LyricsPage (LyricPlayerController.setCurrentTime(position) per frame).

## 6. Conflict-avoidance
- Single-owner files: pubspec.yaml, main.dart, app.dart, models/ services/ state/ theme/ widgets/ shell/ router/routes.dart → **S1 only**. animation/+pages/player/+pages/lyrics/ → **S2**. pages/home/ → **S3**. pages/search/ → **S4**. router/app_router.dart+pages/playlist/+pages/library/+pages/login/ → **S5**.
- pubspec.yaml & main.dart are S1-exclusive; app_router.dart is S5-exclusive (only file importing every page).
- Legacy deletion S1-only, last. Streams read legacy for porting reference but write only new files.
- Hero tag 'album_art' reserved; one per route (MiniPlayer on shell, ArtworkImage on player, mini artwork on lyrics).
- test/ partitioned by stream.

## 7. Risks & verification
- analyze clean: new code standard naming + debugPrint; legacy deletion clears ~93 warnings; each stream analyzes its folders; S5 full-project analyze at integration.
- Failing widget_test.dart (counter) → S1 replaces with a smoke test so `flutter test` green.
- weapi without login: search/detail/lyric anonymous → S1 smoke test live `search("周杰伦")` non-empty; crypto_test asserts encSecKey 256 lowercase hex + params base64.
- play-url needs MUSIC_U: songUrl null/trial when logged out → UI shows "VIP/login required" + skip; verify e2e on a free track first, full catalog after QR (803→Set-Cookie→MUSIC_U).
- Desktop audio: just_audio_background no Windows; verify on Android/web or add just_audio_media_kit.
- AMLL parity: validate against numbers (alignPosition0.35, baseDelay0.05, blur cap32, opacity0.85/0.2/1.0, scale100/97/75, wordFadeWidth0.5, interlude≥4000ms); RepaintBoundary on bg + per-line layers.
