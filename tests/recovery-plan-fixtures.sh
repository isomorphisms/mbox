#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 MBOX_RECOVER_PLAN_EXECUTABLE" >&2
    exit 2
fi

exe=$1
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

check()
{
    fixture=$1
    expected=$2
    expected_status=$3

    out=$(mktemp)
    err=$(mktemp)
    trap 'rm -f "$out" "$err"' EXIT HUP INT TERM

    status=0
    "$exe" "fixtures/transactions/$fixture" >"$out" 2>"$err" || status=$?

    if [ "$status" -ne "$expected_status" ]; then
        cat "$out" >&2
        cat "$err" >&2
        echo "$fixture: status $status, expected $expected_status" >&2
        exit 1
    fi

    if ! grep -Fx "action	$expected" "$out" >/dev/null; then
        cat "$out" >&2
        echo "$fixture: expected action $expected" >&2
        exit 1
    fi

    rm -f "$out" "$err"
    trap - EXIT HUP INT TERM
}

check prepared.json recover 0
check mid-archive.json recover 0
check archive-fsynced.json finish_source 0
check new-source-tail.json finish_source_preserve_tail 0
check source-prefix-mutated.json refuse 2

echo "PASS recovery-plan fixtures"
