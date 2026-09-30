#!/bin/sh
set -eu

root=$(git rev-parse --show-toplevel)
tmp="${TMPDIR:-/tmp}/mbox-branch-receipts.$$"
mkdir "$tmp"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

if test "$#" -eq 0; then
    set -- D Agda Grease "Idriç" Idris
fi

args=
for branch do
    ref=
    if git show-ref --verify --quiet "refs/heads/$branch"; then
        ref="$branch"
    elif git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
        ref="origin/$branch"
    else
        echo "missing local ref for branch: $branch" >&2
        exit 2
    fi

    path="$tmp/$branch.tsv"
    git show "$ref:tests/conformance/expected.tsv" > "$path" || {
        echo "$branch does not publish tests/conformance/expected.tsv" >&2
        exit 1
    }

    if test -z "$args"; then
        args="$branch=$path"
    else
        args="$args
$branch=$path"
    fi
done

set --
old_ifs=$IFS
IFS='
'
for item in $args; do
    set -- "$@" "$item"
done
IFS=$old_ifs

exec sh "$root/tests/conformance/compare-receipts.sh" "$@"
