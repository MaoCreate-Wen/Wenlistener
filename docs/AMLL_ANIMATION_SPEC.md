# AMLL Animation & Layout Spec (horizontal player)

Contract for the Flutter desktop port. Every number below is lifted from AMLL
source; each section cites the exact file + CSS/TS value. Two source trees:

- **RF** = `applemusic-like-lyrics-full-refractor/packages/react-full/src`
- **CORE** = `applemusic-like-lyrics-full-refractor/packages/core/src`
- **TAURI** = `AMLL-player-main/packages/player/src`

Target look: `wenlistener-pc/design/target.png`.

---

## 1. Icon positions — horizontal bottom controls (full-width row)

**Key fact:** the bottom controls are their **own grid row spanning the whole
window width** (`grid-column: 1 / 4`), *not* nested inside the left info column.
They use `flex-direction: row-reverse` + a `flex:1` spacer, so AirPlay lands at
the far **bottom-left** and the queue+lyrics pair land at the far **bottom-right**.

Source `RF/layout/horizontal.module.css` `.bottomControls`:

```css
.bottomControls {
  grid-column: 1 / 4;                 /* full width */
  grid-row: buttom-controls;          /* dedicated grid row */
  mix-blend-mode: plus-lighter;
  display: flex;
  flex-direction: row-reverse;        /* DOM order reversed on screen */
  gap: 4em;
  padding-right: 4em;
  padding-left: 4em;
}
/* @media (max-width:1600px) or (max-height:1000px): */
gap: 2em; padding-right: 2em; padding-left: 2em;
```

Grid rows/cols (`.horizontalLayout`): the bottom row is
`[buttom-controls] 0fr 0.3fr` (0.2fr under `max-height:768px`), cover/info sit in
the left column `[info-side] 0.45fr`, lyrics in `[player-side] 0.55fr`. Global
`gap: 8px` between grid cells.

DOM order the prebuilt emits (`RF/components/PrebuiltLyricPlayer/index.tsx`
`horizontalBottomControls`, ~L676–692):

```
Playlist , Lyrics , <div flex:1 spacer/> , AirPlay
```

With `row-reverse` the painted left→right order becomes:
**AirPlay … (spacer) … Lyrics , Playlist**

- **AirPlay** → far bottom-**left**, `padding-left: 4em` (2em on small).
- **Lyrics-toggle + Playlist/Queue** → far bottom-**right**, `padding-right: 4em`,
  `4em` gap between the two (`2em` on small).

Button glyph sizing: each `PrebuiltToggleIconButton` renders its SVG at the
`ToggleIconButton` box (source SVGs are `viewBox 64×64`; airplay `64×64`). The
transport row scales differently — see §7 note. Toggle buttons have no explicit
px size in the bottom row; they inherit the icon intrinsic and the row's `em`
(root font tracks `--horizontal-layout-max-width` / viewport). For Flutter use
**~26–30 px** glyphs in the bottom row at a 1080p-class window, colored white at
~0.9 opacity, sitting on `mix-blend-mode: plus-lighter` (approximate with
`BlendMode.plus` / additive over the blurred art background).

**Flutter mapping:** one `Row` pinned to the page bottom, full width, with
`Padding(horizontal: 4em≈64px)`, children `[AmllAirplayIcon, Spacer(),
AmllLyricsToggleIcon, SizedBox(width:64), AmllPlaylistIcon]`.

---

## 2. Queue panel (play-queue)

Source: `TAURI/components/NowPlaylistCard/index.tsx` +
`TAURI/components/NowPlayingBar/index.tsx` + `NowPlayingBar/index.module.css`.

**Docking / enter:** the panel is absolutely positioned against the **right
edge**, anchored above the play-bar, and is mounted/unmounted on toggle
(`ListBulletIcon` → `setPlaylistOpened(v => !v)`):

```tsx
// NowPlayingBar/index.tsx
<Flex direction="row-reverse" mx="3" position="absolute"
      right="0"
      bottom="calc(var(--amll-player-playbar-bottom) + var(--space-3))">
  <NowPlaylistCard className={styles.playlistCard} />
</Flex>
```

The card itself transitions on `transform` (slide/settle) —
`.playlistCard { transition: transform 0.2s ease; }`. For a right-docked drawer,
match AMLL's feel with a **slide-in from the right edge, 200 ms, ease** (Flutter
`Curves.ease`), fading opacity 0→1 in parallel.

**Dimensions** (`NowPlaylistCard` Flex + `.playlistCard`):

