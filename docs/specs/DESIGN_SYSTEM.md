# WenListener — Design System (Flutter)

> Standardized via ui-ux-pro-max (OLED Dark + Glassmorphism) and tuned for a Netease-backed,
> Apple-Music / BlackHole-inspired player. Every page agent MUST follow this. Reference tokens
> through `Theme.of(context)` / an `AppTheme` class — **never hardcode `Color(0x...)` in widgets**.

## 1. Direction
Dark-first (OLED), frosted glassmorphism surfaces, **dynamic accent extracted from album art**
(via `palette_generator`, already a dependency). Minimal glow, vibrant play-accent, high contrast
(target WCAG AA+; 7:1 for primary text on black). Motion: 200–300ms micro-interactions, spring for
player/lyrics (see AMLL spec).

## 2. Color tokens (`lib/theme/app_colors.dart`)
Base palette (static, dark):
| Role | Value | Use |
|---|---|---|
| `bg` | `#000000` | app scaffold (true black, OLED) |
| `surface` | `#0E0E14` | cards, sheets (base) |
| `surfaceGlass` | `white @ 8–12% over blur` | glass cards / mini-player / nav |
| `surfaceGlassBorder` | `white @ 12–16%` | 1px hairline on glass |
| `onSurface` | `#F8FAFC` | primary text |
| `onSurfaceMuted` | `white @ 60%` | secondary text |
| `onSurfaceFaint` | `white @ 38%` | tertiary / disabled |
| `accentPlay` | `#22C55E` | play/active affordance (default; overridden by dynamic) |
| `seed` | `#4338CA` → `#1E1B4B` | fallback brand gradient when no art |

**Dynamic accent (core mechanic):** extract from current album art with `palette_generator`
(reuse `computeImageColors` logic), expose as `dynamicAccent` / `dynamicGradient` via the player
state. Accent drives: progress bar, active nav/icon, lyric highlight glow, like button, gradient
washes. Always keep text on a darkened scrim so contrast holds regardless of art.

Material 3: build `ThemeData(useMaterial3: true, brightness: dark, colorScheme:
ColorScheme.fromSeed(seedColor: seed, brightness: dark))`, then override surfaces to the tokens above.

## 3. Typography (`lib/theme/app_typography.dart`)
- **Display / titles / lyrics:** `AlimamaDongFangDaKai` (bundled). Use for page hero titles,
  song title on player, and the lyrics view.
- **Body / UI / metadata:** system default (`-`/Roboto/SF) — clean sans. Do NOT use the display
  font for body or lists (it's a heavy display face).
- Scale (logical px): displayL 32, displayM 28, titleL 22, titleM 18, body 15, label 13, caption 11.
  Line-height 1.4–1.5 for multi-line. Min 15px for body on mobile.

## 4. Spacing / radius / elevation (`lib/theme/app_dimens.dart`)
- Spacing scale (4-pt): 4, 8, 12, 16, 20, 24, 32, 48. Default screen padding 16–20.
- Radius: sm 10, md 16, lg 22, xl 28, pill 999. Album art radius = `size/20` (matches existing).
- Glass blur: `ImageFilter.blur(sigmaX:24, sigmaY:24)` for panels; 30 for full-screen player bg
  (matches current `blurValue`). Mini-player/nav blur σ ≈ 18.
- Elevation = blur + 1px glass border + soft shadow `BoxShadow(color: black@40%, blur 16, y 8)`.
- Touch targets ≥ 44×44.

## 5. Reusable widgets (build these in `lib/widgets/` — page agents consume, don't re-invent)
- `GlassContainer({blur, opacity, border, radius, child})` — the frosted surface primitive.
- `AppScaffold` — black bg + optional dynamic gradient wash + bottom mini-player + nav slot.
- `SongTile({title, artist, artworkUrl, trailing, onTap})` — the canonical list row (used in
  search results, playlist, queue). 56px artwork, md radius, title (1 line) + artist (muted).
- `SectionHeader({title, onMore})` — home carousels / list sections.
- `ArtworkImage({url, size, radius, hero})` — cached network image w/ placeholder + Hero support.
- `PlayPauseButton`, `ProgressBar` (accent-colored, draggable), `LikeButton`.

## 6. Component specs
- **Bottom nav:** glass bar (blur), 3–4 tabs (Home / Search / Library), pill indicator in dynamic
  accent, icon+label, 44px targets. Mini-player sits directly above it.
- **Mini-player bar:** glass, full-width, 64px tall: artwork(48) + title/artist + play/pause + next;
  tap → expand to full player (Hero `album_art`). Thin progress line (accent) along the top edge.
- **Home / discovery:** vertical scroll of sections — greeting header, horizontal carousels
  (playlists/albums) using `SectionHeader` + horizontally-scrolling cards, and a grid ("recommended").
  Cards: artwork + 2-line caption, md radius, subtle press scale (no layout shift).
- **Search:** pinned glass search field (rounded pill) with clear button; below: tab chips
  (Songs/Albums/Artists/Playlists) and a paginated results list of `SongTile`. Empty/loading =
  skeleton list (reserve space, no jumping).
- **Playlist detail:** large blurred-artwork header (cover + title in display font + creator +
  play-all CTA in accent), collapses on scroll (`SliverAppBar`); body = list of `SongTile` with
  index, virtualized (`ListView.builder`/slivers).
- **Full player page:** dynamic art-driven gradient/blob bg (AMLL pragmatic bg), large album art
  (Hero `album_art`, shadow, radius size/20), title (display font) + artist, draggable `ProgressBar`
  + times, prev/playpause/next, secondary row (shuffle/repeat/like/queue/lyrics toggle). Tap art →
  lyrics page.
- **Lyrics page:** implement to `AMLL_ANIMATION_SPEC.md` — spring-driven per-line layout, active
  line at 0.35, blur/scale/opacity by distance, word-by-word karaoke + emphasis when klyric present,
  interlude dots, dynamic-art background. Header = mini artwork + title; tap → back to player.

## 7. Flutter rules (from stack guidelines)
- `ThemeData` + `Theme.of(context)` for all colors/text styles; **no hardcoded colors in widgets.**
- `Column`/`Row` for linear layout; `Stack` only when layering (player bg, lyrics). 
- Keep the tree shallow — extract nested widgets into named widgets/methods (no 10-deep nesting).
- Lists: always `ListView.builder`/slivers (virtualize). `cacheExtent` for smooth scroll.
- Images: `cached_network_image` with placeholder + reserved size (no content jumping).
- Animations: `transform`/`opacity` based; respect a `reduceMotion` flag where feasible.
- Icons: keep the existing SVG set (`flutter_svg_icons`) + Material icons; no emoji as icons.

## 8. Anti-patterns to avoid
Flat/depthless surfaces (use glass + shadow), text-heavy screens, hardcoded colors, over-transparent
glass on light art (always scrim), layout-shifting hover/press, non-virtualized long lists.
