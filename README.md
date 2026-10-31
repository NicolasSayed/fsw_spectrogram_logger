# FSW spectrogram history logger

A self-contained **Windows PowerShell 5.1** script that runs on the R&S FSW's own
Windows computer and periodically saves its existing spectrogram history as
numerical ASCII files. No external PC, Python installation, VISA, third-party
modules, zero-span mode or continuous raw I/Q transfer is needed.

## Short, simple version

[fsw_spectrogram_simple.ps1](fsw_spectrogram_simple.ps1) is about 80 lines of plain
PowerShell, with no embedded C#. Configure your Spectrum/spectrogram display first,
then run it **on the instrument**:

```powershell
# Test one export (replace 2 with your spectrogram window's actual index)
.\fsw_spectrogram_simple.ps1 -Window 2 -RunOnce

# Keep saving history snapshots, every 10 seconds
.\fsw_spectrogram_simple.ps1 -Window 2 -IntervalSeconds 10 -Folder 'C:\FSW_Logs'
```

Edit `$Folder = 'C:\FSW_Logs'` near the top to choose where to save, or override
it with `-Folder` as above. Each launch creates the first available numbered
subfolder: `C:\FSW_Logs\run1`, then `run2`, `run3`, and so on. Existing folders
(even empty ones) and files are skipped and preserved. All snapshots and the log
for that launch go into its new run folder; the console prints the chosen path.

It identifies the FSW, checks the window type and positive span, enables display
updates, saves numerical history with unique UTC filenames, waits for completion,
checks one SCPI error entry and a nonempty file, and writes a simple success log.
It **never clears history**. Exports run sequentially; overrun intervals are
skipped. Press Ctrl+C to stop; a query wait may delay this until `-TimeoutSeconds`
(default 120) expires. The socket is closed on exit and display restoration is
attempted when the connection is usable and no export remains unconfirmed.

The simple script stops on the first error. It has no reconnects, storage caps,
folder locking, channel-change monitoring or full export-format validation.
Run only one logger/controller at a time and use a known working setup. Use the
full logger below for unattended operation with those checks and retry behavior.
Both versions save overlapping history snapshots, with possible gaps, and neither
has been validated on physical FSW hardware yet.

## Full logger

This is a **history snapshot logger**, not a gapless recorder. It leaves frequency,
span, RBW, trace selection, acquisition and history depth as configured in the FSW
UI. Default operation preserves history. The only default setting change enables
remote **display updates**, remembering and restoring the original setting on a
confirmed clean exit. SCPI control itself puts the FSW in remote mode; it does not
leave the front-panel keys fully interactive. Use the FSW's Local softkey after
stopping the logger.

## Instrument-side setup

1. Configure the **Spectrum application** in the FSW UI: positive frequency span,
   desired frequency/RBW/traces and a running spectrogram. Keep both spectrum and
   spectrogram windows in the layout. Do not select zero span or an I/Q application.
2. On the instrument's Windows desktop, open **Windows PowerShell 5.1**. Verify
   `$PSVersionTable.PSVersion`. Copy this repository's `.ps1` file to a local folder,
   for example `C:\FSW_Logger`, then `Set-Location C:\FSW_Logger`.
3. Use a writable local/USB folder, default `C:\FSW_Logs`. It is created if absent.
   Check USB drive letters using `Get-PSDrive -PSProvider FileSystem`.
   Use an absolute drive-letter path, at most 150 characters, using printable
   ASCII without quotes or semicolons. Existing measurements are never deleted.
4. Review the script and use the instrument's approved script-signing/execution
   policy. The logger does not change Windows policy, firewall settings or licenses.
   Embedded C# is compiled in memory by the built-in .NET `Add-Type`; a restricted
   language policy that prohibits this needs an approved deployment from your IT.
5. Stop other remote-control clients and avoid changing the active channel/layout
   during logging. Only one logger can use a given output folder at a time.

The default endpoint is **127.0.0.1:5025**. The manual documents raw SCPI sockets
on 5025/5125; loopback binding on your particular instrument must be checked.
`-HostName` and `-Port` are configurable, but the script must still run on the
instrument whose Windows filesystem receives the export. It does not transfer
files across the network or scan for devices.

