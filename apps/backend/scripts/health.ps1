[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Split-Path -Parent $scriptDir
$zigWrapper = Join-Path $scriptDir "zigw.ps1"
$exePath = Join-Path $rootDir "zig-out\bin\VAR1.exe"

function Write-Var1ProcessDiagnostics {
  param(
    [Parameter(Mandatory = $true)][string]$ExePath,
    [Parameter(Mandatory = $true)][string]$RootDir
  )

  if (-not (Get-Command Get-CimInstance -ErrorAction SilentlyContinue)) {
    return
  }

  $normalizedExePath = [System.IO.Path]::GetFullPath($ExePath).ToLowerInvariant()
  $normalizedRootDir = [System.IO.Path]::GetFullPath($RootDir).ToLowerInvariant()
  $processes = @(
    Get-CimInstance Win32_Process -Filter "name = 'VAR1.exe'" -ErrorAction SilentlyContinue |
      Where-Object {
        $commandLine = [string]$_.CommandLine
        $normalizedCommandLine = $commandLine.ToLowerInvariant()
        $normalizedCommandLine.Contains($normalizedExePath) -or
          ($normalizedCommandLine.Contains($normalizedRootDir) -and
            ($normalizedCommandLine.Contains("kernel-stdio") -or $normalizedCommandLine.Contains("serve")))
      }
  )

  if ($processes.Count -eq 0) {
    return
  }

  Write-Warning "Existing VAR1.exe processes may hold backend build or health locks:"
  foreach ($process in $processes) {
    Write-Warning ("PID {0}: {1}" -f $process.ProcessId, $process.CommandLine)
  }
}

Push-Location $rootDir
try {
  Write-Var1ProcessDiagnostics -ExePath $exePath -RootDir $rootDir

  & $zigWrapper build -Dtarget=x86_64-windows-gnu --summary all
  if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
  }

  & $exePath health
  exit $LASTEXITCODE
} finally {
  Pop-Location
}
