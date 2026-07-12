# Desktop Change Map — player / lyrics / playlist rework

Exact targets for the 9 fixes. All paths absolute under
`C:/Users/Fhw20/desktop/code/wenlistener_desktop`. Line numbers are from the
current tree (2026-07-11); re-confirm before editing since edits shift them.

Reuse `lib/animation/*`, `lib/theme` (`AppColors` / `AppDimens` /
`AppTypography`, display font = `AppTypography.displayFont` 阿里妈妈东方大楷).
Build/analyze with `C:\flutter\bin\flutter.bat` (flutter not on PATH; system
`dart` is stale).

---

## 0. Cross-cutting facts every implementer needs

### 0.1 The Hero source (fix #8)
- **Mini-player file:** `lib/shell/mini_player.dart`.
- **Cover widget:** `ArtworkImage` (`lib/widgets/artwork_image.dart`), built
  inside `_NowPlaying` at **mini_player.dart:136-142**. It **already sets
  `heroTag: 'album_art'`** and already has a full flight shuttle
  (`ArtworkImage._shuttle`, artwork_image.dart:60-98) that lerps corner radius
  + fades the shadow. This is the ready-made Hero SOURCE.
- **Player-side cover:** `_Cover` in `player_page.dart:308-339` renders
  **`PlayerArtwork`** (`lib/pages/player/widgets/player_artwork.dart`), which has
  **NO Hero support at all** — no `heroTag`, no `Hero` wrapper. This is the gap:
  the destination cover never joins the flight, so the push has no shared-element
  morph today.
- `'album_art'` is the ONLY hero tag in the codebase (grep confirmed — only
  mini_player.dart:140 and the ArtworkImage plumbing). No collision.
- **Navigator hierarchy is already correct for Hero:** the shell (hosting the
  mini-player) lives in `StatefulShellRoute.indexedStack` under
  `rootNavigatorKey`; the `/player` + `/lyrics` routes push with
  `parentNavigatorKey: rootNavigatorKey` (app_router.dart:113,120). Source and
  destination share one Navigator, so a Hero will fly.

### 0.2 The exact PlayerProvider fields `LyricsView.build` must `select` (fix #5)
`lyrics_view.dart:233` does `context.watch<PlayerProvider>()` → the ENTIRE view
subtree (the `LayoutBuilder` + per-frame `ListenableBuilder`) rebuilds on every
position tick, on top of the controller's own per-frame `ListenableBuilder`
(lines 289-303). The `watch` result `player` is used at only these four reads:

| Field | Line | Purpose | Change cadence |
|---|---|---|---|
| `player.lyricsLoading` | 239 | first-load spinner gate | per fetch |
| `player.lyricsSettled` | 243 | empty-vs-still-loading gate | per fetch |
| `player.activeLyricIndex` | 251 | reduced-motion static list highlight | per line |
| `player.dynamicAccent` | 299 | interlude-dot colour (passed to `_interlude`) | per song |

None of those change per tick. **Replace the single `context.watch` with four
`context.select` calls** for exactly those four getters (all exist on
PlayerProvider: `lyricsLoading` :134, `lyricsSettled` :140, `activeLyricIndex`
:141, `dynamicAccent` :127). The live position/isPlaying/lines feed is a
SEPARATE channel — `_provider!.addListener(_onProvider)` (didChangeDependencies
:112) driving `_onProvider` (:121-139) → the `LyricPlayerController`. That path
does NOT go through `build`, so removing the `watch` does not disturb the
karaoke sweep; the per-frame rebuild then comes only from the controller's
`ListenableBuilder`, which is intended.

Note `player` is also passed positionally into `_animatedLyrics(player)` (:258)
and read at :299 inside the ListenableBuilder closure — after the refactor,
pass the selected `Color accent` down instead of the whole provider, or read
`dynamicAccent` via its own `select` at the top of `build`.

