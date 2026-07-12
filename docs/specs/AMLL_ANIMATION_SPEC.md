# AMLL Lyrics/Player Animation Model — Flutter Reimplementation Spec

> Source: `applemusic-like-lyrics-full-refractor/packages/core/src/lyric-player`
> This is the authoritative spec for the lyrics + player animation. Build the Flutter
> implementation to these numbers.

## Architecture: NOT a scroll view
Every lyric line is an absolutely-positioned element. Each line's `translateY`, `scale`,
`opacity`, `blur` is driven independently by its own spring. One ticker calls
`player.update(dtMs)` per frame; each line advances its own closed-form spring. Playback
time is pushed separately via `setCurrentTime(ms)`. In Flutter: lines live in a `Stack`,
each wrapped in `Positioned`/`Transform` — do NOT use a ListView/ScrollView for the lyrics.

## 1. Spring physics (`utils/spring.ts`, `lyric-player/base.ts:64-83`)
Closed-form damped-harmonic-oscillator solver (re-seeds from current position + velocity on
retarget). `SpringParams { mass, damping, stiffness, soft }`. **Updated in SECONDS.**

Four spring configs:
| Use | mass | stiffness | damping | ratio | behavior |
|---|---|---|---|---|---|
| posY (line vertical move) | 0.9 | 90 | 15 | 0.833 | underdamped, slight settle |
| scale (line scale) | 2.0 | 100 | 25 | 0.884 | underdamped |
| scaleForBG (bg-line scale) | 1.0 | 50 | 20 | 1.414 | overdamped, no bounce |
| posX (deprecated, disabled) | 1.0 | 100 | 10 | 0.50 | — |

Scale stored in **percent** (100 = 1.0×), applied as `scale/100`. New lines seeded at
`posY = screenHeight*2` (offscreen below) so they fly up into view. `arrived()` when
`|target-current|<0.01 && v<0.01 && v2<0.01`.

**Flutter:** Use `SpringSimulation` + `SpringDescription(mass, stiffness, damping)` — same
`m·x'' + c·x' + k·x = 0` model, constants transfer 1:1. On retarget, restart the simulation
carrying over current velocity. OR port the closed-form solver verbatim (~120 lines) for exact parity.

```dart
posY    : SpringDescription(mass: 0.9, stiffness: 90,  damping: 15);
scale   : SpringDescription(mass: 2.0, stiffness: 100, damping: 25);
bgScale : SpringDescription(mass: 1.0, stiffness: 50,  damping: 20);
```

