# DESKTOP_AUDIO_PLAN.md — Windows 桌面音频 + 原生代码适配方案

> 目标：让 **同一份 `lib/`** 既跑 Android（现状不变）又跑 Windows 桌面。
> 铁律：**绝不破坏 Android 构建**。所有桌面改动必须是**追加式**或用
> `Platform.isAndroid` / `Platform.isWindows` / `defaultTargetPlatform` **守卫**，
> 从不删改现有 Android 代码路径的行为。
>
> Flutter：`C:\flutter\bin\flutter.bat`（3.38.9 / Dart 3.10.8）。
> `windows/` 运行器脚手架**已存在**（标准 Flutter 工程，`windows/runner/*` +
> `windows/flutter/generated_plugins.cmake` 目前只挂了 `permission_handler_windows`）。

---

## 0. 结论速览（TL;DR）

| 关注点 | 桌面上的结论 | 处理 |
|---|---|---|
| `just_audio` 播放 | 需要联邦插件 **`just_audio_windows: ^0.2.3`** | 加 dep（见 §1）|
| `ResolvingAudioSource`（自定义 `StreamAudioSource` + Range） | **可用**，无需改动 | just_audio 在 **Dart 侧**起本地 loopback HTTP 代理服务器伺服 `StreamAudioSource`，只把 `http://127.0.0.1:<port>/…` 交给原生 WMF 播放器——纯 `dart:io`、跨平台。见 §3 |
| `file://` 本地音乐 | 可用 | 同样走 `ResolvingAudioSource._fetchFile`（`StreamAudioSource`）经上面的代理，非直接交原生 |
| `audio_service`（后台 isolate / 通知栏） | **无 Windows 实现** | 守卫 `AudioService.init` 到 Android；桌面降级为纯前台播放。SMTC 作为后续（`smtc_windows`，非 MVP）|
| FFT 律动（原生 `Visualizer` + `wenlistener/fft` EventChannel） | Windows **无此 channel** | `FftService.start()` 守卫到 Android；桌面直接置哨兵 `-1.0` → 合成 pulse |
| `permission_handler`（POST_NOTIFICATIONS / RECORD_AUDIO / microphone） | Android 专属语义 | 所有 `Permission.*.request()` 守卫到 Android |
| `dio` / `cookie_jar` / `dio_cookie_manager` / `pointycastle` / `path_provider` / `file_picker` / `provider` / `go_router` / `cached_network_image` / `qr_flutter` | **Windows 全部可用** | 无需改动（纯 Dart 或已带 `*_windows` 实现）|
| 桌面窗口（尺寸/标题栏） | 需要 **`window_manager: ^0.5.2`** | 加 dep + `main.dart` 桌面守卫初始化（见 §5）|

**版本兼容性已实证**：`flutter pub add just_audio_windows window_manager --dry-run` 对当前
锁定图（`just_audio 0.9.46` → `just_audio_platform_interface 4.6.0`）**干净解析**为
`just_audio_windows 0.2.3` + `window_manager 0.5.2`（连带 `screen_retriever 0.2.2`、
`json_annotation 4.12.0` 传递依赖），**无 version-solving 失败、无任何现有依赖被降级**。

---

## 1. `pubspec.yaml` 追加（精确）

在 audio 段追加 `just_audio_windows`（**只作为 Windows 联邦实现**，Android 不受影响：
联邦插件按平台各挑各的实现，Android 仍用内建的 `just_audio` ExoPlayer 后端）：

```yaml
  just_audio: ^0.9.46
  audio_service: ^0.18.19

  # Windows 桌面：just_audio 的联邦实现（Windows Media Foundation 后端）。
  # 仅在 -d windows 构建时参与；Android 构建完全忽略它。与 just_audio ^0.9.46
  # 对应的 platform-interface 4.6.0 已实测干净解析（just_audio_windows 0.2.3）。
  just_audio_windows: ^0.2.3
```

在 State 段之后（或文件末尾 dependencies 内）追加窗口管理：

```yaml
  # 桌面窗口尺寸 / 最小尺寸 / 居中 / 标题（仅桌面用，Android 忽略）。
  window_manager: ^0.5.2
```

> 保持锁文件其余部分不动。跑一次 `& "C:\flutter\bin\flutter.bat" pub get`。
> `permission_handler_windows 0.2.1` 与 `path_provider_windows 2.3.0` 已在传递图内、
> 无需显式添加。

**不要**添加 `audio_service_windows`（不存在稳定实现）；桌面走前台降级（§4）。

---

## 2. `main.dart` 的守卫（精确改动）

新增导入（文件顶部）：

