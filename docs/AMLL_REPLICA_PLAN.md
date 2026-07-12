# AMLL Player + Lyrics — Code-Level Flutter Replication Plan

Goal: rewrite `/player` (and align `/lyrics`) so the desktop now-playing surface is a
pixel-faithful port of AMLL's **horizontal** `PrebuiltLyricPlayer` layout, matching
`wenlistener-pc/design/target.png` exactly. Only sanctioned deviation: keep our own
page-top grabber (小横条) instead of AMLL's invisible drag-area / titlebar affordance.

Everything below maps a concrete AMLL source element → a concrete Flutter widget in
`wenlistener_desktop`, with the exact AMLL CSS/JS numbers translated to Flutter units.
Reuse the already-ported animation engine in `lib/animation` and the design tokens in
`lib/theme`. Write complete, compiling Dart. Do not touch the mobile app.

---

## 0. Source → target cross-reference

AMLL truth (studied):

- `applemusic-like-lyrics-full-refractor/packages/react-full/src/components/PrebuiltLyricPlayer/index.tsx`
  — the assembled player: cover slot, music-info, progress bar, transport, volume,
  bottom toggle row, lyric slot, background slot.
- `.../src/layout/auto.tsx` → picks horizontal when `width >= height`.
- `.../src/layout/horizontal.tsx` + `horizontal.module.css` — the grid, columns
  `0.45fr / 0.55fr`, rows `drag 0.45fr / thumb auto / cover auto / music-info 3fr /
  bottom 0.3fr`, cover `min(50vh, 38vw)`, lyric `padding-right:15%` + edge mask,
  bottomControls `row-reverse` gap 4em.
- `.../components/{MusicInfo,BouncingSlider,MediaButton,VolumeControlSlider,ToggleIconButton}`
  and `PrebuiltLyricPlayer/index.module.css` (the media-button scales, progress
  label styling, spacing).

target.png (2557×1380) confirms the horizontal layout: LEFT = cover (upper), title
`雨天` / artist `孙燕姿` + `⋯` circle, thin progress bar (`0:27` … `-3:34`), transport
`shuffle · ⏪ · ⏸ · ⏩ · repeat`, volume rail between two speaker glyphs; a bottom
row with **airplay bottom-left** and **lyrics-bubble + playlist-list bottom-right**;
RIGHT = one bright active lyric line (`我却只想回头`) vertically centred on the cover,
neighbours dimmed + distance-blurred, over a soft album mesh-gradient field.

Note two corrections vs. the current code, required to match target.png:
1. **No heart / like button** in the meta row — target shows only title, artist, `⋯`.
2. **Transport uses ⏪ / ⏩ (fast-rewind / fast-forward double-triangle)**, not
   skip-with-bar; and the **bottom toggle row** (airplay / lyrics / playlist) is
   present — the current player page omits it.
3. Background is the **album mesh-gradient** (AMLL `BackgroundRender`), not the plain
   blurred `ArtBackground`.

---

## 1. AMLL grid → Flutter widget tree (horizontal)

AMLL `horizontal.module.css` grid (kept faithfully):

```
columns: [info-side 0.45fr][player-side 0.55fr]
rows:    [drag 0.45fr][thumb auto][cover auto][music-info 3fr][bottom 0.3fr]
```

Flutter realisation — `PlayerPage`:

```
Scaffold(backgroundColor: AppColors.bg)
└─ Stack(fit: expand)
   ├─ _Background()                         // mesh gradient (NeonFlowBackground) + scrim
   └─ SafeArea
      └─ Column
         ├─ _Grabber(onTap: dismiss)        // KEEP OURS — 42×5 pill, 34px band
         └─ Expanded
            └─ _HorizontalBody()            // LayoutBuilder: wide (>=760) vs narrow
```

`_HorizontalBody` (wide path) = the AMLL grid as a `Row` of two flex columns:

```
Row(crossAxisAlignment: stretch)
├─ Flexible(flex: 45, child: _InfoColumn())     // info-side 0.45fr
└─ Flexible(flex: 55, child: _LyricPane())      // player-side 0.55fr
```

