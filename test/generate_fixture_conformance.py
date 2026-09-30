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

def agda_list(values):
    if not values:
        return "[]"
    return " ∷ ".join(str(x) for x in values) + " ∷ []"

def expected_events(name):
    info = manifest["fixtures"][name]
    out = []
    for r in info.get("ranges", []):
        env_start, env_end = r["envelope_range"]
        _, msg_end = r["message_range"]
        out += [
            f"envelope-begins {env_start}",
            f"message-begins {env_end}",
            f"message-ends {msg_end}",
        ]
    return " ∷ ".join(out) + (" ∷ []" if out else "[]")

print("""module FixtureConformance where

open import Data.List using (List; []; _∷_; _++_)
open import Relation.Binary.PropositionalEquality using (_≡_; refl)
open import Mbox

run-events : List Byte → List FrameEvent
run-events input with feed initial-framer input
... | fed state first-events with finish state
...   | fed _ eof-events = first-events ++ eof-events
""")

for var, filename in fixtures:
    data = (root / "fixtures" / filename).read_bytes()
    print(f"{var}-bytes : List Byte")
    print(f"{var}-bytes = {agda_list(data)}")
    print()
    print(f"{var}-events : run-events {var}-bytes ≡ {expected_events(filename)}")
    print(f"{var}-events = refl")
    print()
