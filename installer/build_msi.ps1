<#
.SYNOPSIS
  Builds the WenListener Windows MSI installer.

.DESCRIPTION
  Harvests everything under build\windows\x64\runner\Release (heat.exe),
  compiles Product.wxs + the generated harvest (candle.exe) and links the
  final MSI (light.exe) to dist\WenListener-<version>-x64.msi.

  It does NOT run "flutter build" — build the release payload first:
      C:\flutter\bin\flutter.bat build windows --release

.USAGE
  powershell -ExecutionPolicy Bypass -File installer\build_msi.ps1
#>

$ErrorActionPreference = 'Stop'

# ---- Paths -----------------------------------------------------------------
$InstallerDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot  = Split-Path -Parent $InstallerDir
$ReleaseDir   = Join-Path $ProjectRoot 'build\windows\x64\runner\Release'
$IconFile     = Join-Path $ProjectRoot 'windows\runner\resources\app_icon.ico'
$WixDir       = Join-Path $InstallerDir 'tools\wix314'
$ObjDir       = Join-Path $InstallerDir 'obj'
$DistDir      = Join-Path $ProjectRoot 'dist'

# ---- Preconditions ---------------------------------------------------------
if (-not (Test-Path (Join-Path $ReleaseDir 'wenlistener_desktop.exe'))) {
    throw "Release payload not found: '$ReleaseDir\wenlistener_desktop.exe'. Run 'C:\flutter\bin\flutter.bat build windows --release' first."
}
if (-not (Test-Path (Join-Path $ReleaseDir 'data\flutter_assets'))) {
    throw "Release payload incomplete: '$ReleaseDir\data\flutter_assets' is missing. Re-run the flutter release build."
}
if (-not (Test-Path (Join-Path $WixDir 'candle.exe'))) {
    throw "WiX 3.14 binaries not found in '$WixDir'. Download wix314-binaries.zip from https://github.com/wixtoolset/wix3/releases and extract it there."
}
if (-not (Test-Path $IconFile)) {
    throw "App icon not found: '$IconFile'."
}

# ---- Version from pubspec.yaml (1.0.0+1 -> 1.0.0) ---------------------------
$PubspecPath = Join-Path $ProjectRoot 'pubspec.yaml'
$VersionLine = (Get-Content $PubspecPath) | Where-Object { $_ -match '^version:\s*(\d+\.\d+\.\d+)' } | Select-Object -First 1
if (-not $VersionLine) {
    throw "Could not parse 'version: x.y.z' from '$PubspecPath'."
}
$Version = [regex]::Match($VersionLine, '^version:\s*(\d+\.\d+\.\d+)').Groups[1].Value
Write-Host "Product version: $Version"

New-Item -ItemType Directory -Force $ObjDir  | Out-Null
New-Item -ItemType Directory -Force $DistDir | Out-Null

$Heat   = Join-Path $WixDir 'heat.exe'
$Candle = Join-Path $WixDir 'candle.exe'
$Light  = Join-Path $WixDir 'light.exe'

# ---- 0a) Strip MSVC link by-products so they never bloat the MSI ------------
# heat harvests EVERY file under Release; wenlistener_desktop.exp/.lib/.pdb are
# linker artifacts the app never loads at runtime. flutter build regenerates them
# each time, so deleting them here is harmless.
Get-ChildItem $ReleaseDir -Include *.exp, *.lib, *.pdb -Recurse -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue

# ---- 0b) Bundle the VC++ 2015-2022 runtime app-local -----------------------
# A Flutter Windows RELEASE binary dynamically links the MSVC runtime. This dev
# box has it (VS installed), but a CLEAN target machine without the "VC++ 2015-2022
# Redistributable" would fail to start / show a white window. Copying the runtime
# DLLs next to the exe (they get harvested into the MSI) makes the app self-contained.
$CrtDlls = @('msvcp140.dll', 'msvcp140_1.dll', 'msvcp140_2.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')
foreach ($dll in $CrtDlls) {
    $srcDll = Join-Path $env:SystemRoot "System32\$dll"
    if (Test-Path $srcDll) {
        Copy-Item $srcDll (Join-Path $ReleaseDir $dll) -Force
    } else {
        Write-Warning "VC++ runtime '$dll' not found in System32 - clean-machine installs may white-screen."
    }
}

# ---- 1) Harvest the Release tree (regenerated every build) ------------------
$HarvestWxs = Join-Path $ObjDir 'AppFiles.wxs'
Write-Host "Harvesting $ReleaseDir ..."
& $Heat dir $ReleaseDir `
    -cg AppFiles `
    -dr INSTALLFOLDER `
    -srd -sreg -scom -sfrag -ag `
    -var var.ReleaseDir `
    -nologo `
    -out $HarvestWxs
if ($LASTEXITCODE -ne 0) { throw "heat.exe failed (exit $LASTEXITCODE)." }

# ---- 2) Compile ---------------------------------------------------------------
Write-Host 'Compiling (candle) ...'
& $Candle -nologo -arch x64 `
    "-dProductVersion=$Version" `
    "-dReleaseDir=$ReleaseDir" `
    "-dIconFile=$IconFile" `
    -out "$ObjDir\" `
    (Join-Path $InstallerDir 'Product.wxs') $HarvestWxs
if ($LASTEXITCODE -ne 0) { throw "candle.exe failed (exit $LASTEXITCODE)." }

# ---- 3) Link ----------------------------------------------------------------
$MsiPath = Join-Path $DistDir "WenListener-$Version-x64.msi"
Write-Host 'Linking (light) ...'
& $Light -nologo -ext WixUIExtension -cultures:en-us -spdb -sice:ICE61 `
    -b $InstallerDir `
    -out $MsiPath `
    (Join-Path $ObjDir 'Product.wixobj') (Join-Path $ObjDir 'AppFiles.wixobj')
if ($LASTEXITCODE -ne 0) { throw "light.exe failed (exit $LASTEXITCODE)." }

Write-Host "OK: $MsiPath ($([math]::Round((Get-Item $MsiPath).Length / 1MB, 1)) MB)"
