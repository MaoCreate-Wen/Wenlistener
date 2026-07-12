# AMLL Fidelity Spec 2 — Responsive Player, White Glass, Active-Line Edge

Concrete, source-cited specs for the Flutter desktop horizontal player replica.
All ratios are of the **cover edge** or the **viewport** (`W` = window logical width, `H` = window logical height, both in px). Cite lines are relative to each repo.

Sources:
- AMLL horizontal layout — `applemusic-like-lyrics-full-refractor/packages/react-full/src/layout/horizontal.module.css`
- Assembled player (icon sizes, controls) — `.../react-full/src/components/PrebuiltLyricPlayer/index.module.css` + `index.tsx`
- MediaButton bounce — `.../react-full/src/components/MediaButton/index.module.css`
- BouncingSlider — `.../react-full/src/components/BouncingSlider/index.module.css`
- MusicInfo / Cover / Volume — `.../react-full/src/components/{MusicInfo,Cover,VolumeControlSlider}/index.module.css`
- Lyric font + active glow — `packages/core/src/styles/index.css`, `.../styles/lyric-player.module.css`, `.../lyric-player/dom/lyric-line.ts`
- Queue panel — `AMLL-player-main/packages/player/src/components/NowPlaylistCard/index.tsx`
- Reuse targets — `wenlistener_desktop/lib/theme/{app_dimens,app_typography,app_colors}.dart`, `lib/widgets/{glass_container,transport_controls}.dart`

---

## 1. Responsive Sizing (fixes 排版松散 / 间距被拉大)

### 1.1 Cover size — everything keys off this
`horizontal.module.css:43-47`
```
--horizontal-layout-max-width: min(50vh, 38vw);
@media (max-height:1000px) { min(45vh, 38vw); }
```
Flutter:
```dart
double coverSize(Size w) {
  final vh = w.height <= 1000 ? 0.45 : 0.50;
  return math.min(vh * w.height, 0.38 * w.width);
}
```
Cover is a centered square, `aspectRatio 1:1`, drop-shadow `rgba(0,0,0,.19) 0 1em 1.2em` (`Cover/index.module.css:1-13`). **This is the single scale unit — do NOT hardcode 330px** (`AppDimens.playerCoverSize` is only the mini/feed cover).

### 1.2 Control block width = cover width
`horizontal.module.css:80-99` — `.controls { width: var(--horizontal-layout-max-width) }`. The MetaRow, Scrubber, Transport row, and Volume row are all **clamped to `coverSize` wide** and centered under the cover. So `controlWidth = coverSize`.

### 1.3 Transport icons SCALE with the cover — NOT fixed 22/30/42 px
`PrebuiltLyricPlayer/index.module.css:31-35` — **every transport button is `width: 18%` of the control block (= 18% of cover), `aspect-ratio 1/1`.** The glyph inside is a fraction of that button and also scales. Replace the fixed `iconSize: 22/24`, `playSize: 64` in `transport_controls.dart` with:

| element | ratio to cover | at 700px cover | notes |
|---|---|---|---|
| button hit circle (all 5) | **0.18 × cover** | 126px | `songMediaButton`/`songMediaPlayButton` width:18% |
| play / pause glyph | **0.12 × cover** (≈0.67 × button) | 84px | measured target.png; svg `scale:2` base, `1.1` ≤1080 |
| prev / next glyph | **0.09 × cover** (≈0.50 × button) | 63px | svg `scale:3` base, `2` ≤1080, `1.5` ≤768 |
| shuffle / repeat glyph | **0.06 × cover** (≈0.33 × button) | 42px | `iconStyle` 1.3em base, side glyph is smallest |

Flutter (in the transport builder):
```dart
final btn   = coverSize * 0.18;   // circular MediaButton diameter
final play  = coverSize * 0.12;   // play/pause glyph
final side  = coverSize * 0.09;   // prev/next glyph
final small = coverSize * 0.06;   // shuffle/repeat glyph
```
Row is `space-between` across `controlWidth` (`index.module.css:22-24`), so on a big screen the 5 buttons spread edge-to-edge of the cover and each glyph grows — never stays 22px.

### 1.4 Vertical rhythm — keep the block TIGHT + CENTERED (the core fix)
AMLL's grid gives `music-info` row `3fr` and `.controls` is `flex-column; justify-content: space-between` (`horizontal.module.css:9,91-93`). In the browser the child `em`/`vh` paddings absorb the slack; in Flutter a plain `spaceBetween` Column **balloons** the MetaRow↔Scrubber↔Transport↔Volume gaps on a tall window. Fix:

