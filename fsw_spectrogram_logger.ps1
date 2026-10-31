#requires -Version 5.1
<#
.SYNOPSIS
Periodically export an existing FSW spectrogram history on the instrument itself.
.DESCRIPTION
No reset, measurement setup, trigger, acquisition mode or history-depth changes.
Uses raw SCPI TCP and Windows/.NET only. See README.md and docs/manual_evidence.md.
Files contain history snapshots, which can overlap or have gaps. Not raw I/Q.
.EXAMPLE
.\fsw_spectrogram_logger.ps1 -Window 2 -RunOnce
.EXAMPLE
.\fsw_spectrogram_logger.ps1 -ListWindows -Folder C:\FSW_Logs
.EXAMPLE
.\fsw_spectrogram_logger.ps1 -Window 2 -IntervalSeconds 10 -Folder E:\FSW_Logs
#>
[CmdletBinding()]
param(
    [ValidateRange(1,16)][int]$Window = 2,
    [ValidateRange(0.1,86400)][double]$IntervalSeconds = 10,
    [string]$Folder = 'C:\FSW_Logs',
    [Alias('Instrument')][string]$HostName = '127.0.0.1',
    [ValidateRange(1,65535)][int]$Port = 5025,
    [switch]$RunOnce,
    [switch]$ListWindows,
    [switch]$ClearAfterSave,
    [ValidateRange(0.1,120)][double]$ConnectionTimeoutSeconds = 5,
    [ValidateRange(0.1,600)][double]$CommandTimeoutSeconds = 10,
    [ValidateRange(0.1,3600)][double]$ExportTimeoutSeconds = 120,
    [ValidateRange(0.1,600)][double]$FileTimeoutSeconds = 5,
    [ValidateRange(0.1,3600)][double]$ValidationTimeoutSeconds = 120,
    [ValidateRange(0,10)][int]$MaxRetries = 2,
    [ValidateRange(0,60)][double]$RetryBackoffSeconds = 1,
    [ValidateRange(1,100)][int]$MaxConsecutiveFailures = 3,
    [ValidateRange(0,1000000000)][long]$MaxExports = 0,
    [ValidateRange(0,1000000000)][long]$MaxFileCount = 0,
    [ValidateRange(0,1000000000)][long]$MinimumFreeMB = 256,
    [string]$StopFile
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# C# is compiled in memory by Windows PowerShell's built-in Add-Type. There are
# no downloaded assemblies, external executables, modules or runtime packages.
# All socket waits poll a .NET cancellation flag; no PowerShell runs on a worker.
if (-not ('FswNative.Connection' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net.Sockets;
using System.Text;
using System.Threading;

namespace FswNative {
    public class ConfigurationException : Exception {
        public ConfigurationException(string message) : base(message) { }
    }
    public sealed class StopSignal : IDisposable {
        private readonly ManualResetEventSlim flag = new ManualResetEventSlim(false);
        private readonly ConsoleCancelEventHandler handler;
        private readonly Stopwatch fileClock = Stopwatch.StartNew();
        private long nextFileCheck;
        public string StopFile { get; set; }
        public bool Requested { get { return flag.IsSet; } }
        public void Request() { flag.Set(); }
        public StopSignal(bool listen) {
            if (listen) {
                handler = delegate(object sender, ConsoleCancelEventArgs args) {
                    args.Cancel = true; flag.Set();
                };
                Console.CancelKeyPress += handler;
            }
        }
        public void Check() {
            if (!String.IsNullOrEmpty(StopFile) && fileClock.ElapsedMilliseconds >= nextFileCheck) {
                nextFileCheck = fileClock.ElapsedMilliseconds + 100;
                if (File.Exists(StopFile)) flag.Set();
            }
            if (Requested) throw new OperationCanceledException("Stop requested.");
        }
        public void Wait(int milliseconds) { flag.Wait(milliseconds); Check(); }
        public void Dispose() {
            if (handler != null) Console.CancelKeyPress -= handler;
            flag.Dispose();
        }
    }
    public sealed class Connection : IDisposable {
        private readonly TcpClient client;
        private readonly NetworkStream stream;
        private readonly StopSignal stop;
        private readonly Queue<byte> buffered = new Queue<byte>();
        public string LastCommand { get; private set; }
        private static readonly Encoding Ascii = Encoding.GetEncoding(20127,
            EncoderFallback.ExceptionFallback, DecoderFallback.ExceptionFallback);
        private Connection(TcpClient c, StopSignal s) {
            client = c; stop = s; stream = c.GetStream(); client.NoDelay = true;
        }
        private static void Await(IAsyncResult pending, double seconds, StopSignal stop) {
            Stopwatch clock = Stopwatch.StartNew();
            using (WaitHandle handle = pending.AsyncWaitHandle) {
                while (true) {
                    stop.Check();
                    double left = seconds * 1000 - clock.Elapsed.TotalMilliseconds;
                    if (left <= 0) throw new TimeoutException("SCPI operation timed out.");
                    if (handle.WaitOne((int)Math.Min(200, Math.Max(1, left)))) return;
                }
            }
        }
        public static Connection Open(string host, int port, double seconds, StopSignal stop) {
            TcpClient c = new TcpClient();
            try {
                IAsyncResult pending = c.BeginConnect(host, port, null, null);
                Await(pending, seconds, stop);
                c.EndConnect(pending);
                // BeginConnect completion can still be a refused connection.
                if (!c.Connected) throw new SocketException((int)SocketError.NotConnected);
                return new Connection(c, stop);
            } catch { c.Close(); throw; }
        }
        public void Send(string command, double seconds) {
            stop.Check();
            if (command.IndexOf('\r') >= 0 || command.IndexOf('\n') >= 0)
                throw new ConfigurationException("SCPI command contains a line break.");
            LastCommand = command;
            byte[] bytes = Ascii.GetBytes(command + "\n");
            IAsyncResult pending = stream.BeginWrite(bytes, 0, bytes.Length, null, null);
            try { Await(pending, seconds, stop); stream.EndWrite(pending); }
            catch { client.Close(); throw; }
        }
        public string Query(string command, double seconds) {
            Send(command, seconds);
            Stopwatch clock = Stopwatch.StartNew();
            List<byte> line = new List<byte>();
            byte[] block = new byte[4096];
            while (true) {
                stop.Check();
                if (clock.Elapsed.TotalSeconds >= seconds)
                    throw new TimeoutException("Timed out waiting for reply to " + command);
                if (buffered.Count == 0) {
                    if (!client.Client.Poll(100000, SelectMode.SelectRead)) continue;
                    int count = stream.Read(block, 0, block.Length);
                    if (count == 0) throw new IOException("SCPI connection closed during " + command);
                    for (int i = 0; i < count; i++) buffered.Enqueue(block[i]);
                }
                byte value = buffered.Dequeue();
                if (value == 10) return Ascii.GetString(line.ToArray()).TrimEnd('\r');
                line.Add(value);
                if (line.Count > 65536)
                    throw new ConfigurationException("SCPI reply exceeds 64 KiB: " + command);
            }
        }
        public void Dispose() { stream.Dispose(); client.Close(); }
    }
    public sealed class ExportInfo {
        public long Bytes, Rows;
        public int Frames, PointsPerFrame;
        public string FirstTimestampRaw, LastTimestampRaw;
    }
    public static class Format {
        public static double Number(string text) {
            double value;
            if (!Double.TryParse(text.Trim().Replace(',', '.').Replace('D','E').Replace('d','e'),
                NumberStyles.Float, CultureInfo.InvariantCulture, out value) ||
                Double.IsNaN(value) || Double.IsInfinity(value))
                throw new ConfigurationException("Invalid numeric export field: " + text);
            return value;
        }
        public static string[] Csv(string text) {
            List<string> values = new List<string>(); StringBuilder value = new StringBuilder();
            char quote = '\0';
            for (int i=0; i<text.Length; i++) {
                char c=text[i];
                if (quote != '\0') {
                    if (c==quote) {
                        if (i+1<text.Length && text[i+1]==quote) { value.Append(c); i++; }
                        else quote='\0';
                    } else value.Append(c);
                } else if ((c=='\'' || c=='"') && value.ToString().Trim().Length==0) quote=c;
                else if (c==',') { values.Add(value.ToString().Trim()); value.Clear(); }
                else value.Append(c);
            }
            if (quote!='\0') throw new ConfigurationException("Unterminated quote in window catalogue.");
            values.Add(value.ToString().Trim()); return values.ToArray();
        }
        private static string Line(TextReader reader) {
            StringBuilder text = new StringBuilder(); int c;
            while ((c=reader.Read())!=-1) {
                if (c==10) return text.ToString().TrimEnd('\r');
                text.Append((char)c);
                if (text.Length>1048576) throw new ConfigurationException("Export line exceeds 1 MiB.");
            }
            return text.Length==0 ? null : text.ToString().TrimEnd('\r');
        }
        // Manual v57 table 8-12, pp.664-665. Validate without rewriting the file.
        public static ExportInfo Inspect(string path, double seconds, StopSignal stop) {
            ExportInfo info = new ExportInfo();
            int declaredFrames=0, points=0, rowsInFrame=0; bool inFrame=false, timestamp=false, hz=false;
            Stopwatch clock = Stopwatch.StartNew();
            using (FileStream file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read)) {
                info.Bytes=file.Length;
                using (StreamReader reader=new StreamReader(file,
                    Encoding.GetEncoding(20127, EncoderFallback.ExceptionFallback, DecoderFallback.ExceptionFallback), true, 65536)) {
                    string line;
                    while ((line=Line(reader))!=null) {
                        stop.Check();
                        if (clock.Elapsed.TotalSeconds>seconds) throw new TimeoutException("Export validation timed out.");
                        if (String.IsNullOrWhiteSpace(line)) continue;
                        string[] fields=line.Split(';'); string key=fields[0].Trim();
                        string value=fields.Length>1 ? fields[1].Trim() : "";
                        if (key.Equals("Values",StringComparison.OrdinalIgnoreCase)) {
                            if (!Int32.TryParse(value,out points) || points<1)
                                throw new ConfigurationException("Invalid Values count in spectrogram export.");
                        } else if (key.Equals("Frames",StringComparison.OrdinalIgnoreCase)) {
                            if (!Int32.TryParse(value,out declaredFrames) || declaredFrames<1)
                                throw new ConfigurationException("Empty/invalid spectrogram Frames count.");
                        } else if (key.Equals("x-Unit",StringComparison.OrdinalIgnoreCase)) {
                            hz=value.Equals("Hz",StringComparison.OrdinalIgnoreCase);
                        } else if (key.Equals("Span",StringComparison.OrdinalIgnoreCase)) {
                            if (Number(value)<=0) throw new ConfigurationException("Zero-span data is not supported.");
                        } else if (key.Equals("Frame",StringComparison.OrdinalIgnoreCase)) {
                            if (inFrame && (!timestamp || rowsInFrame!=points))
                                throw new ConfigurationException("Incomplete frame, timestamp or point count in export.");
                            int number;
                            if (!Int32.TryParse(value,out number)) throw new ConfigurationException("Invalid frame number.");
                            inFrame=true; timestamp=false; rowsInFrame=0; info.Frames++;
                        } else if (key.Equals("Timestamp",StringComparison.OrdinalIgnoreCase)) {
                            if (!inFrame || fields.Length<3 || value.Length==0 || fields[2].Trim().Length==0)
                                throw new ConfigurationException("Missing frame date/time metadata.");
                            string raw=String.Join(";",fields,1,fields.Length-1).TrimEnd(';');
                            if (info.FirstTimestampRaw==null) info.FirstTimestampRaw=raw;
                            info.LastTimestampRaw=raw; timestamp=true;
                        } else if (inFrame) {
                            if (!timestamp || fields.Length<2 || fields.Length>4 ||
                                (fields.Length==4 && fields[3].Trim().Length!=0))
                                throw new ConfigurationException("Unrecognized numeric spectrogram row.");
                            Number(fields[0]); Number(fields[1]);
                            if (fields.Length>=3 && fields[2].Trim().Length!=0) Number(fields[2]);
                            rowsInFrame++; info.Rows++;
                        }
                    }
                }
            }
            if (!inFrame || !timestamp || points<1 || !hz || rowsInFrame!=points ||
                declaredFrames!=info.Frames || info.Rows!=(long)points*declaredFrames)
                throw new ConfigurationException("Not a complete supported spectrogram ASCII file: require Hz, Values, Frames, Frame, Timestamp and matching rows. Check ASCII export settings / firmware.");
            FileInfo after=new FileInfo(path);
            if (after.Length!=info.Bytes) throw new IOException("Export changed during validation.");
            info.PointsPerFrame=points; return info;
        }
    }
}
'@
}

function Write-RunLog([string]$Level, [string]$Message) {
    $line = '{0} [{1}] {2}' -f [DateTimeOffset]::UtcNow.ToString('o'), $Level, ($Message -replace '[\r\n]+',' ')
    $script:Log.WriteLine($line)
    [Console]::WriteLine($line)
}

function Assert-Running {
    if ($StopFile -and [IO.File]::Exists($StopFile)) { $script:Stop.Request() }
    $script:Stop.Check()
}

function Wait-Interruptibly([double]$Seconds) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalSeconds -lt $Seconds) {
        Assert-Running
        $left = ($Seconds-$timer.Elapsed.TotalSeconds)*1000
        $script:Stop.Wait([int][Math]::Min(200,[Math]::Max(1,$left)))
    }
}

