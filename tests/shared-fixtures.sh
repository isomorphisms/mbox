#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

hash_file() {
    if command -v sha256 >/dev/null 2>&1; then
        sha256 -q "$1"
    else
        sha256sum "$1" | awk '{print $1}'
    fi
}

while read -r expected name; do
    test -n "$expected" || continue
    actual=$(hash_file "$root/fixtures/$name")
    test "$actual" = "$expected"
done < "$root/fixtures/SHA256SUMS"

sh "$root/tests/transaction-fixtures.sh"

echo "PASS shared mailbox fixtures"
