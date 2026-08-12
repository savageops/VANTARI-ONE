[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$BinaryPath,

  [ValidateSet('execution-owner', 'serve')]
  [string]$EntryPoint = 'execution-owner'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$backendRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$resolvedBinary = (Resolve-Path -LiteralPath $BinaryPath).Path
$binaryName = [IO.Path]::GetFileName($resolvedBinary)
$proofBase = Join-Path $backendRoot '.zig-cache\owner-proofs'
New-Item -ItemType Directory -Force -Path $proofBase | Out-Null
$resolvedBase = (Resolve-Path -LiteralPath $proofBase).Path
$proofRoot = Join-Path $resolvedBase ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $proofRoot | Out-Null
$resolvedProof = (Resolve-Path -LiteralPath $proofRoot).Path
$requiredPrefix = $resolvedBase.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
if (-not $resolvedProof.StartsWith($requiredPrefix, [StringComparison]::OrdinalIgnoreCase)) {
  throw "Proof root escaped the owner-proofs directory: $resolvedProof"
}

$owner = $null
$duplicateOwner = $null
$childIds = @()
$env:VANTARI_WORKSPACE = $resolvedProof
$env:VANTARI_HOME = Join-Path $resolvedProof '.var'

try {
  # `kernel-stdio` requires capability-truth provider configuration even for a
  # health-only probe. Seed the isolated workspace with repository-test values;
  # no live credential or provider request is used.
  $envFixture = @(
    'BASE_URL=http://127.0.0.1:1'
    'API_KEY=owner-tracer-test-key'
    'MODEL=owner-tracer-model'
    "WORKSPACE=$resolvedProof"
  )
  [IO.File]::WriteAllLines((Join-Path $resolvedProof '.env'), $envFixture)

  & $resolvedBinary config init | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Config initialization failed with exit code $LASTEXITCODE"
  }

  $stdoutPath = Join-Path $resolvedProof 'owner.stdout.log'
  $stderrPath = Join-Path $resolvedProof 'owner.stderr.log'
  $ownerArguments = if ($EntryPoint -eq 'serve') {
    @('serve', '--port', '0')
  } else {
    @('execution-owner', '--workspace', '.')
  }
  $workspaceBeforeSpawn = $env:VANTARI_WORKSPACE
  if ($EntryPoint -eq 'execution-owner') {
    $decoyWorkspace = Join-Path $resolvedProof 'decoy-workspace'
    New-Item -ItemType Directory -Path $decoyWorkspace | Out-Null
    $env:VANTARI_WORKSPACE = $decoyWorkspace
  }
  try {
    $owner = Start-Process `
      -FilePath $resolvedBinary `
      -ArgumentList $ownerArguments `
      -WorkingDirectory $resolvedProof `
      -WindowStyle Hidden `
      -RedirectStandardOutput $stdoutPath `
      -RedirectStandardError $stderrPath `
      -PassThru
  } finally {
    $env:VANTARI_WORKSPACE = $workspaceBeforeSpawn
  }

  $statePath = Join-Path $resolvedProof '.var\runtime\execution-owner.json'
  $readyDeadline = [DateTime]::UtcNow.AddSeconds(15)
  while (-not (Test-Path -LiteralPath $statePath)) {
    $owner.Refresh()
    if ($owner.HasExited) {
      $stderrText = if (Test-Path -LiteralPath $stderrPath) {
        (Get-Content -Raw -LiteralPath $stderrPath).Trim()
      } else {
        '<no stderr>'
      }
      throw "Owner exited before readiness with exit code $($owner.ExitCode): $stderrText"
    }
    if ([DateTime]::UtcNow -gt $readyDeadline) {
      throw 'Owner readiness projection timed out'
    }
    Start-Sleep -Milliseconds 100
  }

  $state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
  if ([int]$state.pid -ne $owner.Id) {
    throw "State PID mismatch: $($state.pid) != $($owner.Id)"
  }
  if ([int]$state.port -le 0) {
    throw 'Owner state did not publish a listening port'
  }
  if ([string]::IsNullOrWhiteSpace([string]$state.generation)) {
    throw 'Owner state did not publish a generation'
  }
  if ([string]::IsNullOrWhiteSpace([string]$state.token)) {
    throw 'Owner state did not publish an owner token'
  }
  if (-not ([string]$state.workspace_root).Equals($resolvedProof, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Owner workspace mismatch: $($state.workspace_root) != $resolvedProof"
  }

  $headers = @{ 'x-var1-owner-token' = [string]$state.token }
  $healthUri = "http://127.0.0.1:$($state.port)/owner/health"
  $healthDeadline = [DateTime]::UtcNow.AddSeconds(5)
  $health1 = $null
  while ($null -eq $health1) {
    try {
      $health1 = Invoke-RestMethod -Method Get -Uri $healthUri -Headers $headers
    } catch {
      if ([DateTime]::UtcNow -gt $healthDeadline) { throw }
      Start-Sleep -Milliseconds 50
    }
  }

  if ($health1.schema -ne 'var1.execution_owner.v1') {
    throw "Owner health schema mismatch: $($health1.schema)"
  }
  if ($health1.protocol -ne 'var1.owner_http.v1') {
    throw "Owner health protocol mismatch: $($health1.protocol)"
  }
  if ($health1.generation -ne $state.generation) {
    throw 'First client received a different owner generation'
  }
  $owner.Refresh()
  if ($owner.HasExited) {
    throw 'Owner exited when the first HTTP client detached'
  }

  $health2 = Invoke-RestMethod -Method Get -Uri $healthUri -Headers $headers
  if ($health2.generation -ne $state.generation) {
    throw 'Second client received a different owner generation'
  }
  $owner.Refresh()
  if ($owner.HasExited) {
    throw 'Owner exited when the second HTTP client detached'
  }

  $duplicateRejected = $null
  if ($EntryPoint -eq 'serve') {
    $duplicateStdoutPath = Join-Path $resolvedProof 'duplicate-owner.stdout.log'
    $duplicateStderrPath = Join-Path $resolvedProof 'duplicate-owner.stderr.log'
    $duplicateOwner = Start-Process `
      -FilePath $resolvedBinary `
      -ArgumentList $ownerArguments `
      -WorkingDirectory $resolvedProof `
      -WindowStyle Hidden `
      -RedirectStandardOutput $duplicateStdoutPath `
      -RedirectStandardError $duplicateStderrPath `
      -PassThru
    if (-not $duplicateOwner.WaitForExit(5000)) {
      throw 'Duplicate foreground owner did not fail within five seconds'
    }
    $duplicateStderr = Get-Content -Raw -LiteralPath $duplicateStderrPath
    if ($duplicateOwner.ExitCode -ne 2 -or $duplicateStderr -notmatch 'code=AlreadyRunning') {
      throw "Duplicate foreground owner escaped the lease: exit=$($duplicateOwner.ExitCode), stderr=$duplicateStderr"
    }
    $duplicateRejected = $true
  }

  $childDeadline = [DateTime]::UtcNow.AddSeconds(5)
  do {
    $childProcesses = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $($owner.Id)")
    $childIds = @($childProcesses | Select-Object -ExpandProperty ProcessId)
    $kernelChildren = @(
      $childProcesses | Where-Object {
        $_.Name -eq $binaryName -and $_.CommandLine -match '\skernel-stdio(?:\s|$)'
      }
    )
    if ($kernelChildren.Count -eq 1) { break }
    Start-Sleep -Milliseconds 100
  } while ([DateTime]::UtcNow -lt $childDeadline)
  if ($kernelChildren.Count -ne 1) {
    $childSummary = $childProcesses |
      Select-Object ProcessId, Name, CommandLine |
      ConvertTo-Json -Compress
    throw "Expected exactly one child kernel; found $($kernelChildren.Count): $childSummary"
  }
  $stateHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $statePath).Hash
  [pscustomobject]@{
    type = 'var1.owner_tracer_proof.v1'
    entry_point = $EntryPoint
    explicit_workspace_won = ([string]$state.workspace_root).Equals($resolvedProof, [StringComparison]::OrdinalIgnoreCase)
    owner_pid = $owner.Id
    child_pid = $kernelChildren[0].ProcessId
    os_host_child_pids = @(
      $childProcesses |
        Where-Object { $_.ProcessId -ne $kernelChildren[0].ProcessId } |
        Select-Object -ExpandProperty ProcessId
    )
    generation = $state.generation
    port = $state.port
    token_chars = ([string]$state.token).Length
    state_sha256 = $stateHash
    reconnect_same_generation = ($health2.generation -eq $health1.generation)
    owner_alive_after_two_clients = (-not $owner.HasExited)
    duplicate_owner_rejected = $duplicateRejected
    retained_evidence_root = $resolvedProof
    stdout_log = $stdoutPath
    stderr_log = $stderrPath
  } | ConvertTo-Json -Compress
} finally {
  if ($null -ne $duplicateOwner) {
    $duplicateOwner.Refresh()
    if (-not $duplicateOwner.HasExited) {
      Stop-Process -Id $duplicateOwner.Id -Force -ErrorAction SilentlyContinue
    }
  }
  if ($null -ne $owner) {
    $owner.Refresh()
    if (-not $owner.HasExited) {
      Stop-Process -Id $owner.Id -Force -ErrorAction SilentlyContinue
      Wait-Process -Id $owner.Id -Timeout 8 -ErrorAction SilentlyContinue
    }
  }

  $cleanupDeadline = [DateTime]::UtcNow.AddSeconds(8)
  do {
    $survivors = @(
      $childIds |
        Where-Object { $null -ne (Get-Process -Id $_ -ErrorAction SilentlyContinue) }
    )
    if ($survivors.Count -eq 0) { break }
    Start-Sleep -Milliseconds 50
  } while ([DateTime]::UtcNow -lt $cleanupDeadline)
  if ($survivors.Count -gt 0) {
    foreach ($childId in $survivors) {
      Stop-Process -Id $childId -Force -ErrorAction SilentlyContinue
    }
    throw "Proof child processes survived owner teardown: $($survivors -join ',')"
  }
}
