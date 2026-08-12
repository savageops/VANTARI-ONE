[CmdletBinding()]
param(
    [string]$InstalledExe = "$env:LOCALAPPDATA\Vantari\bin\vantari.exe",
    [string]$WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path,
    [int]$TimeoutMs = 10000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Write-Frame([IO.Stream]$Stream, [string]$Payload) {
    $payloadBytes = [Text.Encoding]::UTF8.GetBytes($Payload)
    $headerBytes = [Text.Encoding]::ASCII.GetBytes("Content-Length: $($payloadBytes.Length)`r`n`r`n")
    $Stream.Write($headerBytes, 0, $headerBytes.Length)
    $Stream.Write($payloadBytes, 0, $payloadBytes.Length)
    $Stream.Flush()
}

function Wait-Task([Threading.Tasks.Task]$Task, [int]$DeadlineMs, [string]$Operation) {
    if (-not $Task.Wait($DeadlineMs)) { throw "$Operation timed out after $DeadlineMs ms" }
    if ($Task.IsFaulted) { throw $Task.Exception.InnerException }
}

function Read-Frame([IO.Stream]$Stream, [int]$DeadlineMs) {
    $header = [Collections.Generic.List[byte]]::new()
    $singleByte = [byte[]]::new(1)
    $started = [Diagnostics.Stopwatch]::StartNew()

    while ($header.Count -lt 8192) {
        $remaining = $DeadlineMs - [int]$started.ElapsedMilliseconds
        if ($remaining -le 0) { throw "frame header read timed out after $DeadlineMs ms" }
        $readTask = $Stream.ReadAsync($singleByte, 0, 1)
        Wait-Task $readTask $remaining 'frame header read'
        if ($readTask.Result -ne 1) { throw 'kernel stdout closed before a complete frame' }
        $header.Add($singleByte[0])
        if ($header.Count -ge 4 -and
            $header[$header.Count - 4] -eq 13 -and
            $header[$header.Count - 3] -eq 10 -and
            $header[$header.Count - 2] -eq 13 -and
            $header[$header.Count - 1] -eq 10) {
            break
        }
    }
    if ($header.Count -ge 8192) { throw 'kernel response header exceeded 8192 bytes' }

    $length = $null
    $headerText = [Text.Encoding]::ASCII.GetString($header.ToArray())
    foreach ($line in $headerText.Split(@("`r`n"), [StringSplitOptions]::RemoveEmptyEntries)) {
        if ($line.StartsWith('Content-Length:', [StringComparison]::OrdinalIgnoreCase)) {
            $length = [int]$line.Substring('Content-Length:'.Length).Trim()
        }
    }
    if ($null -eq $length -or $length -lt 0) { throw 'kernel response omitted Content-Length' }

    $buffer = [byte[]]::new($length)
    $offset = 0
    while ($offset -lt $length) {
        $remaining = $DeadlineMs - [int]$started.ElapsedMilliseconds
        if ($remaining -le 0) { throw "frame body read timed out after $DeadlineMs ms" }
        $readTask = $Stream.ReadAsync($buffer, $offset, $length - $offset)
        Wait-Task $readTask $remaining 'frame body read'
        $read = $readTask.Result
        if ($read -le 0) { throw 'kernel stdout closed during a frame body' }
        $offset += $read
    }
    return [Text.Encoding]::UTF8.GetString($buffer)
}

function Test-RpcError([object]$Response) {
    $property = $Response.PSObject.Properties['error']
    return $null -ne $property -and $null -ne $property.Value
}

if (-not (Test-Path -LiteralPath $InstalledExe -PathType Leaf)) { throw "Installed binary not found: $InstalledExe" }
$InstalledExe = (Resolve-Path -LiteralPath $InstalledExe).Path
$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path

$existing = @(Get-Process -Name 'vantari' -ErrorAction SilentlyContinue)
if ($existing.Count -ne 0) { throw "Refusing smoke proof while vantari.exe is active: $($existing.Id -join ', ')" }

$liveRuntimeRoot = if ($env:VANTARI_HOME) { $env:VANTARI_HOME } else { Join-Path $env:USERPROFILE '.vantari' }
$liveConfigPath = Join-Path $liveRuntimeRoot 'config.json'
if (-not (Test-Path -LiteralPath $liveConfigPath -PathType Leaf)) { throw "Runtime config not found: $liveConfigPath" }
$liveConfigHashBefore = Get-Sha256 $liveConfigPath
$defaultConfigPath = Join-Path $WorkspaceRoot 'apps\backend\src\core\config\default.json'
$configBytes = [IO.File]::ReadAllBytes($defaultConfigPath)
$config = [Text.Encoding]::UTF8.GetString($configBytes) | ConvertFrom-Json
$requestedFullAccess = -not [bool]$config.runtime.full_access_mode

$tempParent = [IO.Path]::GetFullPath((Join-Path $WorkspaceRoot 'apps\backend\.zig-cache\installed-smoke'))
$smokeRoot = [IO.Path]::GetFullPath((Join-Path $tempParent ([Guid]::NewGuid().ToString('N'))))
$tempPrefix = $tempParent.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
if (-not $smokeRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing unscoped smoke runtime path: $smokeRoot"
}
$tempWorkspace = Join-Path $smokeRoot 'workspace'
$runtimeRoot = Join-Path $tempWorkspace '.var'
[void][IO.Directory]::CreateDirectory($runtimeRoot)
$configPath = Join-Path $runtimeRoot 'config.json'
[IO.File]::WriteAllBytes($configPath, $configBytes)
$envFile = @(
    'BASE_URL=https://example.invalid/v1'
    'API_KEY=smoke'
    'MODEL=smoke-model'
    "WORKSPACE=$tempWorkspace"
) -join "`n"
$envFile += "`n"
[IO.File]::WriteAllText((Join-Path $tempWorkspace '.env'), $envFile, [Text.UTF8Encoding]::new($false))

$startInfo = [Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = $InstalledExe
$startInfo.ArgumentList.Add('kernel-stdio')
$startInfo.WorkingDirectory = $tempWorkspace
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.RedirectStandardInput = $true
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
[void]$startInfo.Environment.Remove('VANTARI_HOME')
$startInfo.Environment['VANTARI_WORKSPACE'] = $tempWorkspace

$process = [Diagnostics.Process]::new()
$process.StartInfo = $startInfo
$startedAt = [Diagnostics.Stopwatch]::StartNew()
$responseMs = $null
$responseSchema = $null
$stderrTask = $null
$processStarted = $false

try {
    if (-not $process.Start()) { throw 'Failed to start installed kernel-stdio process' }
    $processStarted = $true
    $stderrTask = $process.StandardError.ReadToEndAsync()

    $initialize = [ordered]@{
        jsonrpc = '2.0'
        id = 'settings-smoke-init'
        method = 'initialize'
        params = [ordered]@{}
    } | ConvertTo-Json -Compress -Depth 5
    Write-Frame $process.StandardInput.BaseStream $initialize
    $initializeResponse = Read-Frame $process.StandardOutput.BaseStream $TimeoutMs | ConvertFrom-Json
    if ($initializeResponse.id -ne 'settings-smoke-init' -or (Test-RpcError $initializeResponse)) {
        throw 'Installed initialize RPC returned an error or mismatched id'
    }

    $setRequest = [ordered]@{
        jsonrpc = '2.0'
        id = 'settings-smoke-set'
        method = 'config/set'
        params = [ordered]@{
            section = 'runtime'
            key = 'full_access_mode'
            value = $requestedFullAccess
        }
    } | ConvertTo-Json -Compress -Depth 5
    $setStarted = [Diagnostics.Stopwatch]::StartNew()
    Write-Frame $process.StandardInput.BaseStream $setRequest
    $setResponse = Read-Frame $process.StandardOutput.BaseStream $TimeoutMs | ConvertFrom-Json
    $setStarted.Stop()
    $responseMs = $setStarted.ElapsedMilliseconds
    if ($setResponse.id -ne 'settings-smoke-set' -or (Test-RpcError $setResponse)) {
        throw 'Installed config/set RPC returned an error or mismatched id'
    }
    $responseSchema = [string]$setResponse.result.schema
    if ($responseSchema -ne 'var1.config_set.v1') { throw "Unexpected config/set schema: $responseSchema" }

    $written = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    if ([bool]$written.runtime.full_access_mode -ne $requestedFullAccess) {
        throw 'config/set did not persist the requested typed value'
    }

    $process.StandardInput.Close()
    if (-not $process.WaitForExit(5000)) {
        $process.Kill($true)
        if (-not $process.WaitForExit(5000)) { throw 'Installed kernel process tree did not exit after forced termination' }
    }
    Wait-Task $stderrTask $TimeoutMs 'kernel stderr drain'
    if (-not [string]::IsNullOrWhiteSpace($stderrTask.Result)) {
        throw 'Installed kernel emitted stderr during settings smoke proof'
    }
} finally {
    if ($processStarted -and -not $process.HasExited) {
        $process.Kill($true)
        [void]$process.WaitForExit(5000)
    }
    $process.Dispose()
    if (Test-Path -LiteralPath $smokeRoot) {
        $resolvedSmokeRoot = [IO.Path]::GetFullPath($smokeRoot)
        if (-not $resolvedSmokeRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing recursive cleanup outside smoke root: $resolvedSmokeRoot"
        }
        [IO.Directory]::Delete($resolvedSmokeRoot, $true)
    }
}

$liveConfigHashAfter = Get-Sha256 $liveConfigPath
if ($liveConfigHashAfter -ne $liveConfigHashBefore) { throw 'Live runtime config changed during isolated smoke proof' }
if (Test-Path -LiteralPath $smokeRoot) { throw "Isolated smoke runtime remained after cleanup: $smokeRoot" }
$remaining = @(Get-Process -Name 'vantari' -ErrorAction SilentlyContinue)
if ($remaining.Count -ne 0) { throw "Vantari process remained after smoke proof: $($remaining.Id -join ', ')" }

$startedAt.Stop()
[pscustomobject]@{
    installed_exe = $InstalledExe
    installed_sha256 = Get-Sha256 $InstalledExe
    initialize = 'ok'
    config_set_schema = $responseSchema
    config_set_ms = $responseMs
    full_access_mode_written = $requestedFullAccess
    isolated_runtime = $true
    isolated_runtime_removed = $true
    live_config_unchanged = $true
    processes_remaining = 0
    total_ms = $startedAt.ElapsedMilliseconds
} | ConvertTo-Json -Compress
