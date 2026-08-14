[CmdletBinding()]
param(
  [string]$InstalledExe = (Join-Path $env:LOCALAPPDATA "Vantari\bin\vantari.exe"),
  [ValidateSet("input", "write")]
  [string]$Scenario = "input"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-RpcFrame {
  param([IO.Stream]$Stream, [string]$Json)
  $payload = [Text.Encoding]::UTF8.GetBytes($Json)
  $header = [Text.Encoding]::ASCII.GetBytes("Content-Length: $($payload.Length)`r`n`r`n")
  $Stream.Write($header, 0, $header.Length)
  $Stream.Write($payload, 0, $payload.Length)
  $Stream.Flush()
}

function Read-Exact {
  param([IO.Stream]$Stream, [int]$Length, [int]$TimeoutMs)
  $buffer = [byte[]]::new($Length)
  $offset = 0
  while ($offset -lt $Length) {
    $task = $Stream.ReadAsync($buffer, $offset, $Length - $offset)
    if (-not $task.Wait($TimeoutMs)) { throw "RPC read timed out after ${TimeoutMs}ms" }
    $read = $task.Result
    if ($read -eq 0) { throw "Kernel closed before RPC payload" }
    $offset += $read
  }
  return $buffer
}

function Read-RpcFrame {
  param([IO.Stream]$Stream, [int]$TimeoutMs = 15000)
  $header = [Collections.Generic.List[byte]]::new()
  while ($true) {
    $byte = [byte[]]::new(1)
    $task = $Stream.ReadAsync($byte, 0, 1)
    if (-not $task.Wait($TimeoutMs)) { throw "RPC header read timed out after ${TimeoutMs}ms" }
    if ($task.Result -eq 0) { throw "Kernel closed before RPC header" }
    $header.Add($byte[0])
    $count = $header.Count
    if ($count -ge 4 -and $header[$count - 4] -eq 13 -and $header[$count - 3] -eq 10 -and $header[$count - 2] -eq 13 -and $header[$count - 1] -eq 10) { break }
    if ($count -gt 4096) { throw "RPC header exceeded 4096 bytes" }
  }
  $headerText = [Text.Encoding]::ASCII.GetString($header.ToArray())
  $match = [regex]::Match($headerText, '(?im)^Content-Length:\s*(\d+)\s*$')
  if (-not $match.Success) { throw "RPC Content-Length missing" }
  $payload = Read-Exact -Stream $Stream -Length ([int]$match.Groups[1].Value) -TimeoutMs $TimeoutMs
  return [Text.Encoding]::UTF8.GetString($payload) | ConvertFrom-Json
}

Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

public sealed class VantariInputFakeProvider : IDisposable
{
    private TcpListener listener;
    private Thread thread;
    private readonly string scenario;
    public int Port { get; private set; }
    public int CompletionRequests { get; private set; }
    public string SecondRequestBody { get; private set; }
    public string FinalRequestBody { get; private set; }
    public bool SawFinal { get; private set; }
    public Exception Error { get; private set; }

    public VantariInputFakeProvider(string scenario)
    {
        this.scenario = scenario;
    }

    public void Start()
    {
        listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        Port = ((IPEndPoint)listener.LocalEndpoint).Port;
        thread = new Thread(Run) { IsBackground = true, Name = "vantari-input-proof-provider" };
        thread.Start();
    }

    private void Run()
    {
        try
        {
            while (!SawFinal && CompletionRequests < 8)
            {
                using (TcpClient client = listener.AcceptTcpClient())
                using (NetworkStream stream = client.GetStream())
                {
                    string headers = ReadHeaders(stream);
                    string firstLine = headers.Split(new[] { "\r\n" }, StringSplitOptions.None)[0];
                    int contentLength = ParseContentLength(headers);
                    string requestBody = ReadBody(stream, contentLength);

                    string body;
                    if (firstLine.IndexOf("/models", StringComparison.OrdinalIgnoreCase) >= 0)
                    {
                        body = "{\"data\":[{\"id\":\"question-model\",\"context_length\":200000}]}";
                    }
                    else if (firstLine.IndexOf("/chat/completions", StringComparison.OrdinalIgnoreCase) >= 0)
                    {
                        CompletionRequests++;
                        if (scenario == "input" && CompletionRequests == 1)
                        {
                            body = "{\"model\":\"question-model\",\"choices\":[{\"message\":{\"content\":null,\"tool_calls\":[{\"id\":\"call_ask_user\",\"type\":\"function\",\"function\":{\"name\":\"ask_user\",\"arguments\":\"{\\\"questions\\\":[{\\\"id\\\":\\\"decision\\\",\\\"prompt\\\":\\\"Choose the release posture.\\\",\\\"options\\\":[{\\\"label\\\":\\\"Proceed\\\"},{\\\"label\\\":\\\"Pause\\\"}]}]}\"}}]},\"finish_reason\":\"tool_calls\"}]}";
                        }
                        else if (scenario == "write" && CompletionRequests == 1)
                        {
                            SecondRequestBody = requestBody;
                            body = "{\"model\":\"question-model\",\"choices\":[{\"message\":{\"content\":null,\"tool_calls\":[{\"id\":\"call_read_before_write\",\"type\":\"function\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\\\"write-result.txt\\\"}\"}}]},\"finish_reason\":\"tool_calls\"}]}";
                        }
                        else if (scenario == "write" && CompletionRequests == 2)
                        {
                            body = "{\"model\":\"question-model\",\"choices\":[{\"message\":{\"content\":null,\"tool_calls\":[{\"id\":\"call_write_effect\",\"type\":\"function\",\"function\":{\"name\":\"write_file\",\"arguments\":\"{\\\"path\\\":\\\"write-result.txt\\\",\\\"content\\\":\\\"WRITE_EFFECT_OK\\\\n\\\"}\"}}]},\"finish_reason\":\"tool_calls\"}]}";
                        }
                        else
                        {
                            if (scenario == "input") SecondRequestBody = requestBody;
                            FinalRequestBody = requestBody;
                            SawFinal = true;
                            string output = scenario == "write" ? "WRITE_EFFECT_OK" : "QUESTION_RESPONSE_OK";
                            body = "{\"model\":\"question-model\",\"choices\":[{\"message\":{\"content\":\"" + output + "\"},\"finish_reason\":\"stop\"}]}";
                        }
                    }
                    else
                    {
                        throw new InvalidDataException("Unexpected provider request: " + firstLine);
                    }

                    byte[] payload = Encoding.UTF8.GetBytes(body);
                    byte[] response = Encoding.ASCII.GetBytes(
                        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " + payload.Length +
                        "\r\nConnection: close\r\n\r\n");
                    stream.Write(response, 0, response.Length);
                    stream.Write(payload, 0, payload.Length);
                    stream.Flush();
                }
            }
        }
        catch (Exception ex)
        {
            Error = ex;
        }
    }

    private static string ReadHeaders(NetworkStream stream)
    {
        using (MemoryStream buffer = new MemoryStream())
        {
            int state = 0;
            while (buffer.Length < 65536)
            {
                int value = stream.ReadByte();
                if (value < 0) throw new EndOfStreamException("Provider request ended before headers");
                buffer.WriteByte((byte)value);
                state = (state == 0 && value == 13) ? 1
                    : (state == 1 && value == 10) ? 2
                    : (state == 2 && value == 13) ? 3
                    : (state == 3 && value == 10) ? 4
                    : 0;
                if (state == 4) return Encoding.ASCII.GetString(buffer.ToArray());
            }
        }
        throw new InvalidDataException("Provider headers exceeded 65536 bytes");
    }

    private static int ParseContentLength(string headers)
    {
        foreach (string line in headers.Split(new[] { "\r\n" }, StringSplitOptions.None))
        {
            if (!line.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase)) continue;
            return int.Parse(line.Substring(line.IndexOf(':') + 1).Trim());
        }
        return 0;
    }

    private static string ReadBody(NetworkStream stream, int length)
    {
        byte[] buffer = new byte[length];
        int offset = 0;
        while (offset < length)
        {
            int read = stream.Read(buffer, offset, length - offset);
            if (read == 0) throw new EndOfStreamException("Provider request ended before body");
            offset += read;
        }
        return Encoding.UTF8.GetString(buffer);
    }

    public void Stop()
    {
        if (listener != null) listener.Stop();
        listener = null;
        if (thread != null && !thread.Join(5000)) throw new TimeoutException("Input proof provider did not stop");
        if (Error != null) throw new InvalidOperationException("Input proof provider failed", Error);
    }

    public void Dispose()
    {
        if (listener != null) listener.Stop();
        if (thread != null) thread.Join(5000);
    }
}
'@

