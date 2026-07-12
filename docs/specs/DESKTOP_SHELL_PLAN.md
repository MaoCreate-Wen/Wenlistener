# DESKTOP_SHELL_PLAN — Windows desktop shell + window management

> Goal: run the **same `lib/`** on Windows desktop, reusing every existing service /
> state / model / animation / widget / theme untouched. The ONLY new surface is a
> **responsive shell**: a left Sidebar + docked mini-player + custom frameless title bar
> on desktop; the existing bottom-nav shell on mobile stays byte-for-byte identical.
>
> **NON-NEGOTIABLE**: no change may alter the Android code path's behavior. Every
> desktop branch is *additive* and *guarded* (`_DesktopLayout.isActive(context)` →
> ultimately `!kIsWeb && Platform.isWindows/Linux/macOS && width ≥ breakpoint`). On
> Android the guard is `false` at compile-reachable runtime, so the mobile `Column`
> shell renders exactly as today.

---

## 0. What exists today (investigation summary)

- **Routing** (`lib/router/app_router.dart`): a single `StatefulShellRoute.indexedStack`
  with **3 branches** — Home (`/`), Search (`/search` + child `/search/results`),
  Library (`/library`) — hosted inside `HomeShell`. All other screens are pushed on
  `rootNavigatorKey` **over** the shell: `/player`, `/lyrics`(→redirects to `/player`,
  lyrics is now an *integrated panel inside* PlayerPage, not a separate page),
  `/login*`, `/profile`, `/accounts`, `/settings`, `/playlist/:id`, `/local/:id`.
- **Shell** (`lib/shell/home_shell.dart`): `Scaffold` → `Column[ Expanded(navigationShell),
  MiniPlayer, AppBottomNav ]`. `AppBottomNav` (`lib/shell/bottom_nav_bar.dart`) owns the
  3 tab destinations as a `static const List<AppNavTab> tabs` (Home/Search/Library) and
  drives `navigationShell.goBranch(index)`. `MiniPlayer` (`lib/shell/mini_player.dart`) is
  always-mounted, uses `context.select` (per-tick-safe), carries the shared `album_art`
  Hero, taps → `context.push(Routes.player)`.
- **Pages** each build their own `AppScaffold` (`lib/widgets/app_scaffold.dart`, OLED-black
  + optional frozen dynamic `washGradient`). Home uses `CustomScrollView`. They read top
  inset via `MediaQuery.padding.top` (0 on desktop — fine). **Pages are already
  platform-neutral Flutter** and need NO change.
- **Player/Lyrics** (`lib/pages/player/player_page.dart`) already reuse the AMLL engine
  (`BouncingSlider`/`MediaButton`/`LyricsView`/`NeonFlowBackground`) — all pure Flutter,
  desktop-capable as-is. No change.
- **Theme** (`lib/theme/*`): tokens exist for everything the mockup needs — `AppColors`
  (bg/glass/onSurface tiers/accentPlay/seed), `AppDimens` (spacing 4→48, radii sm10/md16/
  lg22/xl28/pill, blur nav18/panel24/playerBg30, glass/album shadows), `AppTypography`
  (`AlimamaDongFangDaKai` display face). Reuse verbatim.
- **`windows/` runner already scaffolded** (`windows/runner/*.cpp`, default size 1280×720
  in `main.cpp`). No `window_manager` / `Platform.isWindows` / `defaultTargetPlatform`
  anywhere in `lib/` yet — this is a clean addition.
- **Design source of truth**: `wenlistener-pc/design/mockup.html` (§① shell = 1024×660
  window: 38px titlebar with 3 window buttons top-right, 230px glass sidebar
  Wen**Listener** logo + Home/Search/Library/Settings nav + bottom account card, main
  discovery area, 72px docked glass mini-player with progress hairline on its top edge,
  art48 + meta + centered prev/play/next + right cluster like/queue/volume) +
  `DESIGN_SPEC.md` §2 (frameless drag region, min 1024×680, sidebar 240px collapsible→72,
  mini-player controls, z-scale) + `docs/specs/DESIGN_SYSTEM.md`.

