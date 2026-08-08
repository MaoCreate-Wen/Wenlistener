# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概述

`wenlistener_desktop` 是 **WenListener 的独立 PC（Windows）客户端**：Flutter 桌面应用，**复用移动端 `wenlistener` 的整条逻辑层**（`services/` `models/` `state/` `animation/` `theme/` 几乎逐文件同源），**UI 为桌面重写**（自绘无边框窗口 + 侧边栏 + 桌面播放/歌词/歌单页，非移动端 shell）。多音源后端与移动端一致：`MusicSource` 枚举 `migu, netease, kugou, kugougn, kuwo, local`（`migu` 槽实际装 **QQ音乐**；`kugougn` = **酷狗概念版**独立源，与 `kugou` 分开），默认**网易云**，设置页 `/settings` 可切 **QQ音乐/酷狗/酷狗概念版/酷我**，统一 `MusicApi` 接口经 `MusicApiRouter` **按 `Song.source` 逐曲多路复用**（队列/歌单可混装不同音源）。带 Apple-Music 风格（AMLL）逐字歌词动画。

> **共享逻辑层的权威文档在移动端仓库**：`C:\Users\Fhw20\Desktop\Code\wenlistener\CLAUDE.md`。那份 40KB 文档详述了 `services/`（netease/qq/kugou/kuwo API、加密、`AudioService`/`ResolvingAudioSource`、cookie store、共同歌单、FFT）、`state/` 四大 Provider、`animation/`（AMLL 歌词引擎、mesh gradient）、各音源的登录与匿名 API 细节、以及路由的逐曲分发模型 —— **改动共享层前先读它**。本文件只记录**桌面端的差异**。

## 常用命令（关键：SDK 与移动端不同）

**本项目用 `C:\flutter_next\bin\flutter.bat`（Flutter 3.44.6 / Dart 3.12.2），不是移动端的 `C:\flutter`（3.38.9）。** 原因：3.38.9 的 `flutter_windows.dll` 用 ~15.6ms 定时器伪 vsync，把 180Hz 屏上的 release 帧率钉死在 61–68fps；3.44.6 修复了 Windows 帧调度（实测 166–194fps）。详见 `docs/FRAMERATE_WINDOWS.md`。**`C:\flutter` 与 `C:\flutter_next` 完全隔离，勿动 `C:\flutter`（移动端仍用它）。**

```powershell
& "C:\flutter_next\bin\flutter.bat" pub get
& "C:\flutter_next\bin\flutter.bat" analyze
& "C:\flutter_next\bin\flutter.bat" test                                        # 全套
& "C:\flutter_next\bin\flutter.bat" test test/line_edge_fade_parity_test.dart   # 跑单个测试文件
& "C:\flutter_next\bin\flutter.bat" run -d windows                              # 桌面调试运行
& "C:\flutter_next\bin\flutter.bat" build windows --release                     # release 产物 build\windows\x64\runner\Release\
```

- **仅 `windows/` 一个平台目录**（无 android/ios/macos/linux）—— 桌面独占。系统 PATH 上的 `dart` 是过时的 2.14.4，勿用。
- **切到 3.44.6 需要的最小代码适配（已做，勿回退）**：3.44 的 widgets 库新增 `RepeatMode`，与 `services/audio_service.dart` 自有的同名枚举冲突，故 `lib/state/player_provider.dart:1` 与 `lib/widgets/transport_controls.dart:1` 的 material import 加了 `hide RepeatMode`（零行为变化）。

### 打包 Windows MSI（发布约定）

**每次发布收尾两步：① 递增 `pubspec.yaml` 的 `version:` ② 重出 MSI。** MSI `MajorUpgrade` 靠版本号识别升级 —— **不递增版本就装不上（1603）/ 装成旧的白屏**（[[wenlistener-desktop-release-build]]）。

```powershell
& "C:\flutter_next\bin\flutter.bat" build windows --release      # ① 先出 release 载荷（MSI 脚本不代跑）
powershell -ExecutionPolicy Bypass -File installer\build_msi.ps1  # ② 打 MSI → dist\WenListener-<version>-x64.msi
```