### 0.3 `lib/widgets/amll_icons.dart` does NOT exist yet (fixes #1)
Grep found no `amll_icons` / `AmllIcons` anywhere. The icon agent must CREATE
it. Player/lyrics code should import it as
`import '../../widgets/amll_icons.dart';` (from `pages/player/` and
`pages/lyrics/`) once it lands. Do not block on it — leave the `Icons.*`
references until the glyph set is available, then swap (see fix #1 table).

---

## 1. Swap control icons to AMLL glyphs

**Depends on** `lib/widgets/amll_icons.dart` (to be created — see §0.3).

### player_page.dart (all `Icons.*` in transport / toggles / meta)
| Line(s) | Current glyph | Role |
|---|---|---|
| 420 | `Icons.playlist_add_rounded` | popup: 添加到歌单 |
| 431 | `Icons.library_add_rounded` | popup: 添加到本地歌单 |
| 447 | `Icons.more_horiz_rounded` | ⋯ button |
| 508 | `Icons.repeat_one_rounded` / `Icons.repeat_rounded` | repeat |
| 516 | `Icons.shuffle_rounded` | shuffle |
| 522 | `Icons.fast_rewind_rounded` | prev (double-triangle) |
| 534 | `Icons.pause_rounded` / `Icons.play_arrow_rounded` | play/pause |
| 542 | `Icons.fast_forward_rounded` | next |
| 548 | `repeatIcon` | repeat (var from 508) |
| 567,578 | `Icons.volume_down_rounded` / `volume_up_rounded` | volume flanks |
| 605 | `Icons.airplay` | AirPlay toggle |
| 613 | `Icons.lyrics_outlined` / `Icons.lyrics` | lyrics toggle |
| 622 | `Icons.queue_music_rounded` | queue toggle |

The transport glyphs are passed as `child: Icon(...)` into `MediaButton`
(`media_button.dart`) — MediaButton is glyph-agnostic (takes any `Widget
child`), so swapping only the `Icon` widget is enough; no MediaButton edit
needed. `_Transport` colours (`_white` :493, `_dim` :494) stay.

### lyrics_page.dart
Only glyph is the header has none; the only icon is the empty-state fallback
inside `LyricsView._empty` (`lyrics_view.dart:421` `Icons.lyrics_outlined`) and
`lyrics_page.dart` has no transport. If AMLL glyphs are wanted on the lyrics
`_empty`, that's in `lyrics_view.dart:421`, not lyrics_page.dart. **The lyrics
PAGE itself has no control icons to swap** — the toggle/queue/airplay live on the
player page. (Confirm with the icon agent whether the mini-player's
`Icons.lyrics_outlined` / `Icons.open_in_full_rounded` at
`mini_player.dart:194,204` are in scope — those are shell-owned, do not edit
from the player agent.)

**Coupling:** `ToggleIconButton` and `MediaButton` both take generic children /
`IconData`, so glyph swaps are local to the call sites above.

---

## 2. Hoist AirPlay + lyrics-toggle + queue to a PAGE-level full-width bottom bar

**Problem (as briefed):** `_BottomToggleRow` (`player_page.dart:587-630`) is
built INSIDE `_InfoColumn` (`player_page.dart:293-297`), i.e. trapped in the
left 45% flex column. AirPlay/lyrics/queue are cramped on the left instead of
AirPlay pinned to the PAGE's bottom-left corner and lyrics+queue to the PAGE's
bottom-right corner.

**Targets:**
- Remove the `_BottomToggleRow(...)` invocation from `_InfoColumn.build`
  (**player_page.dart:293-297**) and drop the trailing `Spacer(flex: 30)` /
  rebalance the column flexes (`_InfoColumn` :269-300).
- Hoist a page-level bar into `_PlayerPageState.build`
  (**player_page.dart:62-89**): today the body `Column` (:70-83) is
  `[_Grabber, Expanded(child: body)]`. Add a third child — a full-width bottom
  bar — OR (cleaner) wrap the `Expanded` body + the bar in a `Stack` so the bar
  overlays the page bottom edge at full width, anchored corner-to-corner
  (`Row` with `AirPlay`, `Spacer`, `lyrics`, `queue`, padded to the page's
  horizontal insets, e.g. `EdgeInsets.fromLTRB(28,4,28,8)` as it is now).
- The `_hideLyric` state + `onToggleLyric` currently threads
  `_TwoPaneBody → _InfoColumn → _BottomToggleRow`. Once the bar is page-level,
  the toggle can call `_PlayerPageState`'s setState directly; `_TwoPaneBody`
  still needs `hideLyric` for its layout branch (**:224** `if (!wide ||
  widget.hideLyric) return info;`), so keep passing `hideLyric` down but move
  `onToggleLyric`'s owner up. The `canToggleLyric` gate (only when `wide`,
  measured in `_TwoPaneBody.build` :216 `c.maxWidth >= 760`) must be recomputed
  at page level — either lift a width `LayoutBuilder` around the bar, or have
  `_TwoPaneBody` report `wide` up. Simplest: give the page-level bar its own
  `LayoutBuilder` and use the same `>= 760` threshold.

