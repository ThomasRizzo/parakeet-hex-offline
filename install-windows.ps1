# Offline-friendly Hex + Parakeet installer for Windows (current user only).
#
# Adapted from Anomaly's https://anoma.ly/hex/files/install-windows.ps1, but
# every download comes from this repo's GitHub Release, so a machine that can
# reach only github.com (or nothing, with -Offline) can install Hex and its
# speech models. No administrator rights are needed:
#   - Hex:     %APPDATA%\hex\versions\<version>\hex.exe + hex.com  (the same
#              managed layout the upstream script and HexSetup.exe create)
#   - CLI:     %APPDATA%\hex\bin\hex.com, added to the *user* PATH
#   - Models:  %LOCALAPPDATA%\hex\models\parakeet-unified-en-0.6b-Q8_0.gguf and
#              silero-vad-v6.2-F32.gguf, exactly where Hex looks for them, so
#              Hex finds them installed and never contacts huggingface.co
#   - Start Menu shortcut "Hex" (per-user)
#
# Usage (Windows PowerShell 5.1 or PowerShell 7):
#   irm https://github.com/ThomasRizzo/parakeet-hex-offline/releases/latest/download/install-windows.ps1 | iex
#   powershell -ExecutionPolicy Bypass -File install-windows.ps1 [options]
#
# Options:
#   -Offline              Read every asset from -Source (default: this
#                         script's folder) instead of downloading.
#   -Source <dir>         Folder holding pre-downloaded release assets.
#   -DownloadOnly <dir>   Download the assets this install needs (plus this
#                         script) into <dir> for carrying to another machine.
#   -ExtraModels <list>   Also install other quantizations into
#                         %LOCALAPPDATA%\hex\gguf: F16, F32, Q6_K, Q5_K_M,
#                         Q4_K_M, or All. Hex 3.4 can import F16/F32 with
#                         `hex model import <file>`.
#   -Arch x64|arm64       Override the detected architecture.
#   -Tag <tag> -Repo <owner/name>   Install another release of this mirror.
#   -DisableUpdates       Try to set HKCU\Software\Policies\Anomaly\Hex
#                         DisableUpdates=1 so Hex stops polling anoma.ly
#                         (often blocked for standard users; never fatal).
#   -NoShortcut  -NoPath  -SkipSmokeTest  -KeepDownloads
#   -Uninstall            Remove Hex (keeps settings, history, and models
#                         unless -RemoveModels).
#
# With `irm | iex`, pass options like this:
#   & ([scriptblock]::Create((irm <url>/install-windows.ps1))) -ExtraModels F16

[CmdletBinding()]
param(
    [switch]$Offline,
    [string]$Source,
    [string]$DownloadOnly,
    [string[]]$ExtraModels = @(),
    [string]$Arch = '',
    [string]$Tag,
    [string]$Repo,
    [switch]$DisableUpdates,
    [switch]$NoShortcut,
    [switch]$NoPath,
    [switch]$SkipSmokeTest,
    [switch]$KeepDownloads,
    [switch]$Uninstall,
    [switch]$RemoveModels
)

# Stamped by the release workflow (scripts/build_release.py).
$DefaultRepo = 'ThomasRizzo/parakeet-hex-offline'
$DefaultTag = 'parakeet-7e948f2-hex-3.4.0'

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is very slow with progress on 5.1
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {}

if (-not $Repo) { $Repo = $DefaultRepo }
if (-not $Tag) { $Tag = $DefaultTag }
$baseUrl = "https://github.com/$Repo/releases/download/$Tag"

$scriptDir = $null
if ($PSCommandPath) { $scriptDir = Split-Path -Parent $PSCommandPath }
if ($Offline -and -not $Source) {
    if (-not $scriptDir) { throw '-Offline needs -Source <folder> when the script is not run from a file.' }
    $Source = $scriptDir
}
if ($Source) { $Source = (Resolve-Path -LiteralPath $Source).ProviderPath; $Offline = $true }