if (-not (Test-Path -LiteralPath $InstalledExe -PathType Leaf)) { throw "Installed executable not found: $InstalledExe" }
$InstalledExe = (Resolve-Path -LiteralPath $InstalledExe).Path
$installedHash = (Get-FileHash -LiteralPath $InstalledExe -Algorithm SHA256).Hash
$installedName = [IO.Path]::GetFileNameWithoutExtension($InstalledExe)
$preexisting = @(Get-Process -Name $installedName -ErrorAction SilentlyContinue | Where-Object {
    $_.Path -and [IO.Path]::GetFullPath($_.Path) -ieq $InstalledExe
  })
if ($preexisting.Count -ne 0) { throw "Refusing proof while installed VANTARI is active: $([string]::Join(',', @($preexisting | ForEach-Object Id)))" }

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$backendRoot = Split-Path -Parent $scriptDir
$defaultConfig = Join-Path $backendRoot "src\core\config\default.json"
$proofRoot = Join-Path $env:TEMP ("vantari-installed-input-" + [Guid]::NewGuid().ToString("N"))
$proofWorkspace = Join-Path $proofRoot "workspace"
$process = $null
$provider = $null
$started = $false
$gracefulExit = $false
$sessionId = $null
$inputRequest = $null
$inputResponded = $false
$notifications = [Collections.Generic.List[object]]::new()