**Coupling:** `_TwoPaneBody` (:173-239) and `_InfoColumn` (:245-304) both
currently carry `hideLyric` / `canToggleLyric` / `onToggleLyric` params —
signatures change. `_LyricsPane` unaffected. `ToggleIconButton` reused as-is.

---

## 3. Queue panel: slide from right, dock right, frosted-glass backdrop

**Current:** `_showQueueSheet` (**player_page.dart:633-705**) uses
`showModalBottomSheet` (bottom, `AppColors.surface`, `showDragHandle`,
`DraggableScrollableSheet`). Called from `_BottomToggleRow` at
**player_page.dart:624** `onTap: () => _showQueueSheet(context)`.

**Change:** replace the whole `_showQueueSheet` body with a right-docked panel.
Two viable approaches:
1. `showGeneralDialog` with a `SlideTransition` from `Offset(1,0)`, aligning the
   child to `Alignment.centerRight`, child width ~360-420, full height, wrapped
   in a `BackdropFilter` (reuse `DkGlass` from `desktop_kit.dart:63-101` — it is
   already a `ClipRRect` + `BackdropFilter` + `AppColors.glass` fill + hairline).
   Set `barrierColor` to a faint scrim so the field shows through.
2. Or an in-page `Stack` overlay with an `AnimatedPositioned`/`SlideTransition`
   (avoids a route, keeps the Hero/morph intact).

Keep the existing `Consumer<PlayerProvider>` + `queue` / `currentSong` /
`jumpTo(index)` list body (:646-701) verbatim inside the new frosted container;
only the presentation shell (bottom sheet → right dock + glass) changes. Row
`onTap` still `player.jumpTo(index); Navigator.pop` (:692-695) — if you use an
in-page overlay instead of a route, swap the `Navigator.of(ctx).pop()` for the
overlay's close callback.

**Reuse:** `DkGlass` (`lib/pages/playlist/desktop_kit.dart:63`) is owned by the
playlist agent — you may import/reference it, not edit it. If cross-agent import
is undesirable, replicate its 3-line `BackdropFilter` locally in player_page.

---

## 4. ⋯ menu: frosted glass

**Current:** `_MorePopup` (**player_page.dart:395-465**) is a solid
`PopupMenuButton<int>` with `color: AppColors.surface2` (:400) and a
`RoundedRectangleBorder` + `AppColors.glassBorder` side (:401-404).
`PopupMenuButton` cannot host a `BackdropFilter` behind its Material menu.

**Change:** to get true frosted glass, drop `PopupMenuButton` and drive a custom
overlay — either `showMenu` into a themed `PopupMenuTheme` won't blur either, so
use a bespoke anchored overlay (`OverlayEntry` / `showGeneralDialog` positioned
under the button) whose panel is a `DkGlass` / `BackdropFilter`. Keep the two
actions unchanged: `_showAddToPlaylist` (:452-457) → `_AddToPlaylistDialog`, and
`_showAddToLocalPlaylist` (:459-464) → `_AddToLocalPlaylistDialog`. The trailing
trigger container (:439-448, the circular `Color(0x1FFFFFFF)` + `more_horiz`)
becomes the anchor.

**Coupling:** `_AddToPlaylistDialog` (:798-880) and `_AddToLocalPlaylistDialog`
(:884-976) are self-contained `AlertDialog`s and can stay as-is (or also get the
glass treatment via their `backgroundColor`). `showDialog` calls unaffected.

---

## 5. Karaoke / player frame-drop fixes

### 5a. Per-tick whole-view rebuild — `LyricsView` (PRIMARY)
See §0.2. `lyrics_view.dart:233` `context.watch` → four narrow `context.select`
(`lyricsLoading`, `lyricsSettled`, `activeLyricIndex`, `dynamicAccent`). Biggest
single win — kills a full re-layout every position tick.

### 5b. `_TwoPaneBody.build` re-measures on EVERY build (player)
`player_page.dart:210-212`:
```dart
WidgetsBinding.instance.addPostFrameCallback((_) {
  if (mounted) _measure();
});
```
This schedules a post-frame `_measure` on every single build of `_TwoPaneBody`.
`_measure` (:188-206) does `localToGlobal` + a `setState` when the cover-centre
fraction drifts > 0.003 — so a stray rebuild can loop (setState → build →
schedule → measure → setState). **Fix:** only schedule the measure when inputs
that affect layout change (first build, `hideLyric` flip, or a
`LayoutBuilder`-detected size change), not unconditionally. Cache the last
measured constraints and short-circuit. Move the `addPostFrameCallback` out of
`build` into `didUpdateWidget` + an initial `initState`/first-layout hook, or
gate it behind a `_needsMeasure` flag set by the `LayoutBuilder` when
`c.maxWidth/maxHeight` change.

