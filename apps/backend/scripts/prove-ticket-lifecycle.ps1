[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$BinaryPath,

  [ValidateRange(45, 180)]
  [int]$TimeoutSeconds = 90,

  [switch]$UnconstrainedChild,

  [string]$ResultPath = '',

  [string]$ErrorPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$backendRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$resolvedBinary = (Resolve-Path -LiteralPath $BinaryPath).Path
$binaryName = [IO.Path]::GetFileName($resolvedBinary)
$binaryHash = (Get-FileHash -LiteralPath $resolvedBinary -Algorithm SHA256).Hash
$canonicalInstalled = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Vantari\bin\vantari.exe'))
$artifactKind = if ([string]::Equals($resolvedBinary, $canonicalInstalled, [StringComparison]::OrdinalIgnoreCase)) { 'installed' } else { 'source' }

$proofBase = Join-Path $backendRoot '.zig-cache\owner-proofs'
New-Item -ItemType Directory -Force -Path $proofBase | Out-Null
$resolvedBase = (Resolve-Path -LiteralPath $proofBase).Path

if (-not ('VantariProofJobProbe' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class VantariProofJobProbe
{
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GetCurrentProcess();

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool IsProcessInJob(IntPtr processHandle, IntPtr jobHandle, out bool result);

    public static bool CurrentProcessIsInJob()
    {
        bool result;
        if (!IsProcessInJob(GetCurrentProcess(), IntPtr.Zero, out result))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        return result;
    }
}
'@
}

$currentProcessIsInJob = [VantariProofJobProbe]::CurrentProcessIsInJob()
if ($UnconstrainedChild -and $currentProcessIsInJob) {
  throw 'The out-of-job proof launcher remained constrained by a Windows Job Object'
}
if (-not $UnconstrainedChild -and $currentProcessIsInJob) {
  $launcherRoot = Join-Path $resolvedBase ('launcher-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $launcherRoot | Out-Null
  $childResultPath = Join-Path $launcherRoot 'result.json'
  $childErrorPath = Join-Path $launcherRoot 'error.txt'
  $powershellPath = (Get-Process -Id $PID).Path
  $scriptPath = $MyInvocation.MyCommand.Path
  $commandLine = '"{0}" -NoProfile -WindowStyle Hidden -File "{1}" -BinaryPath "{2}" -TimeoutSeconds {3} -UnconstrainedChild -ResultPath "{4}" -ErrorPath "{5}"' -f @(
    $powershellPath,
    $scriptPath,
    $resolvedBinary,
    $TimeoutSeconds,
    $childResultPath,
    $childErrorPath
  )
  $created = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
    CommandLine = $commandLine
    CurrentDirectory = $backendRoot
  }
  if ([uint32]$created.ReturnValue -ne 0 -or [uint32]$created.ProcessId -eq 0) {
    throw "Could not start unconstrained proof process: return=$($created.ReturnValue)"
  }

  $childProcessId = [int]$created.ProcessId
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds + 90)
  do {
    $childAlive = $null -ne (Get-Process -Id $childProcessId -ErrorAction SilentlyContinue)
    if (-not $childAlive) { break }
    Start-Sleep -Milliseconds 100
  } while ([DateTime]::UtcNow -lt $deadline)

  if ($childAlive) {
    Stop-Process -Id $childProcessId -Force -ErrorAction SilentlyContinue
    throw "Unconstrained proof process $childProcessId exceeded its bounded deadline"
  }
  if (Test-Path -LiteralPath $childErrorPath) {
    throw (Get-Content -Raw -LiteralPath $childErrorPath)
  }
  if (-not (Test-Path -LiteralPath $childResultPath)) {
    throw "Unconstrained proof process $childProcessId exited without a result"
  }
  Get-Content -Raw -LiteralPath $childResultPath
  return
}

$proofRoot = Join-Path $resolvedBase ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $proofRoot | Out-Null
$resolvedProof = (Resolve-Path -LiteralPath $proofRoot).Path
$requiredPrefix = $resolvedBase.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
if (-not $resolvedProof.StartsWith($requiredPrefix, [StringComparison]::OrdinalIgnoreCase)) {
  throw "Proof root escaped the owner-proofs directory: $resolvedProof"
}

$runtimeRoot = Join-Path $resolvedProof '.var'
$ticketsRoot = Join-Path $runtimeRoot 'tickets'
$ticketsPath = Join-Path $ticketsRoot 'tickets.jsonl'
$sessionsRoot = Join-Path $runtimeRoot 'sessions'
$ownerStatePath = Join-Path $runtimeRoot 'runtime\execution-owner.json'
$ticketId = 'ticket-lifecycle-proof'
$defaultConfigPath = Join-Path $backendRoot 'src\core\config\default.json'
$ownedProcessIds = [Collections.Generic.HashSet[int]]::new()
$tuiProcess = $null
$provider = $null

if (-not ('VantariTicketLifecycleProvider' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

public sealed class VantariTicketLifecycleProvider : IDisposable
{
    private sealed class Response
    {
        public string Body;
        public bool ExpectedDisconnect;
    }

    private readonly ManualResetEvent firstParentStarted = new ManualResetEvent(false);
    private readonly ManualResetEvent releaseFirstParent = new ManualResetEvent(false);
    private readonly object recipientLock = new object();
    private TcpListener listener;
    private Thread thread;
    private volatile bool stopping;
    private string directRecipient = "";
    private int parentRequests;
    private int childARequests;
    private int childBRequests;
    private int requests;

    public int Port { get; private set; }
    public int Requests { get { return Volatile.Read(ref requests); } }
    public int ParentRequests { get { return Volatile.Read(ref parentRequests); } }
    public int ChildARequests { get { return Volatile.Read(ref childARequests); } }
    public int ChildBRequests { get { return Volatile.Read(ref childBRequests); } }
    public bool SawGroupInChildB { get; private set; }
    public bool SawNestedMessagesInParent { get; private set; }
    public bool FirstParentWriteDisconnected { get; private set; }
    public Exception Error { get; private set; }

    public string DirectRecipient
    {
        get { lock (recipientLock) return directRecipient; }
        set { lock (recipientLock) directRecipient = value ?? ""; }
    }

    public void Start()
    {
        listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        Port = ((IPEndPoint)listener.LocalEndpoint).Port;
        thread = new Thread(Run) { IsBackground = true, Name = "vantari-ticket-lifecycle-provider" };
        thread.Start();
    }

    public bool WaitForFirstParent(int timeoutMs)
    {
        return firstParentStarted.WaitOne(timeoutMs);
    }

    public void ReleaseFirstParent()
    {
        releaseFirstParent.Set();
    }

    private void Run()
    {
        try
        {
            while (!stopping && Requests < 96)
            {
                TcpClient client;
                try { client = listener.AcceptTcpClient(); }
                catch (SocketException) { if (stopping) break; throw; }
                catch (ObjectDisposedException) { if (stopping) break; throw; }

                using (client)
                using (NetworkStream stream = client.GetStream())
                {
                    string headers = ReadHeaders(stream);
                    string firstLine = headers.Split(new[] { "\r\n" }, StringSplitOptions.None)[0];
                    string body = ReadBody(stream, ParseContentLength(headers));
                    Interlocked.Increment(ref requests);

                    Response response;
                    if (firstLine.IndexOf("/models", StringComparison.OrdinalIgnoreCase) >= 0)
                    {
                        response = new Response { Body = "{\"data\":[{\"id\":\"mesh-model\",\"context_length\":200000}]}" };
                    }
                    else if (firstLine.IndexOf("/chat/completions", StringComparison.OrdinalIgnoreCase) >= 0)
                    {
                        response = Completion(body);
                    }
                    else
                    {
                        throw new InvalidDataException("Unexpected provider request: " + firstLine);
                    }

                    try { WriteResponse(stream, response.Body); }
                    catch (IOException)
                    {
                        if (!response.ExpectedDisconnect) throw;
                        FirstParentWriteDisconnected = true;
                    }
                    catch (SocketException)
                    {
                        if (!response.ExpectedDisconnect) throw;
                        FirstParentWriteDisconnected = true;
                    }
                }
            }
        }
        catch (Exception ex)
        {
            if (!stopping) Error = ex;
        }
    }

    private Response Completion(string body)
    {
        if (body.IndexOf("Task:\\nMESH_SIBLING_A", StringComparison.Ordinal) >= 0)
        {
            int index = Interlocked.Increment(ref childARequests);
            if (index == 1)
            {
                return Tool("mesh-group", "send_agent_message", "{\"target\":\"current_group\",\"delivery\":\"wake\",\"message\":\"MESH_GROUP_NOTICE\",\"references\":[\"proof:move-30\"]}");
            }
            if (index == 2)
            {
                string recipient = DirectRecipient;
                if (recipient.Length == 0) throw new InvalidDataException("Direct recipient was not set");
                string args = "{\"target\":\"direct\",\"recipient_session_id\":" + JsonQuote(recipient) + ",\"delivery\":\"queue\",\"message\":\"MESH_DIRECT_NOTICE\",\"references\":[\"proof:move-30\"]}";
                return Tool("mesh-direct", "send_agent_message", args);
            }
            return Text("MESH_SIBLING_A_COMPLETE");
        }

        if (body.IndexOf("Task:\\nMESH_SIBLING_B", StringComparison.Ordinal) >= 0)
        {
            int index = Interlocked.Increment(ref childBRequests);
            if (index == 1)
            {
                return Tool("mesh-parent", "send_agent_message", "{\"target\":\"parent\",\"delivery\":\"wake\",\"message\":\"MESH_PARENT_NOTICE\",\"references\":[\"proof:move-30\"]}");
            }
            if (body.IndexOf("MESH_GROUP_NOTICE", StringComparison.Ordinal) >= 0)
            {
                SawGroupInChildB = true;
                return Text("MESH_SIBLING_B_COMPLETE");
            }
            return Tool("mesh-b-spin-" + index, "agents", "{}");
        }

        if (body.IndexOf("Task:\\nMESH_TICKET_PARENT", StringComparison.Ordinal) >= 0)
        {
            int index = Interlocked.Increment(ref parentRequests);
            if (index == 1)
            {
                firstParentStarted.Set();
                if (!releaseFirstParent.WaitOne(60000)) throw new TimeoutException("First parent request was not released");
                return new Response { Body = Text("MESH_UNCERTAIN_PRE_CRASH").Body, ExpectedDisconnect = true };
            }
            if (index == 2) return Tool("mesh-agents", "agents", "{}");
            if (index == 3)
            {
                string launchArgs = "{\"context\":\"MESH_NESTED_CONTEXT\",\"tasks\":[{\"name\":\"mesh-a\",\"agent\":\"general\",\"task\":\"MESH_SIBLING_A send one group wake and one direct parent message, then finish.\",\"output_schema\":{}},{\"name\":\"mesh-b\",\"agent\":\"general\",\"task\":\"MESH_SIBLING_B send one parent wake, observe the group message, then finish.\",\"output_schema\":{}}],\"scope_depth\":1,\"contact_budget\":2,\"background\":true,\"validation_status\":\"unverified\",\"escalation_reason\":\"Move 30 requires two siblings to prove group delivery.\"}";
                return Tool("mesh-launch", "launch_agent", launchArgs);
            }
            if (body.IndexOf("MESH_DIRECT_NOTICE", StringComparison.Ordinal) >= 0 &&
                body.IndexOf("MESH_PARENT_NOTICE", StringComparison.Ordinal) >= 0)
            {
                SawNestedMessagesInParent = true;
            }
            if (SawNestedMessagesInParent) return Text("MESH_TICKET_PARENT_COMPLETE");
            if (index == 4) return Text("MESH_WAITING_FOR_NESTED_CHILDREN");
            return Tool("mesh-parent-spin-" + index, "agents", "{}");
        }

        return Text("MESH_UNEXPECTED_PROMPT_COMPLETE");
    }

    private static Response Tool(string id, string name, string arguments)
    {
        string body = "{\"model\":\"mesh-model\",\"choices\":[{\"message\":{\"content\":null,\"tool_calls\":[{\"id\":" + JsonQuote(id) + ",\"type\":\"function\",\"function\":{\"name\":" + JsonQuote(name) + ",\"arguments\":" + JsonQuote(arguments) + "}}]}}]}";
        return new Response { Body = body };
    }

    private static Response Text(string value)
    {
        return new Response { Body = "{\"model\":\"mesh-model\",\"choices\":[{\"message\":{\"content\":" + JsonQuote(value) + "}}]}" };
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

    private static string ReadBody(NetworkStream stream, int length)
    {
        byte[] buffer = new byte[length];
        int offset = 0;
        while (offset < length)
        {
            int read = stream.Read(buffer, offset, length - offset);
            if (read == 0) throw new EndOfStreamException("HTTP request body ended early");
            offset += read;
        }
        return Encoding.UTF8.GetString(buffer);
    }

    private static void WriteResponse(NetworkStream stream, string body)
    {
        byte[] payload = Encoding.UTF8.GetBytes(body);
        byte[] header = Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " + payload.Length + "\r\nConnection: close\r\n\r\n");
        stream.Write(header, 0, header.Length);
        stream.Write(payload, 0, payload.Length);
        stream.Flush();
    }

    private static string JsonQuote(string value)
    {
        return "\"" + value
            .Replace("\\", "\\\\")
            .Replace("\"", "\\\"")
            .Replace("\r", "\\r")
            .Replace("\n", "\\n") + "\"";
    }

    public void Stop()
    {
        stopping = true;
        releaseFirstParent.Set();
        if (listener != null) listener.Stop();
        if (thread != null && !thread.Join(5000)) throw new TimeoutException("Fake provider did not stop");
        if (Error != null) throw new InvalidOperationException("Fake provider failed", Error);
    }

    public void Dispose()
    {
        stopping = true;
        releaseFirstParent.Set();
        if (listener != null) listener.Stop();
        if (thread != null) thread.Join(5000);
    }
}
'@
}

function Get-UnixTimeMilliseconds {
  return [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
}

function Read-JsonLines([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return @() }
  return @(
    Get-Content -LiteralPath $Path |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      ForEach-Object { $_ | ConvertFrom-Json }
  )
}

function Read-TicketEvents {
  return @(Read-JsonLines -Path $ticketsPath | Where-Object { $_.ticket_id -eq $ticketId })
}

function Read-OwnerState {
  if (-not (Test-Path -LiteralPath $ownerStatePath)) {
    throw "Owner projection is missing: $ownerStatePath"
  }
  return Get-Content -Raw -LiteralPath $ownerStatePath | ConvertFrom-Json
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

function Wait-ProcessTreeGone([int[]]$ProcessIds, [int]$Timeout) {
  $deadline = [DateTime]::UtcNow.AddSeconds($Timeout)
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

function Invoke-Health {
  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $resolvedBinary
  $startInfo.ArgumentList.Add('health')
  $startInfo.ArgumentList.Add('--json')
  $startInfo.WorkingDirectory = $resolvedProof
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $startInfo.Environment['VANTARI_WORKSPACE'] = $resolvedProof
  $startInfo.Environment['VANTARI_HOME'] = $runtimeRoot
  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  if (-not $process.Start()) { throw 'Could not start health client' }
  if (-not $process.WaitForExit(30000)) {
    $process.Kill($true)
    $null = $process.WaitForExit(5000)
    throw 'Health client exceeded 30 seconds'
  }
  $stdout = $process.StandardOutput.ReadToEnd().Trim()
  $stderr = $process.StandardError.ReadToEnd().Trim()
  if ($process.ExitCode -ne 0) {
    throw "Health failed with exit code $($process.ExitCode)`: stdout=$stdout stderr=$stderr"
  }
  return $stdout | ConvertFrom-Json
}

function Stop-OwnerGracefully($State, [int]$KernelProcessId) {
  $headers = @{ 'x-var1-owner-token' = [string]$State.token }
  $response = Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:$($State.port)/owner/shutdown" -Headers $headers -TimeoutSec 15
  if ($response.status -ne 'accepted') {
    throw "Owner shutdown returned status '$($response.status)'"
  }
  if (-not (Wait-ProcessTreeGone -ProcessIds @([int]$State.pid, $KernelProcessId) -Timeout 15)) {
    throw "Owner tree did not drain: owner=$($State.pid), kernel=$KernelProcessId"
  }
  return [string]$response.status
}

function Wait-ForTicketEvent(
  [string]$EventType,
  [int]$Timeout,
  [int]$OwnerProcessId = 0,
  [int]$KernelProcessId = 0
) {
  $deadline = [DateTime]::UtcNow.AddSeconds($Timeout)
  do {
    $rows = @(Read-TicketEvents | Where-Object { $_.event_type -eq $EventType })
    if ($rows.Count -gt 0) { return $rows[-1] }
    foreach ($expected in @(
      [pscustomobject]@{ Role = 'owner'; ProcessId = $OwnerProcessId },
      [pscustomobject]@{ Role = 'kernel'; ProcessId = $KernelProcessId }
    )) {
      if ($expected.ProcessId -le 0) { continue }
      if ($null -ne (Get-Process -Id $expected.ProcessId -ErrorAction SilentlyContinue)) { continue }
      $leasePath = Join-Path $runtimeRoot 'schedules\lease.json'
      $lease = if (Test-Path -LiteralPath $leasePath) { Get-Content -Raw -LiteralPath $leasePath } else { '<missing>' }
      throw "Replacement $($expected.Role) process $($expected.ProcessId) exited while waiting for '$EventType'. Last scheduler lease: $lease"
    }
    Start-Sleep -Milliseconds 100
  } while ([DateTime]::UtcNow -lt $deadline)
  throw "Ticket event '$EventType' was not observed within $Timeout seconds"
}

function Read-SessionRecords {
  if (-not (Test-Path -LiteralPath $sessionsRoot)) { return @() }
  return @(
    Get-ChildItem -LiteralPath $sessionsRoot -Filter 'session.json' -Recurse -File |
      ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName | ConvertFrom-Json }
  )
}

function Read-MailRows($SessionRecords) {
  $rows = @()
  foreach ($session in $SessionRecords) {
    $eventsPath = Join-Path (Join-Path $sessionsRoot ([string]$session.id)) 'events.jsonl'
    foreach ($event in @(Read-JsonLines -Path $eventsPath)) {
      if ($event.event_type -notin @('agent_message_sent', 'agent_message_received', 'agent_mailbox_cursor')) { continue }
      $rows += [pscustomobject]@{
        session_id = [string]$session.id
        event_type = [string]$event.event_type
        seq = [uint64]$event.seq
        payload = $event.message | ConvertFrom-Json
      }
    }
  }
  return @($rows)
}

try {
  New-Item -ItemType Directory -Force -Path $runtimeRoot, $ticketsRoot | Out-Null
  Copy-Item -LiteralPath $defaultConfigPath -Destination (Join-Path $runtimeRoot 'config.json')

  $provider = [VantariTicketLifecycleProvider]::new()
  $provider.Start()
  [IO.File]::WriteAllText(
    (Join-Path $resolvedProof '.env'),
    "BASE_URL=http://127.0.0.1:$($provider.Port)`nAPI_KEY=mesh-key`nMODEL=mesh-model`nWORKSPACE=$resolvedProof`nMAX_STEPS=32`n",
    [Text.UTF8Encoding]::new($false)
  )

  $env:VANTARI_WORKSPACE = $resolvedProof
  $env:VANTARI_HOME = $runtimeRoot

  [ordered]@{
    schema = 'var1.ticket_event.v2'
    seq = 1
    event_type = 'create'
    id = $ticketId
    ticket_id = $ticketId
    title = 'Move 30 Windows lifecycle proof'
    description = 'MESH_TICKET_PARENT survive owner loss, resume the same session, launch two children, receive nested messages, and complete.'
    category = 'agent'
    severity = 'high'
    status = 'assigned'
    proposed_owner = 'general'
    workspace_root = $resolvedProof
    source = 'native-proof'
    idempotency_key = 'ticket-lifecycle-proof-create'
    revision = 1
    created_at_ms = Get-UnixTimeMilliseconds
    transitioned_at_ms = Get-UnixTimeMilliseconds
  } | ConvertTo-Json -Compress | Set-Content -LiteralPath $ticketsPath -Encoding utf8NoBOM

  if (Test-Path -LiteralPath $sessionsRoot) {
    throw 'Queue-only assignment created a sessions root before scheduler start'
  }

  $null = Invoke-Health
  $firstOwner = Read-OwnerState
  $null = $ownedProcessIds.Add([int]$firstOwner.pid)
  $firstKernel = Get-KernelChild -OwnerProcessId ([int]$firstOwner.pid)
  $null = $ownedProcessIds.Add([int]$firstKernel.ProcessId)

  if (-not $provider.WaitForFirstParent(20000)) {
    throw 'The claimed child did not reach its first provider request'
  }
  $claim = Wait-ForTicketEvent -EventType 'claim' -Timeout 10
  $provider.DirectRecipient = [string]$claim.session_id
  $initialChild = Read-SessionRecords | Where-Object { $_.id -eq [string]$claim.session_id } | Select-Object -First 1
  if ($null -eq $initialChild -or $null -eq $initialChild.execution_receipt) {
    throw 'Claimed child session or execution receipt is missing'
  }

  # `Start-Process -WindowStyle Hidden` can create a valid hidden console on
  # Windows. That makes `-c` enter the interactive loop instead of exercising
  # the noninteractive terminal boundary. Add one pipe-owning PowerShell
  # wrapper so the actual VANTARI child receives a closed redirected stdin;
  # drain the wrapper streams while it starts and retain the typed envelope.
  $quotedBinary = $resolvedBinary.Replace('"', '""')
  $tuiWrapperCommand = '& "' + $quotedBinary + '" -c'
  $tuiWrapperEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($tuiWrapperCommand))
  $tuiStartInfo = [Diagnostics.ProcessStartInfo]::new()
  $tuiStartInfo.FileName = (Get-Process -Id $PID).Path
  $tuiStartInfo.Arguments = "-NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand $tuiWrapperEncoded"
  $tuiStartInfo.WorkingDirectory = $resolvedProof
  $tuiStartInfo.UseShellExecute = $false
  $tuiStartInfo.CreateNoWindow = $true
  $tuiStartInfo.RedirectStandardInput = $true
  $tuiStartInfo.RedirectStandardOutput = $true
  $tuiStartInfo.RedirectStandardError = $true
  $tuiStartInfo.Environment['VANTARI_WORKSPACE'] = $resolvedProof
  $tuiStartInfo.Environment['VANTARI_HOME'] = $runtimeRoot
  $tuiProcess = [Diagnostics.Process]::new()
  $tuiProcess.StartInfo = $tuiStartInfo
  if (-not $tuiProcess.Start()) { throw 'Could not start noninteractive TUI proof process' }
  $tuiStdoutTask = $tuiProcess.StandardOutput.ReadToEndAsync()
  $tuiStderrTask = $tuiProcess.StandardError.ReadToEndAsync()
  $tuiProcess.StandardInput.Close()
  $null = $ownedProcessIds.Add([int]$tuiProcess.Id)
  if (-not $tuiProcess.WaitForExit(15000)) {
    Stop-Process -Id $tuiProcess.Id -Force -ErrorAction SilentlyContinue
    $tuiStdout = $tuiStdoutTask.GetAwaiter().GetResult()
    $tuiStderr = $tuiStderrTask.GetAwaiter().GetResult()
    throw "Noninteractive TUI did not detach within 15 seconds: stdout=$tuiStdout stderr=$tuiStderr"
  }
  $tuiStdout = $tuiStdoutTask.GetAwaiter().GetResult()
  $tuiStderr = $tuiStderrTask.GetAwaiter().GetResult()
  $tuiExitCode = $tuiProcess.ExitCode
  if ($tuiExitCode -eq 0 -or $tuiStderr -notmatch 'TerminalUnavailable') {
    throw "Noninteractive TUI missed the typed terminal boundary: exit=$tuiExitCode stdout=$tuiStdout stderr=$tuiStderr"
  }
  if ($null -eq (Get-Process -Id ([int]$firstOwner.pid) -ErrorAction SilentlyContinue) -or
      $null -eq (Get-Process -Id ([int]$firstKernel.ProcessId) -ErrorAction SilentlyContinue) -or
      $provider.ParentRequests -ne 1) {
    throw 'Claimed work did not survive TUI/client detach'
  }

  Stop-Process -Id ([int]$firstOwner.pid) -Force
  $firstTreeGone = Wait-ProcessTreeGone -ProcessIds @([int]$firstOwner.pid, [int]$firstKernel.ProcessId) -Timeout 15
  if (-not $firstTreeGone) {
    throw "Forced owner tree survived: owner=$($firstOwner.pid), kernel=$($firstKernel.ProcessId)"
  }
  $provider.ReleaseFirstParent()

  $null = Invoke-Health
  $secondOwner = Read-OwnerState
  $null = $ownedProcessIds.Add([int]$secondOwner.pid)
  $secondKernel = Get-KernelChild -OwnerProcessId ([int]$secondOwner.pid)
  $null = $ownedProcessIds.Add([int]$secondKernel.ProcessId)
  if ([string]$secondOwner.generation -eq [string]$firstOwner.generation) {
    throw 'Replacement owner reused the dead generation'
  }

  $resume = Wait-ForTicketEvent -EventType 'resume' -Timeout $TimeoutSeconds -OwnerProcessId ([int]$secondOwner.pid) -KernelProcessId ([int]$secondKernel.ProcessId)
  $complete = Wait-ForTicketEvent -EventType 'complete' -Timeout $TimeoutSeconds -OwnerProcessId ([int]$secondOwner.pid) -KernelProcessId ([int]$secondKernel.ProcessId)
  if ([string]$resume.session_id -ne [string]$claim.session_id -or [uint32]$resume.attempt -ne [uint32]$claim.attempt) {
    throw 'Resume changed the ticket session or attempt identity'
  }
  if ([uint64]$resume.worker_generation -eq [uint64]$claim.worker_generation -or [uint64]$resume.worker_generation -eq 0) {
    throw 'Resume did not adopt a new nonzero worker generation'
  }
  if ([string]$resume.capability_hash -ne [string]$claim.capability_hash) {
    throw 'Resume changed the ticket capability identity'
  }
  $ticketEvents = Read-TicketEvents
  foreach ($eventType in @('create', 'claim', 'resume', 'complete')) {
    $count = @($ticketEvents | Where-Object { $_.event_type -eq $eventType }).Count
    if ($count -ne 1) { throw "Expected one '$eventType' ticket event; found $count" }
  }

  $sessions = Read-SessionRecords
  $finalChild = $sessions | Where-Object { $_.id -eq [string]$claim.session_id } | Select-Object -First 1
  if ($null -eq $finalChild -or [string]$finalChild.status -ne 'completed') {
    throw 'Resumed ticket child did not reach completed session state'
  }
  foreach ($field in @('group_id', 'task_id', 'capability_hash')) {
    if ([string]$initialChild.execution_receipt.$field -ne [string]$finalChild.execution_receipt.$field) {
      throw "Execution receipt field '$field' changed across owner recovery"
    }
  }

  $nested = @($sessions | Where-Object {
    $null -ne $_.execution_receipt -and [string]$_.parent_session_id -eq [string]$claim.session_id
  })
  if ($nested.Count -ne 2) {
    throw "Expected two nested child sessions; found $($nested.Count)"
  }

  $mailRows = @(Read-MailRows -SessionRecords $sessions)

  $expectedBodies = @('MESH_GROUP_NOTICE', 'MESH_DIRECT_NOTICE', 'MESH_PARENT_NOTICE')
  foreach ($body in $expectedBodies) {
    $received = @($mailRows | Where-Object { $_.event_type -eq 'agent_message_received' -and [string]$_.payload.body -eq $body })
    if ($received.Count -ne 1) { throw "Expected one received '$body' message; found $($received.Count)" }
    $messageId = [string]$received[0].payload.message_id
    $sent = @($mailRows | Where-Object { $_.event_type -eq 'agent_message_sent' -and [string]$_.payload.message_id -eq $messageId })
    if ($sent.Count -ne 1) { throw "Expected one sent receipt for '$body'; found $($sent.Count)" }
  }

  $receivedMessageIds = @($mailRows | Where-Object { $_.event_type -eq 'agent_message_received' } | ForEach-Object { [string]$_.payload.message_id })
  if (@($receivedMessageIds | Group-Object | Where-Object { $_.Count -gt 1 }).Count -ne 0) {
    throw 'Duplicate recipient message ids were persisted'
  }
  if (-not $provider.SawGroupInChildB -or -not $provider.SawNestedMessagesInParent) {
    throw "Provider context missed durable collaboration input: sibling=$($provider.SawGroupInChildB) parent=$($provider.SawNestedMessagesInParent)"
  }

  foreach ($received in @($mailRows | Where-Object { $_.event_type -eq 'agent_message_received' -and [string]$_.payload.body -in $expectedBodies })) {
    $messagesPath = Join-Path (Join-Path $sessionsRoot ([string]$received.session_id)) 'messages.jsonl'
    $transcript = Get-Content -Raw -LiteralPath $messagesPath
    $body = [string]$received.payload.body
    if ($transcript.Contains($body)) {
      throw "Mailbox body '$body' was copied into recipient transcript $messagesPath"
    }
  }

  $secondShutdown = Stop-OwnerGracefully -State $secondOwner -KernelProcessId ([int]$secondKernel.ProcessId)
  $finalZero = Wait-ProcessTreeGone -ProcessIds @($ownedProcessIds) -Timeout 3
  if (-not $finalZero) {
    throw "Proof-owned processes survived final shutdown: $(@($ownedProcessIds) -join ',')"
  }

  $postShutdownTicketEvents = @(Read-TicketEvents)
  foreach ($eventType in @('create', 'claim', 'resume', 'complete')) {
    $count = @($postShutdownTicketEvents | Where-Object { $_.event_type -eq $eventType }).Count
    if ($count -ne 1) { throw "Post-shutdown read expected one '$eventType' ticket event; found $count" }
  }
  $postShutdownSessions = @(Read-SessionRecords)
  $postShutdownChild = $postShutdownSessions | Where-Object { $_.id -eq [string]$claim.session_id } | Select-Object -First 1
  if ($null -eq $postShutdownChild -or [string]$postShutdownChild.status -ne 'completed') {
    throw 'Post-shutdown read lost the completed ticket child'
  }
  $postShutdownMailRows = @(Read-MailRows -SessionRecords $postShutdownSessions)
  $postShutdownReceivedIds = @(
    $postShutdownMailRows |
      Where-Object { $_.event_type -eq 'agent_message_received' } |
      ForEach-Object { [string]$_.payload.message_id } |
      Sort-Object
  )
  $expectedReceivedIds = @($receivedMessageIds | Sort-Object)
  if (($postShutdownReceivedIds -join "`n") -ne ($expectedReceivedIds -join "`n")) {
    throw 'Post-shutdown read changed the recipient message identity set'
  }

  $provider.Stop()
  $providerStopped = $true
  $resultJson = [pscustomobject]@{
    type = 'var1.ticket_lifecycle_proof.v1'
    artifact_kind = $artifactKind
    binary_path = $resolvedBinary
    binary_sha256 = $binaryHash
    proof_root = $resolvedProof
    assignment_side_effect_free = $true
    tui_exit_code = $tuiExitCode
    tui_terminal_boundary = 'TerminalUnavailable'
    work_survived_tui_detach = $true
    first_owner_pid = [int]$firstOwner.pid
    first_kernel_pid = [int]$firstKernel.ProcessId
    first_owner_generation = [string]$firstOwner.generation
    forced_tree_zero = $firstTreeGone
    second_owner_pid = [int]$secondOwner.pid
    second_kernel_pid = [int]$secondKernel.ProcessId
    second_owner_generation = [string]$secondOwner.generation
    second_shutdown = $secondShutdown
    ticket_id = $ticketId
    ticket_attempt = [uint32]$claim.attempt
    ticket_session_id = [string]$claim.session_id
    claim_rows = 1
    resume_rows = 1
    complete_rows = 1
    worker_generation_changed = ([uint64]$claim.worker_generation -ne [uint64]$resume.worker_generation)
    nested_children = $nested.Count
    directed_messages = 1
    group_messages = 1
    parent_messages = 1
    unique_received_messages = $receivedMessageIds.Count
    sibling_context_observed = $provider.SawGroupInChildB
    parent_context_observed = $provider.SawNestedMessagesInParent
    transcript_copy_count = 0
    provider_parent_requests = $provider.ParentRequests
    provider_child_a_requests = $provider.ChildARequests
    provider_child_b_requests = $provider.ChildBRequests
    post_shutdown_readback = $true
    final_zero_processes = $finalZero
  } | ConvertTo-Json -Compress
  [IO.File]::WriteAllText((Join-Path $resolvedProof 'result.json'), $resultJson, [Text.UTF8Encoding]::new($false))
  if (-not [string]::IsNullOrWhiteSpace($ResultPath)) {
    [IO.File]::WriteAllText($ResultPath, $resultJson, [Text.UTF8Encoding]::new($false))
  }
  Write-Output $resultJson
} catch {
  [IO.File]::WriteAllText((Join-Path $resolvedProof 'error.txt'), ($_ | Out-String), [Text.UTF8Encoding]::new($false))
  if (-not [string]::IsNullOrWhiteSpace($ErrorPath)) {
    [IO.File]::WriteAllText($ErrorPath, ($_ | Out-String), [Text.UTF8Encoding]::new($false))
  }
  throw
} finally {
  if ($null -ne $provider) {
    try { $provider.ReleaseFirstParent() } catch {}
    try { $provider.Dispose() } catch {}
  }
  if ($null -ne $tuiProcess) {
    try {
      $tuiProcess.Refresh()
      if (-not $tuiProcess.HasExited) { Stop-Process -Id $tuiProcess.Id -Force -ErrorAction SilentlyContinue }
    } catch {}
  }
  if (Test-Path -LiteralPath $ownerStatePath) {
    try {
      $current = Get-Content -Raw -LiteralPath $ownerStatePath | ConvertFrom-Json
      $null = $ownedProcessIds.Add([int]$current.pid)
      foreach ($child in @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $([int]$current.pid)")) {
        if ($child.Name -eq $binaryName) { $null = $ownedProcessIds.Add([int]$child.ProcessId) }
      }
    } catch {}
  }
  foreach ($processId in @($ownedProcessIds)) {
    if ($null -ne (Get-Process -Id $processId -ErrorAction SilentlyContinue)) {
      Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
    }
  }
}
