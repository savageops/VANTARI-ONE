[CmdletBinding()]
param(
  [string]$InstalledExe = "$env:LOCALAPPDATA\Vantari\bin\vantari.exe",
  [string]$LegacyLedger = "$env:USERPROFILE\.vantari\sessions\summaries.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-RpcFrame {
  param(
    [Parameter(Mandatory = $true)][IO.Stream]$Stream,
    [Parameter(Mandatory = $true)][string]$Json
  )
  $payload = [Text.Encoding]::UTF8.GetBytes($Json)
  $header = [Text.Encoding]::ASCII.GetBytes("Content-Length: $($payload.Length)`r`n`r`n")
  $Stream.Write($header, 0, $header.Length)
  $Stream.Write($payload, 0, $payload.Length)
  $Stream.Flush()
}

function Read-Exact {
  param([IO.Stream]$Stream, [int]$Length)
  $buffer = [byte[]]::new($Length)
  $offset = 0
  while ($offset -lt $Length) {
    $read = $Stream.Read($buffer, $offset, $Length - $offset)
    if ($read -eq 0) { throw 'Unexpected kernel EOF' }
    $offset += $read
  }
  return $buffer
}

function Read-RpcFrame {
  param([Parameter(Mandatory = $true)][IO.Stream]$Stream)
  $header = [Collections.Generic.List[byte]]::new()
  while ($true) {
    $next = $Stream.ReadByte()
    if ($next -lt 0) { throw 'Kernel closed before RPC header' }
    $header.Add([byte]$next)
    $count = $header.Count
    if ($count -ge 4 -and $header[$count - 4] -eq 13 -and $header[$count - 3] -eq 10 -and $header[$count - 2] -eq 13 -and $header[$count - 1] -eq 10) { break }
    if ($count -gt 4096) { throw 'RPC header exceeded 4096 bytes' }
  }
  $headerText = [Text.Encoding]::ASCII.GetString($header.ToArray())
  $match = [regex]::Match($headerText, '(?im)^Content-Length:\s*(\d+)\s*$')
  if (-not $match.Success) { throw 'RPC Content-Length missing' }
  $payload = Read-Exact -Stream $Stream -Length ([int]$match.Groups[1].Value)
  return [Text.Encoding]::UTF8.GetString($payload) | ConvertFrom-Json
}

function Read-RpcResponse {
  param(
    [Parameter(Mandatory = $true)][IO.Stream]$Stream,
    [Parameter(Mandatory = $true)][string]$Id,
    [Collections.Generic.List[object]]$Notifications
  )
  for ($attempt = 0; $attempt -lt 100; $attempt++) {
    $frame = Read-RpcFrame -Stream $Stream
    $idProperty = $frame.PSObject.Properties['id']
    if ($null -ne $idProperty -and [string]$idProperty.Value -eq $Id) { return $frame }
    if ($null -ne $Notifications -and $null -eq $idProperty) { $Notifications.Add($frame) }
  }
  throw "RPC response $Id not observed within 100 frames"
}

Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

public sealed class VantariSummaryFakeProvider : IDisposable
{
    private TcpListener listener;
    private Thread thread;
    public int Port { get; private set; }
    public int Requests { get; private set; }
    public bool SawCompletion { get; private set; }
    public Exception Error { get; private set; }

    public void Start()
    {
        listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        Port = ((IPEndPoint)listener.LocalEndpoint).Port;
        thread = new Thread(Run) { IsBackground = true, Name = "vantari-summary-fake-provider" };
        thread.Start();
    }

