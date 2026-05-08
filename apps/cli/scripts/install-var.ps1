$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$cliRoot = Split-Path -Parent $scriptDir
$repoRoot = Split-Path -Parent (Split-Path -Parent $cliRoot)
$zigw = Join-Path $repoRoot "apps/backend/scripts/zigw.ps1"

Push-Location $cliRoot
try {
    & $zigw build --summary all
}
finally {
    Pop-Location
}

$varSource = Join-Path $cliRoot "zig-out/bin/var.exe"
$vantariSource = Join-Path $cliRoot "zig-out/bin/vantari.exe"
if (!(Test-Path -LiteralPath $varSource)) {
    throw "var.exe was not produced at $varSource"
}
if (!(Test-Path -LiteralPath $vantariSource)) {
    throw "vantari.exe was not produced at $vantariSource"
}

$installDir = Join-Path $env:LOCALAPPDATA "Vantari/bin"
New-Item -ItemType Directory -Force -Path $installDir | Out-Null

$varTarget = Join-Path $installDir "var.exe"
$vantariTarget = Join-Path $installDir "vantari.exe"
$workspaceTarget = Join-Path $installDir "workspace.txt"
Copy-Item -LiteralPath $varSource -Destination $varTarget -Force
Copy-Item -LiteralPath $vantariSource -Destination $vantariTarget -Force

$legacyDefaultWorkspace = Join-Path $repoRoot "apps/backend"
if (Test-Path -LiteralPath $workspaceTarget) {
    $currentWorkspaceBinding = (Get-Content -LiteralPath $workspaceTarget -Raw).Trim()
    if ([string]::Equals($currentWorkspaceBinding.TrimEnd('\'), $legacyDefaultWorkspace.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $workspaceTarget -Force
    }
}

$sourceAuth = Join-Path $repoRoot "apps/backend/.var/auth/auth.json"
$installedAuthDir = Join-Path $env:LOCALAPPDATA "Vantari/auth"
$installedAuth = Join-Path $installedAuthDir "auth.json"
$authInstallStatus = "No repository auth ledger found; configure provider auth before model execution."
if (Test-Path -LiteralPath $sourceAuth) {
    New-Item -ItemType Directory -Force -Path $installedAuthDir | Out-Null
    if (Test-Path -LiteralPath $installedAuth) {
        $authInstallStatus = "Retained existing installed provider auth -> $installedAuth"
    }
    else {
        Copy-Item -LiteralPath $sourceAuth -Destination $installedAuth -Force
        $authInstallStatus = "Seeded installed provider auth -> $installedAuth"
    }
}

$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
$pathParts = @()
if ($userPath) {
    $pathParts = $userPath -split ';' | Where-Object { $_ -ne "" }
}

$alreadyPresent = $false
foreach ($part in $pathParts) {
    if ([string]::Equals($part.TrimEnd('\'), $installDir.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
        $alreadyPresent = $true
        break
    }
}

if (!$alreadyPresent) {
    $nextPath = if ($userPath) { "$installDir;$userPath" } else { $installDir }
    [Environment]::SetEnvironmentVariable("Path", $nextPath, "User")
}

if (($env:Path -split ';') -notcontains $installDir) {
    $env:Path = "$installDir;$env:Path"
}

Write-Host "Installed var.exe -> $varTarget"
Write-Host "Installed vantari.exe -> $vantariTarget"
Write-Host $authInstallStatus
Write-Host "Default workspace resolves from the current terminal directory."
Write-Host "Optional custom workspace: vantari workspace set <path>"
Write-Host "PowerShell reserves bare 'var'; use 'var.exe' or 'vantari' in PowerShell."
