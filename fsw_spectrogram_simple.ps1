#requires -Version 5.1
# Run on the FSW after configuring its Spectrum/spectrogram display. Ctrl+C stops.
param(
    [ValidateRange(1,16)][int]$Window = 2,
    [ValidateRange(0.1,86400)][double]$IntervalSeconds = 10,
    [string]$Folder = 'C:\FSW_Logs',
    [string]$HostName = '127.0.0.1', [ValidateRange(1,65535)][int]$Port = 5025,
    [ValidateRange(0.1,3600)][double]$TimeoutSeconds = 120,
    [switch]$RunOnce
)
$ErrorActionPreference = 'Stop'
if ($Folder -notmatch '^[A-Za-z]:[\\/]' -or $Folder -match '[^\x20-\x7e]|[''";]') {
    throw 'Use an absolute ASCII folder path without quotes or semicolons.'
}
$Folder = [IO.Path]::GetFullPath($Folder)
[IO.Directory]::CreateDirectory($Folder) | Out-Null
$log = Join-Path $Folder ('simple_' + [guid]::NewGuid().ToString('N') + '.log')
$client = [Net.Sockets.TcpClient]::new()
$display = $null; $pending = $false; $writer = $null; $script:usable = $true

function Ask($command, $timeout = $TimeoutSeconds) {
    try {
        $writer.WriteLine($command)
        $reply = $reader.ReadLineAsync()
        if (-not $reply.Wait([TimeSpan]::FromSeconds($timeout))) { throw "SCPI timeout: $command" }
        $text = $reply.GetAwaiter().GetResult()
        if ($null -eq $text) { throw 'FSW connection closed.' }
        return $text.Trim()
    } catch { $script:usable = $false; throw }
}
function Check-Error {
    $errorReply = Ask 'SYST:ERR?'
    if ($errorReply -notmatch '^\+?0\s*,') { throw "FSW error: $errorReply" }
}
try {
    if (-not $client.ConnectAsync($HostName,$Port).Wait(5000)) { throw 'Connection timeout.' }
    $stream = $client.GetStream(); $stream.WriteTimeout = [int]($TimeoutSeconds*1000)
    $writer = [IO.StreamWriter]::new($stream,[Text.Encoding]::ASCII)
    $writer.NewLine = "`n"; $writer.AutoFlush = $true
    $reader = [IO.StreamReader]::new($stream,[Text.Encoding]::ASCII)
    Write-Host (Ask '*IDN?'); Check-Error
    if ((Ask "LAY:WIND${Window}:TYPE?").Trim([char[]]"'`"") -notmatch '^(SGR|SGRAM|SPECTROGRAM)$') { throw 'Choose an existing spectrogram window.' }
    $span = [double]::Parse((Ask 'SENS:FREQ:SPAN?'),[Globalization.CultureInfo]::InvariantCulture)
    if ($span -le 0 -or [double]::IsNaN($span) -or [double]::IsInfinity($span)) { throw 'Positive frequency span required.' }
    if ((Ask 'SYST:DISP:LOCK?') -notin @('0','OFF')) { throw 'Enable remote display updates manually first.' }
    $previous = Ask 'SYST:DISP:UPD?'
    if ($previous -notin @('0','1','ON','OFF')) { throw 'Unknown display update setting.' }
    $display = $previous
    $writer.WriteLine('SYST:DISP:UPD ON'); $null = Ask '*OPC?'; Check-Error
    $clock = [Diagnostics.Stopwatch]::StartNew(); $due = 0.0
    do {
        $start = $clock.Elapsed.TotalSeconds
        $name = 'SGR_' + [DateTimeOffset]::UtcNow.ToString('yyyyMMdd_HHmmss_fffZ') + '_' + [guid]::NewGuid().ToString('N') + '.dat'
        $path = Join-Path $Folder $name
        if ([IO.File]::Exists($path)) { throw 'File already exists; refusing to overwrite.' }
        $pending = $true  # A timeout/drop may leave an export running: never retry it.
        $writer.WriteLine("MMEM:STOR${Window}:SGR '$path'")
        if ((Ask '*OPC?') -notin @('1','+1')) { throw 'Export completion was not confirmed.' }
        $pending = $false; Check-Error
        $file = Get-Item -LiteralPath $path
        if ($file.Length -eq 0) { throw 'FSW created an empty file.' }
        $message = '{0:o} Saved {1} ({2} bytes, {3:F2}s)' -f [DateTimeOffset]::UtcNow,$path,$file.Length,($clock.Elapsed.TotalSeconds-$start)
        Write-Host $message; Add-Content -LiteralPath $log -Value $message -Encoding UTF8
        if ($RunOnce) { break }
        $due += $IntervalSeconds
        while ($due -lt $clock.Elapsed.TotalSeconds) { $due += $IntervalSeconds; Write-Warning 'Export overrun: skipped an interval.' }
        Start-Sleep -Milliseconds ([int][Math]::Max(0,($due-$clock.Elapsed.TotalSeconds)*1000))
    } while ($true)
} finally {
    if ($writer -and $null -ne $display -and -not $pending -and $script:usable) {
        try { $writer.WriteLine("SYST:DISP:UPD $display"); $null = Ask '*OPC?' 2 }
        catch { Write-Warning 'Could not confirm display restoration; check it manually.' }
    }
    if ($pending) { Write-Warning 'Export may still be running; no further SCPI commands were sent.' }
    $client.Dispose()
}
