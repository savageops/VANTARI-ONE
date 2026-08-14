[CmdletBinding()]
param(
  [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path,
  [string]$SourceBinary = 'apps/backend/zig-out/bin/vantari.exe',
  [string]$InstalledBinary = 'C:\Users\Savage\AppData\Local\Vantari\bin\vantari.exe',
  [string]$OutputPath = '.docs/research/2026-08-14-roadmap-24-release-manifest.json',
  [switch]$RunTests,
  [switch]$BuildReleaseFast,
  [switch]$ProbeKernel
)

$ErrorActionPreference = 'Stop'

function Resolve-RepoPath([string]$Path) {
  if ([IO.Path]::IsPathRooted($Path)) {
    return [IO.Path]::GetFullPath($Path)
  }
  return [IO.Path]::GetFullPath((Join-Path $RepoRoot $Path))
}

function Relative-RepoPath([string]$Path) {
  return ([IO.Path]::GetRelativePath($RepoRoot, $Path) -replace '\\', '/')
}

function Get-FileEvidence([string]$Path) {
  $resolved = Resolve-RepoPath $Path
  if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
    return [ordered]@{
      path = Relative-RepoPath $resolved
      status = 'missing'
    }
  }

  $item = Get-Item -LiteralPath $resolved
  return [ordered]@{
    path = Relative-RepoPath $resolved
    status = 'present'
    bytes = $item.Length
    sha256 = (Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash
    last_write_utc = $item.LastWriteTimeUtc.ToString('o')
  }
}

function Invoke-TestProof {
  $zigw = Resolve-RepoPath 'apps/backend/scripts/zigw.ps1'
  $backendRoot = Resolve-RepoPath 'apps/backend'
  Push-Location -LiteralPath $backendRoot
  try {
    $output = (& pwsh -NoProfile -File $zigw build test --summary all 2>&1 | Out-String)
  } finally {
    Pop-Location
  }
  $exitCode = $LASTEXITCODE
  $summary = [regex]::Match($output, 'Build Summary: (\d+)/(\d+) steps succeeded; (\d+)/(\d+) tests passed')
  return [ordered]@{
    status = if ($exitCode -eq 0 -and $summary.Success) { 'passed' } else { 'failed' }
    exit_code = $exitCode
    steps_passed = if ($summary.Success) { [int]$summary.Groups[1].Value } else { $null }
    steps_total = if ($summary.Success) { [int]$summary.Groups[2].Value } else { $null }
    tests_passed = if ($summary.Success) { [int]$summary.Groups[3].Value } else { $null }
    tests_total = if ($summary.Success) { [int]$summary.Groups[4].Value } else { $null }
    output_sha256 = ([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($output)) | ForEach-Object ToString x2) -join ''
  }
}

function Invoke-ReleaseBuild {
  $zigw = Resolve-RepoPath 'apps/backend/scripts/zigw.ps1'
  $backendRoot = Resolve-RepoPath 'apps/backend'
  Push-Location -LiteralPath $backendRoot
  try {
    # Zig's build graph seed defaults to random and changes dependency
    # traversal/link layout. Pin the release artifact so source/installed
    # identity remains a meaningful promotion gate.
    $output = (& pwsh -NoProfile -File $zigw build -Doptimize=ReleaseFast --seed 0 2>&1 | Out-String)
  } finally {
    Pop-Location
  }
  $exitCode = $LASTEXITCODE
  return [ordered]@{
    status = if ($exitCode -eq 0) { 'passed' } else { 'failed' }
    exit_code = $exitCode
    seed = 0
    output_sha256 = ([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($output)) | ForEach-Object ToString x2) -join ''
  }
}

function Stop-ProbeOwner([string]$ProjectionPath, [string]$SourcePath, [object]$BeforeState) {
  if (-not (Test-Path -LiteralPath $ProjectionPath -PathType Leaf)) {
    return [ordered]@{ status = 'missing' }
  }

  $state = Get-Content -LiteralPath $ProjectionPath -Raw | ConvertFrom-Json
  $sameExecutable = [IO.Path]::GetFullPath([string]$state.executable_path) -ieq [IO.Path]::GetFullPath($SourcePath)
  $sameBefore = $null -ne $BeforeState -and
    [string]$BeforeState.generation -eq [string]$state.generation -and
    [int]$BeforeState.pid -eq [int]$state.pid
  if (-not $sameExecutable) {
    return [ordered]@{ status = 'preserved_non_source_owner'; pid = $state.pid }
  }
  if ($sameBefore) {
    return [ordered]@{ status = 'preserved_preexisting_owner'; pid = $state.pid }
  }

  if (-not (Get-Process -Id ([int]$state.pid) -ErrorAction SilentlyContinue)) {
    Remove-Item -LiteralPath $ProjectionPath -Force
    return [ordered]@{ status = 'stale_probe_projection_removed'; pid = $state.pid }
  }

  try {
    $headers = @{ 'x-var1-owner-token' = [string]$state.token }
    $response = Invoke-WebRequest -UseBasicParsing -Method Post `
      -Uri "http://127.0.0.1:$($state.port)/owner/shutdown" `
      -Headers $headers -ContentType 'application/json' -Body '{}'
    $statusCode = [int]$response.StatusCode
  } catch {
    return [ordered]@{ status = 'shutdown_failed'; pid = $state.pid; detail = $_.Exception.Message }
  }

  $processId = [int]$state.pid
  for ($index = 0; $index -lt 40; $index++) {
    if (-not (Get-Process -Id $processId -ErrorAction SilentlyContinue)) {
      if (Test-Path -LiteralPath $ProjectionPath -PathType Leaf) {
        Remove-Item -LiteralPath $ProjectionPath -Force
      }
      return [ordered]@{ status = 'stopped'; pid = $processId; response_status = $statusCode }
    }
    Start-Sleep -Milliseconds 250
  }
  return [ordered]@{ status = 'still_alive'; pid = $processId; response_status = $statusCode }
}

function Wait-ExactPathProcessDrain([string]$ExecutablePath, [int]$TimeoutMilliseconds = 5000) {
  # Owner shutdown is asynchronous. Give proof-owned children a bounded,
  # non-mutating drain window before recording the installed-process census;
  # persistent or user-owned processes remain visible and block promotion.
  $fullPath = [IO.Path]::GetFullPath($ExecutablePath)
  $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
  do {
    $live = @(
      Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -and [IO.Path]::GetFullPath($_.ExecutablePath) -ieq $fullPath }
    )
    if ($live.Count -eq 0) { return }
    Start-Sleep -Milliseconds 250
  } while ([DateTime]::UtcNow -lt $deadline)
}