```dart
import 'dart:io' show Platform;
```

> 说明：`Platform.isAndroid` / `isWindows` 来自 `dart:io`，桌面与 Android 均可用；
> **不要**在此文件顺手引 `dart:io` 的其它 API 去替换现有逻辑，只用这两个布尔。

### 2.1 通知权限请求 → 守卫到 Android

```dart
  // 原：
  //   try { await Permission.notification.request(); } catch (_) {}
  // 改为（Android 专属；桌面无 POST_NOTIFICATIONS 概念，permission_handler_windows
  // 不实现 notification，避免无谓抛错/返回不确定态）：
  if (Platform.isAndroid) {
    try {
      await Permission.notification.request();
    } catch (_) {}
  }
```

### 2.2 `AudioService.init`（后台音频 isolate + 通知栏）→ 守卫到 Android

`audio_service` 在 Windows **没有平台实现**，`AudioService.init` 会抛
`MissingPluginException`。现状虽已 `try/catch` 兜住降级为前台，但**显式守卫**更干净、
也避免在桌面创建/丢弃一个用不上的 `WenAudioHandler`：

```dart
  final AudioPlayer player = AudioPlayer();
  if (Platform.isAndroid) {
    try {
      await asvc.AudioService.init(
        builder: () => WenAudioHandler(player),
        config: const asvc.AudioServiceConfig(
          androidNotificationChannelId: 'com.wenlistener.audio',
          androidNotificationChannelName: 'WenListener',
          androidNotificationOngoing: true,
          androidStopForegroundOnPause: true,
          androidNotificationIcon: 'drawable/ic_stat_music',
        ),
      );
    } catch (e, st) {
      debugPrint('AudioService.init failed (continuing foreground-only): $e\n$st');
    }
  }
```

> 效果：桌面上同一个 `player`（just_audio + just_audio_windows 后端）照常拥有队列/
> 播放/进度/循环/随机——**全部由 app 的 `AudioService`（`services/audio_service.dart`）
> 驱动，本就不依赖 `audio_service` 后台 handler**（handler 只是被动镜像通知栏）。桌面
> 少的只有系统媒体通知；播放功能完整。

### 2.3 `SystemChrome.setSystemUIOverlayStyle` → 无害，可保留

状态栏样式在桌面是 no-op，不会抛错，**保留即可**（无需守卫）。若想更干净可
`if (Platform.isAndroid)` 包一层，非必需。

### 2.4 其余服务图（cookie/dio/crypto/各 API/router/audio/palette/settings）→ **零改动**

全部纯 Dart / 带 Windows 实现，逐字复用。`FftService fft = FftService(player: player)`
构造本身无副作用（不触碰 channel，channel 只在 `start()` 里用）——保留原样。

---

## 3. `ResolvingAudioSource` 在 Windows 上为什么直接可用（无需改动）

关键：`ResolvingAudioSource extends StreamAudioSource`。just_audio 处理
`StreamAudioSource` 的方式是——在 **Dart 侧**（`package:just_audio` 内部）起一个
绑定到 `127.0.0.1` 的 `HttpServer`（`_ProxyHttpServer`，纯 `dart:io`），把每个
`StreamAudioSource` 注册成一个 loopback URL，然后只把 `http://127.0.0.1:<port>/…`
这个 URL 交给原生播放器。`just_audio_windows`（WMF `MediaPlayer`）拿到的永远是一个
普通 HTTP(S) URL，它对 http/localhost/file 播放都支持。

因此：

- `request(start,end)` 的 Range 代理、`_fetch`（HTTP 后端）、`_fetchFile`（`file://`
  本地音乐）**全在 Dart 里执行**，与平台无关 → **Windows 照跑**。
- `ConcatenatingAudioSource`（整队列）在 just_audio_windows 上按**顺序播放**可用
  （无缝 gapless 未必支持，对本 app 非关键）；通知栏 prev/next 在桌面本就不存在，
  但**队列内 prev/next / `seekToNext/Previous` / `LoopMode` / shuffle / `seek(index:)`**
  都是 just_audio 层能力，桌面可用。
- `MediaItem` tag 依旧挂在每个 source 上——桌面没有通知栏消费它，无害。

> 唯一潜在差异：极老版本 just_audio_windows 曾对 `StreamAudioSource` 支持不稳。
> 0.2.3 走 WMF + loopback URL 正常。**验证方式见 §7**（真机式：`-d windows` 跑一
> 首网易免费曲，确认能出声 + 拖动 seek）。

---

## 4. `audio_service` / `WenAudioHandler` 在桌面的降级