Narrow (`< 760` content px): render only `_InfoColumn()` (lyrics hidden), matching
AMLL's `AutoLyricLayout` collapse to a single column.

### 1.1 `_InfoColumn` = the LEFT stack (AMLL rows drag/cover/music-info/bottom)

The AMLL left column is **not vertically centred** — the cover sits in the upper
portion (after a `0.45fr` drag gap), the control block fills the large `3fr` middle
with `space-between`, and the bottom toggles pin to the bottom. Reproduce with
weighted spacers so the vertical rhythm matches the `fr` values:

```
LayoutBuilder(builder: (ctx, c) {
  // AMLL: cover = min(50vh, 38vw); min(45vh, 38vw) when height <= 1000.
  final maxCover = c.maxHeight <= 1000 ? 0.45 * c.maxHeight : 0.50 * c.maxHeight;
  final coverSize = math.min(maxCover, 0.38 * <windowWidth>)
                        .clamp(160.0, 460.0);
  return Column(
    crossAxisAlignment: stretch,
    children: [
      Spacer(flex: 45),                          // [drag 0.45fr] — min ~30px
      Center(child: _Cover(size: coverSize)),    // [cover auto]
      SizedBox(height: coverSize * 0.02 + 8),    // thumb row + gap (margin:2vh-ish)
      Expanded(                                    // [music-info 3fr]
        flex: 300,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: coverEdgeInset),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: coverSize), // controls == cover width
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,  // AMLL .controls
              children: [
                _MetaRow(),        // title/artist + ⋯   (NO heart)
                _ScrubberBar(),    // BouncingSlider + labels
                _Transport(),      // shuffle ⏪ ⏸ ⏩ repeat
                _VolumeRow(),      // speaker · BouncingSlider · speaker
              ],
            ),
          ),
        ),
      ),
      _BottomToggleRow(),                          // [bottom 0.3fr] airplay / lyrics / playlist
      Spacer(flex: 30),                            // trailing 0.3fr
    ],
  );
})
```

The controls column is width-clamped to `coverSize` and horizontally centred, exactly
like AMLL `.controls { width: var(--horizontal-layout-max-width); justify-self:center }`.

### 1.2 `_LyricPane` = the RIGHT column (AMLL `.lyric`)

```
Padding(
  padding: EdgeInsets.only(right: paneWidth * 0.15),   // AMLL padding-right:15% (8% if narrow/short)
  child: ShaderMask(                                     // AMLL mask-image
    blendMode: BlendMode.dstIn,
    shaderCallback: linear top→bottom
        stops [0, .10, .90, 1] colors [transparent, white, white, transparent],
    child: LyricsView(
      padding: EdgeInsets.symmetric(horizontal: AppDimens.space24),
      alignPosition: <coverCentreFraction>,   // aligns active line to cover centre
    ),
  ),
)
```

**alignPosition must equal the cover's vertical centre fraction** (AMLL
`useLayoutEffect` in `PrebuiltLyricPlayer` sets `alignAnchor:"center"`,
`alignPosition = (coverTop + coverH/2 - layoutTop) / layoutH`). With the spacer weights
above the cover centre lands at ≈ **0.33–0.36** of the body height (target.png: cover
centre ≈ y0.34, active line centre ≈ y0.35 — they coincide). Compute it live rather
than hardcode: expose the cover's centre-Y via a `GlobalKey`/`LayoutBuilder` on the
body and feed the fraction into `LyricsView.alignPosition`. Fallback constant `0.34`.
`LyricPlayerController` already anchors the active line's **centre** at
`alignPosition` (`lyric_player_controller.dart:457-468`), so no engine change is
needed — only the value.

The lyric internals (one bright active line, neighbours dimmed + blurred by distance,
word-by-word karaoke sweep for YRC/word lines, interlude dots) are already implemented
by `LyricsView` → `LyricPlayerController` + `LyricLineWidget` and are reused verbatim.

---

## 2. Sub-widget specs (AMLL numbers → Flutter)