$installedEvidence = Get-FileEvidence $InstalledBinary

$testEvidence = if ($RunTests) { Invoke-TestProof } else {
  [ordered]@{ status = 'not_run'; reason = 'Invoke with -RunTests to refresh the current graph.' }
}

$releaseBuild = if ($BuildReleaseFast) { Invoke-ReleaseBuild } else {
  [ordered]@{ status = 'not_run'; reason = 'Invoke with -BuildReleaseFast to refresh the ReleaseFast artifact.' }
}

# Read the binary after every requested build. The test graph can update the
# default output artifact, so the manifest must hash the final ReleaseFast
# consumer rather than a pre-test path snapshot.
$sourceEvidence = Get-FileEvidence $SourceBinary
$hashMatch = $sourceEvidence.status -eq 'present' -and
  $installedEvidence.status -eq 'present' -and
  $sourceEvidence.sha256 -eq $installedEvidence.sha256

$toolRoot = Resolve-RepoPath 'apps/backend/src/core/tools'
$toolDefinitions = @(
  Get-ChildItem -LiteralPath $toolRoot -Filter '*.zig' -Recurse -File |
    Sort-Object FullName |
    ForEach-Object {
      [ordered]@{
        path = Relative-RepoPath $_.FullName
        sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
      }
    }
)