- 工具链：**WiX v3.14.1 binaries**（`installer/tools/wix314/`，v3 语法 `installer/Product.wxs`）—— 本机装不了 `wix` dotnet 工具（只有 .NET 5 SDK）也没 winget，故走 zip 版；详见 `docs/PACKAGING.md`。
- `heat.exe` 每次重新 harvest 整个 `Release/` 目录（exe + `flutter_windows.dll` + 全部插件 DLL + `data/` 树），新增 DLL/资源不会被漏掉。
- **`UpgradeCode` = `8510F5AD-E1EF-4049-B503-3C0FDA5589D7`，永不修改**（改了升级链就断）。VC 运行时已随包分发。

## 版本控制（重要陷阱，与移动端同）

**Git 仓库根是 `C:\Users\Fhw20`（整个用户主目录），不是本项目** —— 本目录下没有独立 `.git`。后果：
- **绝不要** 在本项目跑 `git add .` / `-A` / `commit -a`，会把主目录成千上万无关文件一并暂存。只 `git add` 明确的项目内路径。
- 主目录仓库 `main` 分支零提交，`git log`/`git blame`/diff-baseline 都用不了，别靠它做代码考古。
- **桌面代码提交推到 `pc` 分支**（worktree 流程），推送需 socks5 代理 `socks5h://127.0.0.1:10808`（xray；直连会中途 reset）。见 [[wenlistener-git-push-proxy]] [[wenlistener-commit-push-every-change]]。

## 架构（桌面差异）

共享的分层铁律不变（`pages/ → state/ → services/ → models/`，页面永不 import `services/`，全走 Provider）。桌面端的关键不同：

- **服务图在 `main.dart` 构建一次，比移动端少两块 Android-only 逻辑**（`docs/DESKTOP_WIRING.md §1`）：
  - **无 `AudioService.init(WenAudioHandler)`** —— `audio_service` 包没有 Windows 平台实现（`init` 抛 `MissingPluginException`）。播放纯前台，由 `just_audio` + **`just_audio_windows`（Media Foundation 后端）** 直接出声，没有系统媒体通知/锁屏镜像。`WenAudioHandler`/`audio_handler.dart` 在桌面不参与。
    - **MF `positionStream` 停发护栏（`services/audio_service.dart`，桌面特有，[[wenlistener-desktop-mf-positionstream-stall]]）**：MF 后端切歌几首后会**冷跳停发 `positionStream`**，表现为进度条/歌词冻结、点一下歌词才恢复。`audio_service.dart` 用 `currentIndexStream` 监听 + 位置心跳做**确认停顿后**补一个零位移 indexed `seek` 重新唤醒流（`_push`/220ms 去抖，避免稳态双推；restore 路径自守卫跳过）。这段逻辑注释很密，改切歌/`seekToNext`/自动续播前务必先读它，别退回“每次切歌都重载 source”那种会重新引入 MF desync 的写法。
  - **无 `Permission.notification`** —— 桌面无通知概念。
  - **`FftService` 照常构造但在桌面惰性**：原生 `Visualizer` `EventChannel` 是 Android-only，`start()` 自守卫到哨兵 `< 0`，歌词背景退回合成 pulse（与移动端拒权时同行为）。保留它是为了 `PlayerProvider(lowFreqVolume:)` 和歌词页逻辑与移动端逐字节一致地编译/运行。
