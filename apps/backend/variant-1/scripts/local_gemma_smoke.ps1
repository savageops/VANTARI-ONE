[CmdletBinding()]
param(
  [int]$Port = 4311,
  [string]$ExpectedModel = "",
  [switch]$AllowSanityMismatch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Split-Path -Parent $scriptDir
$smokeDir = Join-Path $rootDir ".zig-cache\smoke"
$zigWrapper = Join-Path $scriptDir "zigw.ps1"
$exePath = Join-Path $rootDir "zig-out\bin\VAR1.exe"
$frontendClientDir = Join-Path (Split-Path -Parent (Split-Path -Parent $rootDir)) "frontend\var1-client"
$bridgeOut = Join-Path $smokeDir "bridge-out.txt"
$bridgeErr = Join-Path $smokeDir "bridge-err.txt"
$sanityPrompt = "Count the lowercase letter r in this exact character sequence: s t r a w b e r r y. Return only the number."
$promptFile = $null
$bridgeProcess = $null

function Read-EnvMap {
  param([string]$EnvPath)

  $values = @{}
  foreach ($line in Get-Content -LiteralPath $EnvPath) {
    if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith("#")) {
      continue
    }

    $parts = $line.Split("=", 2)
    if ($parts.Count -eq 2) {
      $values[$parts[0]] = $parts[1]
    }
  }

  return $values
}

function Get-PortOwnerProcess {
  param([int]$TargetPort)

  if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
    $connection = Get-NetTCPConnection -LocalPort $TargetPort -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($connection) {
      return Get-Process -Id $connection.OwningProcess -ErrorAction SilentlyContinue
    }
  }

  $netstatLine = netstat -ano -p tcp | Select-String -Pattern "LISTENING\s+(\S+:)?$TargetPort\s+.*\s+(\d+)$" | Select-Object -First 1
  if (-not $netstatLine) {
    return $null
  }

  $segments = ($netstatLine.Line -split '\s+') | Where-Object { $_ -ne "" }
  if ($segments.Count -lt 5) {
    return $null
  }

  return Get-Process -Id ([int]$segments[-1]) -ErrorAction SilentlyContinue
}

function Get-ProviderModelsUrl {
  param([string]$BaseUrl)

  $trimmed = $BaseUrl.TrimEnd("/")
  if ($trimmed -match "/v\d+$") {
    return "$trimmed/models"
  }

  return "$trimmed/v1/models"
}

function Assert-ProviderReady {
  param(
    [string]$BaseUrl,
    [string]$ApiKey,
    [string]$Model
  )

  $modelsUrl = Get-ProviderModelsUrl -BaseUrl $BaseUrl
  $headers = @{}
  if (-not [string]::IsNullOrWhiteSpace($ApiKey)) {
    $headers["Authorization"] = "Bearer $ApiKey"
  }

  try {
    $response = Invoke-RestMethod -Uri $modelsUrl -Headers $headers -Method Get -TimeoutSec 15
  } catch {
    throw "GEMMA_LOCAL expected reachable provider at ${modelsUrl}: $($_.Exception.Message)"
  }

  $availableModels = @($response.data | ForEach-Object { $_.id })
  if ($availableModels -notcontains $Model) {
    $available = if ($availableModels.Count -gt 0) { $availableModels -join ", " } else { "<none>" }
    throw "GEMMA_LOCAL expected model $Model to be served at $modelsUrl. Available models: $available"
  }
}

function Clear-BridgePort {
  param([int]$TargetPort)

  $owner = Get-PortOwnerProcess -TargetPort $TargetPort
  if (-not $owner) {
    return
  }

  if ($owner.ProcessName -ne "VAR1") {
    throw "smoke port $TargetPort is already owned by non-VAR1 process $($owner.ProcessName) (PID $($owner.Id))"
  }

  Stop-Process -Id $owner.Id -Force
}

function Invoke-Variant1 {
  param([string[]]$CommandArgs)

  $output = & $exePath @CommandArgs 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "VAR1.exe failed for args [$($CommandArgs -join ' ')]`n$($output | Out-String)"
  }

  return ($output | Out-String).Trim()
}

function Test-ReportsThree {
  param([string]$Text)

  return $Text -match '\b3\b'
}

function Assert-SanityAnswer {
  param(
    [string]$Surface,
    [string]$Text
  )

  if (Test-ReportsThree -Text $Text) {
    return
  }

  $message = "GEMMA_LOCAL $Surface did not clearly report 3: $Text"
  if ($AllowSanityMismatch) {
    Write-Warning "$message; continuing because -AllowSanityMismatch is set"
    return
  }

  throw $message
}