| prop | value |
|---|---|
| width | `max(10vw, 50vh)`, capped `max-width: 400px` |
| height | `50vh`, capped `max-height: 500px` (card css uses `max-height:50vh`) |
| border-radius | `var(--radius-4)` (Radix ≈ **12 px**) |
| border | `solid 1px var(--gray-6)` |
| backdrop blur | **`backdrop-filter: blur(5vh) brightness(0.5)`** (card css) — the inner Flex also sets `backdrop-filter: blur(1em)`; use the stronger `blur(5vh)` + `brightness 0.5` darken |
| tint | `background-color: var(--black-a8)` (≈ `rgba(0,0,0,0.55)`) |

**No full-screen scrim** — the panel floats over the player without dimming the
rest; dismiss = tap the queue button again (toggle) or it hides with the
play-bar (`.hide { transform: translateY(calc(100% + var(--space-3))) }`).

**Item row** (`NowPlaylistCard/index.module.css .playlistSongItem`, list is
`@tanstack/react-virtual`, `estimateSize: 55`):

```css
.playlistSongItem {
  display:flex; align-items:center; gap: var(--space-2);
  padding: var(--space-2) var(--space-4);
  height: calc(var(--space-2)*2 + 50px);   /* ≈ 66 px row */
  &:hover  { background-color:#fff1; }       /* ~6% white */
  &:active { background-color:#ffffff15; }   /* ~8% white */
}
```

Row = `Avatar size 4` (cover) + `{name; artists opacity 0.5}` (single-line
ellipsis) + a `PlayIcon` shown only on the current index. Title header
`Box py=3 px=4` = "当前播放列表". Double-click a row → `queueManager.playAt(index)`.
On open, the list auto-scrolls the current track to center (`scrollToIndex(…,
{align:'center'})`).

**Flutter mapping:** right-docked `AnimatedPositioned`/`SlideTransition` panel,
width `clamp(…, 400)`, height `50vh`, `BackdropFilter(blur ~ 5vh px)` +
`Color(0x8C000000)` tint, `RoundedRectangleBorder(radius 12, 1px gray border)`,
rows 66 px with 6–8% white hover/press.

---

## 3. ⋯ More / overflow menu

Two surfaces:

- **Trigger button** `TAURI`… actually `RF/components/MenuButton/index.module.css`:

```css
.menuButton {
  aspect-ratio:1/1; width: 3.5vh; border-radius:50%;
  background: #ffffff15 !important;   /* ~8% white frosted chip */
  border: none; margin-left:16px;
  & svg { width:72%; color:#ffffff; }
}
```

- **Menu content** — the Tauri app uses Radix `ContextMenu`
  (`TAURI/components/AMLLContextMenu/index.tsx`): rounded frosted popover,
  `radius-4` (≈12 px), thin `gray-6` border, blurred dark translucent panel,
  items with `Ctrl Alt ←/P/→` shortcuts, separators. Match with a
  `blur(~16px)` backdrop, `rgba(0,0,0,0.55)` tint, `12px` radius, `1px` gray
  border, `4–6px` item padding, hover `#fff1`.

---

## 4. Scrubber — `BouncingSlider` (swell on HOVER too)

Source: `RF/components/BouncingSlider/index.tsx` + `index.module.css`.

The height swell is driven by a **spring**, and it fires on **mouseenter**
(hover), mousedown (press) *and* drag — not press-only. Leaving without dragging
springs it back.

Rest / active geometry (spring target positions, converted by
`height = pos * 0.08 px` when `innerHeight ≤ 1000`, else `pos / 10`):

| state | spring target | rendered height |
|---|---|---|
| rest | `80` | **6.4 px** (`80 * 0.08`) |
| **hover** (`onMouseEnter`) | `189` | **15.1 px** |
| press / drag (`onMouseDown`) | `189` | **15.1 px** |
| leave (not dragging) | back to `80` | 6.4 px |

Springs (`index.tsx`):

```ts
heightSpring = new Spring(80);  updateParams({ stiffness:150, mass:1, damping:10 });
bounceSpring = new Spring(0);   updateParams({ stiffness:150 });
```

- **height swell curve** = spring `stiffness 150, mass 1, damping 10` (under-
  damped → slight overshoot/bounce). CSS fallback on the track is
  `transition: height 0.3s cubic-bezier(0.38, 1.625, 0.62, 0.995)` (note the
  `1.625` overshoot — that is the "bounce").
- **overscroll bounce** (`bounceSpring`): when the pointer drags past the ends,
  `relPos>1 → offset=(relPos-1)*900`, `relPos<0 → offset=relPos*900`, applied as
  `translateX(offset/100 px)`, springs back to `0` (`stiffness 150`) on release.

