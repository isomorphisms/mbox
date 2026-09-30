#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cases=${1:-"$root/tests/conformance/cases.tsv"}
receipt=${2:-"$root/tests/conformance/receipt.tsv"}
tmp="${TMPDIR:-/tmp}/mbox-conformance-receipt.$$"

mkdir "$tmp"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

awk -F '	' '
    $0 !~ /^#/ && NF >= 2 { print $1 }
' "$cases" | LC_ALL=C sort > "$tmp/expected"

awk -F '	' '
    $0 ~ /^#/ || NF == 0 { next }
    NF < 2 { print "malformed receipt row: " $0 > "/dev/stderr"; bad=1; next }
    $2 != "PASS" && $2 != "FAIL" && $2 != "UNIMPLEMENTED" && $2 != "BLOCKED" {
        print "invalid status for " $1 ": " $2 > "/dev/stderr"
        bad=1
    }
    { print $1 }
    END { if (bad) exit 1 }
' "$receipt" | LC_ALL=C sort > "$tmp/actual"

if test -n "$(uniq -d "$tmp/actual")"; then
    echo "duplicate conformance case(s):" >&2
    uniq -d "$tmp/actual" >&2
    exit 1
fi

if ! cmp -s "$tmp/expected" "$tmp/actual"; then
    echo "conformance receipt does not cover exactly the shared case list" >&2
    echo "missing or extra case IDs:" >&2
    comm -3 "$tmp/expected" "$tmp/actual" >&2
    exit 1
fi

echo "PASS conformance receipt coverage"
