#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cases="$root/tests/conformance/cases.tsv"

if test "$#" -lt 2; then
    echo "usage: compare-receipts.sh NAME=RECEIPT NAME=RECEIPT [...]" >&2
    exit 2
fi

tmp="${TMPDIR:-/tmp}/mbox-conformance-compare.$$"
mkdir "$tmp"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

awk -F '\t' '$0 !~ /^#/ && NF >= 2 { print $1 }' "$cases" > "$tmp/matrix"
header=case_id

for spec do
    name=${spec%%=*}
    file=${spec#*=}

    if test "$name" = "$spec" || test -z "$name" || test -z "$file"; then
        echo "bad receipt argument: $spec" >&2
        exit 2
    fi

    sh "$root/tests/conformance/check-receipt.sh" "$cases" "$file" >/dev/null

    awk -F '\t' -v OFS='\t' '
        NR == FNR {
            if ($0 !~ /^#/ && NF >= 2)
                status[$1] = $2
            next
        }
        {
            print $0, status[$1]
        }
    ' "$file" "$tmp/matrix" > "$tmp/next"
    mv "$tmp/next" "$tmp/matrix"
    header="$header	$name"
done

printf '%s\n' "$header"
cat "$tmp/matrix"

if awk -F '\t' '
    {
        for (i = 2; i <= NF; ++i)
            if ($i == "FAIL")
                bad = 1
    }
    END { exit bad ? 0 : 1 }
' "$tmp/matrix"
then
    echo "FAIL: at least one implementation disagrees with the shared expectation" >&2
    exit 1
fi

exit 0