Fill / thumb (`index.module.css`):

```css
.inner { height:8px; border-radius:100px; background:#ffffff26;  /* track ~15% white */
         transition: height 0.3s cubic-bezier(0.38,1.625,0.62,0.995); }
.thumb { height:100%; background:white; opacity:0.4;             /* fill rest 0.4 */
         transition: opacity 0.2s cubic-bezier(0.2,0.2,0,1); }
.nowPlayingSlider:active > .thumb { opacity:0.9; }               /* fill active 0.9 */
.nowPlayingSlider > svg { opacity:0.5; }                          /* end icons */
```

| knob | rest | active (hover/press) |
|---|---|---|
| track/fill height | 6.4–8 px | 15.1 px |
| fill opacity | **0.4** | **0.9** (`:active`) |
| height anim | spring(150,1,10) / 0.3s bounce cubic | same |
| fill-opacity anim | `0.2s cubic-bezier(0.2,0.2,0,1)` | same |

`min-height: calc(1.16em * 2)` keeps the hit-area tall. Progress label row below:
`font-size: max(1.2vh, 0.8em)`, `opacity: 0.5`, `space-between`, `margin-top:-4px`.

**Flutter mapping:** custom slider; on hover **and** press animate track height
`6.4→15.1 px` and fill opacity `0.4→0.9` with a spring (stiffness 150, damping 10,
mass 1). Reuse `lib/animation/spring.dart` if it exposes these params; else the
`0.3s` bounce cubic `Cubic(0.38,1.625,0.62,0.995)`.

---

## 5. Lyrics-toggle transition (`hideLyricViewAtom`)

Source: `RF/components/PrebuiltLyricPlayer/index.module.css` +
`RF/layout/horizontal.module.css`. State atom
`RF/states/configAtoms.ts:333 hideLyricViewAtom` (persisted). Toggled by the
Lyrics `PrebuiltToggleIconButton` (`checked={!hideLyricView}`).

Two coordinated moves:

**(a) The lyric pane** (`horizontal.module.css`): fades + is pushed, and the
cover/info column slides right to re-center:

```css
.lyric { transition: opacity 0.5s 0.25s cubic-bezier(0.5,0,0.5,1); }
.horizontalLayout.hideLyric .lyric {
  transition: opacity .25s cubic-bezier(.5,0,.5,1),
              transform .5s  cubic-bezier(.5,0,.5,1);
  opacity: 0; pointer-events: none;
}
.thumb,.cover,.controls { transition: left .5s cubic-bezier(.5,0,.5,1); left:0%; }
.horizontalLayout.hideLyric .thumb,
.horizontalLayout.hideLyric .cover,
.horizontalLayout.hideLyric .controls { left: var(--hide-lyric-left); } /* 61.111111% */
```

So hiding lyrics: lyric column fades out over **0.25s**, and the
thumb/cover/controls **slide right to `left:61.11%`** over **0.5s**
`cubic-bezier(0.5,0,0.5,1)` to sit centered.

**(b) Big vs small music-info swap** (`index.module.css`) — when lyrics hide, the
large centered info block drops in and the small info block drops out:

```css
.autoLyricLayout {
  --info-timing-func-in:  cubic-bezier(0.5, 0, 0.75, 0);
  --info-timing-func-out: cubic-bezier(0.25, 1, 0.5, 1);
}
.bigMusicInfo            { transform: translateY(-25vh); opacity:0;
  transition: transform .3s var(--in), opacity .3s var(--in); }
.bigMusicInfo.hideLyric  { transform: translateY(0); opacity:1;
  transition: transform .5s .3s var(--out), opacity .5s .3s var(--out); }
.smallMusicInfo          { transform: translateY(0); opacity:1;
  transition: transform .5s .3s var(--out), opacity .3s .3s var(--out); }
.smallMusicInfo.hideLyric{ transform: translateY(25vh); opacity:0;
  transition: transform .3s var(--in), opacity .3s var(--in); }
```

Summary: entering "lyrics-hidden", big info animates **up-from -25vh → 0** over
`0.5s` **after a 0.3s delay** (out-curve), while small info exits **down to +25vh**
over `0.3s` (in-curve). Reverse on show.