$support = if ($env:HEX_APPLICATION_SUPPORT_DIR) { $env:HEX_APPLICATION_SUPPORT_DIR } else { Join-Path $env:APPDATA 'hex' }
# Hex keeps models machine-local on Windows: %LOCALAPPDATA%\hex\models
# (src/app_paths.rs), unless HEX_APPLICATION_SUPPORT_DIR picks a folder.
$localRoot = if ($env:HEX_APPLICATION_SUPPORT_DIR) { $env:HEX_APPLICATION_SUPPORT_DIR } else { Join-Path $env:LOCALAPPDATA 'hex' }
$modelsDir = Join-Path $localRoot 'models'
$extraDir = Join-Path $localRoot 'gguf'
$versions = Join-Path $support 'versions'
$pointer = Join-Path $support 'current-version'
$receipt = Join-Path $support 'install.json'
$bin = Join-Path $support 'bin'
$shortcut = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Hex.lnk'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$managedMark = 'Hex managed install'

function Write-Step([string]$text) { Write-Host "==> $text" }

function Remove-ManagedShortcut {
    if (Test-Path -LiteralPath $shortcut) {
        $shell = New-Object -ComObject WScript.Shell
        $link = $shell.CreateShortcut($shortcut)
        if ($link.Description -eq $managedMark) { Remove-Item -LiteralPath $shortcut -Force }
    }
}

