# FSW spectrogram history logger

This is a separate project from the FieldFox decoder. Work on the instrument-native
PowerShell 5.1 logger described in README.md. Keep the runtime self-contained;
Python is only for workstation tests/inspection. Do not add vendor PDFs, firmware,
real measurements, credentials or generated logs to this repository.

Use the supplied FSW manual under ../fsw_work read-only. Cite its version, pages
and hash in docs/manual_evidence.md. Never guess commands or claim hardware
validation from the mock server. Preserve measurement settings and files. No
reset, trigger, acquisition restart or automatic history clearing. Display update
is the sole default setting change, saved and restored on a normal exit.

Use bounded SCPI operations and retries, one export at a time, monotonic timing
and unique filenames. An ambiguous store/clear completion must stop further
exports; never replay an uncertain operation. Clearing is opt-in and follows a
fully validated export only. Do not claim gapless acquisition or exact timestamp
deduplication. Run tests with Windows PowerShell 5.1, not just PowerShell 7:

    py -3.11 -m unittest discover -s tests -v

No live instrument is available locally. Use the loopback mock for all execution.
