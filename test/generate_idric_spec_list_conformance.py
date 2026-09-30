#!/usr/bin/env python3

import json
from pathlib import Path


root = Path(__file__).resolve().parents[1]
fixture_path = root / "fixtures" / "spec-list-selection.mbox"
manifest = json.loads((root / "fixtures" / "manifest.json").read_text())
fixture_info = manifest["fixtures"]["spec-list-selection.mbox"]

selected_ids = set(fixture_info["selected_message_ids"])
not_selected_ids = set(fixture_info["not_selected_message_ids"])


def split_mbox_entries(data: bytes):
    starts = []
    offset = 0

    for line in data.splitlines(keepends=True):
        if line.startswith(b"From "):
            starts.append(offset)
        offset += len(line)

    if not starts:
        return []

    starts.append(len(data))
    return [
        data[starts[index] : starts[index + 1]]
        for index in range(len(starts) - 1)
    ]


def header_block(entry: bytes):
    envelope_end = entry.find(b"\n")
    if envelope_end < 0:
        raise SystemExit("fixture entry has no complete mbox envelope line")

    message = entry[envelope_end + 1 :]

    lf_end = message.find(b"\n\n")
    crlf_end = message.find(b"\r\n\r\n")

    candidates = [
        (lf_end, 2) if lf_end >= 0 else None,
        (crlf_end, 4) if crlf_end >= 0 else None,
    ]
    candidates = [candidate for candidate in candidates if candidate is not None]

    if not candidates:
        return message

    start, separator_length = min(candidates, key=lambda pair: pair[0])
    return message[: start + separator_length]


def message_id(headers: bytes):
    for line in headers.replace(b"\r\n", b"\n").split(b"\n"):
        if line.lower().startswith(b"message-id:"):
            value = line.split(b":", 1)[1].strip()
            return value.decode("ascii")

    raise SystemExit("fixture message is missing Message-ID")


def bits(data: bytes):
    return "[" + ", ".join(str(value) for value in data) + "]"


entries = []
for raw_entry in split_mbox_entries(fixture_path.read_bytes()):
    headers = header_block(raw_entry)
    identity = message_id(headers)

    if identity in selected_ids:
        expected = True
    elif identity in not_selected_ids:
        expected = False
    else:
        raise SystemExit(f"fixture Message-ID is not in manifest expectations: {identity}")

    entries.append((identity, headers, expected))

actual_ids = {identity for identity, _, _ in entries}
expected_ids = selected_ids | not_selected_ids

if actual_ids != expected_ids:
    missing = sorted(expected_ids - actual_ids)
    unexpected = sorted(actual_ids - expected_ids)
    raise SystemExit(
        f"fixture/manifest identity mismatch: missing={missing!r} unexpected={unexpected!r}"
    )

if len(entries) != fixture_info["message_count"]:
    raise SystemExit(
        f"fixture count mismatch: got {len(entries)}, "
        f"expected {fixture_info['message_count']}"
    )

print("""module SpecListFixtureRuntime

import Data.Bits
import Mail.HeaderSelection
import Mail.MboxSelection
import Mail.SpecList
import System

""")

whole_mailbox = fixture_path.read_bytes()
expected_ordinals = [
    index
    for index, (_, _, expected) in enumerate(entries)
    if expected
]

print("whole_mailbox : List Bits8")
print(f"whole_mailbox = {bits(whole_mailbox)}")
print()
print("integrated_ok : Bool")
print("integrated_ok =")
print("    case scan_selection_codes spec_list_policy 4194304 whole_mailbox of")
print("        Left error => False")
print(
    "        Right selected => "
    f"selected_ordinals selected == {expected_ordinals}"
)
print()

checks = ["integrated_ok"]


for index, (identity, headers, expected) in enumerate(entries):
    name = f"message_{index}"
    expected_text = "True" if expected else "False"

    print(f"-- {identity}")
    print(f"{name}_header : List Bits8")
    print(f"{name}_header = {bits(headers)}")
    print()
    print(f"{name}_ok : Bool")
    print(
        f"{name}_ok = "
        f"header_codes_match spec_list_policy {name}_header == {expected_text}"
    )
    print()
    checks.append(f"{name}_ok")

print("all_ok : Bool")
print("all_ok = " + " && ".join(checks))
print()
print("main : IO ()")
print("main =")
print("    if all_ok")
print('       then putStrLn "PASS Idriç SPEC-LIST selection fixture"')
print("       else do")
print('           putStrLn "FAIL Idriç SPEC-LIST selection fixture"')
print("           exitFailure")
