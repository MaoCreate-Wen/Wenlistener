# Packaging — Windows MSI

WenListener Desktop ships as a real MSI (WiX v3) with a standard installer UI,
including install-directory selection.

## Tooling (what actually worked on this machine)

Attempted in order:

1. **Existing install** — `where.exe candle/light/wix`: nothing found.
2. **`dotnet tool install --global wix`** — FAILED. The `wix` dotnet tool
   (v7.0.0) targets `net8.0`; this machine only has the **.NET 5.0.402 SDK**
   (a .NET 8 *runtime* is present, but `dotnet tool install` restores against
   the SDK, so NU1202 "incompatible with net5.0").
3. **`winget install WixToolset.WixToolset`** — winget is not installed.
4. **WiX v3.14.1 binaries zip** — WORKED. Downloaded
   `wix314-binaries.zip` from the official GitHub release
   (`wixtoolset/wix3`, tag `wix3141rtm`) and extracted to:

   ```
   installer/tools/wix314/        (candle.exe, light.exe, heat.exe, WixUIExtension.dll, ...)
   installer/tools/wix314-binaries.zip
   ```

   Consequently the authoring is **WiX v3 syntax** (`Product.wxs`).

## Files

| File | Purpose |
|---|---|
| `installer/Product.wxs` | Main WiX v3 authoring (product, UI, shortcuts, upgrade logic) |
| `installer/License.rtf` | License text shown by the WixUI license dialog |
| `installer/build_msi.ps1` | One-command build script (harvest → candle → light) |
| `installer/tools/wix314/` | WiX 3.14.1 toolset binaries |
| `installer/obj/` | Generated: `AppFiles.wxs` harvest + `.wixobj` (safe to delete) |
| `dist/WenListener-<version>-x64.msi` | Output |

## Installer features

- **Payload**: `heat.exe dir` re-harvests **everything** under
  `build/windows/x64/runner/Release/` on every build (exe,
  `flutter_windows.dll`, all plugin DLLs, the whole `data/` tree). New DLLs
  or assets can never be silently dropped. Component GUIDs are
  path-stable (`-ag`).
- **Install dir**: defaults to `[ProgramFiles64]\WenListener`; the UI is
  `WixUI_InstallDir` with `WIXUI_INSTALLDIR=INSTALLFOLDER`, so the user can
  pick the directory during setup. Per-machine (`InstallScope=perMachine`),
  x64.
- **Shortcuts**: Start-menu shortcut (always) + desktop shortcut
  (default on; skip with `msiexec /i ... DESKTOP_SHORTCUT=0`). Both use the
  app icon.
- **Upgrades**: stable `UpgradeCode` `8510F5AD-E1EF-4049-B503-3C0FDA5589D7`
  + `MajorUpgrade` — installing a newer version replaces the older one;
  downgrades are blocked with a clear message. **Never change the
  UpgradeCode.**
- **Icon**: `windows/runner/resources/app_icon.ico` on the shortcuts and the
  Add/Remove Programs (ARP) entry (`ARPPRODUCTICON`).
- **Identity**: Product name `WenListener`, manufacturer `WenListener`,
  version parsed from `pubspec.yaml` (`1.0.0+1` → `1.0.0`; MSI versions
  ignore the `+build` part).

## Build

```powershell
# 1) Build the release payload (the MSI script does NOT do this):
C:\flutter\bin\flutter.bat build windows --release

# 2) Build the MSI:
powershell -ExecutionPolicy Bypass -File installer\build_msi.ps1
# -> dist\WenListener-<version>-x64.msi
```

The script fails with a clear error if `Release/wenlistener_desktop.exe` or
`Release/data/flutter_assets` is missing, or if the WiX binaries are absent.

To bump the installer version, bump `version:` in `pubspec.yaml` — the script
picks it up automatically.

## Validation performed

- `installer\build_msi.ps1` produced `dist\WenListener-1.0.0-x64.msi`
  (~16 MB). Only harmless ICE60 warnings (unversioned files without a
  Language column — typical for Flutter payloads).
- Admin-less administrative extract:
  `msiexec /a dist\WenListener-1.0.0-x64.msi /qn TARGETDIR=<temp>` →
  exit 0; extracted `WenListener\` contains `wenlistener_desktop.exe`,
  `flutter_windows.dll`, all plugin DLLs and the full `data\` tree —
  **38/38 files identical in count to the Release directory**.
- No real system install was executed.