- 桌面**不** `AudioService.init`（§2.2 守卫），因此 `WenAudioHandler` 不被构造、
  系统媒体通知不存在——**这是可接受的 MVP 降级**，播放本体不受影响。
- `WenAudioHandler` 文件本身**不改**（Android 仍用）。
- **后续（非 MVP）**：Windows 的系统媒体传输控件（SMTC，任务栏媒体浮层 / 键盘媒体键）
  可用 `smtc_windows` 单独实现——新建一个 `WindowsMediaControls`（`if (Platform.isWindows)`
  在 `main.dart` 里镜像同一个 `player` 的 `playerStateStream/sequenceStream` 到 SMTC，
  回调打回 `player.play/pause/seekToNext/Previous`），与 `WenAudioHandler` 平行、互不影响。
  **本 MVP 不做**，仅在此登记。

---

## 5. `window_manager` 桌面窗口初始化（`main.dart`，桌面守卫）

在 `WidgetsFlutterBinding.ensureInitialized()` 之后、服务图构建之前追加。用
`Platform.isWindows`（或 `Platform.isWindows || Platform.isLinux || Platform.isMacOS`）
守卫，Android 完全跳过：

```dart
import 'package:window_manager/window_manager.dart';
// ...
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    const WindowOptions opts = WindowOptions(
      size: Size(1180, 760),          // 对齐 mockup.html 的 sidebar+mini-player 布局
      minimumSize: Size(920, 600),
      center: true,
      title: 'WenListener',
      titleBarStyle: TitleBarStyle.normal,
    );
    await windowManager.waitUntilReadyToShow(opts, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }
  // ...（其余同现状，含 §2 的守卫）
}
```

> 注：`window_manager` 的 API 在非桌面平台调用会抛，故**必须**守卫。Android 分支
> 一行都不进这里。

---

## 6. `fft_service.dart` 的守卫（精确改动）

Windows 上不存在 `EventChannel('wenlistener/fft')`（那是 `MainActivity.kt` 挂的），
且 `Permission.microphone` 在桌面语义不同。现有代码**理论上**已能优雅退化（桌面
`_player.androidAudioSessionId` 为 null、`androidAudioSessionIdStream` 不发 `>0` 值 →
`_attach` 永不以真实 id 触发 → 哨兵 `-1.0` 留存 → 合成 pulse），但依赖两点隐式行为
不稳妥：`Permission.microphone.request()` 在 Windows 可能抛/返回不确定，且
`_player == null` 分支不适用。**显式守卫**最稳：

新增导入：

```dart
import 'dart:io' show Platform;
```

在 `start()` 开头（`if (_started) return; _started = true;` 之后）追加**平台短路**：

```dart
  Future<void> start() async {
    if (_started) return;
    _started = true;

    // 桌面（Windows 等）没有原生 Visualizer 与 wenlistener/fft EventChannel，
    // 也无 Android 式麦克风权限语义 —— 直接置哨兵，让 NeonFlowBackground 用合成
    // pulse。绝不触碰 EventChannel / permission_handler（在桌面会 MissingPlugin/抛）。
    if (!Platform.isAndroid) {
      lowFreqVolume.value = -1.0;
      return;
    }

    try {
      final PermissionStatus status = await Permission.microphone.request();
      // ...（以下 Android 原逻辑完全不变）
```

> 结果：桌面 `/lyrics` 背景照常呼吸（合成 pulse），mesh 渐变、旋转、zoom 全在
> Dart 层（`neon_flow_background.dart` + `mesh_gradient/`，纯 `Canvas.drawVertices`），
> 无原生依赖 → Windows 完整可用。`stop()`/`dispose()` 无需改（桌面下 `_sub` 恒 null，
> `cancel()` 是 no-op）。

`MainActivity.kt` **不改**（仅 Android 编译）。

---

## 7. 各依赖的 Windows 可用性核对

