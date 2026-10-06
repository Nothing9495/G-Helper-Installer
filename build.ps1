<#
.SYNOPSIS
    Builds the G-Helper installer.

.DESCRIPTION
    Single build entry point shared by both GitHub Actions workflows and by hand.
    Producing the artifacts from one script is what keeps CI and Release honest:
    the only thing that may differ between them is the code the tag points at.

    Steps
      1. read AssemblyVersion from app/GHelper.csproj
      2. validate the tag against it
      3. pre-flight the .iss for the row-start bracket trap
      4. dotnet publish, self contained and loose
      5. SHA256SUMS.txt
      6. ISCC

    This script never touches git. Verifying the upstream merge window is a
    release concern and lives in .github/workflows/build-installer.yml.

    Example
      .\build.ps1
      .\build.ps1 -Tag v0.286
      .\build.ps1 -SkipPublish            # re-run ISCC only, for fast iteration
      .\build.ps1 -SkipSetup              # publish only, no installer
#>
[CmdletBinding()]
param(
    # Release tag to build, for example v0.286. Defaults to v<AssemblyVersion>.
    [string]$Tag,

    # Where the installer is written. Must match the naming contract described in
    # installer/GHelper.iss and app/AutoUpdate/AutoUpdateControl.cs.
    [string]$OutputDir,

    # Full path to ISCC.exe. Supply this on CI, where Inno Setup is installed by
    # the workflow and may sit outside every path probed below. Note that a
    # machine level install does not refresh PATH for later steps in the same
    # job, so discovery in the workflow has to use an absolute path anyway.
    [string]$Iscc,

    [switch]$SkipPublish,   # reuse the existing publish payload
    [switch]$SkipSetup      # stop after publishing, do not run ISCC
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot   = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Join-Path $RepoRoot 'app'
$Csproj     = Join-Path $ProjectDir 'GHelper.csproj'
$IssPath    = Join-Path $RepoRoot 'installer\GHelper.iss'
$IconPath   = Join-Path $RepoRoot 'installer\favicon-installer.ico'
$PublishDir = Join-Path $RepoRoot 'app\bin\installer\win-x64'

if (-not $OutputDir) { $OutputDir = Join-Path $RepoRoot 'dist' }

function Step($msg)  { Write-Host "==> $msg" }
function Die($msg)   { throw $msg }

# --------------------------------------------------------------- 1. version

Step 'Reading AssemblyVersion'
if (-not (Test-Path $Csproj)) { Die "Cannot find $Csproj" }

$raw = Get-Content $Csproj -Raw
# Two statements on purpose: PowerShell mis-parses an inline
# [regex]'...'.Match($raw) and reports a confusing String to Match conversion.
$re = [regex]'<AssemblyVersion>([^<]+)</AssemblyVersion>'
$m = $re.Match($raw)
if (-not $m.Success) { Die 'No AssemblyVersion element in GHelper.csproj' }
$Version = $m.Groups[1].Value.Trim()
$ExpectTag = "v$Version"
Write-Host "    AssemblyVersion = $Version"

if (-not $Tag) {
    $Tag = $ExpectTag
    Write-Host "    tag not given, using $Tag"
} elseif ($Tag -ne $ExpectTag) {
    Die "Tag '$Tag' does not match AssemblyVersion '$Version'. Expected '$ExpectTag'."
}


# ---------------------------------------------------- 2. pre-flight the .iss

Step 'Pre-flighting the installer script'
if (-not (Test-Path $IssPath)) { Die "Cannot find $IssPath" }

# Inno treats any row whose first non blank character is a bracket as a section
# tag, even inside Code or a comment. This has bitten the script three times, so
# it is checked here rather than after a 27 second compile.
$bad = @()
$inCode = $false
$lines = Get-Content $IssPath
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^\[Code\]\s*$') { $inCode = $true; continue }
    if ($inCode -and $lines[$i] -match '^\s*\[') { $bad += "line $($i + 1): $($lines[$i].Trim())" }
}
if ($bad.Count -gt 0) {
    $bad | ForEach-Object { Write-Host "    $_" }
    Die 'Installer script has a row starting with a bracket inside the Code section.'
}
Write-Host "    no row starts with a bracket inside [Code]"

# --------------------------------------------------------------- 3. publish

