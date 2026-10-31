"""Run the short script itself in Windows PowerShell 5.1."""
from pathlib import Path
import os
import tempfile
import unittest

from mock_fsw import instrument, SAMPLE
from test_logger import bounded, POWERSHELL, ROOT

SCRIPT = ROOT / "fsw_spectrogram_simple.ps1"


@unittest.skipUnless(os.name == "nt" and POWERSHELL, "Windows PowerShell 5.1 required")
class SimpleTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="FSW simple ")
        self.addCleanup(self.temporary.cleanup)
        self.folder = Path(self.temporary.name)

    def run_script(self, fake, *extra, expected=0):
        command = [POWERSHELL,"-NoProfile","-NonInteractive","-File",str(SCRIPT),
                   "-Folder",str(self.folder),"-Port",str(fake.port),
                   "-TimeoutSeconds",".3","-IntervalSeconds",".1",*extra]
        code, output = bounded(command, timeout=10)
        self.assertEqual(code, expected, output)
        return output

    def test_one_export_preserves_history_and_restores_display(self):
        with instrument() as fake:
            output = self.run_script(fake,"-RunOnce")
            self.assertIn("Saved", output)
            self.assertEqual(fake.paths[0].read_bytes(), SAMPLE)
            self.assertEqual(fake.clear_count, 0)
            self.assertEqual(fake.display, "0")
            log = next(self.folder.glob("simple_*.log"))
            self.assertIn("bytes,", log.read_text(encoding="utf-8-sig"))
            self.assertFalse(any(c.startswith(("*RST","INIT","CALC")) for c in fake.commands))

    def test_wrong_window_stops_without_export(self):
        with instrument() as fake:
            fake.kind = "DIAG"
            self.run_script(fake,"-RunOnce",expected=1)
            self.assertFalse(fake.paths)

    def test_rejected_export_reports_error_and_does_not_retry(self):
        with instrument() as fake:
            fake.mode = "reject"
            output = self.run_script(fake,expected=1)
            self.assertIn("-113", output)
            self.assertEqual(len(fake.paths),1)

    def test_timeout_does_not_replay_or_restore_over_pending_export(self):
        with instrument() as fake:
            fake.mode = "timeout"
            output = self.run_script(fake,expected=1)
            self.assertIn("Export may still be running", output)
            self.assertEqual(len(fake.paths),1)
            self.assertEqual(fake.paths[0].read_bytes(), SAMPLE)
            self.assertEqual(fake.display, "ON")

    def test_dropped_connection_stops(self):
        with instrument() as fake:
            fake.mode = "drop"
            self.run_script(fake,expected=1)
            self.assertEqual(len(fake.paths),1)

    def test_missing_or_empty_file_is_not_success(self):
        for mode in ("no_file","empty"):
            with self.subTest(mode=mode), instrument() as fake:
                fake.mode = mode
                self.run_script(fake,"-RunOnce",expected=1)
                self.assertEqual(fake.clear_count,0)

    def test_unique_filenames_across_runs(self):
        with instrument() as fake:
            self.run_script(fake,"-RunOnce"); self.run_script(fake,"-RunOnce")
            self.assertEqual(len(set(fake.paths)),2)
            self.assertTrue(all(p.read_bytes()==SAMPLE for p in fake.paths))

    def test_invalid_display_setting_is_never_sent_back(self):
        with instrument() as fake:
            fake.display = "ON;*RST"
            self.run_script(fake,"-RunOnce",expected=1)
            self.assertFalse(any(c.startswith("SYST:DISP:UPD ") for c in fake.commands))
            self.assertFalse(fake.paths)

    def test_setup_timeout_does_not_reuse_failed_query_socket(self):
        with instrument() as fake:
            original = fake.handle
            def no_completion_reply(command,state):
                if command=="*OPC?":
                    fake.commands.append(command)
                    return None,False
                return original(command,state)
            fake.handle = no_completion_reply
            self.run_script(fake,"-RunOnce",expected=1)
            self.assertEqual(fake.commands[-1],"*OPC?")
            self.assertFalse(fake.paths)

    def test_loop_skips_overruns_and_stops_on_first_error(self):
        with instrument() as fake:
            fake.delay = .15
            original = fake.handle
            def stop_after_two(command,state):
                if command.startswith("MMEM:STOR") and len(fake.paths)==2: fake.mode="reject"
                return original(command,state)
            fake.handle = stop_after_two
            output = self.run_script(fake,expected=1)
            self.assertIn("Export overrun", output)
            self.assertEqual(len(fake.paths),3)
            self.assertEqual(sum(p.exists() for p in fake.paths),2)
            self.assertEqual(fake.clear_count,0)

    def test_zero_span_rejected(self):
        with instrument() as fake:
            fake.span = "0"
            self.run_script(fake,"-RunOnce",expected=1)
            self.assertFalse(fake.paths)


if __name__ == "__main__": unittest.main()