---

## 1. Strategy — one decision that keeps mobile frozen

**Do NOT touch `StatefulShellRoute.indexedStack` or its 3 branches.** The router,
branches, `goBranch` indices, and all pushed routes stay exactly as they are. The desktop
adaptation is achieved at **two seams only**:

1. **`HomeShell` becomes responsive** via `LayoutBuilder`: when the desktop layout is
   active it renders `DesktopShell(navigationShell)`, otherwise it renders the **current**
   mobile `Column[ Expanded, MiniPlayer, AppBottomNav ]` unchanged. Same
   `StatefulNavigationShell` instance feeds either layout, so tab state / mini-player
   persistence / Hero all keep working identically.

2. **`MaterialApp.router.builder`** wraps *every* route (shell AND pushed full-screen
   routes) in a persistent **`DesktopWindowFrame`** — a top custom title bar (drag region
   + min/max/close) with the routed page below it. On mobile the frame is a pass-through
   (`return child`). This guarantees the window controls stay reachable even while
   `/player`, `/settings`, `/login` etc. cover the shell (those push on the root navigator,
   so a title bar *inside* HomeShell would be hidden by them — hence the app-level frame).

Result: Sidebar + docked mini-player live inside `DesktopShell`; the always-present title
bar lives one level up in the frame. Both are dead code on Android.

**Settings/Accounts stay pushed routes** (as today). The desktop Sidebar's Settings item
just `context.push(Routes.settings)` — it covers the shell like any full-screen route (the
title bar remains from the app-level frame). This avoids adding a 4th shell branch, which
would perturb the shared `indexedStack`/`goBranch` index space that mobile relies on.
(Future optional enhancement noted in §7.)

---

## 2. New dependency

`pubspec.yaml` → add under "Routing + shell" (or a new "Desktop" group):

```yaml
  # Frameless window (Windows/desktop): hidden OS title bar, min size, drag region,
  # min/max/close controls. Desktop-only; unused on Android at runtime.
  window_manager: ^0.4.3
```

`window_manager` auto-registers via the generated plugin registrant on desktop and is a
**no-op import on Android** (its method channel is simply never called behind the
`Platform.isWindows` guards). No native edits to `android/` needed. `windows/runner`
already exists; `flutter pub get` + `flutter build windows` wires the plugin in.

No other new packages. (Caveat, out of scope for the shell but flagged for the desktop
milestone: `audio_service` + `just_audio` need a desktop audio backend — `just_audio` on
Windows currently needs `just_audio_media_kit`/`just_audio_windows`, and `audio_service`
has no Windows notification. The **shell/window work compiles and runs regardless**;
audio-on-Windows is a separate follow-up and must NOT block this shell milestone. Guard any
audio-init that throws on desktop the same way `AudioService.init` is already try/caught in
`main.dart`.)

---

## 3. Files to ADD

All new files live under `lib/shell/desktop/` (kept separate so the mobile shell files are
visibly untouched) + one tiny layout util.

### 3.1 `lib/util/desktop_layout.dart` (new)
The single breakpoint/guard helper. No dependency on `dart:io` at import cost — uses
`defaultTargetPlatform` + `kIsWeb`.

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

class DesktopLayout {
  DesktopLayout._();

  /// Width below which even a desktop window falls back to the mobile shell.
  static const double breakpoint = 900;