### 5c. RepaintBoundary coverage
- `LyricLineWidget` already wraps its output in `RepaintBoundary`
  (`lyric_line_widget.dart:89`). Good.
- `_Background` (player_page.dart:110) and lyrics `_Background`
  (lyrics_page.dart:109) already wrap `NeonFlowBackground` in `RepaintBoundary`;
  `NeonFlowBackground.build` itself also wraps in one (neon_flow_background.dart
  :380). Fine.
- **Add** a `RepaintBoundary` around the `_ScrubberBar`
  (player_page.dart:469-484) and the transport row so the per-second position
  select (:475-477) can't dirty-paint neighbours. The scrubber is the one piece
  that legitimately rebuilds each second.
- Consider a `RepaintBoundary` around the whole `LyricsView` animated stack
  (`lyrics_view.dart:288` `ClipRect`) so its per-frame controller repaints stay
  isolated from the background.

### 5d. Karaoke `saveLayer` / `ShaderMask` cost (`karaoke_text.dart`)
- `_AdditiveLayer` (:369-387) does an **unbounded `saveLayer`** (bounds=null,
  `BlendMode.plus`) per singing line — required for the merged halo, but it runs
  for EVERY word-by-word line each frame if `isSinging`. It's already gated to
  the single singing line (`KaraokeText.build` :58-70 renders non-singing lines
  as one flat `Wrap`, no Stack/saveLayer). Keep that gate; do NOT widen it.
- `_textContent` (:243-257) uses a per-word `ShaderMask(BlendMode.dstIn)` for
  the karaoke sweep — one shader per SUNG word on the singing line. That's the
  intended cost. If frame drops persist, the lever is: skip the `ShaderMask`
  when `sung <= 0` (fully unsung → just the dim base layer) or `sung >= 1`
  (fully sung → the bright layer). Currently `_maskShader` (:330-353) already
  special-cases `right<=0` and `left>=1` by returning a constant-colour gradient,
  but the `ShaderMask`+`saveLayer` still runs — short-circuit in `_textContent`
  to return the plain layer without the `ShaderMask` in those two extremes.
- The glow pass (`_glowContent` :191-237) only builds real content when
  `shouldEmphasize(word)` (emphasis.dart:30) AND `g.hasGlow`; otherwise a
  transparent ghost. Leave as-is.

### 5e. Background per-frame cost is already capped
`NeonFlowBackground` runs at 30fps (`_kMinFrameIntervalMs` :453) and FREEZES
during the player↔lyrics morph (`morph` animation, :233-234) — but note the
morph clock is NOT wired in the desktop player/lyrics pages (neither `_Background`
passes `morph:`). If fix #8's cover-hero/morph introduces a transition, pass the
morph `Animation` into both `_Background`s so the ~40k-vertex `drawVertices`
holds during the flight (constructor param exists: neon_flow_background.dart:85).

---

## 6. Scrubber hover swell — `bouncing_track.dart`

**Current:** `BouncingTrack` swells 8→15px only on `_pressed` / `_dragging`
(`_active`, :55). The swell controller `_swell` (:57-64) is driven by
`_setPressed`/`_setDragging` → `_syncSwell` (:109). There is a `MouseRegion`
(:125-128) but it only sets the cursor — **no `onEnter`/`onExit`**.

**Change:** add `onEnter`/`onExit` to the `MouseRegion` at
**bouncing_track.dart:125** that drives the swell on hover (desktop pointer),
mirroring press. Introduce a `_hovered` bool (like `_pressed` :52) folded into
`_active` (:55 → `_dragging || _pressed || _hovered`), and call `_syncSwell()`
from the hover setters. Keep the existing press/drag behaviour. This makes both
the progress scrubber (`player_scrubber.dart`, which wraps `BouncingTrack` at
:77) and the volume rail (`player_page.dart:571`) swell on hover for free — same
shared widget.

**Coupling:** one edit in `bouncing_track.dart` covers scrubber + volume. No
change to `player_scrubber.dart` needed (it forwards to BouncingTrack).

---

## 7. Lyrics-toggle switch transition