## Find the spectrogram window

```powershell
.\fsw_spectrogram_logger.ps1 -ListWindows
```

Example **mock** output:

```text
Window=1 Name=Spectrum Type=DIAG
Window=2 Name=Spectrogram Type=SGRAM
```

Names and indices can differ and can appear in a different display order. Select
the **numeric index** associated with your intended spectrogram, not a trace
number or simply the first visible panel. The window number in the FSW title bar
is another useful check. `LAY:CAT?` reports names/indices; `LAY:WIND<n>:TYPE?`
reports the type. `-ListWindows` does not export data or change display settings.

The logger requires a spectrogram type `SGR` / `SGRAM` / `SPECTROGRAM`, a positive
frequency span and an unchanged active channel. An absent window or unsupported
discovery command fails clearly. It does not create/select a different window,
switch applications, or silently export a regular trace or screenshot instead.
Firmware/application differences require verification, not a guessed fallback.

## Make one test export first

```powershell
.\fsw_spectrogram_logger.ps1 -Window 2 -RunOnce
```

The script identifies the instrument, checks the window and span, enables diagram
updates if necessary, and sends:

```text
MMEM:STOR2:SGR 'C:\FSW_Logs\SGR_<UTC timestamp>_<unique id>.dat'
*OPC?
SYST:ERR?
```

It waits for completion, logs actual SCPI errors, checks that the local file exists
and is nonempty, then reads it incrementally to validate the documented spectrogram
layout: Hz x-axis, Values/Frames counts, frame numbers, raw date/time metadata and
matching numeric rows. One or two detector Y columns are supported; values and
units are preserved, with no guessed dBm conversion. The `.dat` file is never
rewritten. A successful log entry includes bytes, elapsed export/validation time,
frame count, points per frame and first/last frame timestamps in file order.

Open that first file on the instrument and check the selected trace, units,
frequency range and frame timestamps before leaving it unattended. If export
headers/data differ from the supported layout, the file is retained and the
logger reports the mismatch; do not enable clearing to work around it.

## Run unattended

```powershell
# Every 10 seconds, retaining the existing history
.\fsw_spectrogram_logger.ps1 -Window 2 -IntervalSeconds 10 -Folder 'C:\FSW_Logs'

# USB example: replace E: with the instrument's actual USB drive letter
.\fsw_spectrogram_logger.ps1 -Window 2 -Folder 'E:\FSW_Logs' -IntervalSeconds 10

# Longer export timeout / optional file-count safety cap
.\fsw_spectrogram_logger.ps1 -Window 2 -ExportTimeoutSeconds 300 -MaxFileCount 5000

# Optional bounded run; never deletes older files
.\fsw_spectrogram_logger.ps1 -Window 2 -MaxExports 100
```

There is one export at a time. The initial export starts immediately. Later exports
follow a fixed start-to-start schedule driven by a monotonic stopwatch. If work
takes too long, missed intervals are skipped and logged as `OVERRUN`; there is no
catch-up burst. Log and measurement filenames use **export wall-clock UTC**, e.g.
`SGR_20261031_003800_123Z_<32-character ID>.dat`. These names do not describe the
FSW's measurement time. Raw measurement timestamps stay inside each file with
their original precision and **no assumed time zone**.

Each run writes a uniquely named, flushed UTF-8 text log beside its exports.
The folder's `.fsw_logger.lock` is retained as a harmless lock file after exit;
only the open handle enforces exclusion. Temporary `.reserve` files belong to
individual export attempts and are removed on normal unwinding. Do not share this
folder with another program writing the same generated names. UUID filenames,
exclusive folder locking, `CreateNew` reservations and existing-file checks protect
cooperating logger instances; SCPI cannot make an arbitrary external file writer
participate in that reservation.

## Stop safely

Press **Ctrl+C** in the logger's console. Cooperative socket/file checks observe
the cancellation flag. Previously written files remain intact; a store already
sent may still finish on the instrument. A separate stop-file option is useful
for unattended operation:

