# Command evidence and validation limits

Source: user-supplied `FSW_UserManual_en_57.pdf`, 33,667,424 bytes,
**SHA-256 `d86104510facb8fbc6ccd029b12ab5f0499731cee48ba34c61335f2869bca283`**.
Cover identifies FSW User Manual 1173.9411.02, version 57. Page 2 states firmware
6.40 and later and lists FSW8/13/26/43/50/67/85. The actual target model/firmware
was not supplied. Page references below are printed pages and one-based PDF pages;
they coincide in this supplied file (1,632 pages).

The PDF stays outside the repository under the user's `fsw_work` directory and
was read without modification. No vendor manual images or bulk text are published.

| Implemented behavior | Manual evidence | Limit |
|---|---|---|
| Raw SCPI TCP | pp.824-825, table 12-1; raw ports 5025/5125 and socket resource example | Binding on 127.0.0.1 is checked at runtime, not established by the table |
| Identity | p.905, `*IDN?`, example includes model, serial and firmware | Custom/legacy identity formats fail explicitly |
| Completion | p.905, `*OPC?` reply after preceding operations complete | A lost reply does not establish completion; never replay an ambiguous store/clear |
| Window numbers | p.903, table 13-1: 1..16 in the selected channel | Window indices are not trace indices |
| Window catalogue | p.1116, `LAYout:CATalog[:WINDow]?`: name/index pairs | Can be renamed/reordered; parse quoted names |
| Spectrogram type | pp.1116 and 1121, `SGRam` and `LAYout:WINDow<n>:TYPE?` | The type query is not available in every application; unsupported cases stop |
| Selected channel | pp.913-914, `INSTrument[:SELect]?` returns default type or custom name | Queried, never set; other controllers can still race the checks |
| Existing positive span | p.1211, `[SENSe:]FREQuency:SPAN` | Query only; zero span rejected |
| Numerical history export | p.1391, `MMEMory:STORe<n>:SGRam` / `SPECtrogram` | All history frames with frame number/time; export may take time; suffix is window |
| ASCII layout | pp.662-665, especially table 8-12 on pp.664-665 | Semicolon fields; Hz axis, Values, Frames, Frame, Timestamp, X/Y[/Y2]; AUTOPEAK has two Y values |
| Optional clear | pp.1264-1265, `CALCulate<n>:SGRam:CLEar[:IMMediate]` | p.1264 says suffix can be irrelevant and settings apply to all spectrograms in a channel; warn about broader clearing |
| Finite history | p.1266, `CALCulate<n>:SGRam:HDEPth` | Depth depends on sweep points; no depth change is made |
| Keep diagrams visible | pp.1455-1456, `SYSTem:DISPlay:UPDate` and `LOCK` | Display update is queried, temporarily enabled, then restored if completion is known; a locked display causes a clear failure |
| Remote/front panel behavior | p.885 and p.1455 | Receiving SCPI enters remote mode; front-panel keys are disabled until Local. Do not claim full local interactivity |
| Actual errors | p.1471, `SYSTem:ERRor[:NEXT]?` returns and removes one entry | Drain/log a bounded queue; do not clear it with `*CLS` |
| Secure User Mode | p.1391 | Internal volatile storage limited to 256 MB; disk free space alone is insufficient; USB can provide persistence |

## Inspection performed

- Identified `%PDF-` signature, file size and SHA-256; Poppler `pdfinfo` reported
  1,632 pages, unencrypted PDF 1.7 and FSW manual metadata.
- Poppler `pdfinfo` emitted a stream warning. `pdftotext` was absent from the
  bundled runtime, so **pypdf 6.10.0** extracted the bookmarks and complete relevant
  pages. This avoided bulk processing unrelated measurement applications.
- Visually rendered and inspected p.1391 with Poppler `pdftoppm`, verifying the
  export command, suffix, history description and secure-mode warning.
- Cross-checked official R&S manual/driver documentation links in README.md.
  No vendor program, firmware installer or instrument was executed/contacted.

## What tests establish

The test server uses a shared local filesystem to simulate running the logger on
the instrument itself. Windows PowerShell 5.1 compiles and runs the actual embedded
.NET transport. Tests exercise file checks/streamed validation, default no-clear,
clear-after-valid-file ordering, real error propagation, transport failures before
and after store, no ambiguous replay, unique names, folder exclusion, graceful
stop flags and the serial monotonic schedule. The optional Python inspector uses
only independent synthetic exports.

The optional `fsw_spectrogram_simple.ps1` uses the same documented SCPI commands
in plain PowerShell without the embedded C# transport or streamed format parser.
Its own mock tests check the short loop and failure behavior. It never clears
history or retries an ambiguous operation, and verifies only a nonempty file.

Mock success proves implementation behavior against the mock contract. It does
**not** prove real FSW command availability, file layout on every firmware,
acquisition continuity, USB behavior, physical Ctrl+C delivery by every console
host, frontend timing or display restoration after forced shutdown. Cancellation
of the transport is tested through the same flag checked by the console handler.

## First hardware validation

1. Check PowerShell 5.1, current Spectrum channel, positive span, active spectrogram,
   output permissions and the local SCPI endpoint.
2. Run `-ListWindows`, then `-Window <index> -RunOnce` without clearing. Retain the
   identity/log and the original `.dat`; check frame counts, units, frequency axis
   and measurement timestamps against the instrument UI.
3. Run a short bounded `-MaxExports 3` session; compare overlaps and observe display,
   acquisition responsiveness, cadence, stop handling and resource use.
4. Only if desired, evaluate `-ClearAfterSave` knowing it can clear all channel
   spectrograms and lose intervening frames. No gapless claim follows from success.

These checks need the actual instrument; no real session is required to run the
supplied mock tests. Do not publish real measurement files/logs as test fixtures.