**Current:** `_hideLyric` flips via a bare `setState`
(`player_page.dart:77-78`): `onToggleLyric: () => setState(() => _hideLyric =
!_hideLyric)`. `_TwoPaneBody.build` (:224-235) then hard-swaps between `info`
alone and the `Row(info, lyricsPane)` with NO transition — the right pane pops
in/out.

**Change:** wrap the two-pane branch in an animated cross-fade / size
transition. Options:
- `AnimatedSwitcher` around the `_TwoPaneBody.build` return (:224-235) —
  transition the `_LyricsPane` in/out; but AnimatedSwitcher on a `Row` layout
  change is awkward.
- Better: keep the `Row` always built and animate the lyrics pane's `Flexible`
  flex / opacity via an `AnimationController` (or `TweenAnimationBuilder<double>`
  keyed on `hideLyric`) so the pane slides/fades and the info column's width
  eases 45%↔100%. The `ToggleIconButton` (`toggle_icon_button.dart`) already
  cross-fades its own glyph opacity over 200ms (:48-52) — match that duration
  (200ms, `Curves.ease`) for visual consistency.

The toggle button itself (`_BottomToggleRow` :613-618, moving to the page-level
bar in fix #2) needs no change beyond staying wired to the new owner's toggle.

---

## 8. Cover hero + grabber-dismiss transition

**Source (ready):** mini-player cover `ArtworkImage(heroTag: 'album_art')` —
`mini_player.dart:136-142` (see §0.1). Full flight shuttle already implemented.

**Destination (missing the Hero):** `_Cover` (`player_page.dart:308-339`) →
`PlayerArtwork` (`player_artwork.dart`), which has no Hero support.

**Change — two parts:**
1. Give the player cover a matching Hero. Cleanest: wrap the `PlayerArtwork` in
   `_Cover.build` (**player_page.dart:324-337**) in a `Hero(tag: 'album_art',
   ...)`. But the mini-player's shuttle (`ArtworkImage._shuttle`) expects BOTH
   endpoints to be `_ArtworkHeroChild` (artwork_image.dart:69 — if either isn't,
   it falls back to `toChild` with no morph). So for a pixel-perfect radius/shadow
   morph, the player cover should ALSO use `ArtworkImage` (with `heroTag:
   'album_art'`, the same shadow list `_Cover` passes at :328-335, and a
   `radius`), NOT `PlayerArtwork`. `ArtworkImage` supports `shadow` + `radius` +
   `heroTag` and is under `lib/widgets/` (shell agent owns it — import/reference
   only, do not edit). If replacing `PlayerArtwork` with `ArtworkImage` is
   undesired (it's this agent's own widget), instead add Hero + a compatible
   `flightShuttleBuilder` to `PlayerArtwork`, but then the mini-player's shuttle
   still governs the flight (the `fromHeroContext` is the mini-player) — so the
   from-side must produce an `ArtworkImage`. Net: **the player cover must present
   an `ArtworkImage` with tag `'album_art'`** for the shuttle to engage.
   - The `_Cover` pause-dip `Transform.scale` (:318-323) wraps the artwork —
     keep it OUTSIDE the Hero (scale the Hero child) or the flight geometry
     fights the dip. Put `Hero` as the direct artwork wrapper, `Transform.scale`
     around it.
   - The lyrics page mini cover (`_Header` → `PlayerArtwork`,
     `lyrics_page.dart:142-147`) could also carry `heroTag: 'album_art'` if a
     player↔lyrics hero is wanted, but note only ONE Hero per tag per route may
     be on screen — do not tag both the player cover and a lyrics cover if both
     can be mounted simultaneously.
2. Grabber-dismiss: `_Grabber` (`player_page.dart:138-166`,
   `lyrics_page.dart:212-240`) currently just calls `onTap` → `_dismiss`
   (`player_page.dart:49-55`) → `context.pop()`. The route pop already runs the
   `_sheetTransition` slide-down (app_router.dart:28-45) AND, once the Hero is
   in place, the reverse cover flight. To make the grabber a *drag*-to-dismiss
   (not just tap), add a `GestureDetector.onVerticalDragUpdate/End` on the
   grabber (or the page) that drives `context.pop()` past a threshold; the Hero
   + `_sheetTransition` handle the visuals. Minimal version: keep tap-dismiss,
   just ensure the Hero is wired so the existing pop animates the cover back.

**Coupling / navigator:** both routes are on `rootNavigatorKey`
(app_router.dart:113,120) and the mini-player is in the root-navigator shell, so
the Hero flies. `_sheetPage` is `opaque: true` (app_router.dart:53) — Heroes
require the destination to be pushed on the same navigator, which it is.

---

## 9. Playlist: dissolve `DkScaffold` solid bar, float back button over blurred-cover header

**The 纯色栏:** `DkScaffold` (`desktop_kit.dart:417-490`) draws a solid
`header` row (**:440-463**) — back-arrow (`DkHoverIcon` :450-454) + title
(:456-458) + `actions` — sitting ABOVE the body inside a `Column`
(:480-487), over a `surface→bg` `LinearGradient` (:471-479). That opaque header
band is the "纯色栏" to dissolve.

**Only consumer:** `PlaylistDetailPage` (`playlist_detail_page.dart:42-73`) is
the ONLY `DkScaffold` user in the playlist page — grep/scope confirms it's safe
to rework `DkScaffold` OR bypass it here.

Wait — verify before editing: `DkScaffold` is a shared kit widget; the briefing
says it "has ONLY this one consumer so it's safe to rework." Confirm with a repo
grep for `DkScaffold(` (accounts/settings/login pages may also use it — the kit
doc comment at desktop_kit.dart:415 says "playlist / accounts / login"). **If
other pages consume it, do NOT rework DkScaffold globally** — instead bypass it
in `PlaylistDetailPage` (use a bare `Scaffold` there) so the change is scoped.

**Change:**
- `PlaylistDetailPage.build` (**playlist_detail_page.dart:42**) currently returns
  `DkScaffold(title:'歌单', padding: EdgeInsets.zero, child: FutureBuilder...)`.
  The `_Header` (**:164-284**) is a 300px `Stack` already containing the blurred
  cover fill (`ImageFiltered` blur 40, :186-193), a scrim (:195-203), and the
  title/creator/buttons. The DkScaffold header band is redundant chrome ON TOP of
  this rich header — remove it.
- Replace `DkScaffold` with a plain `Scaffold` (bg `AppColors.bg`) whose body is
  the existing `CustomScrollView` (`_PlaylistBody.build` :123-161), and **float a
  back button** (`DkHoverIcon(icon: Icons.arrow_back_rounded, ...)` — reuse from
  desktop_kit.dart:312, import only) in a `Stack`/`Positioned` (or `SafeArea` +
  `Align.topLeft`) OVER the blurred-cover `_Header`, so it sits on the scrim with
  no solid bar behind it. Give it a subtle circular scrim/hover (DkHoverIcon
  already hover-tints, :349-356).
- Back action stays `context.pop()` (matches DkScaffold's :453 and the
  `_dismiss` pattern).

**Coupling:** `DkArt`, `DkPrimaryButton`, `DkSecondaryButton`, `DkTrackTable`,
`dkShowSongMenu` (all in `desktop_kit.dart`) are reused unchanged. If bypassing
`DkScaffold`, only `PlaylistDetailPage` changes; `desktop_kit.dart` stays intact
(preferred, avoids touching other DkScaffold consumers). The `LocalPlaylistDetailPage`
(`lib/pages/library/local_playlist_detail_page.dart`, route `/local/:id`) may be a
second DkScaffold consumer — check it if a global DkScaffold rework is chosen.

---

## Ownership / coupling summary

| Fix | Owned files to edit | Import-only (other agents) |
|---|---|---|
| 1 | player_page.dart, (lyrics_view `_empty`) | `widgets/amll_icons.dart` (to be created) |
| 2 | player_page.dart (`_PlayerPageState`, `_TwoPaneBody`, `_InfoColumn`, `_BottomToggleRow`) | — |
| 3 | player_page.dart (`_showQueueSheet`) | `DkGlass` (playlist) or inline blur |
| 4 | player_page.dart (`_MorePopup`) | `DkGlass` optional |
| 5 | lyrics_view.dart, player_page.dart (`_TwoPaneBody`, `_ScrubberBar`), karaoke_text.dart | PlayerProvider getters (read-only) |
| 6 | bouncing_track.dart | — |
| 7 | player_page.dart (`_TwoPaneBody`, `_PlayerPageState`) | toggle_icon_button.dart (reuse) |
| 8 | player_page.dart (`_Cover`), lyrics_page.dart (opt) | `widgets/artwork_image.dart` (shell — import), app_router.dart (transition already OK) |
| 9 | playlist_detail_page.dart | `desktop_kit.dart` (DkHoverIcon/DkArt — import; avoid editing DkScaffold if multi-consumer) |
