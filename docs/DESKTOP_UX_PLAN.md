# Desktop UX Redesign — PC Interaction Model

Goal: make `wenlistener_desktop` navigate like a mature PC player (网易云/QQ音乐 PC,
Spotify/Apple Music desktop) instead of a phone. Three pillars:

1. A persistent **top bar** over the content area: ◀ ▶ browser-style history,
   global search, and (right side) window controls + an **account avatar dropdown**.
2. **Accounts / Settings / Login become dialogs** (✕ + Esc), never dead-end routes.
3. **Track lists** behave like a PC player: double-click plays, right-click menu,
   hover reveals play + actions, single-click only selects.

Reuse every existing provider + design token (`AppColors`/`AppDimens`/`AppTypography`,
`DkGlass`, `WenMenuAction`, `showWenContextMenu`). Do **not** touch the mobile app.
The docked bottom `MiniPlayer` stays exactly as is.

---

## Current structure (as read)

- `lib/router/app_router.dart` — `StatefulShellRoute.indexedStack` with **4 branches**
  (首页/搜索/音乐库/**设置**) inside `AppShell`; plus root-navigator full-screen routes:
  `/player`, `/lyrics`, `/accounts`, `/playlist/:id`, `/local/:id`, `/login/:source`.
- `lib/shell/desktop_window_frame.dart` — `MaterialApp.router` `builder:` wraps every
  route with `WindowTitleBar` (wordmark + min/max/close) at the very top.
- `lib/shell/app_shell.dart` — `Column[ Expanded(Row[ Sidebar, Expanded(navigationShell) ]), MiniPlayer ]`.
- `lib/shell/sidebar.dart` — 4 nav items (last = 设置) + `SidebarAccountCard`.
- `lib/shell/sidebar_account_card.dart` — `onTap: context.go(Routes.accounts)` (no back).
- `lib/pages/accounts/accounts_page.dart` — 4 `_SourceCard`s in a `DkScaffold`.
- `lib/pages/settings/settings_page.dart` — a shell branch (tab), body = sectioned `ListView`.
- `lib/pages/settings/account_section.dart` — inline per-source login/logout panels;
  calls `dkGoAccounts` / `dkGoLogin`.
- `lib/pages/login/login_page.dart` — `/login/:source`; per-source private widgets
  `_NeteaseLogin/_QqLogin/_KugouLogin/_KuwoLogin`; `_LoginSuccess` auto-pops.
- `lib/pages/playlist/desktop_kit.dart` — the `Dk*` UI kit incl. `DkTrackRow`,
  `DkTrackTable`, `dkShowSongMenu`, `dkGoLogin`, `dkGoAccounts`, `dkGoLogin` tokens.
- `lib/widgets/track_row.dart` + `track_table.dart` — the shell agent's `TrackRow`/
  `TrackTable` built on `WenMenuAction` + `showWenContextMenu` (context_menu.dart).
- `lib/state/player_provider.dart` — `playSong/playQueue/jumpTo/next/previous`;
  **no** insert-next / append-to-queue methods yet; `queue` getter exists.

Two track-row implementations already do double-click + right-click + hover
(`TrackRow._HoverRow` and `DkTrackRow`). This work standardizes their behavior and
enriches the menu; it does not rebuild them from scratch.

---

## 1) TOP BAR

### 1.1 History mechanism — `NavHistory` (explicit browser stack)

go_router has no forward stack and `canPop` does not span branch (`goBranch`) switches,
so we keep our **own** two-stack history driven by the router's location.

New file `lib/shell/nav_history.dart`:

```
class NavHistory extends ChangeNotifier {
  NavHistory(this._router) {
    _current = _loc();                       // initial location
    _router.routeInformationProvider.addListener(_onLocationChanged);
  }
  final GoRouter _router;
  final List<String> _back = <String>[];
  final List<String> _forward = <String>[];
  String _current = '/';
  bool _navigating = false;                  // set while WE drive go()

  bool get canBack => _back.isNotEmpty;
  bool get canForward => _forward.isNotEmpty;

  String _loc() => _router.routeInformationProvider.value.uri.toString();

  void _onLocationChanged() {
    final String next = _loc();
    if (next == _current) return;
    if (_navigating) { _navigating = false; _current = next; notifyListeners(); return; }
    _back.add(_current);                     // genuine forward navigation
    _forward.clear();
    _current = next;
    notifyListeners();
  }

  void back() {
    if (_back.isEmpty) return;
    _forward.add(_current);
    final String prev = _back.removeLast();
    _navigating = true;
    _router.go(prev);
  }

  void forward() {
    if (_forward.isEmpty) return;
    _back.add(_current);
    final String next = _forward.removeLast();
    _navigating = true;
    _router.go(next);
  }

  @override
  void dispose() {
    _router.routeInformationProvider.removeListener(_onLocationChanged);
    super.dispose();
  }
}
```

Provided once in `lib/app.dart` (top of `MultiProvider`):
`ChangeNotifierProvider<NavHistory>(create: (_) => NavHistory(AppRouter.router))`.
Using `router.go(location)` (not `pop/push`) makes ◀ ▶ uniform across branch switches,
pushed sheets (`/player`, `/lyrics`), and detail routes. Dialogs use the raw
`Navigator` (see §2) so they never enter this history — correct.

### 1.2 The bar widget — `DesktopTopBar`

New file `lib/shell/desktop_top_bar.dart`, `class DesktopTopBar extends StatelessWidget`.
Height `AppDimens.titleBarHeight` (bump to ~48 for the search pill; add
`AppDimens.topBarHeight = 48`). Layout (left→right):

- **◀ ▶** two `IconButton`s. `context.watch<NavHistory>()`; ◀ `onPressed: nav.canBack ? nav.back : null`, ▶ `nav.canForward ? nav.forward : null`. Disabled = faint.
- **Global search box**: a glass pill `TextField` (reuse styling from
  `SearchPage`'s pill). On submit → `submitTopBarSearch(context, kw)` (§1.4).
- `Expanded(child: DragToMoveArea(child: SizedBox.expand()))` — the empty middle is
  the window drag region (frameless).
- **`AccountMenuButton`** (§1.3) — avatar + dropdown.
- **`WindowButtons`** — min / maximize / close (§1.5).

### 1.3 Account avatar dropdown — `AccountMenuButton`

New file `lib/shell/account_menu_button.dart`. A circular avatar (reuse the avatar
block + `_viewFor` summary logic from `SidebarAccountCard`; extract that into a shared
`accountViewFor(context, source)` in `sidebar_account_card.dart` or duplicate — small)
wrapped in a `PopupMenuButton<_AcctMenu>`. Watches the four auth providers +
`SettingsProvider.source` (already all in the tree). Items:

- logged out → **登录** → `showLoginDialog(context, source)`
- logged in  → **退出登录** → the active source's `logout()` (netease/qq/kugou/kuwo)
- always → **账号管理** → `showAccountsDialog(context)`
- always → **设置** → `showSettingsDialog(context)`

No route jump — every item is a dialog or a provider call.

### 1.4 Search seam

`void submitTopBarSearch(BuildContext, String kw)` (put in `desktop_top_bar.dart`):
```
final q = kw.trim(); if (q.isEmpty) return;
context.read<SearchProvider>().search(q);   // existing logic
context.go(Routes.search);                   // switch to the 搜索 branch
```
`SearchPage` already watches `SearchProvider`, so results render. Minor follow-up: have
`SearchPage` sync its own field from `SearchProvider.query` on `didChangeDependencies`
(currently only `initState`) so the in-page pill matches a top-bar-initiated search.

### 1.5 Window controls + mounting

- Extract the `_WindowButton` cluster out of `window_title_bar.dart` into
  `lib/shell/window_buttons.dart` → `class WindowButtons extends StatelessWidget`
  (min / maximize-restore / close, close hovers red). Keep the exact behavior.
- `DesktopWindowFrame` becomes a **pass-through** (`ColoredBox(child: child)` on
  Windows) — it no longer renders a title bar. `window_title_bar.dart` can be deleted
  after `WindowButtons` is extracted.
- **Mount point** — `AppShell` restructures so the top bar sits above content for all
  branches while the sidebar stays full-height on the left:

```
Column[
  Expanded(
    Row[
      Sidebar( ... ),                         // full height, brand wrapped in DragToMoveArea
      Expanded(
        Column[
          DesktopTopBar(),                    // ← new, above content only
          Expanded(navigationShell),
        ],
      ),
    ],
  ),
  MiniPlayer(),                               // unchanged
]
```

- Because the global frame no longer owns window buttons, the two remaining
  full-screen pushed surfaces add their own top-right cluster: drop a
  `Positioned(top: 4, right: 4, child: WindowButtons())` into `PlayerPage` and
  `LyricsPage` (they already have a grabber/close). One line each.
- Wrap the sidebar brand (`_brand()`) in `DragToMoveArea` so the top-left corner
  stays draggable.

---

## 2) DIALOGS (Accounts / Settings / Login)

Shared shell — new file `lib/widgets/dialog_shell.dart`:

```
Future<T?> showWenDialog<T>(BuildContext context, {
  required String title, required Widget child, double width = 720,
});
```
Implementation: `showDialog(barrierDismissible: true, builder: ...)` returning a
centered `DkGlass` panel (max `width`, max-height ~80% viewport, scrollable body) with a
header row `title …… ✕` (`DkHoverIcon(Icons.close_rounded, onTap: Navigator.pop)`), and
**Esc-to-close** via `CallbackShortcuts({SingleActivator(LogicalKeyboardKey.escape): () => Navigator.of(ctx).maybePop()})`
wrapping the panel in a `Focus(autofocus: true, ...)`.

Helpers (each reuses the existing page body verbatim, just re-hosted):

- `lib/pages/accounts/accounts_dialog.dart` → `Future<void> showAccountsDialog(BuildContext)`
  = `showWenDialog(title: '账号管理', child: AccountsBody())`. Refactor
  `accounts_page.dart`: extract the 4-card `Column` into a public `AccountsBody` widget;
  `AccountsPage`/`DkScaffold` no longer needed once the route is removed.
- `lib/pages/settings/settings_dialog.dart` → `Future<void> showSettingsDialog(BuildContext)`
  = `showWenDialog(title: '设置', child: SettingsBody())`. Refactor `settings_page.dart`:
  extract the sectioned `ListView` children into a public `SettingsBody`.
- `lib/pages/login/login_dialog.dart` → `Future<void> showLoginDialog(BuildContext, MusicSource)`
  = `showWenDialog(title: '登录 · <label>', child: LoginPanel(source: token))`. Refactor
  `login_page.dart`: make the per-source body public as `class LoginPanel extends
  StatelessWidget { final String source; }` (moves current `_body()` switch into it, and
  its `_Netease/_Qq/_Kugou/_Kuwo` children become public or move with it). `_LoginSuccess`
  keeps `context.pop()` — inside a dialog that pops the dialog route (correct); it already
  guards `context.canPop()`.

### Routes to REMOVE

In `app_router.dart`: delete the **设置 branch** (branch 3), the `/accounts` route, and
the `/login/:source` route. Keep `/player`, `/lyrics`, `/playlist/:id`, `/local/:id`.
Branch count 4 → 3.

In `routes.dart`: remove `settings`, `accounts`, `login`, `loginPath`, `loginPath`
builders, `nSettings`, `nAccounts`, `nLogin`, and `navSettings`; keep home/search/library
(+ their nav indices 0/1/2), player, lyrics, playlist, localPlaylist.

### Call sites to REPOINT

- `desktop_kit.dart`: `dkGoAccounts(ctx)` → `showAccountsDialog(ctx)`;
  `dkGoLogin(ctx, s)` → `showLoginDialog(ctx, s)` (drop `Routes.loginPath`; keep
  `dkSourceLoginToken` for the label/source mapping). These two helpers keep their names
  so `account_section.dart` (lines 105, 147) and `accounts_page.dart` (line 74) need **no**
  change — the seam is preserved.
- `sidebar_account_card.dart` line 107: `onTap: () => showAccountsDialog(context)`.
- `library_page.dart` line 104: `onAction: () => showSettingsDialog(context)`.
- `sidebar.dart`: drop the 设置 nav item (4 → 3 items) — settings now lives only in the
  avatar dropdown.

---

## 3) TRACK INTERACTION

Both row widgets already implement double-click + right-click + hover-reveal. Two fixes:
**(a)** single-click must only *select*, not play; **(b)** the context menu must offer the
full PC set: **播放 / 下一首播放 / 添加到播放队列 / 添加到歌单… / 查看专辑 / 查看歌手**.

### 3.1 Centralized menu builder — `songMenuActions`

New file `lib/widgets/song_menu.dart` (or a new function in `desktop_kit.dart` to keep the
`Dk` neighbors):

```
List<WenMenuAction> songMenuActions(
  BuildContext context, Song song, {
  VoidCallback? onRemove,          // “从歌单移除” when non-null
}) => <WenMenuAction>[
  WenMenuAction(label: '播放', icon: Icons.play_arrow_rounded,
      onSelected: () => context.read<PlayerProvider>().playSong(song)),
  WenMenuAction(label: '下一首播放', icon: Icons.queue_play_next_rounded,
      onSelected: () => context.read<PlayerProvider>().playNext(song)),
  WenMenuAction(label: '添加到播放队列', icon: Icons.playlist_add_rounded,
      onSelected: () => context.read<PlayerProvider>().enqueue(song)),
  WenMenuAction(label: '添加到歌单…', icon: Icons.library_add_rounded,
      onSelected: () => dkAddToLocalPlaylist(context, song)),
  WenMenuAction(label: '查看专辑', icon: Icons.album_outlined,
      onSelected: () => _viewAlbum(context, song)),
  WenMenuAction(label: '查看歌手', icon: Icons.person_outline_rounded,
      onSelected: () => _viewArtist(context, song)),
  if (onRemove != null)
    WenMenuAction(label: '从歌单移除', icon: Icons.delete_outline_rounded,
        danger: true, onSelected: onRemove),
];
```

- **Queue methods to ADD** to `PlayerProvider` (small, wrap `AudioService`): `playNext(Song)`
  inserts after `currentIndex` and rebuilds via `audio.setQueue`; `enqueue(Song)` appends.
  If `queue` is empty both fall back to `playSong(song)`. Mirror the existing
  `playQueue` bookkeeping (`_queue`, `_currentIndex`).
- **查看专辑/查看歌手**: no album/artist detail routes exist. Interim seam
  `_viewAlbum/_viewArtist` = `context.read<SearchProvider>().search(name); context.go(Routes.search)`
  (album name / first artist name). Note in the doc as a follow-up for real detail routes.

`dkShowSongMenu` in `desktop_kit.dart` is refactored to render `songMenuActions(...)`
through `showWenContextMenu` so backend playlist/library pages and the search page share
one menu. Keep `dkAddToLocalPlaylist` / `_dkAddToUserPlaylist` as the “添加到歌单” impl.

### 3.2 Single-click = select

- `lib/widgets/track_row.dart` `_HoverRow`: remove `onTap: widget.onPlay`; add
  `bool selected` + `VoidCallback? onSelect` to `TrackRow`; `onTap: widget.onSelect`.
  Keep `onDoubleTap: onPlay`, `onSecondaryTapUp: showWenContextMenu`. Selected row tints
  with `AppColors.rowSelected` (distinct from `isActive` now-playing accent).
- `lib/widgets/track_table.dart`: hold `int? _selectedIndex` (StatefulWidget), pass
  `selected`/`onSelect`, and wire `menuActionsFor` default → `songMenuActions(context, s)`.
- `lib/pages/playlist/desktop_kit.dart` `DkTrackRow`: already double-tap only (no
  single-tap play) — add the same `selected`/`onSelect` + `AppColors.rowSelected` and
  route its `onMenu` through `songMenuActions`. Its `onSecondaryTapDown` + hover play
  glyph stay.

Result: every list (home rows, search table, playlist detail, library, local playlist)
inherits identical PC behavior through `TrackRow`/`DkTrackRow` + `songMenuActions`.

---

## Seam names (both implementer agents use these exact identifiers)

| Seam | Location | Purpose |
|---|---|---|
| `class NavHistory extends ChangeNotifier` | `lib/shell/nav_history.dart` | ◀ ▶ history: `canBack/canForward/back()/forward()` |
| `class DesktopTopBar` | `lib/shell/desktop_top_bar.dart` | the top bar; mounts in `AppShell` above content |
| `void submitTopBarSearch(BuildContext, String)` | `lib/shell/desktop_top_bar.dart` | search → `SearchProvider.search` + `go(Routes.search)` |
| `class AccountMenuButton` | `lib/shell/account_menu_button.dart` | avatar + 登录/退出/账号管理/设置 dropdown |
| `class WindowButtons` | `lib/shell/window_buttons.dart` | min/max/close, reused by top bar + player/lyrics |
| `Future<T?> showWenDialog<T>(context, {title, child, width})` | `lib/widgets/dialog_shell.dart` | glass dialog shell with ✕ + Esc |
| `Future<void> showAccountsDialog(BuildContext)` | `lib/pages/accounts/accounts_dialog.dart` | Accounts as dialog |
| `class AccountsBody` | `lib/pages/accounts/accounts_page.dart` | extracted card column |
| `Future<void> showSettingsDialog(BuildContext)` | `lib/pages/settings/settings_dialog.dart` | Settings as dialog |
| `class SettingsBody` | `lib/pages/settings/settings_page.dart` | extracted section list |
| `Future<void> showLoginDialog(BuildContext, MusicSource)` | `lib/pages/login/login_dialog.dart` | per-source login as dialog |
| `class LoginPanel` | `lib/pages/login/login_page.dart` | public per-source login body |
| `List<WenMenuAction> songMenuActions(context, Song, {onRemove})` | `lib/widgets/song_menu.dart` | the PC context menu |
| `PlayerProvider.playNext(Song)` / `enqueue(Song)` | `lib/state/player_provider.dart` | 下一首播放 / 添加到播放队列 |
| `dkGoAccounts` / `dkGoLogin` (kept names, redirected) | `lib/pages/playlist/desktop_kit.dart` | now call the dialogs |

## File list

**New:** `lib/shell/nav_history.dart`, `lib/shell/desktop_top_bar.dart`,
`lib/shell/account_menu_button.dart`, `lib/shell/window_buttons.dart`,
`lib/widgets/dialog_shell.dart`, `lib/widgets/song_menu.dart`,
`lib/pages/accounts/accounts_dialog.dart`, `lib/pages/settings/settings_dialog.dart`,
`lib/pages/login/login_dialog.dart`.

**Modified:** `lib/router/app_router.dart`, `lib/router/routes.dart`,
`lib/shell/app_shell.dart`, `lib/shell/desktop_window_frame.dart`,
`lib/shell/window_title_bar.dart` (extract `WindowButtons`, then remove),
`lib/shell/sidebar.dart`, `lib/shell/sidebar_account_card.dart`, `lib/app.dart`,
`lib/pages/accounts/accounts_page.dart`, `lib/pages/settings/settings_page.dart`,
`lib/pages/settings/account_section.dart`, `lib/pages/login/login_page.dart`,
`lib/pages/library/library_page.dart`, `lib/pages/player/player_page.dart`,
`lib/pages/lyrics/lyrics_page.dart`, `lib/pages/search/search_page.dart`,
`lib/pages/playlist/desktop_kit.dart`, `lib/widgets/track_row.dart`,
`lib/widgets/track_table.dart`, `lib/state/player_provider.dart`.

## Build / verify

`C:\flutter\bin\flutter.bat analyze` then `C:\flutter\bin\flutter.bat build windows`
(desktop target). Manual: ◀ ▶ across tabs + playlist detail; avatar → each dropdown item
opens a dismissible dialog (✕ + Esc); double-click plays, single-click selects, right-click
menu shows all six actions.