| 包 | 锁定版本 | Windows | 备注 |
|---|---|---|---|
| `just_audio` | 0.9.46 | ✅（经 `just_audio_windows 0.2.3`） | WMF 后端；`StreamAudioSource` 经 Dart loopback 代理 |
| `just_audio_windows` | 0.2.3（新增） | ✅ | dry-run 干净解析 |
| `audio_service` | 0.18.19 | ⚠️ 无实现 | 守卫跳过（§2.2/§4）|
| `permission_handler` (+`_windows` 0.2.1) | 11.4.0 | ⚠️ 部分 | 请求调用守卫到 Android（§2.1/§6）|
| `path_provider` (+`_windows` 2.3.0) | 2.1.5 | ✅ | app-support 目录（playback/settings/local-playlist JSON、cookie jar）在 Windows 正常 |
| `dio` | 5.9.2 | ✅ | 纯 Dart HTTP |
| `cookie_jar` / `dio_cookie_manager` | 4.x / 3.x | ✅ | 纯 Dart |
| `pointycastle` | 3.9.1 | ✅ | 纯 Dart（weapi/eapi/QQ 加密全跨平台）|
| `file_picker` | 8.3.7 | ✅ | Windows 原生文件/文件夹选择器（本地音乐导入）|
| `provider` / `go_router` | — | ✅ | 纯 Dart |
| `cached_network_image` / `qr_flutter` / `palette_generator` / `flutter_svg_icons` | — | ✅ | Flutter 通用渲染 |
| `window_manager` | 0.5.2（新增） | ✅ | 桌面窗口 |

---

## 8. `windows/` 原生工程

- 脚手架**已存在**（`windows/runner/*`、`windows/CMakeLists.txt`、
  `windows/flutter/generated_plugins.cmake`）——**无需手改**。
- `flutter pub get` 后，`generated_plugins.cmake` 会自动加入
  `just_audio_windows`、`permission_handler_windows`、`window_manager`、
  `screen_retriever_windows` 等（该文件是 **generated, do not edit**）。
- 无需写任何 C++ / MethodChannel：桌面**没有** Android 那套原生 FFT，
  FFT 走合成 pulse（§6）。`MainActivity.kt` 只属 Android。

---

## 9. 验证步骤（不破坏 Android 前提下）

```powershell
# 1) Android 回归（守卫必须零影响）
& "C:\flutter\bin\flutter.bat" analyze                 # 期望 0 issues
& "C:\flutter\bin\flutter.bat" pub get
& "C:\flutter\bin\flutter.bat" build apk --debug       # Android 仍出包

# 2) 桌面
& "C:\flutter\bin\flutter.bat" config --enable-windows-desktop
& "C:\flutter\bin\flutter.bat" devices                 # 应见 Windows (desktop)
& "C:\flutter\bin\flutter.bat" run -d windows          # 起桌面窗口
```

桌面冒烟清单：
- 窗口按 §5 尺寸打开、可缩放。
- 搜网易免费曲 → 播放**出声**（验证 `ResolvingAudioSource` 经 WMF 代理链路）。
- 拖动进度条 seek 生效（验证 Range 代理）。
- prev/next、循环、随机、点队列项跳转生效（just_audio 层）。
- 打开 `/lyrics`：mesh 背景旋转/呼吸（合成 pulse，无原生 Visualizer 也不冻结）。
- 导入本地文件（`file_picker`）→ 播放 `file://`（验证 `_fetchFile`）。
- 无系统媒体通知（预期降级），无 crash、无 `MissingPluginException` 冒泡到 UI。

---

## 10. 风险与回退

- **风险 A**：`just_audio_windows 0.2.3` 对某些 `StreamAudioSource` 边界（如某些
  302/Range 组合）行为与 ExoPlayer 略有差异。缓解：`ResolvingAudioSource` 已有
  self-heal（过期/非 2xx 重解析一次）；若个别源在桌面失败，`AudioService._onPlayerError`
  会跳下一首（与 Android 同）。真正验证靠 §9 冒烟。
- **风险 B**：桌面无通知栏 → 无锁屏/媒体键控制。回退/后续：`smtc_windows`（§4），非 MVP。
- **回退**：所有改动都是**追加 dep + 平台守卫**。移除 `just_audio_windows`/`window_manager`
  两个 dep、撤掉 `if (Platform.isWindows)`/`if (!Platform.isAndroid)` 守卫即完全回到现状；
  Android 代码路径一字未动。

---

## 附：改动文件清单

| 文件 | 改动 | Android 影响 |
|---|---|---|
| `pubspec.yaml` | +`just_audio_windows: ^0.2.3`、+`window_manager: ^0.5.2` | 无（联邦按平台挑实现）|
| `lib/main.dart` | +`dart:io` `Platform`；`Permission.notification` 与 `AudioService.init` 守卫 Android；+`window_manager` 桌面初始化 | 逻辑等价（守卫内即原 Android 代码）|
| `lib/services/fft_service.dart` | +`dart:io` `Platform`；`start()` 非 Android 短路置哨兵 | 无（Android 走原路径）|
| `windows/**` | 无需手改（`generated_plugins.cmake` 由 pub get 生成）| — |
| `android/**`、`MainActivity.kt`、`audio_handler.dart`、`audio_service.dart`、`resolving_audio_source.dart` | **零改动** | 无 |
</content>
</invoke>
