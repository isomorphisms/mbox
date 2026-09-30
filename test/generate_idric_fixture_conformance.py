#!/usr/bin/env python3
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
manifest = json.loads((root / "fixtures" / "manifest.json").read_text())

fixtures = [
    ("empty", "empty.mbox"),
    ("lf", "mboxo-lf.mbox"),
    ("crlf", "mboxo-crlf.mbox"),
    ("split", "unescaped-from-splits.mbox"),
]

def bytes_list(data):
    return "[" + ", ".join(str(b) for b in data) + "]"

def events(filename):
    info = manifest["fixtures"][filename]
    out = []
    for r in info.get("ranges", []):
        env_start, _ = r["envelope_range"]
        _, msg_end = r["message_range"]
        out.append(f"EnvelopeBegins (AtOctet {env_start})")
        out.append(f"MessageEnds (AtOctet {msg_end})")
    return "[" + ", ".join(out) + "]"

print("""module MboxFixtureRuntime

import Data.Bits
import Mail.Mbox
import Mail.Source

all_splits :
    List Bits8 →
    List Bits8 →
    List Bits8 →
    Bool
all_splits reversed_prefix [] whole =
    same_events
        (frame_codes_chunks (reverse reversed_prefix) [])
        (frame_codes whole)
all_splits reversed_prefix remaining@(octet :: rest) whole =
    same_events
        (frame_codes_chunks (reverse reversed_prefix) remaining)
        (frame_codes whole)
    && all_splits (octet :: reversed_prefix) rest whole

""")

checks = []
for name, filename in fixtures:
    data = (root / "fixtures" / filename).read_bytes()
    print(f"{name}_bytes : List Bits8")
    print(f"{name}_bytes = {bytes_list(data)}")
    print()
    print(f"{name}_expected : List FramingEvent")
    print(f"{name}_expected = {events(filename)}")
    print()
    print(f"{name}_ok : Bool")
    print(f"{name}_ok = same_events (frame_codes {name}_bytes) {name}_expected")
    print()
    checks.append(f"{name}_ok")

print("lf_chunk_equivalence : Bool")
print("lf_chunk_equivalence = all_splits [] lf_bytes lf_bytes")
print()
checks.append("lf_chunk_equivalence")

print("all_ok : Bool")
print("all_ok = " + " && ".join(checks))
print()
print("main : IO ()")
print('main = if all_ok then putStrLn "PASS Idriç shared framing fixtures" else putStrLn "FAIL Idriç shared framing fixtures"')
