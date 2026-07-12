# Impeller on Windows — investigated, not shippable on this toolchain (2026-07-12)

## Why we looked
The lyrics page is fill-rate bound on Windows: Flutter Windows rasterizes with
**Skia over ANGLE (D3D)**, which is slow at offscreen layers (`saveLayer`),
blurs, and per-frame shaders — the exact primitives the AMLL karaoke + mesh
background lean on. Android is smooth because it renders with **Impeller**.
So we probed whether Impeller can be enabled for our Windows build
(Flutter 3.38.9 at `C:\flutter`).

## What we found (empirical, both probes on this machine)

**Debug: WORKS.** The Windows embedder reads engine switches from the
environment in non-release builds. With

```
FLUTTER_ENGINE_SWITCHES=1
FLUTTER_ENGINE_SWITCH_1=enable-impeller
```

the debug exe boots and logs:

```
[IMPORTANT:flutter/shell/platform/embedder/embedder_surface_gl_impeller.cc(99)]
Using the Impeller rendering backend (OpenGL).
```

and the app runs (VM service up, no crash in a 10s soak).

**Release: CANNOT be enabled.** The same env vars on the release exe produce
no Impeller log — the release engine DLL compiles out env-switch reading
(`GetSwitchesFromEnvironment` is guarded by `#ifndef FLUTTER_RELEASE`), and
`FlutterDesktopEngineProperties` exposes no engine-switches field, so the
runner cannot pass the flag programmatically either. There is no supported
path to Impeller in a **release** Windows build on 3.38.9.

## Decision
- **Ship Skia** in release; keep the fill-rate mitigations in
  `lib/animation/neon_flow_background.dart` (1/3-resolution offscreen field
  capped at 360px, 30fps simulation cadence, zero per-frame allocations,
  bilinear blit) and `karaoke_text.dart` (no-glow `saveLayer` skip, single
  expensive line).
- For **local perf testing**, run debug/profile with the env switches above to
  compare Impeller vs Skia.
- **Revisit** when the Flutter toolchain is upgraded: once Impeller ships
  default-on (or release-enable-able) for Windows, delete the downsample
  knobs guarded by `_kFieldDownsample` if no longer needed.