  /// True on a desktop OS (never web, never Android/iOS).
  static bool get isDesktopPlatform =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
       defaultTargetPlatform == TargetPlatform.linux ||
       defaultTargetPlatform == TargetPlatform.macOS);

  /// Render the desktop shell? Desktop OS AND wide enough. On Android this is
  /// ALWAYS false → the existing mobile shell is untouched.
  static bool active(double width) => isDesktopPlatform && width >= breakpoint;
}
```

### 3.2 `lib/shell/desktop/desktop_window_frame.dart` (new)
App-level wrapper used by `MaterialApp.router.builder`. Persistent custom title bar above
every route on desktop; pass-through elsewhere.

- On non-desktop: `return child`.
- On desktop: `Column[ WindowTitleBar(), Expanded(child) ]` over `AppColors.bg`.
- Height budget: title bar 38px (matches mockup) — the routed page (including the
  full-screen `/player` grabber) sits below, so window controls never get covered.

### 3.3 `lib/shell/desktop/window_title_bar.dart` (new)
The custom frameless chrome. 38px tall, glass/transparent over the wash.

- **Left**: small `WenListener` wordmark (muted, `AppTypography` label; `AlimamaDongFangDaKai`
  for "Wen"/"Listener" per mockup logo, optional). 
- **Drag region**: wrap the whole bar (except the buttons) in `window_manager`'s
  `DragToMoveArea` so dragging moves the OS window. Double-click → toggle maximize.
- **Right**: three `_WindowButton`s — minimize (`windowManager.minimize()`), maximize/restore
  (`windowManager.isMaximized() ? unmaximize() : maximize()`), close
  (`windowManager.close()`). Lucide-style stroke glyphs sized 12–14, hover fill
  `AppColors.surfaceGlass`; close hover = red `Color(0xFFE81123)` tint (Windows convention).
  Each has `MouseRegion(cursor: click)` + `Semantics(button:true, label:)`.
- Listens to `WindowListener` (`onWindowMaximize/Unmaximize`) to swap the max/restore glyph.
- Entire file compiles on Android but is never instantiated there.

### 3.4 `lib/shell/desktop/desktop_shell.dart` (new)
The wide-layout body. Takes the same `StatefulNavigationShell` HomeShell already has.

```
Column(
  Expanded(
    Row(
      DesktopSidebar(navigationShell),          // fixed 240 (72 collapsed)
      Expanded( navigationShell ),              // the routed branch page
    ),
  ),
  DesktopMiniPlayer(),                          // docked, full width, 72px
)
```

- Background: `AppColors.bg` (each inner page already paints its own `AppScaffold` wash).
- `navigationShell` is passed straight through (identical instance as mobile) so branch
  state / IndexedStack preservation is unchanged.

### 3.5 `lib/shell/desktop/desktop_sidebar.dart` (new)
Left rail, glass (`GlassContainer` blur `AppDimens.blurNav`), right hairline border.

- **Reuses `AppBottomNav.tabs`** (the existing `static const` Home/Search/Library
  destinations) — no duplicate icon/label list. Maps each to `navigationShell.goBranch(i)`;
  active item = pill tinted by `PlayerProvider.dynamicAccent` (same `context.select` as the
  bottom nav) — visually the mockup's `.nav.active`.
- Appends a **Settings** item → `context.push(Routes.settings)` and a bottom **account card**
  (`.acct` in mockup) → `context.push(Routes.accounts)` / `Routes.profile`. These read
  `AuthProvider`/`SettingsProvider` the same way the existing pages do.
- Logo header (`Wen`+accent`Listener`, display face) at top.
- Optional collapse toggle → 72px icon-only (DESIGN_SPEC "collapsible to 72px"). MVP can
  ship fixed-240 and add collapse later; state held locally (`StatefulWidget`) or in
  `SettingsProvider` if persistence is wanted.
- `currentIndex` comes from `navigationShell.currentIndex` (same source as `AppBottomNav`).

### 3.6 `lib/shell/desktop/desktop_mini_player.dart` (new)
Docked bottom bar matching mockup §① `.mini`. **Reuses all `PlayerProvider` field-selects
from `MiniPlayer`** (song/accent/isPlaying/isBuffering — copy the same per-tick-safe
`context.select` pattern; do NOT `watch` the whole provider — see the marquee/blur stutter
gotcha in CLAUDE.md).

- Layout: `art48` (shared `album_art` Hero, tap → `context.push(Routes.player)`) + title/
  artist meta + centered `prev / PlayPauseButton / next` (reuse `PlayPauseButton`,
  `player.togglePlay/next/previous`) + right cluster: like (`player.toggleLike`, filled when
  `player.isLiked`), open-lyrics/queue, and a **volume slider** (desktop-only affordance;
  `player`/`AudioService` volume — add a thin `setVolume` passthrough only if not already
  present, else omit for MVP).
- Progress hairline on the **top edge** (accent, width = position/duration) — mockup
  `.mini::before`. Drive from `player` position select (a dedicated thin `LinearProgress`
  bound to a `context.select` of the fraction, so only the 2px bar repaints).
- Glass: `GlassContainer` blur `AppDimens.blurNav`, radius 0 (full-width dock) or top-only.

---

## 4. Files to CHANGE (all additive / guarded)

### 4.1 `pubspec.yaml`
Add `window_manager: ^0.4.3` (see §2). No version bump needed for the plan; bump on the
implementation commit per the release convention.

### 4.2 `lib/main.dart`  — guarded window_manager init
Insert **after** `WidgetsFlutterBinding.ensureInitialized()` and **before** `runApp`
(placement anywhere before runApp is fine; do it early). Fully guarded so Android is
untouched:

```dart
import 'dart:io' show Platform;                 // add (guarded uses only)
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:window_manager/window_manager.dart';
// ...
if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
  await windowManager.ensureInitialized();
  const WindowOptions opts = WindowOptions(
    size: Size(1280, 800),
    minimumSize: Size(1024, 680),               // DESIGN_SPEC min
    center: true,
    backgroundColor: Colors.transparent,
    titleBarStyle: TitleBarStyle.hidden,        // frameless — our custom bar
    title: 'WenListener',
  );
  await windowManager.waitUntilReadyToShow(opts, () async {
    await windowManager.show();
    await windowManager.focus();
  });
}
```

Everything else in `main.dart` (audio isolate, cookie/dio/crypto/api graph, providers)
stays as-is. The existing `AudioService.init` try/catch already tolerates a desktop backend
that isn't wired yet.

### 4.3 `lib/app.dart` — wrap MaterialApp.router with the desktop frame
Only the `MaterialApp.router(...)` gets a `builder`:

```dart
MaterialApp.router(
  title: 'WenListener',
  debugShowCheckedModeBanner: false,
  theme: AppTheme.dark(),
  routerConfig: AppRouter.router,
  builder: (context, child) => DesktopWindowFrame(child: child ?? const SizedBox()),
)
```

`DesktopWindowFrame` returns `child` verbatim on mobile → **zero** behavioral change to the
Android tree. Import added: `shell/desktop/desktop_window_frame.dart`.

### 4.4 `lib/shell/home_shell.dart` — responsive branch
Wrap the current body in a `LayoutBuilder`; keep the existing mobile `Column` in the `else`
path **verbatim**:

```dart
return Scaffold(
  backgroundColor: AppColors.bg,
  body: LayoutBuilder(
    builder: (context, constraints) {
      if (DesktopLayout.active(constraints.maxWidth)) {
        return DesktopShell(navigationShell: navigationShell);
      }
      // --- existing mobile shell, unchanged ---
      return Column(children: [
        Expanded(child: navigationShell),
        const MiniPlayer(),
        AppBottomNav(
          currentIndex: navigationShell.currentIndex,
          onTap: (i) => navigationShell.goBranch(
            i, initialLocation: i == navigationShell.currentIndex),
        ),
      ]);
    },
  ),
);
```

Imports added: `../util/desktop_layout.dart`, `desktop/desktop_shell.dart`. `MiniPlayer`,
`AppBottomNav`, `AppColors` imports stay.

### 4.5 `lib/shell/bottom_nav_bar.dart` — **no change**
`AppBottomNav.tabs` is already a `static const List<AppNavTab>`; the desktop Sidebar imports
and reuses it as-is. Left untouched.

### 4.6 (Optional, not required) `windows/runner/main.cpp`
Default size can be aligned to `Size(1024, 680)` / a saved size, but `window_manager`'s
`WindowOptions` already enforces size + minimum at Flutter-init, so this native edit is
**optional cosmetic** and can be skipped.

---

## 5. Responsive contract (how mobile stays frozen)

| Aspect | Mobile (Android) | Desktop (Windows) |
|---|---|---|
| Guard value | `DesktopLayout.active(w)` = **false** always | true when width ≥ 900 |
| Shell body | existing `Column`+`MiniPlayer`+`AppBottomNav` (verbatim) | `DesktopShell` (Sidebar + main + docked mini) |
| Title bar | none (OS status bar) | app-level `DesktopWindowFrame` (drag + min/max/close) |
| Nav destinations | `AppBottomNav.tabs` (3) | same `AppBottomNav.tabs` (3) + Settings/Account pushed |
| Route table | unchanged | unchanged (same `StatefulShellRoute`) |
| Player/Lyrics | pushed `/player` (AMLL) | same pushed `/player`, under persistent title bar |
| `navigationShell` | same instance | same instance |

The Android path never constructs any `desktop/` widget: the `LayoutBuilder` else-branch and
the frame pass-through short-circuit before touching them. `window_manager` calls are behind
`Platform.isWindows`. Nothing in the mobile flow is edited except the additive
`LayoutBuilder` wrap and the additive `MaterialApp.builder`.

---

## 6. Reuse map (no re-implementation)

- **State**: `PlayerProvider` (song/accent/isPlaying/isBuffering/isLiked/washGradient/
  position), `SettingsProvider`, `AuthProvider`, `MusicApiRouter`, `LibraryProvider` — all
  consumed by the desktop shell via the **same `context.select`/`read`** patterns the mobile
  widgets use. No provider added, no signature changed.
- **Widgets**: `GlassContainer`, `ArtworkImage` (Hero `album_art`), `PlayPauseButton`,
  `AppScaffold`, `SongTile`, `SkeletonBox` — reused directly.
- **Theme**: `AppColors`/`AppDimens`/`AppTypography` tokens only; no hardcoded colors.
- **Pages/Animations**: Home/Search/Library/Settings/Player(+integrated Lyrics)/AMLL engine
  unchanged.

---

## 7. Build / verify + future

- `& "C:\flutter\bin\flutter.bat" pub get`
- `& "C:\flutter\bin\flutter.bat" analyze` (target 0 issues)
- `& "C:\flutter\bin\flutter.bat" build apk --debug` → **must still pass** (Android
  unbroken — the acceptance gate for this change).
- `& "C:\flutter\bin\flutter.bat" build windows` / `run -d windows` → desktop shell.
- Manual: window drags/min/max/close; min size clamps at 1024×680; sidebar tab switch keeps
  branch state; mini-player docks + opens `/player`; resize below 900 gracefully falls back
  to the bottom-nav shell (proves the responsive seam).

**Future (out of this milestone, noted):** (a) promote Settings to a 4th shell branch on
desktop only if in-content settings is wanted (needs care to not shift mobile `goBranch`
indices); (b) sidebar collapse persistence in `SettingsProvider`; (c) desktop audio backend
(`just_audio_windows`/`media_kit` + guard `AudioService.init`); (d) remember window
size/position via `window_manager`'s `setBounds` + a store.

---

## 8. File checklist

**Add**
- `lib/util/desktop_layout.dart`
- `lib/shell/desktop/desktop_window_frame.dart`
- `lib/shell/desktop/window_title_bar.dart`
- `lib/shell/desktop/desktop_shell.dart`
- `lib/shell/desktop/desktop_sidebar.dart`
- `lib/shell/desktop/desktop_mini_player.dart`

**Change (additive/guarded)**
- `pubspec.yaml` (+`window_manager`)
- `lib/main.dart` (guarded `window_manager` init)
- `lib/app.dart` (`MaterialApp.router.builder` → `DesktopWindowFrame`)
- `lib/shell/home_shell.dart` (`LayoutBuilder` → desktop vs. existing mobile `Column`)

**Unchanged (reused)**
- `lib/router/app_router.dart`, `lib/router/routes.dart`, `lib/shell/bottom_nav_bar.dart`,
  `lib/shell/mini_player.dart`, all `lib/pages/**`, all `lib/theme/**`, all `lib/state/**`,
  all `lib/widgets/**`, all `lib/animation/**`.
</content>
</invoke>