try {
  New-Item -ItemType Directory -Force -Path $proofWorkspace | Out-Null
  Copy-Item -LiteralPath $defaultConfig -Destination (Join-Path $proofRoot "config.json")

  $provider = [VantariInputFakeProvider]::new($Scenario)
  $provider.Start()
  [IO.File]::WriteAllText(
    (Join-Path $proofWorkspace ".env"),
    "BASE_URL=http://127.0.0.1:$($provider.Port)`nAPI_KEY=proof`nMODEL=question-model`nWORKSPACE=$proofWorkspace`n",
    [Text.UTF8Encoding]::new($false)
  )

  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $InstalledExe
  $startInfo.Arguments = "kernel-stdio"
  $startInfo.WorkingDirectory = $proofWorkspace
  $startInfo.UseShellExecute = $false
  $startInfo.RedirectStandardInput = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $startInfo.CreateNoWindow = $true
  $startInfo.Environment["VANTARI_HOME"] = $proofRoot
  $startInfo.Environment["VANTARI_WORKSPACE"] = $proofWorkspace
  [void]$startInfo.Environment.Remove("VANTARI_TEST_ROOT")

  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  if (-not $process.Start()) { throw "Could not start installed kernel" }
  $started = $true

  $promptText = if ($Scenario -eq "input") {
    "Ask one operator question, then report QUESTION_RESPONSE_OK."
  } else {
    "Read the target, write the requested proof file, then report WRITE_EFFECT_OK."
  }
  $createRequest = [ordered]@{
    jsonrpc = "2.0"
    id = "input-create"
    method = "session/create"
    params = [ordered]@{ prompt = $promptText; enable_agent_tools = $true }
  } | ConvertTo-Json -Compress -Depth 8
  Write-RpcFrame -Stream $process.StandardInput.BaseStream -Json $createRequest
  try {
    $created = Read-RpcFrame -Stream $process.StandardOutput.BaseStream
  }
  catch {
    $childError = if ($process.HasExited) { $process.StandardError.ReadToEnd() } else { "process still running" }
    throw "Installed kernel closed before session/create: $childError"
  }
  $createdError = $created.PSObject.Properties["error"]
  if ($created.id -ne "input-create" -or ($null -ne $createdError -and $null -ne $createdError.Value)) { throw "Installed session/create failed: $($created | ConvertTo-Json -Compress -Depth 8)" }
  $sessionId = [string]$created.result.session.session_id

  $sendRequest = [ordered]@{
    jsonrpc = "2.0"
    id = "input-send"
    method = "session/send"
    params = [ordered]@{ session_id = $sessionId; enable_agent_tools = $true; prompt_mode = if ($Scenario -eq "input") { "orchestrate" } else { "build" } }
  } | ConvertTo-Json -Compress -Depth 8
  Write-RpcFrame -Stream $process.StandardInput.BaseStream -Json $sendRequest

  $sendResponse = $null
  $inputResponse = $null
  for ($attempt = 0; $attempt -lt 40 -and $null -eq $sendResponse; $attempt++) {
    $frame = Read-RpcFrame -Stream $process.StandardOutput.BaseStream
    $frameId = $frame.PSObject.Properties["id"]
    if ($null -ne $frameId) {
      if ($frame.id -eq "input-send") { $sendResponse = $frame }
      elseif ($frame.id -eq "input-respond") { $inputResponse = $frame }
      continue
    }

    $notifications.Add($frame)
    if ($frame.method -ne "session/event" -or $frame.params.event_type -ne "input_requested") { continue }
    if ($Scenario -ne "input") { throw "Write scenario unexpectedly emitted input_requested" }
    if ($inputRequest -ne $null) { throw "Installed provider emitted duplicate input_requested events" }
    $inputRequest = [string]$frame.params.message | ConvertFrom-Json
    if ($inputRequest.schema -ne "var1.input_requested.v1" -or $inputRequest.request_id -ne "call_ask_user") {
      throw "Unexpected input request: $($frame.params.message)"
    }
    if (@($inputRequest.questions).Count -ne 1 -or $inputRequest.questions[0].id -ne "decision") {
      throw "Installed provider question shape diverged"
    }

    $respondRequest = [ordered]@{
      jsonrpc = "2.0"
      id = "input-respond"
      method = "input/respond"
      params = [ordered]@{
        session_id = $sessionId
        request_id = [string]$inputRequest.request_id
        answers = @([ordered]@{ question_id = "decision"; selected = @("a") })
      }
    } | ConvertTo-Json -Compress -Depth 8
    Write-RpcFrame -Stream $process.StandardInput.BaseStream -Json $respondRequest
    $inputResponded = $true
  }

  $sendError = if ($null -ne $sendResponse) { $sendResponse.PSObject.Properties["error"] } else { $null }
  if ($null -eq $sendResponse -or ($null -ne $sendError -and $null -ne $sendError.Value)) { throw "Installed session/send failed: $($sendResponse | ConvertTo-Json -Compress -Depth 8)" }
  if ($sendResponse.result.session.status -ne "completed") { throw "Installed $Scenario turn did not complete: $($sendResponse.result.session.status)" }
  $expectedOutput = if ($Scenario -eq "input") { "QUESTION_RESPONSE_OK" } else { "WRITE_EFFECT_OK" }
  if ($sendResponse.result.session.output -ne $expectedOutput) { throw "Installed $Scenario output diverged: $($sendResponse.result.session.output)" }
  if (-not $provider.SawFinal) { throw "Provider did not reach its final response" }
  if ($Scenario -eq "input") {
    if ($null -eq $inputRequest) { throw "Installed provider did not emit input_requested" }
    if (-not $inputResponded) { throw "Installed input/respond was not sent" }
    $inputError = if ($null -ne $inputResponse) { $inputResponse.PSObject.Properties["error"] } else { $null }
    if ($null -eq $inputResponse -or ($null -ne $inputError -and $null -ne $inputError.Value)) { throw "Installed input/respond failed: $($inputResponse | ConvertTo-Json -Compress -Depth 8)" }
    if ($provider.CompletionRequests -ne 2) { throw "Provider question exchange used $($provider.CompletionRequests) completion requests" }
    if ([string]::IsNullOrEmpty($provider.SecondRequestBody) -or $provider.SecondRequestBody.IndexOf("var1.input_response.v1", [StringComparison]::Ordinal) -lt 0) {
      throw "Provider did not receive the durable input response envelope"
    }
  } else {
    if ($null -ne $inputRequest) { throw "Write scenario retained an input request" }
    if ($provider.CompletionRequests -ne 3) { throw "Provider write exchange used $($provider.CompletionRequests) completion requests" }
    if ([string]::IsNullOrEmpty($provider.FinalRequestBody) -or $provider.FinalRequestBody.IndexOf("var1.tool_effect.v1", [StringComparison]::Ordinal) -lt 0) {
      throw "Provider did not receive the canonical tool effect envelope: $($provider.FinalRequestBody)"
    }
    $writtenPath = Join-Path $proofWorkspace "write-result.txt"
    if (-not (Test-Path -LiteralPath $writtenPath -PathType Leaf)) { throw "Installed write effect did not create $writtenPath" }
    $writtenContent = [IO.File]::ReadAllText($writtenPath)
    if ($writtenContent -ne "WRITE_EFFECT_OK`n") { throw "Installed write effect content diverged: $writtenContent" }
  }

  $sessionRoot = Join-Path (Join-Path $proofRoot "sessions") $sessionId
  $eventsPath = Join-Path $sessionRoot "events.jsonl"
  $messagesPath = Join-Path $sessionRoot "messages.jsonl"
  $intentsPath = Join-Path $sessionRoot "intents.jsonl"
  if (-not (Test-Path -LiteralPath $eventsPath -PathType Leaf)) { throw "Installed event ledger missing: $eventsPath" }
  $events = @(Get-Content -LiteralPath $eventsPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
  $messages = @(Get-Content -LiteralPath $messagesPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
  $eventTypes = @($events | ForEach-Object { [string]$_.event_type })
  $inputEvents = @($events | Where-Object event_type -eq "input_requested")
  $toolRequestedEvents = @($events | Where-Object event_type -eq "tool_requested")
  $toolCompletedEvents = @($events | Where-Object event_type -eq "tool_completed")
  $expectedToolCount = if ($Scenario -eq "input") { 1 } else { 2 }
  if ($Scenario -eq "input" -and $inputEvents.Count -ne 1) { throw "Installed event ledger omitted input_requested" }
  if ($Scenario -eq "write" -and $inputEvents.Count -ne 0) { throw "Installed write ledger emitted input_requested" }
  if ($toolRequestedEvents.Count -lt $expectedToolCount) { throw "Installed event ledger omitted a tool request" }
  if ($toolCompletedEvents.Count -lt $expectedToolCount) { throw "Installed event ledger omitted tool_completed" }
  $effectMessages = @($messages | Where-Object {
      [string]$_.role -eq "tool" -and ([string]$_.content).IndexOf("var1.tool_effect.v1", [StringComparison]::Ordinal) -ge 0
    })
  $committedIntents = @()
  if ($Scenario -eq "write") {
    if ($effectMessages.Count -lt 1) { throw "Installed transcript omitted var1.tool_effect.v1" }
    if (-not (Test-Path -LiteralPath $intentsPath -PathType Leaf)) { throw "Installed write-intent ledger missing: $intentsPath" }
    $intents = @(Get-Content -LiteralPath $intentsPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
    $committedIntents = @($intents | Where-Object {
        [string]$_.status -eq "committed" -and -not [string]::IsNullOrEmpty([string]$_.after_sha256) -and [int]$_.bytes_written -gt 0
      })
    if ($committedIntents.Count -ne 1) { throw "Installed write-intent ledger has $($committedIntents.Count) committed rows" }
  }
  $terminal = @($events | Where-Object event_type -eq "turn_terminal")
  if ($terminal.Count -ne 1) { throw "Installed event ledger has $($terminal.Count) turn_terminal rows" }
  $terminalPayload = [string]$terminal[0].message | ConvertFrom-Json
  if ($terminalPayload.schema -ne "var1.turn_terminal.v1" -or $terminalPayload.outcome -ne "completed") { throw "Unexpected installed terminal payload: $($terminal[0].message)" }
  if (-not (Test-Path -LiteralPath $messagesPath -PathType Leaf)) { throw "Installed transcript missing: $messagesPath" }

  $process.StandardInput.Close()
  if (-not $process.WaitForExit(5000)) { throw "Installed kernel did not exit after EOF" }
  $gracefulExit = $true
  if ($process.ExitCode -ne 0) { throw "Installed kernel exited $($process.ExitCode): $($process.StandardError.ReadToEnd())" }

  [pscustomobject]@{
    schema = if ($Scenario -eq "input") { "var1.installed_input_response_proof.v1" } else { "var1.installed_write_effect_proof.v1" }
    scenario = $Scenario
    installed_sha256 = $installedHash
    session_id = $sessionId
    status = [string]$sendResponse.result.session.status
    output = [string]$sendResponse.result.session.output
    provider_completion_requests = $provider.CompletionRequests
    provider_received_input_response = ($Scenario -eq "input")
    input_request_id = if ($null -ne $inputRequest) { [string]$inputRequest.request_id } else { $null }
    input_response_accepted = if ($null -ne $inputResponse) { [bool]$inputResponse.result.accepted } else { $false }
    write_effect_verified = ($Scenario -eq "write")
    effect_message_verified = ($Scenario -eq "write" -and $effectMessages.Count -eq 1)
    write_intent_committed = ($Scenario -eq "write" -and $committedIntents.Count -eq 1)
    written_path = if ($Scenario -eq "write") { "write-result.txt" } else { $null }
    event_rows = $events.Count
    event_types = [string]::Join(",", $eventTypes)
    terminal_outcome = [string]$terminalPayload.outcome
    process_exit_code = $process.ExitCode
    graceful_eof_exit = $gracefulExit
  } | ConvertTo-Json -Compress
}
finally {
  if ($provider -ne $null) {
    try { $provider.Stop() } catch { }
  }
  if ($started -and $process -ne $null -and -not $process.HasExited) {
    try { $process.StandardInput.Close() } catch { }
    if (-not $process.WaitForExit(5000)) {
      if ([IO.Path]::GetFullPath($process.StartInfo.FileName) -ieq $InstalledExe) { $process.Kill() }
      $process.WaitForExit(5000)
    }
  }

  $resolvedProofRoot = [IO.Path]::GetFullPath($proofRoot)
  $tempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd("\") + "\"
  if (-not $resolvedProofRoot.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing cleanup outside temp root: $resolvedProofRoot"
  }
  if (Test-Path -LiteralPath $resolvedProofRoot) { [IO.Directory]::Delete($resolvedProofRoot, $true) }
  $leftovers = @(Get-Process -Name $installedName -ErrorAction SilentlyContinue | Where-Object {
      $_.Path -and [IO.Path]::GetFullPath($_.Path) -ieq $InstalledExe
    })
  if ($leftovers.Count -ne 0) { throw "Installed input proof left VANTARI processes: $([string]::Join(',', @($leftovers | ForEach-Object Id)))" }
}