$capabilityProbe = [ordered]@{
  owner = 'apps/backend/src/shared/types.zig:ToolDefinition.availability + apps/backend/src/core/tools/registry.zig'
  status = 'not_run'
  command = "$SourceBinary tools --json"
  reason = 'Run only through an authenticated owner; the current installed owner pair is preserved and source/installed promotion is blocked.'
}
if ($ProbeKernel) {
  $binaryPath = Resolve-RepoPath $SourceBinary
  $probeWorkspace = if ($env:VANTARI_WORKSPACE) {
    [IO.Path]::GetFullPath((Join-Path (Get-Location).Path $env:VANTARI_WORKSPACE))
  } else {
    (Get-Location).Path
  }
  $probeProjectionPath = [IO.Path]::GetFullPath((Join-Path $probeWorkspace '.var/runtime/execution-owner.json'))
  $beforeProbeState = if (Test-Path -LiteralPath $probeProjectionPath -PathType Leaf) {
    Get-Content -LiteralPath $probeProjectionPath -Raw | ConvertFrom-Json
  } else { $null }
  $previousProbeHome = [Environment]::GetEnvironmentVariable('VANTARI_HOME', 'Process')
  try {
    # The capability catalog is read-only. Remove the process-only global-home
    # override so the explicit workspace resolves its canonical .var auth and
    # config owners instead of probing an empty second runtime root.
    Remove-Item Env:VANTARI_HOME -ErrorAction SilentlyContinue
    $probeOutput = (& $binaryPath tools --json 2>&1 | Out-String)
    $probeExit = $LASTEXITCODE
  } finally {
    if ($null -eq $previousProbeHome) {
      Remove-Item Env:VANTARI_HOME -ErrorAction SilentlyContinue
    } else {
      $env:VANTARI_HOME = $previousProbeHome
    }
  }
  $probeCleanup = Stop-ProbeOwner $probeProjectionPath $binaryPath $beforeProbeState
  $capabilityProbe = [ordered]@{
    owner = 'apps/backend/src/shared/types.zig:ToolDefinition.availability + apps/backend/src/core/tools/registry.zig'
    status = if ($probeExit -eq 0) { 'passed' } else { 'failed' }
    exit_code = $probeExit
    output_sha256 = ([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($probeOutput)) | ForEach-Object ToString x2) -join ''
    runtime_root = '.var (VANTARI_HOME unset)'
    cleanup = $probeCleanup
  }
}

$proofRoot = Resolve-RepoPath 'apps/backend/scripts'
$proofScripts = @(
  Get-ChildItem -LiteralPath $proofRoot -Filter '*.ps1' -File |
    Where-Object { $_.Name -match '^(prove|verify|install|write-release)' } |
    Sort-Object Name |
    ForEach-Object { Relative-RepoPath $_.FullName }
)

$requiredDocs = @(
  '.docs/index.md',
  '.docs/technical_summary.md',
  '.docs/workspace.json',
  '.refs/index.md',
  '.docs/roadmap/24-harness-capability-next-90.md',
  '.docs/research/2026-08-14-roadmap-24-full-checklist.md',
  '.docs/research/2026-08-14-roadmap-24-provider-probe.md',
  '.docs/research/2026-08-14-roadmap-24-completion-audit.md',
  '.docs/research/2026-08-14-roadmap-24-installed-frontier-proof.json',
  '.docs/research/2026-08-14-roadmap-24-installed-input-response.json',
  '.docs/research/2026-08-14-roadmap-24-installed-write-effect.json'
) | ForEach-Object { Get-FileEvidence $_ }

$providerProbe = Get-FileEvidence '.docs/research/2026-08-14-roadmap-24-provider-probe.md'
$inputResponseProof = Get-FileEvidence '.docs/research/2026-08-14-roadmap-24-installed-input-response.json'
$writeEffectProof = Get-FileEvidence '.docs/research/2026-08-14-roadmap-24-installed-write-effect.json'

