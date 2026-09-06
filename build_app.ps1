#requires -Version 5.1
<#
.SYNOPSIS
    Build the standalone Windows app (VBXE PAL Studio + palettize4.exe) and zip it.

.DESCRIPTION
    Creates an isolated build venv, installs packaging/requirements-build.txt,
    runs PyInstaller against packaging/vbxe_pal_studio.spec, seeds the shipped
    presets, and packs dist/VBXE PAL Studio/ into "VBXE PAL Studio v<ver>.zip".

    This is independent of the .venv used to run from source - it makes its own
    .venv-build and never touches yours.

.PARAMETER Clean
    Delete .venv-build, build/ and dist/ first.

.PARAMETER Python
    Python launcher spec for the build venv. Default: try -3.12, -3.13, -3.11,
    -3.10 in turn, then the default 'py -3'. PyInstaller 6.x + PySide6 6.11 are
    reliable on 3.10-3.13; 3.14 is bleeding-edge and only a last resort.

.EXAMPLE
    pwsh ./build_app.ps1
    pwsh ./build_app.ps1 -Clean
    pwsh ./build_app.ps1 -Python -3.10
#>
[CmdletBinding()]
param(
    [switch]$Clean,
    [string]$Python = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Root      = $PSScriptRoot
$Spec      = Join-Path $Root "packaging\vbxe_pal_studio.spec"
$Reqs      = Join-Path $Root "packaging\requirements-build.txt"
$VenvDir   = Join-Path $Root ".venv-build"
$BuildDir  = Join-Path $Root "build"
$DistDir   = Join-Path $Root "dist"
$AppName   = "VBXE PAL Studio"
$AppDir    = Join-Path $DistDir $AppName
$PresetSrc = Join-Path $Root "Convertor\palgui\presets"

function Write-Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }

# --- version, straight out of the package -----------------------------------
$initPy = Join-Path $Root "Convertor\palgui\__init__.py"
$verLine = Select-String -Path $initPy -Pattern "__version__\s*=\s*['""]([^'""]+)['""]" | Select-Object -First 1
if (-not $verLine) { throw "could not read __version__ from $initPy" }
$Version = $verLine.Matches[0].Groups[1].Value
Write-Host "VBXE PAL Studio v$Version" -ForegroundColor Green

# --- clean ----------------------------------------------------------------------
if ($Clean) {
    Write-Step "Clean"
    foreach ($d in @($VenvDir, $BuildDir, $DistDir)) {
        if (Test-Path $d) { Remove-Item -Recurse -Force $d; Write-Host "removed $d" }
    }
}

# --- pick an interpreter ------------------------------------------------------
Write-Step "Locate Python"
function Probe-Py($pyArgList) {
    $v = & py @pyArgList -c "import sys; print('%d.%d' % sys.version_info[:2])" 2>$null
    if ($LASTEXITCODE -eq 0 -and $v) { return $v.Trim() }
    return $null
}

$candidates = if ($Python) { @($Python.Split(" ")) } `
              else { @(@("-3.12"), @("-3.13"), @("-3.11"), @("-3.10"), @("-3")) }

$pyArgs = $null; $probe = $null
foreach ($c in $candidates) {
    $arr = @($c)
    $v = Probe-Py $arr
    if ($v) { $pyArgs = $arr; $probe = $v; break }
}
if (-not $pyArgs) { throw "no usable Python via the 'py' launcher (tried: $($candidates -join ', '))" }

Write-Host "using Python $probe  (py $($pyArgs -join ' '))"
if ($probe -notin @("3.10", "3.11", "3.12", "3.13")) {
    Write-Warning "Python $probe is outside the tested range 3.10-3.13; PyInstaller/PySide6 may misbehave. Continuing."
}

# --- build venv --------------------------------------------------------------
Write-Step "Build venv"
$VenvPy = Join-Path $VenvDir "Scripts\python.exe"
if (-not (Test-Path $VenvPy)) {
    & py @pyArgs -m venv $VenvDir
    if ($LASTEXITCODE -ne 0) { throw "venv creation failed" }
}
& $VenvPy -m pip install --upgrade pip | Out-Host
& $VenvPy -m pip install -r $Reqs | Out-Host
if ($LASTEXITCODE -ne 0) { throw "pip install failed" }

# --- PyInstaller -----------------------------------------------------------------
Write-Step "PyInstaller"
if (Test-Path $AppDir) { Remove-Item -Recurse -Force $AppDir }
& $VenvPy -m PyInstaller --clean --noconfirm `
    --distpath $DistDir --workpath $BuildDir `
    $Spec | Out-Host
if ($LASTEXITCODE -ne 0) { throw "PyInstaller failed" }
if (-not (Test-Path (Join-Path $AppDir "$AppName.exe"))) {
    throw "expected $AppName.exe in $AppDir - build produced nothing usable"
}

# --- seed the shipped presets ----------------------------------------------------
Write-Step "Presets"
$PresetDst = Join-Path $AppDir "presets"
New-Item -ItemType Directory -Force -Path $PresetDst | Out-Null
Copy-Item (Join-Path $PresetSrc "*.json") $PresetDst -Force
Write-Host ("copied {0} preset(s)" -f (Get-ChildItem $PresetDst -Filter *.json).Count)

# --- zip -----------------------------------------------------------------------
Write-Step "Package"
$Zip = Join-Path $Root ("{0} v{1}.zip" -f $AppName, $Version)
if (Test-Path $Zip) { Remove-Item -Force $Zip }
Compress-Archive -Path $AppDir -DestinationPath $Zip -CompressionLevel Optimal
$mb = [math]::Round((Get-Item $Zip).Length / 1MB, 1)
Write-Host "`nBuilt $Zip ($mb MB)" -ForegroundColor Green
Write-Host "Folder: $AppDir"