- Give the control block an **intrinsic (content) height**, then **center it vertically** in its region (`Align(center)` / `MainAxisAlignment.center` on the outer column) instead of `spaceBetween` across the full `3fr`.
- **Cap the block:** `maxHeight ≈ coverSize` (≈ `min(50vh,38vw)`); if content is shorter, center it — do not stretch.
- Use **fixed em-scaled gaps** between the four rows, tied to cover, not free space:
  - MetaRow → Scrubber: `coverSize * 0.05`
  - Scrubber → Transport: `coverSize * 0.06`
  - Transport → Volume: `coverSize * 0.05`
  - block `margin-top: 1.75em - 8px` (`horizontal.module.css:97`) ≈ `coverSize * 0.03` nudge up.
- Scrubber track height 8px, min row height `2 × 1.16em` (`BouncingSlider:8,17`); time labels `font-size: max(1.2vh, 0.8em)`, opacity .5 (`index.module.css:97-98`).

Net: a tall/fullscreen window grows the cover + icons proportionally but the four rows stay packed as a centered cluster — kills 间距被拉大.

### 1.5 Lyric font scales with the pane
`core/src/styles/index.css:14-18`
```
font-size: max(max(5vh, 2.5vw), 12px);      /* main/active line */
@media (max-width:768px) { max(8vw, 12px); }
```
Flutter (lyric pane, `W`/`H` = window px):
```dart
double lyricFontSize(Size w) => w.width < 768
  ? math.max(0.08 * w.width, 12)
  : math.max(math.max(0.05 * w.height, 0.025 * w.width), 12);
```
Sub/translation line = `0.5em`, opacity .3 (`lyric-player.module.css:137-141`); background (far) lines = `0.7em`, opacity .4→.0001 (`:52,69`). Line box `padding 0.5em 1em`, `border-radius 0.25em`, hover bg `#fff1` (white α.066). Lyric pane has a `linear-gradient(transparent, black 10%, black 90%, transparent)` vertical mask + `padding-right 15%` (8% ≤1600w) (`horizontal.module.css:108-118`).

---

## 2. White Frosted Glass (queue panel + ⋯ menus)

AMLL's own queue uses **dark** glass (`NowPlaylistCard:80-81` → `blur(1em)` + `--black-a8`). The target here is **Apple-Music light glass**, so override to white translucent. Reuse `GlassContainer` (`lib/widgets/glass_container.dart` already does `BackdropFilter` + `Colors.white.withValues(alpha:)` + hairline).

| token | value | Flutter |
|---|---|---|
| blur sigma | **28** (AMLL `blur(1em)` ≈ 28px at the pane font; Apple 20–30) | `ImageFilter.blur(sigmaX:28, sigmaY:28)` |
| white tint | **Colors.white @ 0.15** (range 0.12–0.18) | `Colors.white.withValues(alpha: 0.15)` |
| top-sheen overlay (optional) | white @ 0.06 linear top→bottom | subtle Apple gloss |
| border | **Colors.white @ 0.25**, width 1 | `Border.all(color: Colors.white.withValues(alpha:0.25), width:1)` |
| radius | **22** | `AppDimens.radiusLg` |
| drop shadow | black @ 0.28, blur 30, y 12 | outer elevation |

Legible text/icons on the light-frosted surface (do NOT keep pure-white body text — it disappears):
- primary text: **black @ 0.88** (`Color(0xE0000000)`)
- secondary/artist: **black @ 0.55**
- icons / chevrons: **black @ 0.72**
- active/now-playing row accent: keep the app accent at full alpha; row hover fill black @ 0.06.

---

## 3. Active Lyric White Edge (白边强调)

AMLL emphasizes the sung line two ways, both in `core/src/lyric-player/dom/lyric-line.ts`:

1. **Blur/opacity separation** — inactive lines get `filter: blur(min(32, blur)px)` + reduced opacity; the active line is opacity 1, blur 0. Over the mesh background with `mix-blend-mode: plus-lighter` (`index.css:13`) the active white text reads as a crisp bright edge vs. the milky neighbors. Distance-driven blur `du/3000` clamped (`:571-586`).

2. **Per-word white glow** (the literal 白边) — `lyric-line.ts:600-616` animates a `text-shadow` on each sung character:
```
text-shadow: 0 0 min(0.3, blur*0.3)em rgba(255,255,255, glowLevel)
glowLevel = empEasing(x) * blur      // blur capped 0.8 → alpha up to ~0.8
```
plus a `scale(1 + transX*0.1*amount)` on the word (`amount` ≤1.2 → up to ~1.12×) and a tiny `translate` (`:602-604`).

