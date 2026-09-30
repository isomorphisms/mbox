#!/usr/bin/env python3

import json
from pathlib import Path


root = Path(__file__).resolve().parents[1]
transactions = root / "fixtures" / "transactions"

cases = [
    ("ordinary", "ordinary.json"),
    ("prepared", "prepared.json"),
    ("mid_archive", "mid-archive.json"),
    ("archive_fsynced", "archive-fsynced.json"),
    ("new_source_tail", "new-source-tail.json"),
    ("source_prefix_mutated", "source-prefix-mutated.json"),
]


def load(name):
    return json.loads((transactions / name).read_text())


def phase_expr(data):
    if data.get("journal") is None and data.get("observed_state", {}).get("journal") is None:
        return "NoJournal"

    phase = data.get("phase")
    if phase == "prepared":
        return "Prepared"
    if phase == "appending":
        completed = data["archive_append"]["completed_occurrences"]
        return f"(Appending {completed})"
    if phase == "archive_fsynced":
        return "ArchiveFsynced"

    # ordinary.json has no journal/phase.
    if data.get("observed_state", {}).get("journal") is None:
        return "NoJournal"

    raise SystemExit(f"unrecognized phase in fixture: {phase!r}")


def source_relation_expr(data):
    scenario = data["scenario"]
    if scenario == "new-source-tail":
        return "SnapshotWithAppendOnlyTail"
    if scenario == "source-prefix-mutated":
        return "SnapshotPrefixChanged"
    return "ExactSnapshot"


def expected_action_expr(data):
    action = data["expected"]["action"]
    if action == "move":
        return "StartFreshMove"
    if action == "recover":
        completed = data["archive_append"]["completed_occurrences"]
        selected = len(data["selected"])
        return f"(AppendRemaining {selected - completed})"
    if action == "finish_source":
        return "FinishSourceRewrite"
    if action == "finish_source_preserve_tail":
        return "FinishSourceRewritePreservingTail"
    if action == "refuse":
        return "RefuseSourceChanged"
    raise SystemExit(f"unrecognized expected action: {action!r}")


print("""module TransactionFixtureRuntime

import Mail.Refile.Transaction
import System

""")

checks = []
for label, filename in cases:
    data = load(filename)
    selected = len(data.get("selected", []))

    # ordinary.json deliberately omits selected details; the common fixture
    # contains three selected occurrences.
    if data["scenario"] == "ordinary":
        selected = 3

    phase = phase_expr(data)
    relation = source_relation_expr(data)
    expected = expected_action_expr(data)

    print(f"{label}_ok : Bool")
    print(
        f"{label}_ok = "
        f"plan_recovery {selected} {relation} {phase} == {expected}"
    )
    print()
    checks.append(f"{label}_ok")

print("impossible_progress_ok : Bool")
print(
    "impossible_progress_ok = "
    "plan_recovery 3 ExactSnapshot (Appending 4) == RefuseImpossibleProgress"
)
print()
checks.append("impossible_progress_ok")

print("tail_before_archive_durable_ok : Bool")
print(
    "tail_before_archive_durable_ok = "
    "plan_recovery 3 SnapshotWithAppendOnlyTail Prepared == RefuseSourceChanged"
)
print()
checks.append("tail_before_archive_durable_ok")

print("all_ok : Bool")
print("all_ok = " + " && ".join(checks))
print()
print("main : IO ()")
print("main =")
print("    if all_ok")
print('       then putStrLn "PASS Idriç transaction recovery planner"')
print("       else do")
print('           putStrLn "FAIL Idriç transaction recovery planner"')
print("           exitFailure")
