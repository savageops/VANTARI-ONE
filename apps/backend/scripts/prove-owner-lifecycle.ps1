[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$BinaryPath,

  [ValidateRange(2, 64)]
  [int]$ConcurrentClients = 20
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

$statePath = Join-Path $resolvedProof '.var\runtime\execution-owner.json'
$clients = @()
$ownedProcessIds = [Collections.Generic.HashSet[int]]::new()
$env:VANTARI_WORKSPACE = $resolvedProof
$env:VANTARI_HOME = Join-Path $resolvedProof '.var'

function Invoke-Health {
  $text = (& $resolvedBinary health --json 2>&1 | Out-String).Trim()
  if ($LASTEXITCODE -ne 0) {
    throw "Health failed with exit code $LASTEXITCODE`: $text"
  }
  $null = $text | ConvertFrom-Json
}

function Read-OwnerState {
  if (-not (Test-Path -LiteralPath $statePath)) {
    throw "Owner projection is missing: $statePath"
  }
  return Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
}

function Get-KernelChild([int]$OwnerProcessId) {
  $children = @(
    Get-CimInstance Win32_Process -Filter "ParentProcessId = $OwnerProcessId" |
      Where-Object {
        $_.Name -eq $binaryName -and $_.CommandLine -match '\skernel-stdio(?:\s|$)'
      }
  )
  if ($children.Count -ne 1) {
    throw "Expected one kernel child for owner $OwnerProcessId; found $($children.Count)"
  }
  return $children[0]
}

function Wait-ProcessTreeGone([int[]]$ProcessIds, [int]$TimeoutSeconds) {
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  do {
    $remaining = @(
      $ProcessIds |
        Sort-Object -Unique |
        Where-Object { $null -ne (Get-Process -Id $_ -ErrorAction SilentlyContinue) }
    )
    if ($remaining.Count -eq 0) { return $true }
    Start-Sleep -Milliseconds 50
  } while ([DateTime]::UtcNow -lt $deadline)
  return $false
}

function Stop-OwnerGracefully($State, [int]$KernelProcessId) {
  $headers = @{ 'x-var1-owner-token' = [string]$State.token }
  $response = Invoke-RestMethod `
    -Method Post `
    -Uri "http://127.0.0.1:$($State.port)/owner/shutdown" `
    -Headers $headers
  if ($response.status -ne 'accepted') {
    throw "Owner shutdown returned status '$($response.status)'"
  }
  $gone = Wait-ProcessTreeGone -ProcessIds @([int]$State.pid, $KernelProcessId) -TimeoutSeconds 15
  if (-not $gone) {
    throw "Owner tree did not drain: owner=$($State.pid), kernel=$KernelProcessId"
  }
  return [string]$response.status
}

try {
  [IO.File]::WriteAllLines((Join-Path $resolvedProof '.env'), @(
    'BASE_URL=http://127.0.0.1:1'
    'API_KEY=owner-lifecycle-test-key'
    'MODEL=owner-lifecycle-model'
    "WORKSPACE=$resolvedProof"
  ))
  & $resolvedBinary config init | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Config initialization failed with exit code $LASTEXITCODE"
  }

  for ($index = 1; $index -le $ConcurrentClients; $index += 1) {
    $stdoutPath = Join-Path $resolvedProof ("client-{0:D2}.stdout.json" -f $index)
    $stderrPath = Join-Path $resolvedProof ("client-{0:D2}.stderr.log" -f $index)
    $process = Start-Process `
      -FilePath $resolvedBinary `
      -ArgumentList @('health', '--json') `
      -WorkingDirectory $resolvedProof `
      -WindowStyle Hidden `
      -RedirectStandardOutput $stdoutPath `
      -RedirectStandardError $stderrPath `
      -PassThru
    $clients += [pscustomobject]@{
      Index = $index
      Process = $process
      Stdout = $stdoutPath
      Stderr = $stderrPath
    }
  }

  $clientDeadline = [DateTime]::UtcNow.AddSeconds(45)
  do {
    $runningClients = @(
      $clients | Where-Object {
        $_.Process.Refresh()
        -not $_.Process.HasExited
      }
    )
    if ($runningClients.Count -eq 0) { break }
    Start-Sleep -Milliseconds 50
  } while ([DateTime]::UtcNow -lt $clientDeadline)
  if ($runningClients.Count -ne 0) {
    throw "$($runningClients.Count) concurrent clients timed out"
  }

  $failedClients = @($clients | Where-Object { $_.Process.ExitCode -ne 0 })
  if ($failedClients.Count -ne 0) {
    $failure = @(
      $failedClients | ForEach-Object {
        [pscustomobject]@{
          index = $_.Index
          exit_code = $_.Process.ExitCode
          stdout = Get-Content -Raw -LiteralPath $_.Stdout -ErrorAction SilentlyContinue
          stderr = Get-Content -Raw -LiteralPath $_.Stderr -ErrorAction SilentlyContinue
        }
      }
    ) | ConvertTo-Json -Compress
    throw "Concurrent owner clients failed: $failure"
  }
  foreach ($client in $clients) {
    $null = Get-Content -Raw -LiteralPath $client.Stdout | ConvertFrom-Json
  }

  $first = Read-OwnerState
  $null = $ownedProcessIds.Add([int]$first.pid)
  $firstKernel = Get-KernelChild -OwnerProcessId ([int]$first.pid)
  $null = $ownedProcessIds.Add([int]$firstKernel.ProcessId)
  $firstShutdown = Stop-OwnerGracefully -State $first -KernelProcessId ([int]$firstKernel.ProcessId)

  Invoke-Health
  $second = Read-OwnerState
  $null = $ownedProcessIds.Add([int]$second.pid)
  $secondKernel = Get-KernelChild -OwnerProcessId ([int]$second.pid)
  $null = $ownedProcessIds.Add([int]$secondKernel.ProcessId)
  if ($second.generation -eq $first.generation) {
    throw 'Graceful recovery reused the stopped owner generation'
  }

  Stop-Process -Id ([int]$second.pid) -Force
  $crashGone = Wait-ProcessTreeGone `
    -ProcessIds @([int]$second.pid, [int]$secondKernel.ProcessId) `
    -TimeoutSeconds 10
  if (-not $crashGone) {
    throw "Crash tree survived: owner=$($second.pid), kernel=$($secondKernel.ProcessId)"
  }

  Invoke-Health
  $third = Read-OwnerState
  $null = $ownedProcessIds.Add([int]$third.pid)
  $thirdKernel = Get-KernelChild -OwnerProcessId ([int]$third.pid)
  $null = $ownedProcessIds.Add([int]$thirdKernel.ProcessId)
  if ($third.generation -eq $second.generation) {
    throw 'Crash recovery reused the dead owner generation'
  }
  $thirdShutdown = Stop-OwnerGracefully -State $third -KernelProcessId ([int]$thirdKernel.ProcessId)

  $finalGone = Wait-ProcessTreeGone -ProcessIds @($ownedProcessIds) -TimeoutSeconds 2
  if (-not $finalGone) {
    throw "Proof-owned processes survived final shutdown: $(@($ownedProcessIds) -join ',')"
  }

  [pscustomobject]@{
    type = 'var1.owner_lifecycle_proof.v1'
    concurrent_clients = $ConcurrentClients
    successful_clients = $ConcurrentClients
    first_owner_pid = [int]$first.pid
    first_kernel_pid = [int]$firstKernel.ProcessId
    first_generation = [string]$first.generation
    first_shutdown = $firstShutdown
    second_owner_pid = [int]$second.pid
    second_kernel_pid = [int]$secondKernel.ProcessId
    second_generation = [string]$second.generation
    crash_tree_zero = $crashGone
    third_owner_pid = [int]$third.pid
    third_kernel_pid = [int]$thirdKernel.ProcessId
    third_generation = [string]$third.generation
    third_shutdown = $thirdShutdown
    final_zero_processes = $finalGone
    retained_evidence_root = $resolvedProof
  } | ConvertTo-Json -Compress
} finally {
  foreach ($client in $clients) {
    $client.Process.Refresh()
    if (-not $client.Process.HasExited) {
      Stop-Process -Id $client.Process.Id -Force -ErrorAction SilentlyContinue
    }
  }

  if (Test-Path -LiteralPath $statePath) {
    try {
      $current = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
      $null = $ownedProcessIds.Add([int]$current.pid)
      $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $([int]$current.pid)")
      foreach ($child in $children) {
        if ($child.Name -eq $binaryName) {
          $null = $ownedProcessIds.Add([int]$child.ProcessId)
        }
      }
    } catch {
      # Preserve the original proof failure; the known PID set is still cleaned.
    }
  }
  foreach ($processId in @($ownedProcessIds)) {
    if ($null -ne (Get-Process -Id $processId -ErrorAction SilentlyContinue)) {
      Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
    }
  }
}
