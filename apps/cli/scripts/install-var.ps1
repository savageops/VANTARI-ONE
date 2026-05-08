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
Write-Host "Default workspace resolves from the current terminal directory."
Write-Host "Optional custom workspace: vantari workspace set <path>"
Write-Host "PowerShell reserves bare 'var'; use 'var.exe' or 'vantari' in PowerShell."