if (-not $SkipPublish) {
    Step 'Publishing a loose self contained payload'
    # The project file, not the solution: a solution level --output raises
    # NETSDK1194. PublishSingleFile stays off, the installer installs the tree.
    & dotnet publish $Csproj `
        -c Release -r win-x64 --self-contained true `
        -p:PublishSingleFile=false -p:DebugType=none `
        -o $PublishDir
    if ($LASTEXITCODE -ne 0) { Die "dotnet publish failed with exit code $LASTEXITCODE" }

    $count = (Get-ChildItem $PublishDir -Recurse -File).Count
    Write-Host "    $count files in $PublishDir"
    if ($count -lt 50) { Die 'Payload looks far too small, publish did not produce a self contained tree.' }
}

if (-not (Test-Path (Join-Path $PublishDir 'GHelper.exe'))) {
    Die "Payload is missing GHelper.exe. Run without -SkipPublish."
}

# --------------------------------------------------------------- 4. installer

if (-not $SkipSetup) {
    Step 'Building the installer'

    Step 'Locating ISCC'
    if ($Iscc) {
        if (-not (Test-Path $Iscc)) { Die "ISCC not found at the -Iscc path '$Iscc'." }
    } else {
        $candidates = @()
        $onPath = Get-Command iscc -ErrorAction SilentlyContinue
        if ($onPath) { $candidates += $onPath.Source }
        # Per user and all users, both major versions. A per user install lands in
        # LOCALAPPDATA, an all users install in Program Files, and the x64 Inno
        # Setup 7 defaults to the latter, so both have to be probed.
        $roots = @(
            (Join-Path $env:LOCALAPPDATA 'Programs'),
            $env:ProgramFiles,
            ${env:ProgramFiles(x86)}
        ) | Where-Object { $_ -and (Test-Path $_) }
        foreach ($r in $roots) {
            foreach ($v in 7, 6) { $candidates += (Join-Path $r "Inno Setup $v\ISCC.exe") }
        }
        $Iscc = $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    }
    if (-not $Iscc) {
        Die 'ISCC.exe not found. Install Inno Setup 6.3 or newer, or pass -Iscc. ' +
            'CI installs 7.1.0 from: github.com/jrsoftware/issrc/releases/tag/is-7_1_0'
    }
    Write-Host "    $Iscc"

    Step 'Compiling'
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

    # The defines mirror the fallbacks in GHelper.iss so the script also compiles
    # by hand from a checkout. ISCC writes straight to the console, so its output
    # is captured and only surfaced on failure to keep the log readable.
    $isccLog = & $Iscc "/DMyAppVersion=$Version" "/DMyPublishDir=$PublishDir" "/O$OutputDir" $IssPath 2>&1
    if ($LASTEXITCODE -ne 0) {
        $isccLog | ForEach-Object { Write-Host "    $_" }
        Die "ISCC failed with exit code $LASTEXITCODE"
    }
    if ($env:GITHUB_ACTIONS -eq 'true') {
        $isccLog | Where-Object { $_ -match 'Error|Warning' } |
            ForEach-Object { Write-Host "    $_" }
    }

    $setup = Join-Path $OutputDir "GHelper-$Tag-Setup.exe"
    if (-not (Test-Path $setup)) { Die "Expected $setup but it was not produced." }

    Step 'Writing checksums'
    $sums = Join-Path $OutputDir 'SHA256SUMS.txt'
    $hash = (Get-FileHash -Algorithm SHA256 $setup).Hash.ToLower()
    # Name the asset exactly as it is published. Listing "$Tag-Setup.exe" instead
    # would make `sha256sum -c SHA256SUMS.txt` look for a file that was never built.
    "$hash  $(Split-Path $setup -Leaf)" | Set-Content -Encoding ASCII $sums

    $sizeMb = [math]::Round((Get-Item $setup).Length / 1MB, 1)
    Write-Host ''
    Write-Host 'Build succeeded.'
    Write-Host "    tag     : $Tag"
    Write-Host "    version : $Version"
    Write-Host "    setup   : $setup ($sizeMb MB)"
    Write-Host "    checksums: $sums"

    # Consumed by the release workflow for gh release upload.
    if ($env:GITHUB_OUTPUT) {
        "setup_exe=$setup"       | Out-File -Append -Encoding utf8 $env:GITHUB_OUTPUT
        "checksums=$sums"        | Out-File -Append -Encoding utf8 $env:GITHUB_OUTPUT
        "tag=$Tag"               | Out-File -Append -Encoding utf8 $env:GITHUB_OUTPUT
    }
} else {
    Write-Host '==> Skipping the installer build as requested.'
}