### 2.1 `_Cover` — AMLL `Cover` + horizontal `.cover`
- Square, `coverSize` per §1.1, `BorderRadius.circular(AppDimens.albumRadius(size))`
  (= size/20; target shows ~4% radius).
- Shadow: `BoxShadow(Color(0x59000000), blur 34, y 18, spread -6)`.
- Pause-dip (AMLL `musicPaused`): `TweenAnimationBuilder` scale `1.0` playing →
  `0.86` paused, 400ms `easeOutCubic` (reuse existing `_Cover`).
- Uses `PlayerArtwork(url, size, radius, shadow)`.

### 2.2 `_MetaRow` — AMLL `MusicInfo` (`MusicInfo/index.module.css`)
```
Row(crossAxisAlignment: center)
├─ Expanded(
│    Column(crossAxisAlignment: start, mainAxisSize: min)
│    ├─ Text(title, AlimamaDongFangDaKai)   // name: weight 500, opacity .9, 1 line ellipsis
│    │     style: AppTypography.displayM.copyWith(fontSize: 26, height 1.15,
│    │            fontWeight w600, color white@0.95, letterSpacing 0.4)
│    ├─ SizedBox(height: 4)
│    └─ Text(artist)                          // artists: opacity .45, weight 400
│          style: AppTypography.label.copyWith(color white@0.5, letterSpacing 0.4)
│  )
├─ SizedBox(width: 8)
└─ _MorePopup()                               // ⋯ circle — KEEP (real popup, not toast)
```
**Remove the heart / like `_CircleIconButton`.** target.png has no like affordance.
`_MorePopup`: 38px translucent circle `Color(0x1FFFFFFF)`, `Icons.more_horiz_rounded`
22px white, `PopupMenuButton` → 添加到歌单 / 添加到本地歌单 (unchanged).

### 2.3 `_ScrubberBar` — AMLL `BouncingSlider` + `PrebuiltProgressBar`
Reuse existing `PlayerScrubber` (already a faithful `BouncingSlider` port):
- Track `.inner`: white @ 15% (`0x26FFFFFF`), height **8px rest → 15px active**,
  swell curve `Cubic(0.38, 1.625, 0.62, 0.995)`; radius 100.
- Fill `.thumb`: solid white, opacity **0.4 rest → 0.9 active**, 200ms `Cubic(0.2,0.2,0,1)`,
  left-anchored, **no knob**.
- Rubber-band overscroll spring (`bounceSpring`): `SpringDescription(mass1, stiff150,
  damp18)`, `±9px` per full-width past an end (already implemented).
- Labels row (AMLL `.progressBarLabels`): `justify-between`, weight 500, font
  `max(1.2vh, 0.8em)` ≈ 12px, opacity 0.5. Left = elapsed `0:27`; right = remaining
  `-3:34` (tap toggles to total, `showRemainingTimeAtom`). Tabular figures.
- Seek throttled 100ms (AMLL `useThrottle`) — call `player.seek` on commit.

### 2.4 `_Transport` — AMLL `PrebuiltMediaButtons` + `.controls`
Row, `MainAxisAlignment.spaceBetween` (AMLL `.controls{justify-content:space-between}`),
five `MediaButton`s (reuse `pages/player/widgets/media_button.dart` — press-dip +
`1→0.85→1.1→1` bounce, `#fff0→#fff2` wash, no ripple). Glyph mapping (correct the
current skip-glyphs):

| AMLL button        | glyph        | Flutter icon                    | size | active/inactive |
|--------------------|--------------|---------------------------------|------|-----------------|
| shuffle (`ShuffleIcon`)   | crossing arrows | `Icons.shuffle_rounded`         | 22 | white / white@50% |
| prev (`IconRewind`)       | ⏪ double-tri   | `Icons.fast_rewind_rounded`     | 30 | white |
| play/pause (`IconPause/Play`) | ▮▮ / ▶ | `Icons.pause_rounded` / `Icons.play_arrow_rounded` | 42 | white (72px button) |
| next (`IconForward`)      | ⏩ double-tri   | `Icons.fast_forward_rounded`    | 30 | white |
| repeat (`RepeatIcon…`)    | loop / loop-1  | `Icons.repeat_rounded` / `Icons.repeat_one_rounded` | 22 | white when on / white@50% off |