function Wait-ForBridgeHealth {
  param([int]$TargetPort)

  for ($attempt = 0; $attempt -lt 40; $attempt += 1) {
    try {
      return Invoke-RestMethod -Uri "http://127.0.0.1:$TargetPort/api/health"
    } catch {
      Start-Sleep -Seconds 1
    }
  }

  throw "bridge health check did not respond on port $TargetPort"
}

function Invoke-BridgeRpc {
  param(
    [int]$TargetPort,
    [string]$BridgeToken,
    [int]$Id,
    [string]$Method,
    [hashtable]$Params
  )

  $body = @{
    jsonrpc = "2.0"
    id = $Id
    method = $Method
    params = $Params
  } | ConvertTo-Json -Depth 30 -Compress

  if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
    throw "GEMMA_LOCAL bridge RPC smoke requires curl.exe for exact header emission"
  }

  $bodyPath = Join-Path $smokeDir "bridge-rpc-$Id-$([guid]::NewGuid().ToString('N')).json"
  try {
    [System.IO.File]::WriteAllText($bodyPath, $body, [System.Text.UTF8Encoding]::new($false))
    $curlArgs = @(
      "-sS",
      "-X", "POST",
      "-H", "Content-Type: application/json",
      "-H", "X-Var1-Bridge-Token: $($BridgeToken.Trim())",
      "--data-binary", "@$bodyPath",
      "http://127.0.0.1:$TargetPort/rpc"
    )
    $rawResponse = & curl.exe @curlArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
      throw "GEMMA_LOCAL bridge RPC $Method curl failed: $($rawResponse | Out-String)"
    }
    $response = $rawResponse | Out-String | ConvertFrom-Json
  } finally {
    Remove-Item -LiteralPath $bodyPath -Force -ErrorAction SilentlyContinue
  }

  if (($response.PSObject.Properties.Name -contains "error") -and $null -ne $response.error) {
    throw "GEMMA_LOCAL bridge RPC $Method failed: $($response.error | ConvertTo-Json -Compress)"
  }

  if (-not ($response.PSObject.Properties.Name -contains "result")) {
    throw "GEMMA_LOCAL bridge RPC $Method returned no result: $($response | ConvertTo-Json -Depth 30 -Compress)"
  }

  return $response.result
}