**Flutter mapping:** an `AnimationController` (~0.5s) drives (1) an `AlignmentX`/
`left` slide of the cover+controls column to 61.11%, (2) opacity of the lyric
`Widget` (0.25s), (3) a cross-fade+translateY(±25vh) between big/small info.
Curves: slide `Cubic(0.5,0,0.5,1)`; info-in `Cubic(0.5,0,0.75,0)`, info-out
`Cubic(0.25,1,0.5,1)` with the 0.3s stagger.

---

## 6. Cover → player hero / open-close dismiss

Source: `RF/layout/horizontal.tsx` (framer-motion shared-layout) +
`horizontal.module.css`.

The cover, thumbnail and controls are `motion.div` with **shared `layoutId`s**
(`amll-player-thumb`, `amll-player-cover`, `amll-player-controls`) wrapped in a
`<LayoutGroup>` (`PrebuiltLyricPlayer/index.tsx` L703). framer-motion animates
these between layouts with its default **layout spring** (type:"spring", low
stiffness) → this is the Flutter `Hero` flight analog.

The layout container itself:

```css
.horizontalLayout { transition: all 0.5s ease-in-out; }
.thumb,.cover,.controls { transition: left 0.5s cubic-bezier(0.5,0,0.5,1); }
.cover { aspect-ratio:1/1; width/height: var(--horizontal-layout-max-width);
         /* = min(50vh, 38vw); ≤1000px-tall: min(45vh,38vw) */ }
```

**Flutter mapping:** wrap the cover in a `Hero(tag:'amll-cover')` and drive the
now-playing route with a `PageRouteBuilder` whose transition is a spring/
`Curves.easeInOut` over **500 ms**; the flight itself should feel spring-like
(match framer's default: ~stiffness 100–150, damping ~20). Cover target size
`min(50vh, 38vw)`. On dismiss, reverse the same 500 ms flight.

---

## 7. Karaoke per-word rise timing & easing

Source: `CORE/lyric-player/dom/lyric-line.ts`.

**Float (the per-word upward rise), `initFloatAnimation` (L528):**

```ts
const delay    = word.startTime - line.startTime;       // starts when the word does
const duration = Math.max(1000, word.endTime - word.startTime);
let up = 0.05;                 // rise distance in em
if (line.isBG) up *= 2;        // background lines rise 0.10em
animate([ translateY(0px) , translateY(-up em) ], {
  duration, delay,
  easing: "ease-out",          // ← the rise easing
  composite: "add", fill: "both",
});
```

So each word rises **0.05em** (0.10em for background lines), starting at its own
`startTime`, over `max(1000ms, wordDuration)`, easing **`ease-out`** (Flutter
`Curves.easeOut`), composited additively on top of the line transform.

**Emphasis (long-held words) `initEmphasizeAnimation` (L558):** adds scale +
slight X wobble + glow on top of the float. Tunables:

```ts
let amount = du/2000; amount = amount>1 ? sqrt(amount) : amount**3;  // scale drive
let blur   = du/3000; blur   = blur>1   ? sqrt(blur)   : blur**3;    // glow drive
amount *= 0.6;  blur *= 0.5;
// last word of the line gets extra: amount*=1.6; blur*=1.5; du*=1.2;
amount = min(1.2, amount);  blur = min(0.8, blur);
scale = 1 + transX * 0.1 * amount;                 // ≤ ~1.12 peak
glow  = empEasing(x) * blur;                        // text-shadow alpha
// extra float on emphasis: duration = du*1.4, delay = wordDe - 400ms
// per-character stagger: wordDe = de + (du/2.5/nChars)*i
ANIMATION_FRAME_QUANTITY = 32; EMP_EASING_MID = 0.5; // makeEmpEasing bell curve
```

**Line spring params** (`CORE/lyric-player/base.ts` L64–82) — the whole-line
scroll motion the words ride on:

| spring | mass | damping | stiffness |
|---|---|---|---|
| posX | 1 | 10 | 100 |
| **posY** (scroll) | 0.9 | 15 | 90 |
| **scale** | 2 | 25 | 100 |
| blur | 1 | 20 | 50 |

**Flutter mapping (preserve the feel, keep it smooth):** drive each word's
`translateY` from `0 → -0.05em` (`-0.10em` for BG) with `Curves.easeOut` over
`max(1000ms, wordDur)`, delayed to the word's onset; emphasis = add a scale to
≤~1.12 + text-shadow glow (alpha ≤0.8) with a 32-sample bell easing
(`EMP_EASING_MID=0.5`) and a `du/2.5/nChars` per-character stagger, its float
starting 400ms early over `du*1.4`. Line scroll = spring `posY(mass .9, damp 15,
stiff 90)`, scale `(mass 2, damp 25, stiff 100)`.