**Flutter recipe (faithful = outer glow, not a hard stroke):**
```dart
// active / sung main line — outer white glow (AMLL text-shadow)
TextStyle activeLyric(double fs) => TextStyle(
  fontFamily: AppTypography.displayFont,
  fontSize: fs,
  color: Colors.white,
  fontWeight: FontWeight.w700,
  shadows: [
    Shadow(color: Colors.white.withValues(alpha: 0.55),
           blurRadius: fs * 0.12, offset: Offset.zero),   // ≈ 0.12em, static peak
    Shadow(color: Colors.white.withValues(alpha: 0.25),
           blurRadius: fs * 0.30, offset: Offset.zero),   // soft outer ring
  ],
);
```
- Ramp `alpha` 0→0.55 as the word activates (mirror `glowLevel`) for the animated version; pair with a `scale 1.0→1.10` on the active line and `blur 0` while neighbors get `ImageFilter.blur ~ 2–6px` + opacity 0.4.
- If a harder edge is wanted instead of glow, stack a stroked pass: `Paint()..style=stroke..strokeWidth = fs*0.02..color = Colors.white.withValues(alpha:0.5)` under a filled white pass — but AMLL itself uses the **glow**, so prefer the shadow recipe.

---

## 4. Button Press-Bounce (unify every button)

Exact AMLL MediaButton feel (`MediaButton/index.module.css:1-49`), already in `transport_controls.dart`; apply the SAME to toggle/airplay/lyrics/queue, playlist 播放全部/收藏, and hover icons:

- **Bounce keyframes** (child scale), duration **0.7s**, `animation-composition: accumulate`:
  `0%→1.0 · 20%→0.85 · 50%→1.1 · 100%→1.0`
  Flutter `TweenSequence`: `[1.0→0.85 weight 20, 0.85→1.1 weight 30, 1.1→1.0 weight 50]`, 700ms, on tap-fire.
- **Press dip / active** — background wash `#fff2` = **white @ 0.125**; while pressed the bounce is cancelled (`animation-name: none`) so it reads as a held dip, then bounces on release.
- **Hover** — same `background-color #fff2` (white @ 0.125), `transition background-color 0.3s`.
- **Child transform transition** `0.5s`; button is a circle (`border-radius 50%`, `aspect-ratio 1/1`, transparent `#fff0` idle).

(The current `220ms settle` in `transport_controls.dart` is a simplification; switch to the 700ms 3-stop sequence + 0.125 wash for exact parity, then reuse via a shared `BounceButton` wrapper.)

---

## 5. Queue Panel Sizing

`NowPlaylistCard:55-82`:
- **Row height = 55px** (`estimateSize: () => 55`); avatar `size 4`, name + artist stacked.
- Header `py:3 px:4` (≈ 12/16px) → ~44px.
- Panel: `height: 50vh`, `maxHeight: 500px`, `maxWidth: 400px`, `width: max(10vw, 50vh)`.

Flutter:
```dart
const rowHeight   = 56.0;
const headerH     = 44.0;
final panelHeight = (0.5 * H).clamp(320.0, 500.0);   // ~ header + 8 rows visible
final panelWidth  = math.max(0.10 * W, 0.5 * H).clamp(300.0, 400.0);
```
- ~10 rows visible ⇒ `10 × 56 = 560`, capped at `maxHeight 500` → header + ~8 rows scroll (AMLL's real behavior); if a strict 10 visible is wanted set `panelHeight = headerH + 10*56 = 604` and drop the 500 cap.
- **Right-docked, slide-in from right**: anchor to the right edge, animate `translateX(width→0)` + fade, `cubic-bezier(0.5,0,0.5,1)` ~0.35s. Surface = the §2 white glass. Scroll list, auto-scroll current row to center on open.

---

## Key numbers (quick reference)
- cover = `min(0.50·H, 0.38·W)` (`0.45·H` when `H≤1000`)
- controlWidth = cover; transport button = **0.18·cover**
- glyphs: play **0.12·cover**, prev/next **0.09·cover**, shuffle/repeat **0.06·cover**
- lyric font = `max(max(0.05·H, 0.025·W), 12)` (narrow: `max(0.08·W,12)`); sub 0.5em, bg 0.7em
- white glass: blur **28**, white **α0.15** (0.12–0.18), border white **α0.25**, radius **22**; text black α0.88/0.55, icon black α0.72
- active edge: `Shadow(white α0.55, blur 0.12·fs)` + outer `α0.25, blur 0.30·fs`; word scale →1.10
- bounce: `1→0.85→1.1→1` over **700ms**; press/hover wash white **α0.125**
- queue: row **56**, header **44**, panel H `(0.5·H).clamp(320,500)`, W `max(0.10·W,0.5·H).clamp(300,400)`