- **桌面窗口自绘（`Platform.isWindows` 守卫）**：`main.dart` 在 `runApp` 前用 `window_manager` 起无边框窗口（初始 1180×760、最小 1024×680、居中、`titleBarStyle: hidden`、隐藏系统按钮）。标题栏/最小化最大化关闭由 `shell/desktop_window_frame.dart` + `shell/window_buttons.dart` + `shell/window_drag_region.dart` 自绘。
- **系统托盘 + 关闭行为 + 轻量模式**：`shell/tray_controller.dart`（`tray_manager`）活在 widget 树之外（与服务图同级），故托盘播放控制和 ✕ 行为在**轻量模式**（UI 树被 dispose）下仍工作。关闭行为（退出/最小化到托盘）是 `SettingsProvider.closeBehavior` 持久化设置。
- **桌面 shell UI（`lib/shell/`，全新）**：`app_shell.dart`（侧边栏布局，非移动端底部 tab）、`sidebar.dart` + `sidebar_nav_item.dart` + `sidebar_account_card.dart`、`desktop_top_bar.dart`、`account_menu_button.dart`、`nav_history.dart`（前进/后退历史）、`fullscreen_controller.dart`、`mini_player.dart`（桌面版，Hero `album_art` 源）。
- **路由集中在 `lib/router/app_router.dart`（`go_router`）**，路径常量在 `router/routes.dart`。`ShellRoute` 把 `home / search / library` 包进 `app_shell`（侧边栏常驻）；`player`、`lyrics`、`playlist/:id`、`local/:id`（共同歌单）、`settings`、`accounts`、登录页是 shell 之外的顶层路由。加页面/改导航先看这里。
- **`WenListenerApp` 构造参 15 个**（`cookieStore/dio/crypto/neteaseApi/qqApi(+qqCookies)/kugouApi/kugougnApi/kuwoApi(+kuwoCookies)/musicApi/audio/palette/fft/settings`）；改构造签名要 `main.dart` + `app.dart` 两处同步。多音源接线（QQ 装 `migu` 槽、`kugougn` 酷狗概念版为独立 API+账号 store（`services/kugougn_api.dart` / `kugougn_account_store.dart` / `models/kugougn_account.dart`）、`KugouAuthProvider` 须 `lazy:false` 开机装回活跃账号等）与移动端一致，见移动端 CLAUDE.md。
- **内存优化（桌面重点，[[wenlistener-desktop-flutter-app]]）**：`main.dart` 把 `imageCache.maximumSizeBytes` 压到 **64MB**（默认 100MB），配合 `ResizeImage`（封面解码 ≤640² 分桶）+ 列表 `SliverFixedExtentList`，把歌词页工作集从 400–500MB 压到 ~193MB release —— 元凶是 2000–3000px 网易封面的 25–36MB RGBA 全分辨率解码常驻缓存。`services/resource_cache.dart` 是桌面新增的资源缓存。

## 权威文档（改动前先读）

- **共享层**：移动端 `..\wenlistener\CLAUDE.md` + 本仓库 `docs/specs/`（`MASTER_PLAN.md` §3 冻结的跨层接口契约、`NETEASE_API_SPEC.md`、`AMLL_ANIMATION_SPEC.md`、`DESIGN_SYSTEM.md`、桌面端的 `DESKTOP_AUDIO_PLAN.md` / `DESKTOP_SHELL_PLAN.md`）。
- **桌面专属**：
  - `docs/FRAMERATE_WINDOWS.md` —— 帧率墙根因与 3.44.6 切换结论（**动构建/SDK 前必读**）。
  - `docs/PACKAGING.md` —— MSI（WiX v3）打包全流程与 UpgradeCode。
  - `docs/DESKTOP_WIRING.md` —— 服务图上桌面 vs 移动的差异（哪些 Android-only 被守卫掉）。
  - `docs/DESKTOP_UI_PLAN.md` / `docs/DESKTOP_UX_PLAN.md` / `docs/DESKTOP_CHANGE_MAP.md` —— 桌面 UI/UX 设计与播放/歌词/歌单页改造的逐文件行号目标（`DESKTOP_CHANGE_MAP.md` 里的构建命令写的是旧 `C:\flutter`，实际以 `FRAMERATE_WINDOWS.md` 的 `C:\flutter_next` 为准）。
  - `docs/AMLL_FIDELITY_SPEC_2.md` / `docs/AMLL_REPLICA_PLAN.md` / `docs/IMPELLER_WINDOWS.md` —— AMLL 复刻保真度与 Impeller 排查（历史）。
  - AMLL 全量源在本地 `..\applemusic-like-lyrics-full-refractor\packages\react-full` 与 `..\amll-player-main`，改播放/歌词动画前对照。

## 约定

- 与移动端同：标准 Dart 命名、`debugPrint` 而非 `print`、颜色/文字走 `AppColors`/`Theme` 不硬编码、长列表用 `builder`/sliver、图片用带缓存的 `ArtworkImage`；跨层接口签名以 `docs/specs/MASTER_PLAN.md §3` 为准视为冻结。
- **桌面交互**：hover 态（scrubber/音量条 hover 膨胀、`hover_scale.dart`、`DkHoverIcon`）、右键菜单（`widgets/context_menu.dart` / `song_menu.dart`）、键盘/窗口手势是桌面特有，移动端无对应；改这些不影响共享逻辑层。
- 网易封面 URL 必须过 `models/image_url.dart` 的 `httpsImageUrl()` 且带 `kNeteaseImageHeaders`（同移动端，否则只剩占位图）。