$installedProcesses = @()
if ($installedEvidence.status -eq 'present') {
  $installedFullPath = [IO.Path]::GetFullPath((Resolve-RepoPath $InstalledBinary))
  if ($ProbeKernel -and $capabilityProbe.cleanup.status -eq 'stopped') {
    Wait-ExactPathProcessDrain $installedFullPath
  }
  $installedProcesses = @(
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
      Where-Object { $_.ExecutablePath -and [IO.Path]::GetFullPath($_.ExecutablePath) -ieq $installedFullPath } |
      Sort-Object ProcessId |
      ForEach-Object {
        [ordered]@{
          pid = $_.ProcessId
          parent_pid = $_.ParentProcessId
          command_line = $_.CommandLine
          created_at = $_.CreationDate
        }
      }
  )
}

$blockedBy = [System.Collections.Generic.List[string]]::new()
if ($sourceEvidence.status -ne 'present') { $blockedBy.Add('source ReleaseFast binary is missing') }
if ($installedEvidence.status -ne 'present') { $blockedBy.Add('installed binary is missing') }
if (-not $hashMatch) { $blockedBy.Add('source and installed SHA-256 differ') }
if ($installedProcesses.Count -gt 0) { $blockedBy.Add('installed executable has preserved live process owners') }
if ($testEvidence.status -ne 'passed') { $blockedBy.Add('current full test graph is not freshly passed') }
if ($releaseBuild.status -ne 'passed') { $blockedBy.Add('current ReleaseFast build was not freshly passed') }
if ($inputResponseProof.status -ne 'present') { $blockedBy.Add('installed provider-driven input proof is missing') }
if ($writeEffectProof.status -ne 'present') { $blockedBy.Add('installed provider-driven write/effect proof is missing') }
if ($ProbeKernel -and $capabilityProbe.cleanup.status -notin @('stopped', 'missing', 'stale_probe_projection_removed', 'preserved_preexisting_owner', 'preserved_non_source_owner')) {
  $blockedBy.Add('source capability probe owner did not cleanly shut down')
}

$manifest = [ordered]@{
  type = 'var1.release_manifest.v1'
  generated_at_utc = [DateTime]::UtcNow.ToString('o')
  repo_root = $RepoRoot
  source = $sourceEvidence
  installed = $installedEvidence
  source_installed_hash_match = $hashMatch
  tests = $testEvidence
  release_build = $releaseBuild
  capability_probe = $capabilityProbe
  provider_probe = $providerProbe
  input_response_proof = $inputResponseProof
  write_effect_proof = $writeEffectProof
  tool_definition_sources = $toolDefinitions
  proof_scripts = $proofScripts
  required_docs = $requiredDocs
  installed_processes = $installedProcesses
  promotion = [ordered]@{
    status = if ($blockedBy.Count -eq 0) { 'promotable' } else { 'blocked' }
    blocked_by = @($blockedBy)
    mutation_allowed = $false
  }
  reference_pressure = [ordered]@{
    owner = 'apps/backend/scripts/ref-pressure.sh'
    status = 'deferred'
    reason = 'Run the canonical shell script in its supported shell to refresh reference drift.'
  }
}

$outputFile = Resolve-RepoPath $OutputPath
$outputDirectory = Split-Path -Parent $outputFile
New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
$json = $manifest | ConvertTo-Json -Depth 12
[IO.File]::WriteAllText($outputFile, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))

Write-Output ("manifest={0}" -f (Relative-RepoPath $outputFile))
Write-Output ("status={0}" -f $manifest.promotion.status)
Write-Output ("release_build={0}" -f $releaseBuild.status)
Write-Output ("source_sha256={0}" -f ($sourceEvidence.sha256 ?? 'missing'))
Write-Output ("installed_sha256={0}" -f ($installedEvidence.sha256 ?? 'missing'))
Write-Output ("preserved_installed_processes={0}" -f $installedProcesses.Count)

if ($manifest.promotion.status -ne 'promotable') { exit 2 }