```powershell
.\fsw_spectrogram_logger.ps1 -Window 2 -StopFile 'C:\FSW_Logs\stop.flag'
# From another local PowerShell window, request a stop:
New-Item -ItemType File -Path 'C:\FSW_Logs\stop.flag'
```

An existing stop file prevents a new run from exporting. Remove only that stop flag
when you intentionally want to start again. Closing/killing the console is less
graceful than Ctrl+C/StopFile. Windows can terminate processes before cleanup;
display restoration is attempted, not guaranteed under forced termination.

## Clearing is explicitly optional

```powershell
.\fsw_spectrogram_logger.ps1 -Window 2 -IntervalSeconds 10 -ClearAfterSave
```

This sends `CALC2:SGR:CLE` **only after** a complete export, clean SCPI error
check, successful file-format validation and another channel/window check.
**The manual says spectrogram settings can apply to all spectrogram windows in
the active channel; do not assume clearing is isolated to window 2.** Frames
acquired between export and clear may be lost. This mode is never gapless and is
off by default.

## Failures, retries and storage

- Transport failures **before a store** use up to `MaxRetries + 1` connection/setup
  attempts, with bounded exponential backoff capped at 30 seconds. Reconnection
  verifies instrument identity and context. A timed-out query socket is discarded;
  error diagnosis uses a fresh connection so delayed replies cannot be confused.
- A confirmed completed export with a missing/empty file can fail that interval
  and recover at a later one. Persistent failures stop at
  `MaxConsecutiveFailures` (default 3). `-RunOnce` reports failure immediately.
- Unsupported commands, bad context, invalid file contents and safety limits stop
  rather than continuously repeating a bad configuration. Actual nonzero
  `SYST:ERR?` entries are logged. Querying the queue consumes its entries;
  pre-existing errors are logged separately. No `*CLS` is sent.
- A timeout/drop **after sending store or clear** has an ambiguous outcome.
  The logger stops with exit code 3, retains all output/partial files, and sends
  no further export/clear/display commands. It cannot prove that a disconnected
  operation has finished. Inspect the FSW before restarting; it does not replay
  the operation on a new socket or rename an incomplete file as successful.
- Free-space safety defaults to 256 MiB, checked before each export. Set
  `-MinimumFreeMB 0` to disable the threshold; optional `-MaxFileCount` defaults
  to unlimited. These are preflight checks, not a reservation of enough space
  for a potentially large history buffer. No data is deleted to make room.
- In **Secure User Mode**, internal storage can be volatile and limited to
  256 MB despite reported disk free space. Prefer an approved USB location for
  persistent results. The logger does not disable secure mode.

Exit codes: `0` completed/requested stop, `1` exhausted transient/export-file
failures, `2` configuration/SCPI/format/safety failure, `3` ambiguous completion.
PowerShell parameter-binding or host-termination errors have the host's own code.

## Parameters

| Parameter | Default | Purpose |
|---|---|---|
| `Window` | 2 | Existing spectrogram window index, 1..16 |
| `IntervalSeconds` | 10 | Fixed start-to-start cadence, seconds |
| `Folder` | `C:\FSW_Logs` | Local/USB output and log directory |
| `HostName` / `Instrument` | `127.0.0.1` | Instrument's local SCPI endpoint |
| `Port` | 5025 | Raw TCP SCPI port |
| `RunOnce` | off | One validated export, then exit |
| `ListWindows` | off | Log names/indices/types without exporting |
| `ClearAfterSave` | off | Clear history only after validated export |
| `ConnectionTimeoutSeconds` | 5 | Bounded asynchronous connect wait |
| `CommandTimeoutSeconds` | 10 | Per write and query-reply timeout |
| `ExportTimeoutSeconds` | 120 | Completion-reply timeout for store/clear |
| `FileTimeoutSeconds` | 5 | Wait for a nonempty local export |
| `ValidationTimeoutSeconds` | 120 | Deadline checked between export lines |
| `MaxRetries` | 2 | Additional connection/setup attempts |
| `RetryBackoffSeconds` | 1 | Initial exponential retry delay |
| `MaxConsecutiveFailures` | 3 | Failed intervals allowed before stopping |
| `MinimumFreeMB` | 256 | Minimum available disk space, 0 disables |
| `MaxFileCount` | 0 | Cap existing `SGR_*.dat` files, 0 unlimited |
| `MaxExports` | 0 | Stop after this many successful exports, 0 unlimited |
| `StopFile` | none | Absolute local flag path requesting graceful stop |

