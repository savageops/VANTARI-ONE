[CmdletBinding()]
param(
  [string]$InstalledExe = (Join-Path $env:LOCALAPPDATA "Vantari\bin\vantari.exe")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$backendRoot = Split-Path -Parent $scriptDir
$sourceExe = Join-Path $backendRoot "zig-out\bin\vantari.exe"

if (-not (Test-Path -LiteralPath $InstalledExe -PathType Leaf)) {
  throw "Installed executable not found: $InstalledExe"
}
if (-not (Test-Path -LiteralPath $sourceExe -PathType Leaf)) {
  throw "ReleaseFast source executable not found: $sourceExe"
}

$installedFullPath = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $InstalledExe).Path)
$sourceHash = (Get-FileHash -LiteralPath $sourceExe -Algorithm SHA256).Hash
$installedHash = (Get-FileHash -LiteralPath $installedFullPath -Algorithm SHA256).Hash
if ($sourceHash -ne $installedHash) {
  throw "Source/installed hash mismatch: source=$sourceHash installed=$installedHash"
}

$installedName = [IO.Path]::GetFileNameWithoutExtension($installedFullPath)
$preexisting = @(Get-Process -Name $installedName -ErrorAction SilentlyContinue | Where-Object {
    $_.Path -and [IO.Path]::GetFullPath($_.Path) -ieq $installedFullPath
  })
if ($preexisting.Count -ne 0) {
  throw "Refusing proof while installed VANTARI is active: $([string]::Join(',', @($preexisting | ForEach-Object Id)))"
}

$proofRoot = Join-Path $env:TEMP ("vantari-installed-provider-selector-" + [Guid]::NewGuid().ToString("N"))
$proofWorkspace = Join-Path $proofRoot "workspace"
$priorVantariHome = $env:VANTARI_HOME
$priorVantariWorkspace = $env:VANTARI_WORKSPACE
$selectorExit = $null
$selectorOutput = ""

try {
  New-Item -ItemType Directory -Force -Path $proofWorkspace | Out-Null

  $helpOutput = (& $installedFullPath run --help 2>&1 | Out-String)
  if ($LASTEXITCODE -ne 0) { throw "Installed run --help failed with exit code $LASTEXITCODE" }
  if (-not $helpOutput.Contains("--provider <id>")) { throw "Installed help omitted --provider" }
  if (-not $helpOutput.Contains("--model <id|provider/id>")) { throw "Installed help omitted provider/model selector" }

  $env:VANTARI_HOME = $proofRoot
  $env:VANTARI_WORKSPACE = $proofWorkspace
  $selectorOutput = (& $installedFullPath run --prompt "provider selector negative probe" --model "anthropic/claude-sonnet" --json --no-agent-tools 2>&1 | Out-String).Trim()
  $selectorExit = $LASTEXITCODE
  if ($selectorExit -eq 0) { throw "Provider selector unexpectedly reached a completion without credentials" }
  if (-not ($selectorOutput.Contains("anthropic") -or $selectorOutput.Contains("provider") -or $selectorOutput.Contains("auth"))) {
    throw "Provider selector negative path did not report a provider/auth boundary: $selectorOutput"
  }

  [pscustomobject]@{
    schema = "var1.installed_provider_model_selector_proof.v1"
    source_sha256 = $sourceHash
    installed_sha256 = $installedHash
    hashes_match = $true
    help_has_provider = $helpOutput.Contains("--provider <id>")
    help_has_provider_model_selector = $helpOutput.Contains("--model <id|provider/id>")
    selector = "anthropic/claude-sonnet"
    selector_exit_code = $selectorExit
    selector_fail_closed = $true
    selector_output = $selectorOutput
  } | ConvertTo-Json -Compress
}
finally {
  $env:VANTARI_HOME = $priorVantariHome
  $env:VANTARI_WORKSPACE = $priorVantariWorkspace

  Start-Sleep -Milliseconds 200
  $leftovers = @(Get-Process -Name $installedName -ErrorAction SilentlyContinue | Where-Object {
      $_.Path -and [IO.Path]::GetFullPath($_.Path) -ieq $installedFullPath
    })
  if ($leftovers.Count -ne 0) {
    throw "Installed provider selector left VANTARI processes: $([string]::Join(',', @($leftovers | ForEach-Object Id)))"
  }

  $resolvedProofRoot = [IO.Path]::GetFullPath($proofRoot)
  $tempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd("\") + "\"
  if (-not $resolvedProofRoot.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing cleanup outside temp root: $resolvedProofRoot"
  }
  if (Test-Path -LiteralPath $resolvedProofRoot) {
    [IO.Directory]::Delete($resolvedProofRoot, $true)
  }
}
