[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$BinaryPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$backendRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$resolvedBinary = (Resolve-Path -LiteralPath $BinaryPath).Path
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

$runtimeRoot = Join-Path $resolvedProof '.var'
$schedulesRoot = Join-Path $runtimeRoot 'schedules'
$jobsRoot = Join-Path $schedulesRoot 'jobs'
$attemptsPath = Join-Path $schedulesRoot 'attempts.jsonl'
$leasePath = Join-Path $schedulesRoot 'lease.json'
$jobPath = Join-Path $jobsRoot 'schedule-leadership-proof.json'
$ticketsRoot = Join-Path $runtimeRoot 'tickets'
$ticketsPath = Join-Path $ticketsRoot 'tickets.jsonl'
$ticketId = 'ticket-admission-proof'
$defaultConfigPath = Join-Path $backendRoot 'src\core\config\default.json'
$kernels = @()

function Start-Kernel([string]$Label) {
  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $resolvedBinary
  $startInfo.ArgumentList.Add('kernel-stdio')
  $startInfo.WorkingDirectory = $resolvedProof
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardInput = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $startInfo.Environment['VANTARI_WORKSPACE'] = $resolvedProof
  $startInfo.Environment['VANTARI_HOME'] = $runtimeRoot

  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  if (-not $process.Start()) {
    throw "Failed to start $Label kernel"
  }
  return [pscustomobject]@{
    Label = $Label
    Process = $process
  }
}

function Assert-KernelAlive($Kernel) {
  $Kernel.Process.Refresh()
  if ($Kernel.Process.HasExited) {
    $stdout = $Kernel.Process.StandardOutput.ReadToEnd()
    $stderr = $Kernel.Process.StandardError.ReadToEnd()
    throw "$($Kernel.Label) kernel exited early with $($Kernel.Process.ExitCode): stdout=$stdout stderr=$stderr"
  }
}

function Stop-Kernel($Kernel) {
  $Kernel.Process.Refresh()
  if (-not $Kernel.Process.HasExited) {
    $Kernel.Process.StandardInput.Close()
    if (-not $Kernel.Process.WaitForExit(15000)) {
      $Kernel.Process.Kill($true)
      if (-not $Kernel.Process.WaitForExit(5000)) {
        throw "$($Kernel.Label) kernel did not terminate"
      }
    }
  }
  $stdout = $Kernel.Process.StandardOutput.ReadToEnd()
  $stderr = $Kernel.Process.StandardError.ReadToEnd()
  [IO.File]::WriteAllText((Join-Path $resolvedProof "$($Kernel.Label).stdout.log"), $stdout)
  [IO.File]::WriteAllText((Join-Path $resolvedProof "$($Kernel.Label).stderr.log"), $stderr)
}

function Read-Attempts {
  if (-not (Test-Path -LiteralPath $attemptsPath)) { return @() }
  return @(
    Get-Content -LiteralPath $attemptsPath |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      ForEach-Object { $_ | ConvertFrom-Json }
  )
}

function Read-TicketEvents {
  if (-not (Test-Path -LiteralPath $ticketsPath)) { return @() }
  return @(
    Get-Content -LiteralPath $ticketsPath |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      ForEach-Object { $_ | ConvertFrom-Json }
  )
}

try {
  New-Item -ItemType Directory -Force -Path $jobsRoot | Out-Null
  New-Item -ItemType Directory -Force -Path $ticketsRoot | Out-Null
  Copy-Item -LiteralPath $defaultConfigPath -Destination (Join-Path $runtimeRoot 'config.json')
  [IO.File]::WriteAllLines((Join-Path $resolvedProof '.env'), @(
    'BASE_URL=http://127.0.0.1:1'
    'API_KEY=scheduler-leadership-proof-key'
    'MODEL=scheduler-leadership-proof-model'
    "WORKSPACE=$resolvedProof"
    'MAX_STEPS=1'
  ))

  [ordered]@{
    id = 'schedule-leadership-proof'
    title = 'Two kernels, one scheduler winner'
    target_kind = 'shell'
    target = 'powershell -NoProfile -Command "Start-Sleep -Milliseconds 750"'
    schedule_kind = 'once'
    due_at_ms = 1
    interval_ms = $null
    next_due_at_ms = 1
    status = 'active'
    misfire_policy = 'fire_once'
    max_catch_up = 1
    created_at_ms = 1
    updated_at_ms = 1
    revision = 1
  } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $jobPath -Encoding utf8NoBOM

  [ordered]@{
    schema = 'var1.ticket_event.v2'
    seq = 1
    event_type = 'create'
    id = $ticketId
    ticket_id = $ticketId
    title = 'Two kernels, one ticket child'
    description = 'Prove one assigned ticket materializes exactly one child session.'
    category = 'research'
    severity = 'high'
    status = 'assigned'
    proposed_owner = 'recon'
    source = 'native-proof'
    idempotency_key = 'ticket-admission-proof-create'
    revision = 1
    created_at_ms = 1
    transitioned_at_ms = 1
  } | ConvertTo-Json -Compress | Set-Content -LiteralPath $ticketsPath -Encoding utf8NoBOM

  $kernels = @(
    Start-Kernel -Label 'kernel-a'
    Start-Kernel -Label 'kernel-b'
  )

  $deadline = [DateTime]::UtcNow.AddSeconds(15)
  do {
    foreach ($kernel in $kernels) { Assert-KernelAlive $kernel }
    $attempts = Read-Attempts
    $terminalRows = @($attempts | Where-Object { $_.status -in @('completed', 'failed') })
    $ticketEvents = Read-TicketEvents
    $claimRows = @($ticketEvents | Where-Object { $_.event_type -eq 'claim' -and $_.ticket_id -eq $ticketId })
    $claimSessionPath = if ($claimRows.Count -gt 0) {
      Join-Path (Join-Path (Join-Path $runtimeRoot 'sessions') ([string]$claimRows[0].session_id)) 'session.json'
    } else { '' }
    if ($terminalRows.Count -ge 1 -and $claimRows.Count -ge 1 -and (Test-Path -LiteralPath $claimSessionPath)) { break }
    Start-Sleep -Milliseconds 25
  } while ([DateTime]::UtcNow -lt $deadline)

  if ($terminalRows.Count -ne 1) {
    throw "Expected one terminal attempt row; found $($terminalRows.Count)"
  }
  $attempts = Read-Attempts
  $attemptIds = @($attempts | Select-Object -ExpandProperty attempt_id -Unique)
  $reservedRows = @($attempts | Where-Object { $_.status -eq 'reserved' })
  $terminalRows = @($attempts | Where-Object { $_.status -in @('completed', 'failed') })
  if ($attemptIds.Count -ne 1 -or $reservedRows.Count -ne 1 -or $terminalRows.Count -ne 1) {
    throw "Split scheduler execution detected: ids=$($attemptIds.Count), reserved=$($reservedRows.Count), terminal=$($terminalRows.Count)"
  }
  $ticketEvents = Read-TicketEvents
  $claimRows = @($ticketEvents | Where-Object { $_.event_type -eq 'claim' -and $_.ticket_id -eq $ticketId })
  if ($claimRows.Count -ne 1) {
    throw "Expected one serialized ticket claim; found $($claimRows.Count)"
  }
  $claim = $claimRows[0]
  if ([string]::IsNullOrWhiteSpace([string]$claim.session_id) -or
      -not ([string]$claim.session_id).StartsWith('session-ticket-child-', [StringComparison]::Ordinal)) {
    throw "Ticket claim did not reserve a deterministic child identity: $($claim.session_id)"
  }
  if ([uint64]$claim.worker_generation -eq 0 -or [string]::IsNullOrWhiteSpace([string]$claim.lease_token)) {
    throw 'Ticket claim did not commit worker generation and lease identity'
  }

  $sessionFiles = @(Get-ChildItem -LiteralPath (Join-Path $runtimeRoot 'sessions') -Filter 'session.json' -Recurse -File)
  $childSessions = @(
    $sessionFiles |
      ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName | ConvertFrom-Json } |
      Where-Object {
        $_.PSObject.Properties.Name -contains 'execution_receipt' -and $null -ne $_.execution_receipt
      }
  )
  if ($childSessions.Count -ne 1 -or [string]$childSessions[0].id -ne [string]$claim.session_id) {
    throw "Expected one claimed child session; children=$($childSessions.Count), claim=$($claim.session_id)"
  }
  if ([string]$childSessions[0].execution_receipt.capability_hash -ne [string]$claim.capability_hash) {
    throw 'Ticket claim and child receipt capability hashes diverged'
  }
  if (-not (Test-Path -LiteralPath $leasePath)) {
    throw "Scheduler lease projection is missing: $leasePath"
  }
  $lease = Get-Content -Raw -LiteralPath $leasePath | ConvertFrom-Json
  if ([string]::IsNullOrWhiteSpace([string]$lease.owner_id) -or [uint64]$lease.generation -eq 0) {
    throw 'Scheduler lease did not publish a nonzero generation fence'
  }
  if ([int64]$lease.expires_at_ms -le [int64]$lease.acquired_at_ms) {
    throw 'Scheduler lease expiry does not advance beyond acquisition'
  }
  if ([string]$claim.worker_id -ne [string]$lease.owner_id -or
      [uint64]$claim.worker_generation -ne [uint64]$lease.generation) {
    throw 'Ticket claim did not retain the scheduler owner generation'
  }
  foreach ($kernel in $kernels) { Assert-KernelAlive $kernel }

  foreach ($kernel in $kernels) { Stop-Kernel $kernel }
  $finalZero = @($kernels | Where-Object {
    $_.Process.Refresh()
    -not $_.Process.HasExited
  }).Count -eq 0
  if (-not $finalZero) {
    throw 'Proof-owned kernels survived graceful shutdown'
  }

  [pscustomobject]@{
    type = 'var1.scheduler_ticket_admission_proof.v1'
    kernel_pids = @($kernels | ForEach-Object { $_.Process.Id })
    concurrent_kernels = 2
    unique_attempts = $attemptIds.Count
    reserved_rows = $reservedRows.Count
    terminal_rows = $terminalRows.Count
    terminal_status = [string]$terminalRows[0].status
    winning_owner_id = [string]$lease.owner_id
    winning_generation = [uint64]$lease.generation
    generation_fenced = ([uint64]$lease.generation -ne 0)
    ticket_id = $ticketId
    ticket_claim_rows = $claimRows.Count
    ticket_child_sessions = $childSessions.Count
    ticket_child_session_id = [string]$claim.session_id
    ticket_worker_generation = [uint64]$claim.worker_generation
    ticket_lease_committed = -not [string]::IsNullOrWhiteSpace([string]$claim.lease_token)
    final_zero_processes = $finalZero
    retained_evidence_root = $resolvedProof
  } | ConvertTo-Json -Compress
} finally {
  foreach ($kernel in $kernels) {
    try {
      $kernel.Process.Refresh()
      if (-not $kernel.Process.HasExited) {
        $kernel.Process.Kill($true)
        $null = $kernel.Process.WaitForExit(5000)
      }
      $stdoutPath = Join-Path $resolvedProof "$($kernel.Label).stdout.log"
      $stderrPath = Join-Path $resolvedProof "$($kernel.Label).stderr.log"
      if (-not (Test-Path -LiteralPath $stdoutPath)) {
        [IO.File]::WriteAllText($stdoutPath, $kernel.Process.StandardOutput.ReadToEnd())
      }
      if (-not (Test-Path -LiteralPath $stderrPath)) {
        [IO.File]::WriteAllText($stderrPath, $kernel.Process.StandardError.ReadToEnd())
      }
    } catch {
      # Preserve the original proof failure after targeting only proof-owned PIDs.
    }
  }
}
