# Windows 帧率（frame pacing）问题与结论

日期：2026-07-12 ｜ 实验：Flutter stable 3.44.6 vs 3.38.9 ｜ 结论：**已解决，本项目切换到 C:\flutter_next（3.44.6）**

## 背景（既定事实，勿重查）

- 症状：在 2560x1440 @ 180Hz 主屏上，release 版桌面端被钉死在 **61–68 fps**，GPU/CPU 几乎空闲。
- 根因在引擎层：3.38.9 的 `flutter_windows.dll` 用 **~15.6ms 定时器伪 vsync** 驱动帧调度（timer-based vsync），与显示器实际刷新率无关，Dart 侧无法绕过。
- 旁证：Impeller 开关、窗口模式、DWM 设置均无效（见 `IMPELLER_WINDOWS.md` 时期的排查）。

## 实验：Flutter stable 3.44.6

- SDK 装在 **`C:\flutter_next`**（官方 zip，SHA-256 校验通过
  `2e803e240c981733ec6b543752415196ff1b16e03f93474bddd59c777ac07a56`）。
- 版本：`Flutter 3.44.6 · stable · Dart 3.12.2 · Engine d3a3293399556a85388faf8c6f0723a7a5597aa8`。
- `flutter build windows --release` 构建成功（VS2019 + Win10 SDK 19041 工具链不变）。

### 实测（RTSS 帧率覆盖层，播放器打开、逐字歌词滚动中）

| 场景 | 采样 (fps) | 截图（scratchpad `sdk344_*.png`） |
|---|---|---|
| 首页（1400x900 窗口） | 194 | `sdk344_home.png` |
| 歌词页・窗口化 | 173 / 171 / 171 / 170 / 170 / 166（约 20s） | `sdk344_player1..6.png` |
| 歌词页・最大化 (2560x1440) | 180 / 179 / 194 / 180 | `sdk344_max1..4.png` |

**判定：166–194 fps 持续，≈ 钉在 180Hz 刷新率上；61–68 的墙消失。3.44.6 修复了 Windows 帧调度。**

（对照：同一场景在 3.38.9 下稳定 61–68 fps。）

## 本项目从此使用的 SDK

- **本项目（wenlistener_desktop）的一切构建改用 `C:\flutter_next\bin\flutter.bat`（3.44.6）。**
- **移动端项目（wenlistener）保持 `C:\flutter\bin\flutter.bat`（3.38.9），两者互不影响；不要动 `C:\flutter`。**
- MSI 打包不变：`installer\build_msi.ps1` → `dist\WenListener-1.0.0-x64.msi`（已用 3.44.6 产物重打，2026-07-12，16.9 MB）。

## 升级所需的最小代码适配（仅 2 行，非行为性）

3.44.6 的 widgets 库新增了 `RepeatMode`（`repeating_animation_builder.dart`），与本项目
`services/audio_service.dart` 自有的 `RepeatMode` 枚举重名，导致 2 个文件出现 ambiguous-import 编译错误。
修复为在这 2 个文件的 material 导入上加 `hide`（零行为变化）：

- `lib/state/player_provider.dart`:1 → `import 'package:flutter/material.dart' hide RepeatMode;`
- `lib/widgets/transport_controls.dart`:1 → `import 'package:flutter/material.dart' hide RepeatMode;`

`pubspec.yaml` **无需改动**（`sdk: '>=3.4.0 <4.0.0'` 兼容 Dart 3.12.2）；`pubspec.lock` 由 pub get
更新了 5 个 SDK 钉死的包（characters/matcher/material_color_utilities/meta/test_api）。

`flutter analyze`：0 error。原有 4 条提示仍在（kuwo_api.dart x2、music_api_router.dart、qq_api.dart，
其中 unnecessary_cast 被新分析器升级为 warning）；另有 7 条新 warning 来自 3.44 分析器把 just_audio 的
`StreamAudioSource/StreamAudioResponse` 标记为 experimental（`resolving_audio_source.dart`，纯分析器提示，无需改码）。

## 环境备忘

- `C:\flutter_next` 与 `C:\flutter` 完全隔离，保留两套。
- 官方 zip 保留在 scratchpad（`flutter_windows_3.44.6-stable.zip`，1,899,929,646 字节）。
- 若需回滚：还原上述 2 行 `hide`（备份在 scratchpad `lib_backup_338/`），用 `C:\flutter\bin\flutter.bat`
  重新 pub get + build 即可回到 3.38.9（帧率墙会回来）。