    private void Run()
    {
        try
        {
            while (!SawCompletion && Requests < 4)
            {
                using (TcpClient client = listener.AcceptTcpClient())
                using (NetworkStream stream = client.GetStream())
                {
                    string headers = ReadHeaders(stream);
                    Requests++;
                    string firstLine = headers.Split(new[] { "\r\n" }, StringSplitOptions.None)[0];
                    int contentLength = ParseContentLength(headers);
                    ReadBody(stream, contentLength);

                    string body;
                    if (firstLine.IndexOf("/models", StringComparison.OrdinalIgnoreCase) >= 0)
                    {
                        body = "{\"data\":[{\"id\":\"smoke-model\",\"context_length\":200000}]}";
                    }
                    else
                    {
                        SawCompletion = firstLine.IndexOf("/chat/completions", StringComparison.OrdinalIgnoreCase) >= 0;
                        body = "{\"model\":\"smoke-model\",\"choices\":[{\"message\":{\"content\":\"Installed summary migration completed.\"}}]}";
                    }
                    byte[] payload = Encoding.UTF8.GetBytes(body);
                    byte[] head = Encoding.ASCII.GetBytes(
                        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " + payload.Length +
                        "\r\nConnection: close\r\n\r\n");
                    stream.Write(head, 0, head.Length);
                    stream.Write(payload, 0, payload.Length);
                    stream.Flush();
                }
            }
        }
        catch (Exception ex)
        {
            if (!(ex is SocketException) || listener != null) Error = ex;
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
                if (value < 0) throw new EndOfStreamException("HTTP request ended before headers");
                buffer.WriteByte((byte)value);
                state = (state == 0 && value == 13) ? 1
                    : (state == 1 && value == 10) ? 2
                    : (state == 2 && value == 13) ? 3
                    : (state == 3 && value == 10) ? 4
                    : 0;
                if (state == 4) return Encoding.ASCII.GetString(buffer.ToArray());
            }
        }
        throw new InvalidDataException("HTTP headers exceeded 65536 bytes");
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

    private static void ReadBody(NetworkStream stream, int length)
    {
        byte[] buffer = new byte[8192];
        int remaining = length;
        while (remaining > 0)
        {
            int read = stream.Read(buffer, 0, Math.Min(buffer.Length, remaining));
            if (read == 0) throw new EndOfStreamException("HTTP request body ended early");
            remaining -= read;
        }
    }

    public void Stop()
    {
        if (listener != null) listener.Stop();
        listener = null;
        if (thread != null && !thread.Join(5000)) throw new TimeoutException("Fake provider did not stop");
        if (Error != null) throw new InvalidOperationException("Fake provider failed", Error);
    }

    public void Dispose()
    {
        if (listener != null) listener.Stop();
        if (thread != null) thread.Join(5000);
    }
}
'@

if (-not (Test-Path -LiteralPath $InstalledExe -PathType Leaf)) { throw "Installed binary not found: $InstalledExe" }
if (-not (Test-Path -LiteralPath $LegacyLedger -PathType Leaf)) { throw "Legacy summary ledger not found: $LegacyLedger" }
if (@(Get-Process -Name 'vantari' -ErrorAction SilentlyContinue).Count -ne 0) { throw 'Refusing proof while vantari.exe is active' }

$InstalledExe = (Resolve-Path -LiteralPath $InstalledExe).Path
$LegacyLedger = (Resolve-Path -LiteralPath $LegacyLedger).Path
$legacyHash = (Get-FileHash -LiteralPath $LegacyLedger -Algorithm SHA256).Hash
$legacyDocument = Get-Content -LiteralPath $LegacyLedger -Raw | ConvertFrom-Json
$legacyRows = @($legacyDocument.PSObject.Properties).Count
$backendRoot = Split-Path -Parent $PSScriptRoot
$defaultConfig = Join-Path $backendRoot 'src\core\config\default.json'
$smokeRoot = Join-Path $env:TEMP ("vantari-summary-migration-" + [Guid]::NewGuid().ToString('N'))
$tempPrefix = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
$tempWorkspace = Join-Path $smokeRoot 'workspace'
$sessionsRoot = Join-Path $smokeRoot 'sessions'
$legacyCopy = Join-Path $sessionsRoot 'summaries.json'
$jsonlPath = Join-Path $sessionsRoot 'summaries.jsonl'
$process = $null
$started = $false
$provider = $null