function Read-ErrorQueue($Connection, [string]$Context, [switch]$PreExisting) {
    $errors = New-Object 'Collections.Generic.List[string]'
    for ($i=0; $i -lt 16; $i++) {
        $reply = $Connection.Query('SYST:ERR?', $CommandTimeoutSeconds)
        if ($reply -notmatch '^\s*([+-]?\d+)\s*,') {
            throw [FswNative.ConfigurationException]::new("Invalid SYST:ERR? reply: $reply")
        }
        if ([int]$Matches[1] -eq 0) {
            if ($errors.Count -gt 0 -and -not $PreExisting) {
                throw [FswNative.ConfigurationException]::new("SCPI rejected $Context : $($errors -join ' | ')")
            }
            return
        }
        $errors.Add($reply)
        Write-RunLog 'SCPI' "$Context : $reply"
    }
    throw [FswNative.ConfigurationException]::new('SCPI error queue did not empty in 16 reads. Stop other controllers and inspect the instrument.')
}

function Query-Checked([string]$Command) {
    $reply = $script:Connection.Query($Command,$CommandTimeoutSeconds)
    Read-ErrorQueue $script:Connection $Command
    return $reply.Trim()
}

function Wait-Operation($Connection, [double]$Timeout) {
    $reply = $Connection.Query('*OPC?',$Timeout).Trim()
    if ($reply -ne '1' -and $reply -ne '+1') {
        throw [FswNative.ConfigurationException]::new("Unexpected *OPC? response: $reply")
    }
}