## 2. Active-line selection & layout (`base.ts:481-821`)
- Lines pre-shifted to start up to **1000ms early** (bounded by previous line's endTime), so
  lines begin lifting ~1s before sung.
- Active line = `startTime ≤ time < endTime`. `scrollToIndex = min(bufferedLines)`.
- Y layout: single accumulator top-to-bottom. Active line anchored at **`alignPosition = 0.35`**
  (35% from top). `curPos -= scrollOffset`; subtract heights before active; `curPos += height*0.35`;
  iterate assigning curPos then `curPos += lineHeight`. `LINE_HEIGHT_FALLBACK = screenH/5`.

## 3. The cascade / stagger ("flow") (`base.ts:727-817`)
```
delay = 0; baseDelay = sync ? 0 : 0.05      // 50 ms
for each line (top→bottom):
   line.setTransform(curPos, scale, opacity, blur, delay)
   if (curPos >= 0 && !seeking):
       if (!line.isBG) delay += baseDelay        // each visible line lags 50ms more
       if (i >= scrollToIndex) baseDelay /= 1.05 // increment decays 5%/line
```
Net: staggered downward "flow", gaps tighten so it doesn't smear. Instant on seek.

## 4. Active vs inactive styling (`base.ts:749-806`)
**Opacity:** active/buffered = **0.85**; inactive = `isNonDynamic ? 0.2 : 1.0` (plain
line-lyrics dim to 0.2; word-by-word stay 1.0 and rely on blur); passed (if hidePassedLines) ≈ 0.00001.

**Scale (percent):** active = 100; inactive while playing = **97** (if enableScale); inactive BG = 75.

**Blur (px, capped at 32):** active = 0; inactive base 1 **+1px per line of distance** from active:
above → `blur += |active - i| + 1`; below → `blur += |i - max(active,latest)|`. Narrow screens
(width ≤ 1024) → `blur *= 0.8`. **Blur scales with distance** ≈ `1 + distance` px.

**Brightness/glow (per-line, from live scale):**
```
s = clamp((scale/100 - 0.97) / 0.03, 0, 1)
brightMaskAlpha = s*0.8 + 0.2     // sung text of active line → 1.0; inactive → 0.2
darkMaskAlpha   = s*0.2 + 0.2     // unsung text of active line → 0.4; inactive → 0.2
```
CSS transitions: opacity .25s, filter .2s.

## 5. Word-by-word animation (`dom/lyric-line.ts`)
Three layered effects per word:
- **(a) Float:** `translateY(0 → -0.05em)` (BG lines -0.10em), `duration = max(1000ms, wordDur)`,
  `delay = word.start - line.start`, `Curves.easeOut`, additive.
- **(b) Karaoke fill:** L→R gradient mask "inks in" each word as sung. `fadeWidth = wordHeight *
  wordFadeWidth`, **`wordFadeWidth = 0.5`** (iPad look; 1.0 = Android). Flutter: `ShaderMask` +
  animated `LinearGradient` whose stop tracks playback time per word; or two-layer (sung/unsung)
  text with a `ClipRect` sweep. Bright/dark alphas from §4 formula.
- **(c) Emphasis (bouncing glowing chars):** only when `shouldEmphasize(word)` = CJK with dur≥1000ms,
  OR non-CJK dur≥1000ms with trimmed length in [2,7]. Split into per-char spans, staggered:
  ```
  du = max(1000, dur); amount = (du/2000 >1 ? sqrt : ^3) * 0.6  (cap 1.2)
  blur = (du/3000 >1 ? sqrt : ^3) * 0.5  (cap 0.8)
  if last word of line: amount*=1.6; blur*=1.5; du*=1.2
  per char i: delay = (du/2.5/n)*i
    ease = rise-then-fall pulse (two cubic beziers around x=0.5)
    scale   = 1 + ease*0.1*amount           // up to +12%
    offsetX = -ease*0.03*amount*(n/2 - i)    // chars splay from center (em)
    offsetY = -ease*0.025*amount             // slight lift (em)
    glow    = Shadow(white @ opacity ease*blur, blurRadius min(0.3, blur*0.3)·em)
  ```
  Flutter: `Row` of per-char widgets, each an `AnimationController` with `Interval` stagger;
  apply `Transform` (scale/translate) + `Text(style: shadows:[...])` glow. Final word gets bigger pop.

## 6. Interlude breathing dots (`dom/interlude-dots.ts`)
Show only when gap ≥ **4000ms**, at the active line's position. 3 dots:
```
breatheDuration = interludeDur / ceil(interludeDur / 1500)         // ~1.5s breaths
scale = sin(1.5π - 2t/breathe)/20 + 1                              // breathe ±0.05
if t<2000: scale *= easeOutExpo(t/2000)                            // grow-in
opacity: t<500 → 0; 500-1000 → ramp 0→1                           // fade-in
last 750ms: scale *= 1 - easeInOutBack(...)                        // shrink-out
last 375ms: opacity *= clamp((dur-t)/375)                          // fade-out
scale = max(0, scale) * 0.7
```
Per-dot fill lights dot0→1→2 in sequence across `interludeDur-750`, offset `dur/3` each
(progress indicator). `easeInOutBack` c1=1.70158, c2=c1*1.525.

## 7. Background (album-art fluid) — two routes
**Faithful (mesh gradient, WebGL):** album art → 32×32, `contrast .4 → saturate 3 → contrast 1.7 →
brightness .75 → blur 2`; bicubic Hermite mesh, 15 subdivisions; fragment shader rotates UV around
(0.2,0.2) by `(time+volume)*2` (slow swirl), zoom `1-volume*2`, dither + vignette
`smoothstep(0.8,0.3,dist); mask=0.6+v*0.4`. `flowSpeed=4`, `renderScale=0.75`. Port via Flutter
`FragmentProgram` + `drawVertices` CustomPainter.

**Pragmatic (recommended for Flutter) — blurred rotating album blobs (Pixi renderer):**
4 sprites of the album art, anchored center, sizes `√2/0.8/0.5/0.25 × maxSize`, rotating at
`±delta/1000, ∓delta/500, +delta/1000, -delta/750 × flowSpeed`; s3/s4 also orbit via `cos(time)`.
Heavy stacked blur (σ up to ~80-320) + `saturate 1.2 / brightness 0.6 / contrast 0.3`.
Flutter: `Stack` of 4 `Transform.rotate` album images (4 controllers, alternating speeds) wrapped
in `ImageFiltered(ImageFilter.blur(σ))` + `ColorFiltered(ColorFilter.matrix)`; crossfade album swaps.

## Key tunables to expose (mirror AMLL setters)
`alignPosition` (0.35), `wordFadeWidth` (0.5), `enableScale` (97 vs 100), `enableBlur`,
`enableSpring`, `hidePassedLines`, `flowSpeed` (bg 4), `renderScale` (bg 0.75), ~1000ms early-start
line shift, the three spring configs.

## Load-bearing source files
- `utils/spring.ts` — closed-form spring (port this)
- `lyric-player/base.ts` — calcLayout (Y + cascade), setCurrentTime (active state), spring configs, styling
- `lyric-player/dom/lyric-line.ts` — float, karaoke mask, emphasis bounce/glow
- `lyric-player/dom/interlude-dots.ts` — breathing dots
- `bg-render/mesh-renderer/index.ts` + `mesh.frag.glsl` (faithful bg); `bg-render/pixi-renderer.ts` (pragmatic bg)
