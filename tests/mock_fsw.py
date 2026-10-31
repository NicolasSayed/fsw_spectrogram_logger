"""Loopback-only mock. Its synthetic exports are independent of vendor data."""
from contextlib import contextmanager
from pathlib import Path
import re
import socketserver
import threading
import time


SAMPLE = b"""Type;FSW;
Version;6.40;
Mode;ANALYZER;SPECTROGRAM
Span;2000000;Hz
Trace 1:;;
x-Unit;Hz;
y-Unit;dBm;
Values;3;
Frames;2;
Frame;0;
Timestamp;31.Oct 2026;00:38:00.123
999000000;-70;-80
1000000000;-50;-60
1001000000;-71;-81
Frame;-1;
Timestamp;31.Oct 2026;00:37:59.123
999000000;-72;-82
1000000000;-52;-62
1001000000;-73;-83
"""


class MockFSW:
    def __init__(self):
        self.commands = []
        self.errors = []
        self.catalogue = "'Spectrum',1,'Spectrogram',2"
        self.kind = "SGRAM"
        self.span = "2000000"
        self.channel = "Spectrum"
        self.identity = "Rohde&Schwarz,FSW-26,TEST_ONLY/000000,6.40"
        self.display = "0"
        self.display_lock = "0"
        self.payload = SAMPLE
        self.mode = "success"
        self.delay = 0
        self.fragment = False
        self.store_times = []
        self.paths = []
        self.clear_count = 0
        self.drop_idn_once = False
        self.unsupported_query = False
        self.connections = 0

    def handle(self, command, state):
        self.commands.append(command)
        if command == "*IDN?":
            if self.drop_idn_once:
                self.drop_idn_once = False
                return None, True
            return self.identity, False
        if command == "SYST:ERR?":
            return self.errors.pop(0) if self.errors else '0,"No error"', False
        if command == "INST:SEL?": return self.channel, False
        if command == "LAY:CAT?": return self.catalogue, False
        if re.fullmatch(r"LAY:WIND\d+:TYPE\?", command):
            if self.unsupported_query:
                self.errors.append('-113,"Undefined header; LAY:WIND:TYPE?"')
                return None, False
            return "DIAG" if command == "LAY:WIND1:TYPE?" else self.kind, False
        if command == "SENS:FREQ:SPAN?": return self.span, False
        if command == "SYST:DISP:LOCK?": return self.display_lock, False
        if command == "SYST:DISP:UPD?": return self.display, False
        if command.startswith("SYST:DISP:UPD "):
            self.display = command.split()[-1]
            return None, False
        if command == "*OPC?":
            if state.pop("store_pending", False) and self.mode == "timeout":
                return None, False
            return "1", False
        match = re.fullmatch(r"MMEM:STOR(\d+):SGR '([^']+)'", command)
        if match:
            self.store_times.append(time.monotonic())
            path = Path(match[2]); self.paths.append(path)
            if self.mode == "reject":
                self.errors.append('-113,"Undefined header; MMEM:STOR:SGR"')
            elif self.mode not in {"no_file", "empty"} and not (self.mode == "fail_once" and len(self.paths) == 1):
                if path.exists(): raise AssertionError("Logger tried to overwrite existing data")
                time.sleep(self.delay)
                path.write_bytes(self.payload)
            elif self.mode == "empty": path.touch()
            state["store_pending"] = True
            return None, self.mode == "drop"
        if re.fullmatch(r"CALC\d+:SGR:CLE", command):
            assert self.paths and self.paths[-1].read_bytes() == self.payload
            self.clear_count += 1
            if self.mode == "clear_reject": self.errors.append('-113,"Clear unsupported"')
            return None, False
        self.errors.append('-113,"Unexpected command in mock"')
        return None, False


@contextmanager
def instrument():
    fake = MockFSW()
    class Handler(socketserver.StreamRequestHandler):
        def handle(self):
            fake.connections += 1
            state = {}
            try:
                while raw := self.rfile.readline(65537):
                    if len(raw) > 65536: return
                    reply, close = fake.handle(raw.decode("ascii").strip(), state)
                    if close: return
                    if reply is not None:
                        data = reply.encode("ascii") + b"\r\n"
                        if fake.fragment:
                            for byte in data:
                                self.wfile.write(bytes([byte])); self.wfile.flush()
                                time.sleep(.001)
                        else: self.wfile.write(data); self.wfile.flush()
            except (ConnectionError, OSError): pass
    class Server(socketserver.ThreadingTCPServer):
        daemon_threads = True
        allow_reuse_address = True
    with Server(("127.0.0.1", 0), Handler) as server:
        fake.port = server.server_address[1]
        thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": .05}, daemon=True)
        thread.start()
        try: yield fake
        finally: server.shutdown(); thread.join(timeout=3)
