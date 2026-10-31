from pathlib import Path
import json
import contextlib
import io
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from spectrogram_export_inspector import frames, inspect, main, ExportFormatError
from mock_fsw import SAMPLE


class InspectorTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.path = Path(self.temporary.name)/"one.dat"
        self.path.write_bytes(SAMPLE)

    def test_frame_metadata_and_autopeak_columns_preserved(self):
        result = list(frames(self.path))
        self.assertEqual([f.number for f in result], [0, -1])
        self.assertEqual([f.columns for f in result], [3, 3])
        self.assertEqual(result[0].points, 3)
        self.assertEqual(result[0].timestamp_raw, "31.Oct 2026;00:38:00.123")

    def test_repeated_frames_are_candidates_without_removing_data(self):
        other = self.path.with_name("two.dat"); other.write_bytes(SAMPLE)
        result = inspect([self.path, other])
        self.assertEqual(result["candidate_repeated_frames"], 2)
        self.assertEqual(other.read_bytes(), SAMPLE)
        self.assertEqual(self.path.read_bytes(), SAMPLE)

    def test_same_time_different_values_reported(self):
        other = self.path.with_name("two.dat")
        other.write_bytes(SAMPLE.replace(b";-70;-80", b";-71;-80"))
        result = inspect([self.path, other])
        self.assertEqual(result["candidate_repeated_frames"], 1)
        self.assertEqual(result["same_timestamp_different_payload"], 1)

    def test_regular_trace_or_truncated_spectrogram_rejected(self):
        for data in [b"Values;2;\n1;-60\n2;-70\n", SAMPLE.rsplit(b"1001000000", 1)[0]]:
            self.path.write_bytes(data)
            with self.assertRaises(ExportFormatError): list(frames(self.path))

    def test_index_is_bounded(self):
        with self.assertRaisesRegex(ValueError, "index limit"):
            inspect([self.path], max_indexed_frames=1)

    def test_output_is_new_file_only(self):
        output = self.path.with_suffix(".json")
        self.assertEqual(main([str(self.path), "--output", str(output)]), 0)
        self.assertEqual(json.loads(output.read_text())["files"][0]["frames"], 2)
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as error:
                main([str(self.path), "--output", str(output)])
        self.assertEqual(error.exception.code, 2)


if __name__ == "__main__": unittest.main()
