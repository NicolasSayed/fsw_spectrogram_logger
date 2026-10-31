"""Optional workstation inspector for the v57 semicolon ASCII spectrogram layout.

Streaming numeric data, raw timestamps, bounded candidate-overlap index. Does not
rewrite, merge or deduplicate measurements. Python is not needed on the FSW.
"""
from dataclasses import dataclass
from pathlib import Path
import argparse
import hashlib
import json
import math
import sys

MAX_LINE = 1024 * 1024


class ExportFormatError(ValueError):
    pass


@dataclass(frozen=True)
class Frame:
    number: int
    timestamp_raw: str
    points: int
    columns: int
    payload_sha256: str


def number(value):
    try:
        result = float(value.strip().replace(",", ".").replace("D", "E").replace("d", "e"))
    except ValueError as error:
        raise ExportFormatError(f"Invalid numeric value: {value!r}") from error
    if not math.isfinite(result):
        raise ExportFormatError("Nonfinite measurement value")
    return result


def frames(path):
    """Yield validated frames; exhausting the iterator also checks total counts."""
    points = declared = seen = rows = columns = 0
    current = None
    timestamp = None
    digest = None
    units = {}

    def finish():
        if not timestamp or points < 1 or rows != points or units.get("x-unit", "").lower() != "hz":
            raise ExportFormatError("Incomplete frame: require Timestamp, Values, Hz and matching numeric rows")
        return Frame(current, timestamp, rows, columns, digest.hexdigest())

    try:
        with Path(path).open("r", encoding="utf-8-sig", newline="") as stream:
            while True:
                line = stream.readline(MAX_LINE + 1)
                if not line:
                    break
                if len(line) > MAX_LINE:
                    raise ExportFormatError("Export line exceeds 1 MiB")
                if not line.strip():
                    continue
                fields = [v.strip() for v in line.rstrip("\r\n").split(";")]
                key = fields[0].lower()
                value = fields[1] if len(fields) > 1 else ""
                if key == "values":
                    points = int(value)
                elif key == "frames":
                    declared = int(value)
                elif key in {"x-unit", "y-unit"}:
                    units[key] = value
                elif key == "span":
                    if number(value) <= 0:
                        raise ExportFormatError("Zero span is not supported")
                elif key == "frame":
                    if current is not None:
                        yield finish()
                    current = int(value)
                    seen += 1
                    rows = columns = 0
                    timestamp = None
                    digest = hashlib.sha256(json.dumps(units, sort_keys=True).encode("utf-8"))
                elif key == "timestamp":
                    if current is None or len(fields) < 3 or not value or not fields[2]:
                        raise ExportFormatError("Missing frame date/time metadata")
                    timestamp = ";".join(fields[1:]).rstrip(";")
                elif current is not None:
                    while fields and fields[-1] == "": fields.pop()
                    if not timestamp or len(fields) not in {2, 3}:
                        raise ExportFormatError("Unrecognized numeric spectrogram row")
                    for field in fields: number(field)
                    if columns and columns != len(fields):
                        raise ExportFormatError("Inconsistent detector column count")
                    columns = len(fields)
                    digest.update((";".join(fields) + "\n").encode("utf-8"))
                    rows += 1
            if current is None:
                raise ExportFormatError("No spectrogram Frame records")
            yield finish()
            if declared < 1 or declared != seen:
                raise ExportFormatError("Frames count does not match the file")
    except (UnicodeError, ValueError) as error:
        if isinstance(error, ExportFormatError): raise
        raise ExportFormatError(str(error)) from error


def inspect(paths, max_indexed_frames=100000):
    if not 1 <= max_indexed_frames <= 1000000:
        raise ValueError("max_indexed_frames must be 1..1000000")
    index = {}
    summaries = []
    candidates = []
    repeated = conflicts = 0
    timestamps = {}
    for path in paths:
        path = Path(path)
        count = 0
        first = last = None
        for frame in frames(path):
            count += 1
            if first is None: first = frame.timestamp_raw
            last = frame.timestamp_raw
            key = (frame.timestamp_raw, frame.payload_sha256)
            location = {"file": str(path), "frame_number": frame.number}
            if key in index:
                repeated += 1
                if len(candidates) < 20:
                    candidates.append({"timestamp_raw": frame.timestamp_raw,
                                       "first": index[key], "repeated": location})
            else:
                if len(index) >= max_indexed_frames:
                    raise ValueError("Candidate index limit reached. Inspect smaller batches or increase --max-indexed-frames.")
                if frame.timestamp_raw in timestamps and timestamps[frame.timestamp_raw] != frame.payload_sha256:
                    conflicts += 1
                timestamps[frame.timestamp_raw] = frame.payload_sha256
                index[key] = location
        summaries.append({"file": str(path), "frames": count, "first_frame_timestamp_raw": first,
                          "last_frame_timestamp_raw": last})
    return {"files": summaries, "candidate_repeated_frames": repeated,
            "same_timestamp_different_payload": conflicts, "examples": candidates,
            "note": "Raw timestamps have no assumed timezone. Matches use timestamp, units and identical stripped numeric rows. Frame numbers are relative and not unique IDs. No data was removed; matches do not prove sample identity or gapless coverage."}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("files", nargs="+", type=Path)
    parser.add_argument("--max-indexed-frames", type=int, default=100000)
    parser.add_argument("--output", type=Path, help="New JSON file; existing files are protected")
    args = parser.parse_args(argv)
    try:
        result = inspect(args.files, args.max_indexed_frames)
        output = json.dumps(result, indent=2, ensure_ascii=True) + "\n"
        if args.output:
            with args.output.open("x", encoding="utf-8") as stream: stream.write(output)
        else: print(output, end="")
    except (OSError, ValueError) as error:
        parser.exit(2, f"Inspection failed: {error}\n")
    return 0


if __name__ == "__main__": sys.exit(main())
