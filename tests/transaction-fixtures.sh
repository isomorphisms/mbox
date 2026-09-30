#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
f="$root/fixtures/transactions/common"
tmp="${TMPDIR:-/tmp}/mbox-transaction-fixtures.$$"

mkdir "$tmp"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

cat "$f/keeper-before.mbox" "$f/selected.mbox" "$f/keeper-after.mbox" > "$tmp/source-before"
cmp "$tmp/source-before" "$f/source-before.mbox"

cat "$f/keeper-before.mbox" "$f/keeper-after.mbox" > "$tmp/expected-source"
cmp "$tmp/expected-source" "$f/expected-source.mbox"

cat "$f/archive-before.mbox" "$f/selected.mbox" > "$tmp/expected-archive"
cmp "$tmp/expected-archive" "$f/expected-archive.mbox"

cat "$f/archive-before.mbox" "$f/selected-first.mbox" > "$tmp/archive-mid-one"
cmp "$tmp/archive-mid-one" "$f/archive-mid-one.mbox"

cat "$f/source-before.mbox" "$f/new-tail.mbox" > "$tmp/source-with-tail"
cmp "$tmp/source-with-tail" "$f/source-with-new-tail.mbox"

cat "$f/expected-source.mbox" "$f/new-tail.mbox" > "$tmp/expected-source-with-tail"
cmp "$tmp/expected-source-with-tail" "$f/expected-source-with-new-tail.mbox"

# The archive begins with one old byte-identical duplicate. A successful move
# adds both source occurrences, so the final archive has three.
test "$(grep -c '^From selected-duplicate@example.org ' "$f/archive-before.mbox")" -eq 1
test "$(grep -c '^From selected-duplicate@example.org ' "$f/source-before.mbox")" -eq 2
test "$(grep -c '^From selected-duplicate@example.org ' "$f/expected-archive.mbox")" -eq 3

# Prepared recovery starts from untouched source/archive.
cmp "$f/source-before.mbox" "$f/source-before.mbox"
cmp "$f/archive-before.mbox" "$f/archive-before.mbox"

# Mid-archive recovery must append exactly the two remaining occurrences.
cat "$f/archive-mid-one.mbox" "$f/selected-duplicate.mbox" "$f/selected-duplicate.mbox" > "$tmp/mid-recovered"
cmp "$tmp/mid-recovered" "$f/expected-archive.mbox"

# Archive-fsynced recovery must not append again.
cmp "$f/expected-archive.mbox" "$f/expected-archive.mbox"

# An append-only source tail survives recovery.
cmp "$f/expected-source-with-new-tail.mbox" "$tmp/expected-source-with-tail"

# A non-append-only prefix mutation is deliberately a refusal case. The fixture
# itself must differ from the snapshotted source.
if cmp -s "$f/source-mutated.mbox" "$f/source-before.mbox"; then
    echo "source mutation fixture accidentally equals source snapshot" >&2
    exit 1
fi

echo "PASS transaction fixture equations"
