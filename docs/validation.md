# Validation

## Executed checks

- **Windows PowerShell 5.1.26100.9711**: parsed the complete `.ps1` with the native
  PowerShell parser, then compiled and executed its embedded C# using `Add-Type`.
- **Python 3.11 standard-library unittest**:
  `py -3.11 -m unittest discover -s tests -v` — **39 tests passed, 0 skipped**.
  33 execute Windows PowerShell against a loopback instrument or exercise its
  file-reservation helpers; 6 exercise the optional workstation inspector.
- A separate actual `-Window 2 -RunOnce` execution against the mock produced a
  321-byte numerical spectrogram, validated its two frames and three points per
  frame, restored the original display-update value and exited 0.
- The original supplied manual's `%PDF-` signature, 33,667,424-byte size and
  SHA-256 were checked; its hash remained unchanged after inspection. PDF reading
  used pypdf 6.10.0 and Poppler 26.07.0; source evidence is documented separately.

Selected fields from the separate **mock/synthetic** execution, with paths and
timestamps omitted here:

```text
IDN=Rohde&Schwarz,FSW-26,TEST_ONLY/000000,6.40
EXPORT_OK ... bytes=321 elapsed_s=0.010 frames=2 points_per_frame=3 ...
STOP successes=1 exit_code=0
```

The server's identity/version and frame data above are synthetic, not a detected
physical FSW. Files and logs generated during tests are excluded from Git.

## Coverage

The logger tests cover valid output; window listing; quoted/renamed windows and
indices other than 1/2; wrong/missing windows; zero span; pre-existing errors;
unsupported queries whose error must be recovered on a fresh connection; rejected
store/clear commands; CRLF/TCP fragmentation; a dropped connection before store;
ambiguous timeout/drop after store without replay or clearing; missing/empty files;
temporary and persistent completed-export failures; invalid numeric/truncated data;
regular-trace rejection; unique names and forced filename collision; folder lock
exclusion; disk/file-count safety; stopped runs before connection, during an idle
interval and during an unconfirmed export; safe path quoting; display locking;
restoration and skipped scheduling slots after an overrun.

The inspector tests cover exact raw timestamps, two AUTOPEAK columns, unchanged
files, candidate overlaps, timestamp collisions with different values, incomplete
input, the bounded candidate index and no-overwrite JSON output.

Test subprocesses have deadlines and owned-tree cleanup. The tests contact only
the loopback mock, never an instrument. The console Ctrl+C handler and stop-file
path use the same cancellation checks; physical Ctrl+C delivery by a particular
instrument/console host is not independently proven by these tests.

## Pending hardware checks

No FSW was reachable in this workspace. `-RunOnce` on the actual instrument,
firmware/model identification, localhost binding, actual export layout, UI update
behavior, acquisition timing during export, USB/Secure User Mode and hours-long
logging are still unvalidated. The script does not claim gapless acquisition,
atomic export/clear, or lossless deduplication.

Start with the [hardware procedure](manual_evidence.md#first-hardware-validation).
Retain the initial instrument-generated file/log privately if its layout or SCPI
behavior differs; no vendor binary or real measurement is required to run the
mock test suite.
