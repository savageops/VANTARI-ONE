[CmdletBinding()]
param(
  [string]$InstallPath = (Join-Path $env:LOCALAPPDATA "Vantari\bin\vantari.exe"),
  [switch]$SkipBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$backendRoot = Split-Path -Parent $scriptDir
$repoRoot = Split-Path -Parent (Split-Path -Parent $backendRoot)
$builtPath = Join-Path $backendRoot "zig-out\bin\vantari.exe"
$zigWrapper = Join-Path $scriptDir "zigw.ps1"
$zigVersion = "0.15.1"
$zigExe = Join-Path $env:LOCALAPPDATA "VANTARI-ONE\toolchains\zig-x86_64-windows-$zigVersion\zig.exe"

if (-not $SkipBuild) {
  if (-not (Test-Path -LiteralPath $zigExe)) {
    & $zigWrapper version *> $null
    if ($LASTEXITCODE -ne 0) {
      throw "could not provision the Zig toolchain with $zigWrapper"
    }
  }
  if (-not (Test-Path -LiteralPath $zigExe)) {
    throw "Zig toolchain not found: $zigExe"
  }
  $env:ZIG_LOCAL_CACHE_DIR = Join-Path $env:TEMP ("VANTARI-ONE-install-local-" + $PID)
  $env:ZIG_GLOBAL_CACHE_DIR = Join-Path $env:TEMP ("VANTARI-ONE-install-global-" + $PID)
  New-Item -ItemType Directory -Force -Path $env:ZIG_LOCAL_CACHE_DIR, $env:ZIG_GLOBAL_CACHE_DIR | Out-Null
  Push-Location $backendRoot
  try {
    & $zigExe build -Doptimize=ReleaseFast
  } finally {
    Pop-Location
  }
  if ($LASTEXITCODE -ne 0) {
    throw "vantari release build failed with exit code $LASTEXITCODE"
  }
}

if (-not (Test-Path -LiteralPath $builtPath)) {
  throw "built executable not found: $builtPath"
}

$installDirectory = Split-Path -Parent $InstallPath
New-Item -ItemType Directory -Force -Path $installDirectory | Out-Null

# A running installed owner must drain through its authenticated owner route.
# Force-stopping an arbitrary process can leave a provider turn, child kernel,
# or durable lease mid-flight. If the projection cannot prove ownership of the
# exact process and current workspace, fail closed and preserve the old binary.
function Get-InstalledExecutableProcesses {
  param(
    [Parameter(Mandatory = $true)][string]$ExecutablePath
  )

  $target = [System.IO.Path]::GetFullPath($ExecutablePath)
  $name = [System.IO.Path]::GetFileNameWithoutExtension($target)
  $processes = Get-Process -Name $name -ErrorAction SilentlyContinue | Where-Object {
    $_.Path -and [string]::Equals([System.IO.Path]::GetFullPath($_.Path), $target, [StringComparison]::OrdinalIgnoreCase)
  }

  return @($processes)
}

function Read-MatchingOwnerState {
  param(
    [Parameter(Mandatory = $true)][string]$StatePath,
    [Parameter(Mandatory = $true)]$Process,
    [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
    [Parameter(Mandatory = $true)][string]$ExecutablePath
  )

  if (-not (Test-Path -LiteralPath $StatePath)) {
    return $null
  }

  try {
    $state = Get-Content -Raw -LiteralPath $StatePath | ConvertFrom-Json
    $stateWorkspace = [IO.Path]::GetFullPath([string]$state.workspace_root)
    $expectedWorkspace = [IO.Path]::GetFullPath($WorkspaceRoot)
    $stateExecutable = [IO.Path]::GetFullPath([string]$state.executable_path)
    $targetExecutable = [IO.Path]::GetFullPath($ExecutablePath)
    if ([int]$state.pid -ne $Process.Id) { return $null }
    if (-not $stateWorkspace.Equals($expectedWorkspace, [StringComparison]::OrdinalIgnoreCase)) { return $null }
    if (-not $stateExecutable.Equals($targetExecutable, [StringComparison]::OrdinalIgnoreCase)) { return $null }
    if ([int]$state.port -le 0 -or [string]::IsNullOrWhiteSpace([string]$state.token)) { return $null }
    return $state
  } catch {
    return $null
  }
}

function Stop-InstalledExecutableProcesses {
  param(
    [Parameter(Mandatory = $true)][string]$ExecutablePath,
    [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
    [Parameter(Mandatory = $true)][string]$OwnerStatePath
  )

  $processes = @(Get-InstalledExecutableProcesses -ExecutablePath $ExecutablePath)
  if ($processes.Count -eq 0) {
    return
  }

  $ownerMatches = @(
    foreach ($process in $processes) {
      $state = Read-MatchingOwnerState `
        -StatePath $OwnerStatePath `
        -Process $process `
        -WorkspaceRoot $WorkspaceRoot `
        -ExecutablePath $ExecutablePath
      if ($null -ne $state) {
        [pscustomobject]@{ Process = $process; State = $state }
      }
    }
  )
  if ($ownerMatches.Count -ne 1) {
    $processIds = @($processes | Select-Object -ExpandProperty Id) -join ','
    throw "installed executable is locked by pid(s)=$processIds, but exactly one matching authenticated owner projection was not found at $OwnerStatePath; refusing force-stop. Drain the owner through its shutdown route or stop it manually, then retry."
  }

  $ownerMatch = $ownerMatches[0]
  $process = $ownerMatch.Process
  $state = $ownerMatch.State
  try {
    $headers = @{ 'x-var1-owner-token' = [string]$state.token }
    $response = Invoke-RestMethod `
      -Method Post `
      -Uri "http://127.0.0.1:$($state.port)/owner/shutdown" `
      -Headers $headers `
      -TimeoutSec 5
    if ($response.status -ne 'accepted') {
      throw "owner shutdown returned status '$($response.status)'"
    }
  } catch {
    throw "could not gracefully stop installed owner pid=$($process.Id): $($_.Exception.Message)"
  }

  Write-Host "Gracefully stopping installed owner pid=$($process.Id) port=$($state.port) workspace=$($state.workspace_root)"
  $deadline = [DateTime]::UtcNow.AddSeconds(15)
  do {
    $remaining = @(Get-InstalledExecutableProcesses -ExecutablePath $ExecutablePath)
    if ($remaining.Count -eq 0) { break }
    Start-Sleep -Milliseconds 100
  } while ([DateTime]::UtcNow -lt $deadline)
  if ($remaining.Count -ne 0) {
    throw "installed owner shutdown did not drain the executable process tree: $(@($remaining | Select-Object -ExpandProperty Id) -join ',')"
  }
}

$ownerStatePath = Join-Path $repoRoot ".var\runtime\execution-owner.json"
Stop-InstalledExecutableProcesses `
  -ExecutablePath $InstallPath `
  -WorkspaceRoot $repoRoot `
  -OwnerStatePath $ownerStatePath

# Stage-copy with backup so a failed move doesn't corrupt the existing binary.
$stagingPath = "$InstallPath.$PID.tmp"
$backupPath = "$InstallPath.$(Get-Date -Format 'yyyyMMdd-HHmmss').bak"

try {
  Copy-Item -LiteralPath $builtPath -Destination $stagingPath -Force

  if (Test-Path -LiteralPath $InstallPath) {
    Copy-Item -LiteralPath $InstallPath -Destination $backupPath -Force
  }

  Move-Item -LiteralPath $stagingPath -Destination $InstallPath -Force
} catch {
  if (Test-Path -LiteralPath $stagingPath) {
    Remove-Item -LiteralPath $stagingPath -Force -ErrorAction SilentlyContinue
  }
  throw "could not install vantari. The installed binary may be running or locked: $($_.Exception.Message)"
}

$builtHash = (Get-FileHash -LiteralPath $builtPath -Algorithm SHA256).Hash
$installedHash = (Get-FileHash -LiteralPath $InstallPath -Algorithm SHA256).Hash
if ($builtHash -ne $installedHash) {
  throw "installed hash mismatch: built=$builtHash installed=$installedHash"
}

& $InstallPath --help *> $null
if ($LASTEXITCODE -ne 0) {
  throw "installed vantari failed --help with exit code $LASTEXITCODE"
}

# Seed provider auth and set VANTARI_HOME for user-home storage.
# Production uses ~/.vantari (or %USERPROFILE%\.vantari on Windows).
$vantariHome = Join-Path $env:USERPROFILE ".vantari"
New-Item -ItemType Directory -Force -Path $vantariHome | Out-Null

# Set VANTARI_HOME user env var so all vantari processes use the user-home root.
[Environment]::SetEnvironmentVariable("VANTARI_HOME", $vantariHome, "User")
$env:VANTARI_HOME = $vantariHome

# Seed the canonical non-secret runtime configuration next to auth.json.
$configTemplate = Join-Path $backendRoot "src\core\config\default.json"
$installedConfig = Join-Path $vantariHome "config.json"
$configInstallStatus = "Retained existing runtime config -> $installedConfig"

function Test-InstalledRuntimeConfig {
  param(
    [Parameter(Mandatory = $true)][string]$ExecutablePath
  )

  $previousPreference = $ErrorActionPreference
  try {
    # Invalid config is the expected negative branch of this probe. PowerShell
    # 5 promotes native stderr to NativeCommandError under Stop, so suppress
    # only this command's output and inspect its process exit code directly.
    $ErrorActionPreference = "Continue"
    & $ExecutablePath config validate 1> $null 2> $null
    return $LASTEXITCODE -eq 0
  } finally {
    $ErrorActionPreference = $previousPreference
  }
}

if (!(Test-Path -LiteralPath $installedConfig)) {
  Copy-Item -LiteralPath $configTemplate -Destination $installedConfig -Force
  $configInstallStatus = "Seeded runtime config -> $installedConfig"
} else {
  # Retain valid operator-owned config verbatim. An invalid legacy file cannot
  # hot-load the current agent registry, so preserve it as a recoverable backup
  # and materialize the complete current schema. Carry the one known v1 rename
  # (`context.auto_compact` -> `context.auto_compaction`) forward.
  if (-not (Test-InstalledRuntimeConfig -ExecutablePath $InstallPath)) {
    $configBackup = "$installedConfig.$(Get-Date -Format 'yyyyMMdd-HHmmss').bak"
    $legacyAutoCompaction = $null
    try {
      $legacyDocument = Get-Content -LiteralPath $installedConfig -Raw | ConvertFrom-Json
      if ($null -ne $legacyDocument.context) {
        $legacyProperty = $legacyDocument.context.PSObject.Properties['auto_compact']
        if ($null -eq $legacyProperty) {
          $legacyProperty = $legacyDocument.context.PSObject.Properties['auto_compaction']
        }
        if ($null -ne $legacyProperty -and $legacyProperty.Value -is [bool]) {
          $legacyAutoCompaction = [bool]$legacyProperty.Value
        }
      }
    } catch {
      # The byte-identical backup remains the recovery owner for malformed JSON.
    }

    Copy-Item -LiteralPath $installedConfig -Destination $configBackup -Force
    Copy-Item -LiteralPath $configTemplate -Destination $installedConfig -Force
    if ($legacyAutoCompaction -eq $false) {
      $materializedConfig = Get-Content -LiteralPath $installedConfig -Raw
      $materializedConfig = $materializedConfig.Replace('"auto_compaction": true', '"auto_compaction": false')
      [System.IO.File]::WriteAllText($installedConfig, $materializedConfig, [System.Text.UTF8Encoding]::new($false))
    }

    if (-not (Test-InstalledRuntimeConfig -ExecutablePath $InstallPath)) {
      Copy-Item -LiteralPath $configBackup -Destination $installedConfig -Force
      throw "materialized runtime config failed validation; restored $configBackup"
    }
    $configInstallStatus = "Migrated invalid runtime config -> $installedConfig (backup: $configBackup)"
  }
}

# Seed provider auth as ~/.vantari/auth.json. Nested and AppData locations are
# migration inputs only; the runtime never writes new credentials there.
$sourceAuth = Join-Path $backendRoot ".var\auth\auth.json"
$installedAuth = Join-Path $vantariHome "auth.json"
$legacyHomeAuth = Join-Path $vantariHome "auth\auth.json"
$legacyAppDataAuth = Join-Path $env:LOCALAPPDATA "Vantari\auth\auth.json"
$authInstallStatus = "No repository auth ledger found; configure provider auth before model execution."
if (Test-Path -LiteralPath $installedAuth) {
  $authInstallStatus = "Retained existing provider auth -> $installedAuth"
}
elseif (Test-Path -LiteralPath $legacyHomeAuth) {
  Move-Item -LiteralPath $legacyHomeAuth -Destination $installedAuth
  $authInstallStatus = "Migrated provider auth -> $installedAuth"
}
elseif (Test-Path -LiteralPath $legacyAppDataAuth) {
  Move-Item -LiteralPath $legacyAppDataAuth -Destination $installedAuth
  $authInstallStatus = "Migrated provider auth -> $installedAuth"
}
elseif (Test-Path -LiteralPath $sourceAuth) {
  Copy-Item -LiteralPath $sourceAuth -Destination $installedAuth -Force
  $authInstallStatus = "Seeded installed provider auth -> $installedAuth"
}

# Add install dir to PATH if not already present.
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
$pathParts = @()
if ($userPath) {
  $pathParts = $userPath -split ';' | Where-Object { $_ -ne "" }
}

$alreadyPresent = $false
foreach ($part in $pathParts) {
  if ([string]::Equals($part.TrimEnd('\'), $installDirectory.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
    $alreadyPresent = $true
    break
  }
}

if (!$alreadyPresent) {
  $nextPath = if ($userPath) { "$installDirectory;$userPath" } else { $installDirectory }
  [Environment]::SetEnvironmentVariable("Path", $nextPath, "User")
}

Write-Output "installed: $InstallPath"
Write-Output "sha256: $installedHash"
Write-Output $configInstallStatus
Write-Output $authInstallStatus
if (Test-Path -LiteralPath $backupPath) {
  Write-Output "backup: $backupPath"
}
Write-Output "Default workspace resolves from the current terminal directory."
Write-Output "Optional custom workspace: vantari workspace set <path>"
Write-Output "PowerShell reserves bare 'var'; use 'var.exe' or 'vantari' in PowerShell."