function Get-Windows {
    $catalogue = Query-Checked 'LAY:CAT?'
    $parts = [FswNative.Format]::Csv($catalogue)
    if ($parts.Count -lt 2 -or $parts.Count % 2 -ne 0) {
        throw [FswNative.ConfigurationException]::new("Unrecognized window catalogue: $catalogue")
    }
    for ($i=0; $i -lt $parts.Count; $i+=2) {
        $index = 0
        if (-not [int]::TryParse($parts[$i+1],[ref]$index) -or $index -lt 1 -or $index -gt 16) {
            throw [FswNative.ConfigurationException]::new("Invalid window index in catalogue: $catalogue")
        }
        [PSCustomObject]@{Name=$parts[$i]; Index=$index}
    }
}

function Assert-Context {
    $channel = Query-Checked 'INST:SEL?'
    if ($null -eq $script:InitialChannel) { $script:InitialChannel=$channel; Write-RunLog 'INFO' "Active channel=$channel" }
    elseif ($channel -ne $script:InitialChannel) {
        throw [FswNative.ConfigurationException]::new("Active channel changed from $script:InitialChannel to $channel. No channel is selected automatically.")
    }
    $windows = @(Get-Windows)
    if (-not ($windows | Where-Object {$_.Index -eq $Window})) {
        throw [FswNative.ConfigurationException]::new("Window $Window is absent. Use -ListWindows; indices refer to the active channel.")
    }
    $kind = (Query-Checked "LAY:WIND${Window}:TYPE?").Trim([char[]]@([char]39,[char]34)).ToUpperInvariant()
    if ($kind -ne 'SGR' -and $kind -ne 'SGRAM' -and $kind -ne 'SPECTROGRAM') {
        throw [FswNative.ConfigurationException]::new("Window $Window has type $kind, not a supported Spectrum spectrogram. No export attempted.")
    }
    $span = [FswNative.Format]::Number((Query-Checked 'SENS:FREQ:SPAN?'))
    if ($span -le 0) { throw [FswNative.ConfigurationException]::new('Positive frequency span required; zero-span logging is intentionally unsupported.') }
}

