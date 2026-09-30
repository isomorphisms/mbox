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

def octets(data):
    if not data:
        return "[]"
    return "[" + ", ".join(f"source_octet {b}" for b in data) + "]"

def events(filename):
    info = manifest["fixtures"][filename]
    out = []
    for r in info.get("ranges", []):
        env_start, _ = r["envelope_range"]
        _, msg_end = r["message_range"]
        out.append(f"EnvelopeBegins (AtOctet {env_start})")
        out.append(f"MessageEnds (AtOctet {msg_end})")
    return "[" + ", ".join(out) + "]"

print("""module MboxFixtureTypecheck

import Mail.Mbox
import Mail.Source

""")

for name, filename in fixtures:
    data = (root / "fixtures" / filename).read_bytes()
    print(f"{name}_bytes : List MailSourceOctet")
    print(f"{name}_bytes = {octets(data)}")
    print()
    print(f"{name}_events : frame_octets {name}_bytes = {events(filename)}")
    print(f"{name}_events = Refl")
    print()