Button diameters follow AMLL relative scale (play biggest): shuffle/repeat **44**,
prev/next **56**, play/pause **72**. Colours: active pure white `0xFFFFFFFF`, inactive
`0x80FFFFFF`. Wire to `player.toggleShuffle / previous / togglePlay / next /
cycleRepeat`; show a 2px `CircularProgressIndicator` in the play button while
`isBuffering`.

### 2.5 `_VolumeRow` — AMLL `VolumeControl` (`VolumeControlSlider`)
AMLL volume is a `BouncingSlider` flanked by speaker glyphs (`icon_speaker` /
`icon_speaker_3`). Reproduce as:
```
Row
├─ Icon(Icons.volume_down_rounded, 20, white@0.5)   // beforeIcon (speaker-min)
├─ SizedBox(width: 12)
├─ Expanded(child: _VolumeBar)                        // same track look as scrubber
└─ Icon(Icons.volume_up_rounded, 20, white@0.5)      // afterIcon (speaker-max)
```
`_VolumeBar`: white@15% track, height 8, left-anchored white fill opacity 0.4→0.9 on
drag (matches `.inner`/`.thumb`). For maximum fidelity, factor a shared
`BouncingTrack` widget out of `PlayerScrubber` and use it for both progress and volume
(same swell + overscroll). Wire to `player.setVolume` (throttled 100ms). AMLL `min:0
max:1`.