function Connect-Instrument {
    for ($attempt=0; $attempt -le $MaxRetries; $attempt++) {
        Assert-Running
        try {
            $script:Connection = [FswNative.Connection]::Open($HostName,$Port,$ConnectionTimeoutSeconds,$script:Stop)
            $identity=$script:Connection.Query('*IDN?',$CommandTimeoutSeconds).Trim().Trim('"')
            Write-RunLog 'INFO' "IDN=$identity endpoint=${HostName}:$Port"
            $idParts=$identity.Split(',')
            if ($idParts.Count -lt 4 -or $idParts[0] -notmatch '(?i)Rohde.*Schwarz' -or $idParts[1] -notmatch '^FSW(?:-?\d+)?$') {
                throw [FswNative.ConfigurationException]::new('Identity is not an R&S FSW. Custom/legacy IDN formats require manual verification; not changed automatically.')
            }
            if ($null -ne $script:Identity -and $identity -ne $script:Identity) {
                throw [FswNative.ConfigurationException]::new('Instrument identity changed after reconnect.')
            }
            $script:Identity=$identity
            Read-ErrorQueue $script:Connection 'pre-existing error' -PreExisting
            if ($ListWindows) { return }
            Assert-Context
            if ((Query-Checked 'SYST:DISP:LOCK?') -notin @('0','OFF')) {
                throw [FswNative.ConfigurationException]::new('Remote display update is locked. Enable it manually on the instrument; the logger does not unlock controls.')
            }
            $update=(Query-Checked 'SYST:DISP:UPD?').ToUpperInvariant()
            if ($update -notin @('0','1','ON','OFF')) { throw [FswNative.ConfigurationException]::new("Unknown display update setting: $update") }
            if ($null -eq $script:OriginalDisplay) { $script:OriginalDisplay=$update }
            if ($update -in @('0','OFF')) {
                # Keep diagrams available; no acquisition or measurement settings.
                $script:DisplayChanged=$true
                $script:Connection.Send('SYST:DISP:UPD ON',$CommandTimeoutSeconds)
                Wait-Operation $script:Connection $CommandTimeoutSeconds
                Read-ErrorQueue $script:Connection 'enable display update'
                Write-RunLog 'INFO' 'Remote display updates enabled; original setting will be restored on a confirmed clean exit.'
            }
            return
        } catch {
            $root=$_.Exception.GetBaseException()
            if ($null -ne $script:Connection) { $script:Connection.Dispose(); $script:Connection=$null }
            if ($root -is [FswNative.ConfigurationException] -or $root -is [OperationCanceledException]) { throw }
            Write-RunLog 'WARN' "Connection/setup attempt $($attempt+1)/$($MaxRetries+1): $($root.Message)"
            # Query errors may produce no reply. A new socket is safe for error
            # diagnosis; never send another query on the timed-out response stream.
            Get-FailureDiagnosis
            if ($attempt -eq $MaxRetries) { throw }
            Wait-Interruptibly ([Math]::Min(30,$RetryBackoffSeconds*[Math]::Pow(2,$attempt)))
        }
    }
}