function Set-BinOnPath([bool]$present) {
    $environment = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
    try {
        $current = [string]$environment.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $entries = @($current -split ';' | Where-Object { $_ -and $_.TrimEnd('\') -ne $bin })
        if ($present) { $entries += $bin }
        $updated = $entries -join ';'
        if ($updated -ne $current) {
            $environment.SetValue('Path', $updated, [Microsoft.Win32.RegistryValueKind]::ExpandString)
            # SetEnvironmentVariable broadcasts WM_SETTINGCHANGE to running programs.
            [Environment]::SetEnvironmentVariable('HexPathRefresh', '1', 'User')
            [Environment]::SetEnvironmentVariable('HexPathRefresh', $null, 'User')
        }
    } finally {
        $environment.Close()
    }
}

if ($Uninstall) {
    Remove-ManagedShortcut
    Set-BinOnPath $false
    if (Test-Path -LiteralPath $bin) { Remove-Item -LiteralPath $bin -Recurse -Force }
    try { Remove-ItemProperty -Path $runKey -Name 'Hex' -ErrorAction Stop } catch {}
    if (Test-Path -LiteralPath $versions) { Remove-Item -LiteralPath $versions -Recurse -Force }
    if (Test-Path -LiteralPath $pointer) { Remove-Item -LiteralPath $pointer -Force }
    if (Test-Path -LiteralPath $receipt) { Remove-Item -LiteralPath $receipt -Force }
    if ($RemoveModels) {
        foreach ($dir in @($modelsDir, $extraDir)) {
            if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
        }
        Write-Output "Removed Hex and its models. Settings remain in $support."
    } else {
        Write-Output "Removed Hex. Settings remain in $support; models in $modelsDir."
    }
    return
}

# ---------------------------------------------------------------- assets ---

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("parakeet-hex-offline-" + $Tag)
if ($DownloadOnly) {
    New-Item -ItemType Directory -Force -Path $DownloadOnly | Out-Null
    $tempRoot = (Resolve-Path -LiteralPath $DownloadOnly).ProviderPath
}
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

function Get-Sha256([string]$path) {
    (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
}

# Returns a local path to release asset $name with the given size/sha256,
# downloading it from the release (or taking it from -Source) and verifying it.
function Get-Asset([string]$name, [long]$size, [string]$sha256) {
    if ($Offline) {
        $path = Join-Path $Source $name
        if (-not (Test-Path -LiteralPath $path)) { throw "Missing $name in $Source." }
    } else {
        $path = Join-Path $tempRoot $name
        $ok = $false
        if ((Test-Path -LiteralPath $path) -and $sha256) {
            $ok = ((Get-Item -LiteralPath $path).Length -eq $size) -and ((Get-Sha256 $path) -eq $sha256)
        }
        if (-not $ok) {
            $partial = "$path.download"
            if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
            $mb = if ($size -gt 0) { ' ({0:N0} MB)' -f ($size / 1MB) } else { '' }
            Write-Host "    downloading $name$mb"
            $attempt = 0
            while ($true) {
                $attempt++
                try {
                    Invoke-WebRequest -Uri "$baseUrl/$name" -OutFile $partial -UseBasicParsing -TimeoutSec 1800
                    break
                } catch {
                    if ($attempt -ge 3) { throw "Download of $baseUrl/$name failed: $($_.Exception.Message)" }
                    Start-Sleep -Seconds (5 * $attempt)
                }
            }
            Move-Item -LiteralPath $partial -Destination $path -Force
        }
    }
    if ($sha256) {
        $bytes = (Get-Item -LiteralPath $path).Length
        if ($bytes -ne $size) { throw "$name has $bytes bytes, expected $size." }
        $actual = Get-Sha256 $path
        if ($actual -ne $sha256) { throw "$name failed SHA-256 verification ($actual, expected $sha256)." }
    }
    return $path
}

# Moves <source> over <path>. A running program can't be replaced but can be
# renamed, so one in the way moves aside to <path>.old, removed next time.
function Move-FileIntoPlace([string]$from, [string]$path) {
    $aside = "$path.old"
    if (Test-Path -LiteralPath $aside) { Remove-Item -LiteralPath $aside -Force -ErrorAction SilentlyContinue }
    try {
        Move-Item -LiteralPath $from -Destination $path -Force
    } catch {
        Move-Item -LiteralPath $path -Destination $aside -Force
        Move-Item -LiteralPath $from -Destination $path -Force
    }
}

# Installs manifest entry $entry (a model, possibly split into parts) at $dest.
function Install-ModelFile($entry, [string]$dest) {
    if ((Test-Path -LiteralPath $dest) -and ((Get-Item -LiteralPath $dest).Length -eq [long]$entry.size)) {
        if ((Get-Sha256 $dest) -eq $entry.sha256) {
            Write-Host "    $($entry.name) already installed and verified"
            return
        }
    }
    $partial = "$dest.offline-partial"
    if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
    if ($entry.parts) {
        $out = [IO.File]::Open($partial, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
        try {
            foreach ($part in $entry.parts) {
                $p = Get-Asset $part.name ([long]$part.size) $part.sha256
                $in = [IO.File]::OpenRead($p)
                try { $in.CopyTo($out, 8MB) } finally { $in.Dispose() }
                if (-not $Offline -and -not $KeepDownloads) { Remove-Item -LiteralPath $p -Force }
            }
        } finally {
            $out.Dispose()
        }
    } else {
        $p = Get-Asset $entry.name ([long]$entry.size) $entry.sha256
        if ($Offline -or $KeepDownloads) {
            Copy-Item -LiteralPath $p -Destination $partial -Force
        } else {
            Move-Item -LiteralPath $p -Destination $partial -Force
        }
    }
    $bytes = (Get-Item -LiteralPath $partial).Length
    if ($bytes -ne [long]$entry.size) { Remove-Item -LiteralPath $partial -Force; throw "$($entry.name): $bytes bytes, expected $($entry.size)." }
    $actual = Get-Sha256 $partial
    if ($actual -ne $entry.sha256) { Remove-Item -LiteralPath $partial -Force; throw "$($entry.name) failed SHA-256 verification." }
    Move-FileIntoPlace $partial $dest
    Write-Host "    installed $dest"
}

if ($Offline) { Write-Step "Using local assets in $Source" } else { Write-Step "Using $baseUrl" }

# SHA256SUMS vouches for manifest.json; the manifest lists every file's size,
# SHA-256, and (for files over 2 GiB) its parts.
$sumsPath = Get-Asset 'SHA256SUMS' 0 ''
$sums = @{}
foreach ($line in (Get-Content -LiteralPath $sumsPath)) {
    if ($line -match '^([0-9a-f]{64}) [ *]?(.+)$') { $sums[$Matches[2].Trim()] = $Matches[1] }
}
if (-not $sums.ContainsKey('manifest.json')) { throw 'SHA256SUMS does not list manifest.json.' }
$manifestPath = Join-Path $tempRoot 'manifest.json'
if ($Offline) { $manifestPath = Join-Path $Source 'manifest.json' }
if (-not $Offline) {
    Invoke-WebRequest -Uri "$baseUrl/manifest.json" -OutFile $manifestPath -UseBasicParsing -TimeoutSec 120
}
if ((Get-Sha256 $manifestPath) -ne $sums['manifest.json']) { throw 'manifest.json does not match SHA256SUMS.' }
$manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
if ($manifest.schema -ne 1) { throw "Unsupported manifest schema $($manifest.schema)." }
$version = [string]$manifest.hex.version
if ($version -notmatch '^[0-9A-Za-z][0-9A-Za-z.+_-]{0,127}$') { throw "Unexpected version $version." }

if ($Arch -and $Arch -notin @('x64', 'arm64')) { throw "-Arch must be x64 or arm64, not $Arch." }
if (-not $Arch) {
    # A 32-bit PowerShell on 64-bit Windows reports the real machine here.
    $machine = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    $Arch = switch ($machine) {
        'AMD64' { 'x64' }
        'ARM64' { 'arm64' }
        default { throw "Hex supports 64-bit x64 and ARM64 Windows, not $machine." }
    }
}
$appFile = @($manifest.hex.files | Where-Object { $_.arch -eq $Arch -and $_.role -eq 'app' })[0]
$cliFile = @($manifest.hex.files | Where-Object { $_.arch -eq $Arch -and $_.role -eq 'cli' })[0]
if (-not $appFile) { throw "This release has no Hex build for windows-$Arch." }

$defaultModel = @($manifest.models | Where-Object { $_.role -eq 'hex-default-model' })[0]
$detector = @($manifest.models | Where-Object { $_.role -eq 'hex-speech-detector' })[0]
if (-not $defaultModel -or -not $detector) { throw 'The manifest lacks the Hex model files.' }

$extras = @()
$wanted = @($ExtraModels | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($wanted.Count -gt 0) {
    $candidates = @($manifest.models | Where-Object { $_.role -eq 'extra-model' })
    foreach ($w in $wanted) {
        if ($w -eq 'All') { $extras += $candidates; continue }
        $hit = @($candidates | Where-Object { $_.name -like "*-$w.gguf" })
        if ($hit.Count -eq 0) {
            $known = ($candidates | ForEach-Object { ($_.name -replace '^.*-([^-]+)\.gguf$', '$1') }) -join ', '
            throw "Unknown -ExtraModels value '$w'. Available: $known, All."
        }
        $extras += $hit
    }
    $extras = @($extras | Sort-Object name -Unique)
}

# -------------------------------------------------------- download-only ---

if ($DownloadOnly) {
    Write-Step "Downloading assets for windows-$Arch into $tempRoot"
    $Offline = $false
    $needed = @($appFile)
    if ($cliFile) { $needed += $cliFile }
    foreach ($m in @($defaultModel, $detector) + $extras) {
        if ($m.parts) { $needed += @($m.parts) } else { $needed += $m }
    }
    foreach ($f in $needed) { $null = Get-Asset $f.name ([long]$f.size) $f.sha256 }
    $self = Join-Path $tempRoot 'install-windows.ps1'
    if ($sums.ContainsKey('install-windows.ps1')) {
        $null = Get-Asset 'install-windows.ps1' 0 ''
        if ((Get-Sha256 $self) -ne $sums['install-windows.ps1']) { throw 'install-windows.ps1 does not match SHA256SUMS.' }
    }
    Write-Output "Downloaded. Copy $tempRoot to the target and run:"
    Write-Output "  powershell -ExecutionPolicy Bypass -File install-windows.ps1 -Offline$(if ($extras.Count) { ' -ExtraModels ' + ($wanted -join ',') })"
    return
}

# ------------------------------------------------------------------ Hex ---

Write-Step "Installing Hex $version (windows-$Arch)"
$versionDir = Join-Path $versions $version
$executable = Join-Path $versionDir 'hex.exe'
$console = Join-Path $versionDir 'hex.com'
New-Item -ItemType Directory -Force -Path $versionDir | Out-Null

$p = Get-Asset $appFile.name ([long]$appFile.size) $appFile.sha256
Copy-Item -LiteralPath $p -Destination "$executable.partial" -Force
Move-FileIntoPlace "$executable.partial" $executable
if ($cliFile) {
    $p = Get-Asset $cliFile.name ([long]$cliFile.size) $cliFile.sha256
    Copy-Item -LiteralPath $p -Destination "$console.partial" -Force
    Move-FileIntoPlace "$console.partial" $console
}

# The version probe, as upstream: hex.com waits for hex.exe, a GUI program.
if ($cliFile) {
    $reported = (& $console --version) -split '\s+' | Select-Object -Last 1
} else {
    $probe = Join-Path $versionDir 'version.txt'
    Start-Process $executable -ArgumentList '--version' -Wait -NoNewWindow -RedirectStandardOutput $probe
    $reported = (Get-Content -LiteralPath $probe -Raw).Trim() -split '\s+' | Select-Object -Last 1
    Remove-Item -LiteralPath $probe -Force
}
if ($reported -ne $version) {
    Remove-Item -LiteralPath $executable -Force
    if (Test-Path -LiteralPath $console) { Remove-Item -LiteralPath $console -Force }
    throw "The installed Hex reports version '$reported', expected $version."
}

$pointerPartial = Join-Path $support 'current-version.partial'
Set-Content -LiteralPath $pointerPartial -Value $version -NoNewline
Move-Item -LiteralPath $pointerPartial -Destination $pointer -Force
$receiptPartial = "$receipt.partial"
# WriteAllText writes UTF-8 without a byte order mark on every PowerShell.
[IO.File]::WriteAllText($receiptPartial, ([ordered]@{ app = 'hex'; artifact = 'desktop'; channel = 'stable'; method = 'direct'; root = $support } | ConvertTo-Json -Compress))
Move-Item -LiteralPath $receiptPartial -Destination $receipt -Force

if (-not $NoShortcut) {
    try {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $shortcut) | Out-Null
        $shell = New-Object -ComObject WScript.Shell
        $link = $shell.CreateShortcut($shortcut)
        $link.TargetPath = $executable
        $link.Arguments = 'app'
        $link.Description = $managedMark
        $link.WorkingDirectory = $versionDir
        $link.Save()
    } catch {
        Write-Warning "Could not create the Start Menu shortcut: $($_.Exception.Message)"
    }
}

if ($cliFile) {
    New-Item -ItemType Directory -Force -Path $bin | Out-Null
    $copy = Join-Path $bin 'hex.com.partial'
    Copy-Item -LiteralPath $console -Destination $copy -Force
    Move-FileIntoPlace $copy (Join-Path $bin 'hex.com')
    if (-not $NoPath) { Set-BinOnPath $true }
}

if ($DisableUpdates) {
    try {
        $key = 'HKCU:\Software\Policies\Anomaly\Hex'
        if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
        New-ItemProperty -Path $key -Name 'DisableUpdates' -Value 1 -PropertyType DWord -Force | Out-Null
        Write-Host '    update checks disabled (HKCU policy DisableUpdates=1)'
    } catch {
        Write-Warning "Could not set HKCU\Software\Policies\Anomaly\Hex DisableUpdates (that key usually needs an administrator). Hex's update check will fail quietly without anoma.ly."
    }
}

# --------------------------------------------------------------- models ---

Write-Step "Installing speech models into $modelsDir"
New-Item -ItemType Directory -Force -Path $modelsDir | Out-Null
Install-ModelFile $defaultModel (Join-Path $modelsDir $defaultModel.path)
Install-ModelFile $detector (Join-Path $modelsDir $detector.path)
if ($extras.Count -gt 0) {
    Write-Step "Installing extra quantizations into $extraDir"
    New-Item -ItemType Directory -Force -Path $extraDir | Out-Null
    foreach ($m in $extras) { Install-ModelFile $m (Join-Path $extraDir $m.path) }
}

if (-not $Offline -and -not $KeepDownloads -and -not $DownloadOnly) {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# ----------------------------------------------------------- smoke test ---

if ($cliFile -and -not $SkipSmokeTest) {
    Write-Step 'Smoke test'
    Write-Host "    hex --version: $reported"
    # With the file already in place, `model install` only checks it against
    # Hex's pinned SHA-256, records the verification, and selects the model;
    # it downloads nothing.
    # Windows PowerShell 5.1 turns a native program's stderr into errors
    # under 'Stop', so relax it while Hex runs.
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $console model install parakeet_unified_en --language en 2>&1
        $code = $LASTEXITCODE
        $out | ForEach-Object { Write-Host "    $_" }
        if ($code -ne 0) {
            Write-Warning "hex model install exited $code. If Hex was running, run 'hex model use parakeet_unified_en' once it answers."
        }
        $status = & $console model status parakeet_unified_en --language en 2>&1
        $code = $LASTEXITCODE
        $status | ForEach-Object { Write-Host "    $_" }
        if ($code -ne 0) { Write-Warning "hex model status exited $code." }
    } finally {
        $ErrorActionPreference = $saved
    }
}

Write-Output ''
Write-Output "Installed Hex $version with Parakeet Unified English (Q8_0)."
Write-Output "  Executable: $executable"
Write-Output "  Models:     $modelsDir"
if (-not $NoShortcut) { Write-Output '  Start Menu: Hex' }
if ($cliFile -and -not $NoPath) { Write-Output "  Terminal:   hex (open a new terminal; $bin is on your user PATH)" }
if ($extras.Count -gt 0) {
    Write-Output "  Extra GGUFs: $extraDir (Hex $version imports F16/F32: hex model import <file>)"
}
Write-Output 'Hex will not need huggingface.co for the default model or speech detector.'