### 2.6 `_BottomToggleRow` — AMLL `horizontalBottomControls` + `.bottomControls`
AMLL DOM `[Playlist, Lyrics, <flex spacer>, AirPlay]` with `flex-direction:row-reverse`
→ visual L→R: **AirPlay (left) … Lyrics, Playlist (right)**. Reproduce directly:
```
Row(
  children: [
    _ToggleIconButton(type: airplay),          // bottom-left
    Spacer(),                                    // flex:1 gap
    _ToggleIconButton(type: lyrics, checked: !hideLyric, onTap: toggleLyrics),
    SizedBox(width: 4em-equiv ≈ 40),             // AMLL gap 4em (2em when narrow/short)
    _ToggleIconButton(type: playlist),
  ],
)
padding: EdgeInsets.symmetric(horizontal: ~40)   // AMLL padding 4em (2em narrow)
```
`_ToggleIconButton` = AMLL `ToggleIconButton` (opacity ~0.5 unchecked → ~0.9 checked,
transparent circular hit target, no ripple). Glyphs (Material rounded standing in for
AMLL's SVGs; port the real SVGs via a `CustomPainter` later for exact match):

| type     | icon (unchecked / checked)                                   |
|----------|--------------------------------------------------------------|
| airplay  | `Icons.airplay` (single state)                               |
| lyrics   | `Icons.lyrics_outlined` / `Icons.lyrics` (speech-bubble+dots)|
| playlist | `Icons.queue_music_outlined` / `Icons.queue_music`          |

Behaviour: `lyrics` toggles a `hideLyricView` bool (collapse the right pane, animate
`_InfoColumn` to fill — AMLL `.hideLyric` slides controls right / fades lyric). For v1,
`lyrics` toggles pane visibility; `airplay` / `playlist` open the queue/route sheets we
already have (or no-op with a tooltip if unrouted). Size ≈ 26px glyph in a 40px target.

### 2.7 `_Background` — AMLL `BackgroundRender`
Replace the plain `ArtBackground` with the **mesh-gradient** renderer to match AMLL and
target.png's soft warm field:
```
Stack(fit: expand)
├─ RepaintBoundary(child: NeonFlowBackground(       // lib/animation — AMLL MeshGradientRenderer port
│     imageUrl: artworkUrl, colors: paletteColors,
│     playing: isPlaying, reactive: settings.rhythmEnabled,
│     lowFreqVolume: fft?.lowFreqVolume))
└─ DecoratedBox(vertical scrim 0x33/0x1A/0x40 black for control legibility)
```
Read `artworkUrl`, `paletteColors`, `isPlaying` via `context.select`. (This aligns the
player background with the `/lyrics` page, which already uses `NeonFlowBackground`.)

---

## 3. Measurement table (AMLL formula → Flutter value)

| Element                 | AMLL source                              | Flutter value |
|-------------------------|------------------------------------------|---------------|
| Left / right split      | `0.45fr / 0.55fr`                        | `Flexible flex 45 / 55` |
| Cover size              | `min(50vh,38vw)` (45vh if h≤1000)        | `min(0.50·H, 0.38·W).clamp(160,460)` |
| Cover radius            | `Cover` rounded                          | `size/20` |
| Cover shadow            | player shadow                            | `0x59000000, blur34, y18, spread-6` |
| Pause dip               | `musicPaused` scale                      | `1.0→0.86`, 400ms easeOutCubic |
| Controls block width    | `.controls width == cover`               | `maxWidth: coverSize`, centred |
| Controls vertical dist. | `.controls space-between` in 3fr row     | `Expanded(flex:300)` + `spaceBetween` |
| Title font              | `MusicInfo .name` weight500 op.9         | `AlimamaDongFangDaKai` 26 / w600 / white@0.95 / ls0.4 |
| Artist font             | `.artists` op.45 weight400               | 13 / w400 / white@0.5 / ls0.4 |
| ⋯ button                | `MenuButton`                             | 38px circle `0x1FFFFFFF`, `more_horiz` 22 |
| Progress track          | `.inner` 8px→15px, `#ffffff26`           | h 8→15, `0x26FFFFFF`, swell `Cubic(.38,1.625,.62,.995)` |
| Progress fill           | `.thumb` white op.4→.9                   | white α 0.4→0.9, 200ms `Cubic(.2,.2,0,1)`, no knob |
| Progress overscroll     | `bounceSpring` ±9px, stiff150            | `SpringDescription(1,150,18)`, ±9px clamp 28 |
| Time labels             | `.progressBarLabels` op.5 w500 max(1.2vh,.8em) | 12px, w500, white@0.5, tabular |
| Transport align         | `.controls space-between`                | `Row spaceBetween` |
| Play button             | `.songMediaPlayButton` scale2            | 72px btn, glyph 42 |
| Side buttons            | `.songMediaButton` scale3→2              | prev/next 56 (glyph 30); shuffle/repeat 44 (glyph 22) |
| MediaButton wash        | `#fff0→#fff2`                            | `0x00FFFFFF→0x22FFFFFF`, 300ms |
| MediaButton bounce      | `1→.85→1.1→1` 0.7s                        | TweenSequence 20/30/50, 700ms |
| Volume rail             | `VolumeControl` BouncingSlider, min0 max1| shared `BouncingTrack`, speaker icons 20 white@0.5 |
| Bottom row              | `.bottomControls` row-reverse gap4em pad4em | `Row [airplay, Spacer, lyrics, gap40, playlist]`, hpad 40 (20 narrow) |
| Toggle glyph            | `ToggleIconButton` op.5→.9               | 26px glyph, 40px target, white α 0.5→0.9 |
| Lyric pane pad-right    | `.lyric padding-right:15%` (8% narrow)   | `right: paneW·0.15` (0.08 if W≤1600 or H≤1000) |
| Lyric edge mask         | `mask-image: linear(transp,black10%,black90%,transp)` | ShaderMask dstIn stops [0,.10,.90,1] |
| Active-line align       | `alignAnchor:"center"`, cover-centre frac| `LyricsView.alignPosition ≈ 0.34` (compute live) |
| Lyric main font         | `lyricFontFamily`                        | `AlimamaDongFangDaKai` 30 / w400 (34 on maximized page) |
| Lyric active vs neighbour | blur+dim by distance                   | engine default (`LyricLineRender` blur/opacity) |

`H`, `W` = the body's constraints (below the grabber). AMLL `1em ≈ 16px`; `4em ≈ 40px`
after the `font-size:.8em` clamp at `max-height:768px` — use ~40 wide-screen, ~20 narrow.

---

## 4. File list

Rewrite (own `pages/player` + `pages/lyrics`; reuse everything else):

| File | Action |
|------|--------|
| `lib/pages/player/player_page.dart` | **Rewrite** to the horizontal AMLL grid: `_HorizontalBody` (Row 45/55) → `_InfoColumn` (spacer-weighted: drag / cover / controls-3fr spaceBetween / bottom) + `_LyricPane`. Drop the heart; add `_BottomToggleRow`; swap background to mesh; correct transport glyphs; keep grabber, `_MorePopup`, dialogs, `_ErrorListener`. |
| `lib/pages/player/widgets/bouncing_track.dart` | **New** — shared knob-less `BouncingSlider` track (swell 8→15, fill α .4→.9, overscroll spring) extracted from `PlayerScrubber`, reused by scrubber + volume. |
| `lib/pages/player/widgets/player_scrubber.dart` | **Edit** — build on `BouncingTrack`; keep labels + indeterminate fallback. |
| `lib/pages/player/widgets/toggle_icon_button.dart` | **New** — AMLL `ToggleIconButton` port (opacity .5→.9, transparent circle, no ripple, airplay/lyrics/playlist glyphs). |
| `lib/pages/player/widgets/media_button.dart` | **Reuse** (already faithful) — only glyphs change at call sites. |
| `lib/pages/player/widgets/player_artwork.dart` | **Reuse** unchanged. |
| `lib/pages/lyrics/lyrics_page.dart` | **Edit** — align active-line `alignPosition` and lyric font size with the two-pane pane so the maximized view matches; keep FFT background wiring. |
| `lib/pages/lyrics/widgets/lyrics_view.dart` | **Reuse** — accept the computed `alignPosition`; no engine change. |
| `lib/animation/**` (`lyric_player_controller`, `lyric_line_render`, `neon_flow_background`, `interlude_dots`, `emphasis`, `mesh_gradient/*`) | **Reuse** as-is. |
| `lib/theme/{app_dimens,app_typography,app_colors}.dart` | **Reuse**; optionally add named tokens (`coverShadow34`, media-button diameters, toggle sizes) to avoid inline literals. |

No new packages. No mobile-app changes. Fonts already bundled (`AlimamaDongFangDaKai`).

---

## 5. Behaviour / state wiring

- All reads via `context.select<PlayerProvider,…>` (field-level) so the per-tick
  position update only rebuilds `_ScrubberBar` — never the cover, transport or lyrics
  (per the per-tick-rebuild memo). `paletteColors`, `dynamicAccent`, `isPlaying`,
  `shuffleEnabled`, `repeatMode`, `volume`, `isBuffering` are existing getters.
- `hideLyricView` = a local `StatefulWidget` bool in `PlayerPage` (AMLL
  `hideLyricViewAtom`), toggled by the bottom `lyrics` button; drives an
  `AnimatedFractionallySizedBox`/flex tween that collapses `_LyricPane` and lets
  `_InfoColumn` slide toward centre (AMLL `.hideLyric` 0.5s `cubic(.5,0,.5,1)`).
- Lyric interactions (drag-to-browse, wheel scroll, tap-to-seek, 5s spring-home) are
  already in `LyricsView`; interlude dots + YRC karaoke sweep come free from the engine.
- Reduced-motion: `LyricsView` already falls back to `_StaticLyrics`.

## 6. Verification

Build for Windows and eyeball against target.png:
`C:\flutter\bin\flutter.bat run -d windows` (or `build windows`). Check: cover upper-
left with active lyric centred on it; thin knob-less bars that swell on hover/drag;
`⏪ ⏸ ⏩` glyphs (not skip-bars); no heart; airplay bottom-left, lyrics+list bottom-
right; mesh-gradient field behind. Resize narrow (<760) → single info column.