function Get-FailureDiagnosis {
    $diagnostic=$null
    try {
        $diagnostic=[FswNative.Connection]::Open($HostName,$Port,$ConnectionTimeoutSeconds,$script:Stop)
        Read-ErrorQueue $diagnostic 'after transport failure'
    } catch {
        $root=$_.Exception.GetBaseException()
        if ($root -is [FswNative.ConfigurationException] -or $root -is [OperationCanceledException]) { throw }
        Write-RunLog 'WARN' "SCPI error diagnosis unavailable: $($root.Message)"
    } finally { if ($null -ne $diagnostic) { $diagnostic.Dispose() } }
}

function New-ExportReservation([string]$Directory, [string]$Token = ([Guid]::NewGuid().ToString('N')), [DateTimeOffset]$ExportTime = [DateTimeOffset]::UtcNow) {
    # Timestamp alone is not unique. GUID + CreateNew reservation + an exclusive
    # folder lock protect cooperating instances; arbitrary external writers cannot
    # be made atomic with a SCPI file-store command.
    $stamp=$ExportTime.ToUniversalTime().ToString('yyyyMMdd_HHmmss_fffZ')
    $path=[IO.Path]::Combine($Directory,"SGR_${stamp}_${Token}.dat")
    if ([IO.File]::Exists($path)) { throw [IO.IOException]::new("Refusing to overwrite $path") }
    $reservation=[IO.File]::Open($path+'.reserve',[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    return [PSCustomObject]@{Path=$path; Lock=$reservation}
}

function Test-Storage {
    $drive=[IO.DriveInfo]::new([IO.Path]::GetPathRoot($script:OutputFolder))
    if (-not $drive.IsReady -or $drive.AvailableFreeSpace -lt $MinimumFreeMB*1MB) {
        throw [FswNative.ConfigurationException]::new("Storage not ready or below MinimumFreeMB=$MinimumFreeMB. No files deleted.")
    }
    if ($MaxFileCount -gt 0) {
        $count=0
        foreach ($file in [IO.Directory]::EnumerateFiles($script:OutputFolder,'SGR_*.dat')) {
            Assert-Running; $count++
            if ($count -ge $MaxFileCount) { throw [FswNative.ConfigurationException]::new('MaxFileCount reached. No files deleted.') }
        }
    }
}

function Wait-ExportFile([string]$Path) {
    $timer=[Diagnostics.Stopwatch]::StartNew()
    do {
        Assert-Running
        if ([IO.File]::Exists($Path) -and ([IO.FileInfo]::new($Path)).Length -gt 0) { return }
        Wait-Interruptibly 0.1
    } while ($timer.Elapsed.TotalSeconds -lt $FileTimeoutSeconds)
    throw [IO.IOException]::new("Export completed but no nonempty local file appeared: $Path. Check instrument-side execution, permissions, storage and firmware.")
}

function Restore-Display {
    if (-not $script:DisplayChanged) { return }
    if ($script:Uncertain) {
        Write-RunLog 'WARN' 'Display restoration skipped: an operation may still be running. No additional SCPI changes are sent.'
        return
    }
    $cleanupStop=[FswNative.StopSignal]::new($false); $cleanup=$null
    try {
        $cleanup=[FswNative.Connection]::Open($HostName,$Port,2,$cleanupStop)
        $cleanup.Send(('SYST:DISP:UPD '+$script:OriginalDisplay),2)
        Wait-Operation $cleanup 2
        $reply=$cleanup.Query('SYST:ERR?',2)
        if ($reply -notmatch '^\s*\+?0\s*,') { throw [IO.IOException]::new($reply) }
        Write-RunLog 'INFO' "Original display update setting restored: $script:OriginalDisplay"
    } catch { Write-RunLog 'WARN' "Could not confirm display restoration: $($_.Exception.GetBaseException().Message). Restore it manually; measurement settings were not changed." }
    finally { if ($null -ne $cleanup) { $cleanup.Dispose() }; $cleanupStop.Dispose() }
}

function Invoke-FswLogger {
    $script:Connection=$null; $script:InitialChannel=$null; $script:Identity=$null
    $script:OriginalDisplay=$null; $script:DisplayChanged=$false; $script:Uncertain=$false
    $script:Log=$null; $script:Stop=$null; $folderLock=$null; $reservation=$null
    $exitCode=0; $successes=0; $failures=0
    try {
        if ($Folder -notmatch '^[A-Za-z]:[\\/]' -or $Folder -match '[^\x20-\x7e]|[''"\r\n]' -or $Folder.Contains(';')) {
            throw [FswNative.ConfigurationException]::new('Folder must be an absolute local/USB drive path using printable ASCII without quotes or semicolons (for safe SCPI quoting).')
        }
        $script:OutputFolder=[IO.Path]::GetFullPath($Folder)
        if ($script:OutputFolder.Length -gt 150) { throw [FswNative.ConfigurationException]::new('Output folder is too long; use at most 150 characters for Windows path compatibility.') }
        if ($StopFile -and $StopFile -notmatch '^[A-Za-z]:[\\/]') { throw [FswNative.ConfigurationException]::new('StopFile must be an absolute local path.') }
        if ($ListWindows -and $ClearAfterSave) { throw [FswNative.ConfigurationException]::new('ListWindows cannot be combined with ClearAfterSave.') }
        [IO.Directory]::CreateDirectory($script:OutputFolder) | Out-Null
        $folderLock=[IO.File]::Open([IO.Path]::Combine($script:OutputFolder,'.fsw_logger.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $logPath=[IO.Path]::Combine($script:OutputFolder,('logger_'+[DateTimeOffset]::UtcNow.ToString('yyyyMMdd_HHmmss_fffZ')+'_'+[Guid]::NewGuid().ToString('N')+'.log'))
        $logStream=[IO.File]::Open($logPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
        $script:Log=[IO.StreamWriter]::new($logStream,[Text.UTF8Encoding]::new($false)); $script:Log.AutoFlush=$true
        $script:Stop=[FswNative.StopSignal]::new($true)
        $script:Stop.StopFile=$StopFile
        Write-RunLog 'INFO' "FSW spectrogram logger 0.1.0; window=$Window interval_s=$IntervalSeconds log=$logPath"
        Write-RunLog 'INFO' 'Snapshot filenames/logs use export wall-clock UTC, not measurement time. History is preserved unless ClearAfterSave was explicitly selected. Ctrl+C or StopFile stops logging.'
        if ($ClearAfterSave) { Write-RunLog 'WARN' 'ClearAfterSave selected: clearing can affect ALL spectrogram windows in this channel and can lose newly acquired frames. Not gapless.' }
        $clock=[Diagnostics.Stopwatch]::StartNew(); $due=0.0
        while ($true) {
            Assert-Running
            try {
                if ($null -eq $script:Connection) { Connect-Instrument }
                if ($ListWindows) {
                    foreach ($entry in @(Get-Windows)) {
                        $type=Query-Checked "LAY:WIND$($entry.Index):TYPE?"
                        Write-RunLog 'INFO' "Window=$($entry.Index) Name=$($entry.Name) Type=$type"
                    }
                    break
                }
                Assert-Context; Test-Storage
                $reservation=New-ExportReservation $script:OutputFolder
                $started=[DateTimeOffset]::UtcNow; $exportTimer=[Diagnostics.Stopwatch]::StartNew()
                $command="MMEM:STOR${Window}:SGR '$($reservation.Path)'"
                Write-RunLog 'INFO' "EXPORT_BEGIN started_utc=$($started.ToString('o')) path=$($reservation.Path)"
                $script:Uncertain=$true  # Even a failed write may have reached FSW.
                $script:Connection.Send($command,$CommandTimeoutSeconds)
                Wait-Operation $script:Connection $ExportTimeoutSeconds
                $script:Uncertain=$false
                Read-ErrorQueue $script:Connection $command
                Wait-ExportFile $reservation.Path
                $info=[FswNative.Format]::Inspect($reservation.Path,$ValidationTimeoutSeconds,$script:Stop)
                # Reject context changes during export before allowing any clear.
                Assert-Context
                $elapsed=$exportTimer.Elapsed.TotalSeconds.ToString('F3',[Globalization.CultureInfo]::InvariantCulture)
                Write-RunLog 'INFO' "EXPORT_OK path=$($reservation.Path) bytes=$($info.Bytes) elapsed_s=$elapsed frames=$($info.Frames) points_per_frame=$($info.PointsPerFrame) first_frame_time_raw=$($info.FirstTimestampRaw) last_frame_time_raw=$($info.LastTimestampRaw)"
                if ($ClearAfterSave) {
                    Assert-Running
                    $script:Uncertain=$true
                    $script:Connection.Send("CALC${Window}:SGR:CLE",$CommandTimeoutSeconds)
                    Wait-Operation $script:Connection $ExportTimeoutSeconds
                    $script:Uncertain=$false
                    Read-ErrorQueue $script:Connection 'clear spectrogram history'
                    Write-RunLog 'WARN' "HISTORY_CLEARED after verified file=$($reservation.Path); export-to-clear acquisition gap is possible."
                }
                $successes++; $failures=0
                if ($RunOnce -or ($MaxExports -gt 0 -and $successes -ge $MaxExports)) { break }
            } catch {
                $root=$_.Exception.GetBaseException()
                if ($root -is [OperationCanceledException]) { throw }
                if ($script:Uncertain) {
                    Write-RunLog 'ERROR' "AMBIGUOUS_COMPLETION: $($root.Message). Export/clear may still be running; no operation is replayed. Existing/partial files retained. Inspect FSW before restarting."
                    $exitCode=3; break
                }
                if ($root -is [FswNative.ConfigurationException]) { throw }
                Write-RunLog 'ERROR' "Attempt failed: $($root.Message)"
                if ($null -ne $script:Connection) { $script:Connection.Dispose(); $script:Connection=$null }
                Get-FailureDiagnosis
                $failures++
                if ($RunOnce -or $failures -ge $MaxConsecutiveFailures) { $exitCode=1; break }
            } finally {
                if ($null -ne $reservation) {
                    $reservation.Lock.Dispose()
                    # Remove only this logger's empty reservation marker, never data.
                    [IO.File]::Delete($reservation.Path+'.reserve'); $reservation=$null
                }
            }
            # Fixed start-to-start monotonic schedule. Missed slots are skipped;
            # no catch-up burst and no overlapping exports, including after errors.
            $due += $IntervalSeconds
            if ($clock.Elapsed.TotalSeconds -gt $due) {
                $skipped=[Math]::Floor(($clock.Elapsed.TotalSeconds-$due)/$IntervalSeconds)+1
                $due += $skipped*$IntervalSeconds
                Write-RunLog 'WARN' "OVERRUN skipped_intervals=$skipped; next export follows the fixed monotonic schedule."
            }
            Wait-Interruptibly ([Math]::Max(0,$due-$clock.Elapsed.TotalSeconds))
        }
    } catch {
        $root=$_.Exception.GetBaseException()
        if ($root -is [OperationCanceledException]) {
            if ($null -ne $script:Log) { Write-RunLog 'INFO' 'Stop requested; saved files preserved.' }
            if ($script:Uncertain) { Write-RunLog 'WARN' 'Stop occurred during an unconfirmed export/clear; it may still finish on the FSW. No further SCPI changes are sent.' }
        } else {
            $exitCode=2
            if ($null -ne $script:Log) { Write-RunLog 'ERROR' $root.Message }
            else { [Console]::Error.WriteLine($root.Message) }
        }
    } finally {
        if ($null -ne $script:Connection) { $script:Connection.Dispose(); $script:Connection=$null }
        if ($null -ne $script:Log) {
            Restore-Display
            Write-RunLog 'INFO' "STOP successes=$successes exit_code=$exitCode"
            $script:Log.Dispose()
        }
        if ($null -ne $script:Stop) { $script:Stop.Dispose() }
        if ($null -ne $folderLock) { $folderLock.Dispose() }
    }
    return $exitCode
}

# Dot-source for deterministic helper tests; normal invocation runs the logger.
if ($MyInvocation.InvocationName -ne '.') { exit (Invoke-FswLogger) }
