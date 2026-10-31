"""Execute the actual logger in Windows PowerShell 5.1 against a local mock."""
from pathlib import Path
import os
import re
import shutil
import subprocess
import tempfile
import time
import unittest

from mock_fsw import instrument, SAMPLE

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "fsw_spectrogram_logger.ps1"
POWERSHELL = shutil.which("powershell.exe")


def bounded(command, timeout=20):
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        output, _ = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"], capture_output=True, timeout=10)
        process.wait(timeout=5)
        raise
    return process.returncode, output


@unittest.skipUnless(os.name == "nt" and POWERSHELL, "Windows PowerShell 5.1 required")
class LoggerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="FSW tests ")
        self.addCleanup(self.temporary.cleanup)
        self.folder = Path(self.temporary.name)

    def command(self, fake, *extra):
        return [POWERSHELL, "-NoLogo", "-NoProfile", "-NonInteractive", "-File", str(SCRIPT),
                "-Folder", str(self.folder), "-Port", str(fake.port), "-ConnectionTimeoutSeconds", ".3",
                "-CommandTimeoutSeconds", ".5", "-ExportTimeoutSeconds", ".5",
                "-FileTimeoutSeconds", ".15", "-RetryBackoffSeconds", "0",
                "-IntervalSeconds", ".1", "-MinimumFreeMB", "0", *extra]

    def run_logger(self, fake, *extra, expected=0):
        code, output = bounded(self.command(fake, *extra))
        self.assertEqual(code, expected, output)
        return output

    def test_success_preserves_measurement_and_file(self):
        with instrument() as fake:
            output = self.run_logger(fake, "-RunOnce")
            self.assertEqual(len(fake.paths), 1)
            self.assertEqual(fake.paths[0].read_bytes(), SAMPLE)
            self.assertRegex(fake.paths[0].name, r"^SGR_\d{8}_\d{6}_\d{3}Z_[a-f0-9]{32}\.dat$")
            self.assertIn("EXPORT_OK", output)
            self.assertIn("frames=2 points_per_frame=3", output)
            self.assertIn("elapsed_s=", output)
            self.assertIn("Original display update setting restored", output)
            self.assertIn(fake.display, {"0", "OFF"})
            self.assertFalse(any(c.startswith(("*RST", "INIT", "ABOR", "TRAC:", "CALC")) for c in fake.commands))
            self.assertFalse(list(self.folder.glob("*.reserve")))

    def test_list_windows_does_not_change_display_or_export(self):
        with instrument() as fake:
            output = self.run_logger(fake, "-ListWindows")
            self.assertIn("Window=2 Name=Spectrogram Type=SGRAM", output)
            self.assertFalse(fake.paths)
            self.assertFalse(any(c.startswith("SYST:DISP:UPD ") for c in fake.commands))

    def test_configured_window_not_assumed_one(self):
        with instrument() as fake:
            fake.catalogue = "'Window, renamed',3,'Spectrum',1"
            self.run_logger(fake, "-Window", "3", "-RunOnce")
            self.assertTrue(any(c.startswith("MMEM:STOR3:SGR ") for c in fake.commands))

    def test_rejected_command_reports_real_error_without_retry(self):
        with instrument() as fake:
            fake.mode = "reject"
            output = self.run_logger(fake, "-RunOnce", expected=2)
            self.assertIn('-113,"Undefined header', output)
            self.assertEqual(len(fake.paths), 1)
            self.assertEqual(fake.clear_count, 0)

    def test_absent_window(self):
        with instrument() as fake:
            fake.catalogue = "'Spectrum',1"
            output = self.run_logger(fake, "-RunOnce", expected=2)
            self.assertIn("Window 2 is absent", output)
            self.assertFalse(fake.paths)

    def test_wrong_window_type(self):
        with instrument() as fake:
            fake.kind = "DIAG"
            output = self.run_logger(fake, "-RunOnce", expected=2)
            self.assertIn("not a supported", output)
            self.assertFalse(fake.paths)

    def test_zero_span(self):
        with instrument() as fake:
            fake.span = "0"
            self.run_logger(fake, "-RunOnce", expected=2)
            self.assertFalse(fake.paths)

    def test_unsupported_query_diagnosed_on_fresh_connection(self):
        with instrument() as fake:
            fake.unsupported_query = True
            output = self.run_logger(fake, "-RunOnce", expected=2)
            self.assertIn('-113,"Undefined header', output)
            self.assertGreaterEqual(fake.connections, 2)
            self.assertFalse(fake.paths)

    def test_timeout_after_store_never_replayed_or_cleared(self):
        with instrument() as fake:
            fake.mode = "timeout"
            output = self.run_logger(fake, "-ClearAfterSave", expected=3)
            self.assertIn("AMBIGUOUS_COMPLETION", output)
            self.assertEqual(len(fake.paths), 1)
            self.assertEqual(fake.paths[0].read_bytes(), SAMPLE)
            self.assertEqual(fake.clear_count, 0)

    def test_connection_drop_after_store_never_replayed(self):
        with instrument() as fake:
            fake.mode = "drop"
            self.run_logger(fake, expected=3)
            self.assertEqual(len(fake.paths), 1)
            self.assertEqual(fake.clear_count, 0)

    def test_connection_drop_before_export_reconnects(self):
        with instrument() as fake:
            fake.drop_idn_once = True
            output = self.run_logger(fake, "-RunOnce")
            self.assertIn("Connection/setup attempt", output)
            self.assertEqual(len(fake.paths), 1)

    def test_no_file_runonce_fails(self):
        with instrument() as fake:
            fake.mode = "no_file"
            output = self.run_logger(fake, "-RunOnce", expected=1)
            self.assertIn("no nonempty local file appeared", output)
            self.assertEqual(fake.clear_count, 0)

    def test_empty_file_not_success(self):
        with instrument() as fake:
            fake.mode = "empty"
            self.run_logger(fake, "-RunOnce", expected=1)
            self.assertEqual(fake.paths[0].stat().st_size, 0)

    def test_occasional_completed_export_failure_continues(self):
        with instrument() as fake:
            fake.mode = "fail_once"
            output = self.run_logger(fake, "-MaxExports", "2")
            self.assertEqual(len(fake.paths), 3)
            self.assertIn("STOP successes=2 exit_code=0", output)

    def test_persistent_no_file_stops_at_failure_limit(self):
        with instrument() as fake:
            fake.mode = "no_file"
            self.run_logger(fake, "-MaxConsecutiveFailures", "2", expected=1)
            self.assertEqual(len(fake.paths), 2)

    def test_clear_only_after_valid_export(self):
        with instrument() as fake:
            output = self.run_logger(fake, "-RunOnce", "-ClearAfterSave")
            self.assertEqual(fake.clear_count, 1)
            self.assertEqual(fake.paths[0].read_bytes(), SAMPLE)
            self.assertIn("HISTORY_CLEARED", output)

    def test_clear_rejected_keeps_export_and_stops(self):
        with instrument() as fake:
            fake.mode = "clear_reject"
            output = self.run_logger(fake, "-RunOnce", "-ClearAfterSave", expected=2)
            self.assertIn('Clear unsupported', output)
            self.assertEqual(fake.clear_count, 1)
            self.assertEqual(fake.paths[0].read_bytes(), SAMPLE)

    def test_corrupt_numeric_data_never_cleared(self):
        with instrument() as fake:
            fake.payload = SAMPLE.replace(b"1000000000;-50;-60", b"1000000000;BAD;-60")
            self.run_logger(fake, "-RunOnce", "-ClearAfterSave", expected=2)
            self.assertEqual(fake.clear_count, 0)
            self.assertEqual(fake.paths[0].read_bytes(), fake.payload)

    def test_truncated_frame_never_cleared(self):
        with instrument() as fake:
            fake.payload = SAMPLE.rsplit(b"1001000000", 1)[0]
            self.run_logger(fake, "-RunOnce", "-ClearAfterSave", expected=2)
            self.assertEqual(fake.clear_count, 0)

    def test_regular_trace_rejected(self):
        with instrument() as fake:
            fake.payload = b"x-Unit;Hz;\nValues;2;\n1;-70\n2;-60\n"
            self.run_logger(fake, "-RunOnce", expected=2)

    def test_file_count_safety_never_deletes(self):
        old = self.folder / "SGR_existing.dat"; old.write_bytes(b"old data")
        with instrument() as fake:
            self.run_logger(fake, "-RunOnce", "-MaxFileCount", "1", expected=2)
            self.assertFalse(fake.paths)
            self.assertEqual(old.read_bytes(), b"old data")

    def test_free_space_safety(self):
        with instrument() as fake:
            command = self.command(fake, "-RunOnce")
            command[command.index("-MinimumFreeMB")+1] = "1000000000"
            code, output = bounded(command)
            self.assertEqual(code, 2, output)
            self.assertFalse(fake.paths)

    def test_unique_filenames_across_runs(self):
        with instrument() as fake:
            self.run_logger(fake, "-RunOnce"); self.run_logger(fake, "-RunOnce")
            self.assertEqual(len(set(fake.paths)), 2)
            self.assertTrue(all(p.read_bytes() == SAMPLE for p in fake.paths))

    def test_overrun_skips_slots_without_catchup(self):
        with instrument() as fake:
            fake.delay = .25
            output = self.run_logger(fake, "-MaxExports", "2")
            self.assertIn("OVERRUN skipped_intervals=", output)
            self.assertGreaterEqual(fake.store_times[1]-fake.store_times[0], .25)

    def test_fragmented_crlf_responses(self):
        with instrument() as fake:
            fake.fragment = True
            self.run_logger(fake, "-RunOnce")

    def test_existing_error_queue_logged_before_commands(self):
        with instrument() as fake:
            fake.errors = ['-200,"PREEXISTING_TEST_ERROR"']
            output = self.run_logger(fake, "-RunOnce")
            self.assertIn("pre-existing error", output)
            self.assertIn("PREEXISTING_TEST_ERROR", output)
            self.assertNotIn("*CLS", fake.commands)

    def test_display_locked_stops_without_unlocking(self):
        with instrument() as fake:
            fake.display_lock = "1"
            self.run_logger(fake, "-RunOnce", expected=2)
            self.assertFalse(fake.paths)
            self.assertNotIn("SYST:DISP:LOCK 0", fake.commands)

    def test_preexisting_stop_file_is_graceful(self):
        stop = self.folder / "stop.flag"; stop.touch()
        with instrument() as fake:
            self.run_logger(fake, "-StopFile", str(stop))
            self.assertFalse(fake.commands)

    def test_stop_file_during_wait_is_graceful(self):
        stop = self.folder / "stop.flag"
        with instrument() as fake:
            command = self.command(fake, "-StopFile", str(stop))
            command[command.index("-IntervalSeconds")+1] = "5"
            process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            try:
                deadline = time.monotonic()+8
                while time.monotonic()<deadline:
                    if any("EXPORT_OK" in p.read_text(encoding="utf-8") for p in self.folder.glob("*.log")): break
                    time.sleep(.05)
                else: self.fail("No completed export")
                stop.touch()
                output, _ = process.communicate(timeout=5)
                self.assertEqual(process.returncode, 0, output)
                self.assertEqual(len(fake.paths), 1)
                self.assertIn("Stop requested", output)
            finally:
                if process.poll() is None:
                    subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"], capture_output=True, timeout=10)
                    process.wait(timeout=5)

    def test_safe_folder_rejects_scpi_injection(self):
        with instrument() as fake:
            command = self.command(fake, "-RunOnce")
            command[command.index("-Folder")+1] = "C:\\unsafe';*RST"
            code, output = bounded(command)
            self.assertEqual(code, 2, output)
            self.assertFalse(fake.commands)

    def test_stop_during_unconfirmed_export_keeps_file_and_never_clears(self):
        stop = self.folder / "stop.flag"
        with instrument() as fake:
            fake.mode = "timeout"
            command = self.command(fake, "-StopFile", str(stop), "-ClearAfterSave")
            command[command.index("-ExportTimeoutSeconds")+1] = "5"
            process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            try:
                deadline = time.monotonic()+8
                while time.monotonic()<deadline:
                    if fake.paths and fake.paths[0].exists() and fake.commands[-1] == "*OPC?": break
                    time.sleep(.03)
                else: self.fail("No pending export")
                stop.touch()
                output, _ = process.communicate(timeout=4)
                self.assertEqual(process.returncode, 0, output)
                self.assertEqual(fake.paths[0].read_bytes(), SAMPLE)
                self.assertEqual(fake.clear_count, 0)
                self.assertIn("unconfirmed export/clear", output)
            finally:
                if process.poll() is None:
                    subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"], capture_output=True, timeout=10)
                    process.wait(timeout=5)

    def test_collision_reservation_preserves_existing_file(self):
        quote = lambda value: "'"+str(value).replace("'", "''")+"'"
        code = f""". {quote(SCRIPT)}
$stamp=[DateTimeOffset]::Parse('2026-10-31T00:00:00Z')
$r=New-ExportReservation -Directory {quote(self.folder)} -Token fixed -ExportTime $stamp
$r.Lock.Dispose()
[IO.File]::WriteAllText($r.Path,'unchanged')
try {{ New-ExportReservation -Directory {quote(self.folder)} -Token fixed -ExportTime $stamp; exit 9 }} catch {{}}
if ([IO.File]::ReadAllText($r.Path) -ne 'unchanged') {{ exit 8 }}
exit 0
"""
        result, output = bounded([POWERSHELL, "-NoProfile", "-NonInteractive", "-Command", code])
        self.assertEqual(result, 0, output)

    def test_second_logger_cannot_use_locked_folder(self):
        quote = lambda value: "'"+str(value).replace("'", "''")+"'"
        ready = self.folder / "ready.flag"
        release = self.folder / "release.flag"
        code = f"""$f=[IO.File]::Open({quote(self.folder/'.fsw_logger.lock')},[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try {{
    [IO.File]::WriteAllText({quote(ready)},'ready')
    while (-not [IO.File]::Exists({quote(release)})) {{ [Threading.Thread]::Sleep(50) }}
}} finally {{ $f.Dispose() }}
"""
        process = subprocess.Popen([POWERSHELL,"-NoProfile","-NonInteractive","-Command",code],
                                   stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
        try:
            deadline = time.monotonic()+5
            while not ready.exists() and time.monotonic()<deadline: time.sleep(.03)
            self.assertTrue(ready.exists())
            with instrument() as fake:
                self.run_logger(fake,"-RunOnce",expected=2)
                self.assertFalse(fake.commands)
        finally:
            release.touch()
            try: process.communicate(timeout=3)
            except subprocess.TimeoutExpired:
                subprocess.run(["taskkill","/PID",str(process.pid),"/T","/F"],capture_output=True,timeout=10)
                process.wait(timeout=5)


if __name__ == "__main__": unittest.main()