try {
  New-Item -ItemType Directory -Path $sessionsRoot, $tempWorkspace -Force | Out-Null
  Copy-Item -LiteralPath $LegacyLedger -Destination $legacyCopy
  Copy-Item -LiteralPath $defaultConfig -Destination (Join-Path $smokeRoot 'config.json')
  $provider = [VantariSummaryFakeProvider]::new()
  $provider.Start()
  [IO.File]::WriteAllText(
    (Join-Path $tempWorkspace '.env'),
    "BASE_URL=http://127.0.0.1:$($provider.Port)`nAPI_KEY=smoke`nMODEL=smoke-model`nWORKSPACE=$tempWorkspace`n",
    [Text.UTF8Encoding]::new($false)
  )

  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $InstalledExe
  $startInfo.ArgumentList.Add('kernel-stdio')
  $startInfo.WorkingDirectory = $tempWorkspace
  $startInfo.UseShellExecute = $false
  $startInfo.RedirectStandardInput = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $startInfo.CreateNoWindow = $true
  $startInfo.Environment['VANTARI_HOME'] = $smokeRoot
  $startInfo.Environment['VANTARI_WORKSPACE'] = $tempWorkspace
  [void]$startInfo.Environment.Remove('VANTARI_TEST_ROOT')

  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  if (-not $process.Start()) { throw 'Could not start installed kernel' }
  $started = $true
  $notifications = [Collections.Generic.List[object]]::new()

  Write-RpcFrame -Stream $process.StandardInput.BaseStream -Json '{"jsonrpc":"2.0","id":"summary-create","method":"session/create","params":{"prompt":"Prove installed summary migration.","enable_agent_tools":false}}'
  $created = Read-RpcResponse -Stream $process.StandardOutput.BaseStream -Id 'summary-create' -Notifications $notifications
  $createError = $created.PSObject.Properties['error']
  if ($created.id -ne 'summary-create' -or ($null -ne $createError -and $null -ne $createError.Value)) {
    throw 'Installed session/create failed'
  }
  $sessionId = [string]$created.result.session.session_id
  $messagesPath = Join-Path (Join-Path $sessionsRoot $sessionId) 'messages.jsonl'
  $sendRequest = [ordered]@{
    jsonrpc = '2.0'
    id = 'summary-send'
    method = 'session/send'
    params = [ordered]@{ session_id = $sessionId; enable_agent_tools = $false }
  } | ConvertTo-Json -Compress -Depth 5
  Write-RpcFrame -Stream $process.StandardInput.BaseStream -Json $sendRequest
  $sent = Read-RpcResponse -Stream $process.StandardOutput.BaseStream -Id 'summary-send' -Notifications $notifications
  $sendError = $sent.PSObject.Properties['error']
  if ($sent.id -ne 'summary-send' -or ($null -ne $sendError -and $null -ne $sendError.Value) -or $sent.result.session.status -ne 'completed') {
    throw 'Installed session/send did not complete'
  }
  $process.StandardInput.Close()
  if (-not $process.WaitForExit(5000)) { throw 'Installed kernel did not exit after EOF' }
  if ($process.ExitCode -ne 0) { throw "Installed kernel exited $($process.ExitCode): $($process.StandardError.ReadToEnd())" }

  if (-not (Test-Path -LiteralPath $messagesPath -PathType Leaf)) { throw 'messages.jsonl was not created' }
  $messageRows = 0
  $messageIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  $messageSequences = [Collections.Generic.HashSet[long]]::new()
  $messageRoles = [Collections.Generic.List[string]]::new()
  foreach ($line in Get-Content -LiteralPath $messagesPath) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $row = $line | ConvertFrom-Json
    $messageRows += 1
    if ([long]$row.seq -ne $messageRows) { throw "Non-contiguous installed message sequence: $($row.seq) at row $messageRows" }
    if (-not $messageIds.Add([string]$row.id)) { throw "Duplicate installed message id: $($row.id)" }
    if (-not $messageSequences.Add([long]$row.seq)) { throw "Duplicate installed message sequence: $($row.seq)" }
    $messageRoles.Add([string]$row.role)
  }
  if ($messageRows -ne 2) { throw "Installed turn wrote $messageRows messages; expected 2" }
  if ($messageRoles[0] -ne 'user' -or $messageRoles[1] -ne 'assistant') {
    throw "Installed message roles were not user,assistant: $([string]::Join(',', $messageRoles))"
  }

  $eventNotifications = @($notifications | Where-Object { $_.method -eq 'session/event' })
  if ($eventNotifications.Count -eq 0) { throw 'Installed turn emitted no session/event notifications' }
  $notificationSequences = [Collections.Generic.HashSet[long]]::new()
  $lastNotificationSeq = [long]0
  foreach ($notification in $eventNotifications) {
    if ($notification.params.schema -ne 'var1.session_event_notification.v1') {
      throw "Unexpected event notification schema: $($notification.params.schema)"
    }
    $seq = [long]$notification.params.seq
    if ($seq -le $lastNotificationSeq) { throw "Installed event notifications were not monotonic: $lastNotificationSeq then $seq" }
    if (-not $notificationSequences.Add($seq)) { throw "Duplicate installed event notification sequence: $seq" }
    $lastNotificationSeq = $seq
  }
  $eventsPath = Join-Path (Join-Path $sessionsRoot $sessionId) 'events.jsonl'
  if (-not (Test-Path -LiteralPath $eventsPath -PathType Leaf)) { throw 'events.jsonl was not created' }
  $lastStoredEvent = (Get-Content -LiteralPath $eventsPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1) | ConvertFrom-Json
  $lastNotification = $eventNotifications[-1].params
  if ([long]$lastStoredEvent.seq -ne $lastNotificationSeq) { throw 'Last installed event notification did not match stored sequence' }
  if ($lastStoredEvent.event_type -ne $lastNotification.event_type -or $lastStoredEvent.event_type -ne 'turn_finished') {
    throw "Installed terminal event order diverged: stored=$($lastStoredEvent.event_type) notified=$($lastNotification.event_type)"
  }

  if (-not (Test-Path -LiteralPath $jsonlPath -PathType Leaf)) { throw 'summaries.jsonl was not created' }
  $validRows = 0
  $sessions = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  $sequences = [Collections.Generic.HashSet[long]]::new()
  foreach ($line in Get-Content -LiteralPath $jsonlPath) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $row = $line | ConvertFrom-Json
    if ($row.schema -ne 'var1.session_summary.v2') { throw "Unexpected summary schema: $($row.schema)" }
    if (-not $sessions.Add([string]$row.session_id)) { throw "Duplicate imported session: $($row.session_id)" }
    if (-not $sequences.Add([long]$row.seq)) { throw "Duplicate imported sequence: $($row.seq)" }
    $validRows += 1
  }
  $expectedRows = $legacyRows + 1
  if ($validRows -ne $expectedRows) { throw "Imported/appended $validRows rows; expected $expectedRows" }
  if ((Get-FileHash -LiteralPath $legacyCopy -Algorithm SHA256).Hash -ne $legacyHash) { throw 'Legacy copy changed during migration' }
  if ((Get-FileHash -LiteralPath $LegacyLedger -Algorithm SHA256).Hash -ne $legacyHash) { throw 'Live legacy ledger changed during migration proof' }

  $provider.Stop()

  [pscustomobject]@{
    schema = 'var1.installed_summary_migration_proof.v1'
    legacy_rows = $legacyRows
    imported_rows = $legacyRows
    appended_rows = $validRows - $legacyRows
    unique_sessions = $sessions.Count
    unique_sequences = $sequences.Count
    message_rows = $messageRows
    message_unique_ids = $messageIds.Count
    message_unique_sequences = $messageSequences.Count
    message_roles = [string]::Join(',', $messageRoles)
    event_notifications = $eventNotifications.Count
    event_notification_unique_sequences = $notificationSequences.Count
    terminal_event_type = [string]$lastStoredEvent.event_type
    terminal_event_seq = [long]$lastStoredEvent.seq
    legacy_sha256 = $legacyHash
    installed_sha256 = (Get-FileHash -LiteralPath $InstalledExe -Algorithm SHA256).Hash
    process_exit_code = $process.ExitCode
    provider_requests = $provider.Requests
    provider_completion = $provider.SawCompletion
  } | ConvertTo-Json -Compress
} finally {
  if ($null -ne $process) {
    if ($started -and -not $process.HasExited) {
      $process.Kill($true)
      [void]$process.WaitForExit(5000)
    }
    $process.Dispose()
  }
  if ($null -ne $provider) { $provider.Dispose() }
  if (Test-Path -LiteralPath $smokeRoot) {
    $resolved = [IO.Path]::GetFullPath($smokeRoot)
    if (-not $resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Refusing cleanup outside temp root: $resolved" }
    [IO.Directory]::Delete($resolved, $true)
  }
}