try {
  New-Item -ItemType Directory -Force -Path $smokeDir | Out-Null

  $envValues = Read-EnvMap -EnvPath (Join-Path $rootDir ".env")
  if ($envValues["BASE_URL"] -ne "http://127.0.0.1:1234") {
    throw "GEMMA_LOCAL expected BASE_URL=http://127.0.0.1:1234 in .env"
  }

  $configuredModel = if ($envValues.ContainsKey("MODEL")) { $envValues["MODEL"] } else { "" }
  if ([string]::IsNullOrWhiteSpace($configuredModel)) {
    throw "GEMMA_LOCAL expected MODEL to be configured in .env"
  }

  $expectedRuntimeModel = if ([string]::IsNullOrWhiteSpace($ExpectedModel)) { $configuredModel } else { $ExpectedModel }
  if ($configuredModel -ne $expectedRuntimeModel) {
    throw "GEMMA_LOCAL expected MODEL=$expectedRuntimeModel in .env"
  }
  Assert-ProviderReady -BaseUrl $envValues["BASE_URL"] -ApiKey $envValues["API_KEY"] -Model $expectedRuntimeModel

  Write-Host "GEMMA_LOCAL suite"
  & $zigWrapper build test --summary all
  if ($LASTEXITCODE -ne 0) {
    throw "zig test suite failed"
  }

  Write-Host "GEMMA_LOCAL effective config"
  $effectiveHealthOutput = Invoke-Variant1 -CommandArgs @("health")
  if ($effectiveHealthOutput -notmatch [regex]::Escape("model: $expectedRuntimeModel")) {
    throw "GEMMA_LOCAL runtime health did not report expected model $expectedRuntimeModel. Health output: $effectiveHealthOutput"
  }
  Write-Host $effectiveHealthOutput

  Write-Host "GEMMA_LOCAL windows build"
  & $zigWrapper build -Dtarget=x86_64-windows-gnu --summary all
  if ($LASTEXITCODE -ne 0) {
    throw "windows build failed"
  }

  Write-Host "GEMMA_LOCAL direct run"
  $directRunOutput = Invoke-Variant1 -CommandArgs @("run", "--prompt", $sanityPrompt)
  Assert-SanityAnswer -Surface "direct run" -Text $directRunOutput
  Write-Host $directRunOutput

  $promptFile = Join-Path $smokeDir "VAR1-gemma-delegated-prompt-$([guid]::NewGuid().ToString('N')).txt"
  @'
Launch a child agent named berry-child.
Child prompt: Count the lowercase letter r in this exact character sequence: s t r a w b e r r y. Return only the number.
Use agent_status as the primary supervision surface.
Use wait_agent only when you are ready to collect a current or terminal snapshot.
Return only the child's final answer and nothing else.
'@ | Set-Content -LiteralPath $promptFile -NoNewline

  Write-Host "GEMMA_LOCAL delegated"
  $delegatedOutput = Invoke-Variant1 -CommandArgs @("run", "--prompt-file", $promptFile)
  Assert-SanityAnswer -Surface "delegated run" -Text $delegatedOutput
  Write-Host $delegatedOutput

  Clear-BridgePort -TargetPort $Port
  Remove-Item -LiteralPath $bridgeOut, $bridgeErr -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath (Join-Path $rootDir "bridge-out.txt"), (Join-Path $rootDir "bridge-err.txt") -Force -ErrorAction SilentlyContinue

  Write-Host "GEMMA_LOCAL bridge"
  $bridgeProcess = Start-Process -FilePath $exePath -ArgumentList @("serve", "--host", "127.0.0.1", "--port", $Port.ToString()) -RedirectStandardOutput $bridgeOut -RedirectStandardError $bridgeErr -PassThru -WindowStyle Hidden

  $health = Wait-ForBridgeHealth -TargetPort $Port
  if ($health.model -ne $expectedRuntimeModel) {
    throw "GEMMA_LOCAL bridge health reported unexpected model: $($health.model)"
  }

  if (-not (Test-Path -LiteralPath (Join-Path $frontendClientDir "index.html"))) {
    throw "GEMMA_LOCAL expected external browser client at $frontendClientDir"
  }

  $bridgeHome = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/" -Method Get
  if ($bridgeHome -notmatch "VAR1 HTTP bridge ready") {
    throw "GEMMA_LOCAL bridge root did not return bridge-only text"
  }
  if ($bridgeHome -notmatch "apps/frontend/var1-client") {
    throw "GEMMA_LOCAL bridge root did not point operators to apps/frontend/var1-client"
  }

  $bridgeToken = ([string]$health.bridge_token).Trim()
  if ([string]::IsNullOrWhiteSpace($bridgeToken)) {
    throw "GEMMA_LOCAL bridge health did not expose a bridge token"
  }

  $created = Invoke-BridgeRpc -TargetPort $Port -BridgeToken $bridgeToken -Id 1 -Method "session/create" -Params @{
    prompt = $sanityPrompt
    enable_agent_tools = $true
  }
  $sessionId = $created.session.session_id
  if ([string]::IsNullOrWhiteSpace($sessionId)) {
    throw "GEMMA_LOCAL bridge session/create did not return a session id"
  }

  $sent = Invoke-BridgeRpc -TargetPort $Port -BridgeToken $bridgeToken -Id 2 -Method "session/send" -Params @{
    session_id = $sessionId
    enable_agent_tools = $true
  }
  $detailAnswer = if ($null -ne $sent.session.output) { [string]$sent.session.output } else { "" }
  if ($sent.session.status -ne "completed") {
    throw "GEMMA_LOCAL bridge session/send did not complete. Status: $($sent.session.status)"
  }
  Assert-SanityAnswer -Surface "bridge session/send" -Text $detailAnswer

  $detail = Invoke-BridgeRpc -TargetPort $Port -BridgeToken $bridgeToken -Id 3 -Method "session/get" -Params @{
    session_id = $sessionId
  }
  $journalEventTypes = @($detail.events | ForEach-Object { $_.event_type })
  if ($journalEventTypes -notcontains "assistant_response") {
    throw "GEMMA_LOCAL bridge session/get did not expose assistant_response"
  }

  $summary = [ordered]@{
    model = $health.model
    workspace_root = $health.workspace_root
    session_id = $sessionId
    status = $sent.session.status
    answer = $sent.session.output
    sanity_answer_verified = (Test-ReportsThree -Text $detailAnswer)
    journal_events = ($journalEventTypes -join ",")
  } | ConvertTo-Json -Compress

  Write-Host $summary
  Write-Host "GEMMA_LOCAL bridge ok"
} finally {
  if ($promptFile -and (Test-Path -LiteralPath $promptFile)) {
    Remove-Item -LiteralPath $promptFile -Force
  }

  if ($bridgeProcess -and -not $bridgeProcess.HasExited) {
    Stop-Process -Id $bridgeProcess.Id -Force
  } else {
    Clear-BridgePort -TargetPort $Port
  }
}