Export validation streams rows with a 1 MiB line cap; it does not load the history
into RAM. SCPI responses are capped at 64 KiB. Operating-system disk/USB stalls
and forced process termination are outside these cooperative deadlines.

## Understand overlap and gaps

With default history preservation, successive files often repeat frames. If the
buffer wraps between saves, old frames may disappear before any file contains
them. Exporting can itself affect instrument responsiveness or acquisition timing;
there is no tested guarantee that measurement continues without interruption while
the firmware serializes the history. Clearing adds an export-to-clear race.

Frame numbers such as `0`, `-1` are relative positions, not global IDs. Treat the
FSW's frame timestamps separately from filename/log wall clocks. Do not deduplicate
by frame number or timestamp alone. Even matching timestamps and values cannot
prove distinct acquisitions were identical or that no frames were missed.

An optional **external workstation** helper checks the documented semicolon
ASCII/UTF-8 layout and reports potential repeated frames without changing files:

```powershell
python spectrogram_export_inspector.py .\first.dat .\second.dat --output overlap.json
```

It preserves raw timestamp strings, hashes units and stripped numerical rows
(including a second AUTOPEAK column), and reports same-timestamp/different-payload
cases separately. Matching is textual: different numeric formatting can miss an
overlap. Its candidate index is bounded to 100,000 unique frames by default
(`--max-indexed-frames`, at most 1,000,000). For larger sets, inspect batches.
It never merges/removes data or claims lossless deduplication. Headerless, binary,
other applications or different firmware layouts may require a new inspector.
This helper is **not an instrument runtime dependency**.

## Validation and references

```powershell
# Development PC only; Python standard library, no pip packages needed
py -3.11 -m unittest discover -s tests -v
```

Tests execute the actual script in **Windows PowerShell 5.1** against a loopback
server which creates independent synthetic spectrogram ASCII files. They cover
success, discovery, non-default windows, errors, timeouts, fragmented replies,
connection loss, missing/empty/invalid files, collision protection, clearing,
cancellation, skipped intervals and storage limits. Tests own their subprocesses
and terminate their process trees on a timeout. Nothing contacts a real FSW.

The implementation was checked against the supplied **FSW User Manual,
1173.9411.02, version 57**, applicable to firmware 6.40 and later. See
[manual evidence](docs/manual_evidence.md) for pages, hash, inspection tools and
the distinction between documented behavior, mock verification and pending
instrument verification. **51 tests passed without skips**; the executed checks
and a real mock-run excerpt are recorded in [validation](docs/validation.md).
The exact model/firmware and localhost binding remain
to be checked with `-ListWindows` and `-RunOnce` on your FSW. No actual on-device
export or hours-long hardware run has been claimed.

Official references: [FSW manual index](https://www.rohde-schwarz.com/uk/manual/fsw/),
[FSW user manual page](https://www.rohde-schwarz.com/in/manual/fsw-user-manual_78701-29088.html),
[R&S driver socket example](https://rohde-schwarz.github.io/RsFsw_PythonDocumentation/getting_started.html).
The driver example illustrates socket addressing; this logger does not use that
Python driver or its initialization/reset behavior.

If the localhost raw socket is unavailable, check the configured SCPI port and
instrument remote-control settings with your approved setup. No VISA/HiSLIP
fallback is implemented or claimed tested. An existing approved R&S VISA tool can
help diagnose the endpoint, but is not required by this script. Do not change
measurement setup or substitute screenshots to hide an unsupported command.

No vendor PDF, firmware, driver code, real recording or decoded user data is
included in this repository.
