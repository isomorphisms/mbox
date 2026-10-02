#!/usr/bin/env bash
set -euxo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

workspace=${GITHUB_WORKSPACE:-"$repo_root"}
ick_revision=ac15b23e75755773809ada172ed378555b0adffe

sh tests/shared-fixtures.sh

test "$(head -n 1 ci/build-toolchain.tsv)" = \
  $'build_id\ttarget\ttoolchain\tick_revision\tick_status\tick_evidence'
test "$(awk -F '\t' 'NR > 1 {print $3}' ci/build-toolchain.tsv | sort -u)" = ick
test "$(awk -F '\t' 'NR > 1 {print $4}' ci/build-toolchain.tsv | sort -u)" = \
  "$ick_revision"
test "$(awk -F '\t' 'NR > 1 {print $5}' ci/build-toolchain.tsv | sort -u)" = \
  qualified

(
  cd .ick/dmd/compiler/src
  ldmd2 -run ./build.d dmd HOST_DMD="$(command -v ldmd2)"
)

dmd_bin=$(find .ick/dmd/generated -type f -name dmd -perm -u+x -print -quit)
test -n "$dmd_bin"
dmd_bin=$(realpath "$dmd_bin")
"$dmd_bin" --version
printf '%s\n' "$dmd_bin" > "$workspace/.icky-dmd-bin"

mkdir -p .runtime-dmd/generated/linux/release/64
cp "$dmd_bin" .runtime-dmd/generated/linux/release/64/dmd
chmod +x .runtime-dmd/generated/linux/release/64/dmd

runtime_dmd="$workspace/.runtime-dmd/generated/linux/release/64/dmd"

make -C .runtime-dmd/druntime -j"$(nproc)" \
  MODEL=64 OS=linux BUILD=release SHARED=0 DMD="$runtime_dmd"

make -C .runtime-phobos -j"$(nproc)" \
  MODEL=64 OS=linux BUILD=release SHARED=0 USE_IMPORTC=1 \
  DMD_DIR="$workspace/.runtime-dmd" DMD="$runtime_dmd"

test -f .runtime-dmd/generated/linux/release/64/libdruntime.a
test -f .runtime-phobos/generated/linux/release/64/libphobos2.a

runtime_import="$workspace/.runtime-dmd/druntime/import"
runtime_source="$workspace/.runtime-dmd/druntime/src"
phobos="$workspace/.runtime-phobos"
phobos_lib="$phobos/generated/linux/release/64/libphobos2.a"
link_flags=(-defaultlib= -debuglib= -L-lpthread -L-lm -L-ldl)
common=(-conf= -fPIC "-I$runtime_import" "-I$phobos" -Isource)

"$runtime_dmd" -conf= -fPIC -unittest -main \
  "-I$runtime_import" "-I$phobos" -Isource \
  source/mbox.d source/mbox_file.d \
  "$phobos_lib" \
  "${link_flags[@]}" \
  -of=/tmp/mbox-d-tests
/tmp/mbox-d-tests

"$runtime_dmd" "${common[@]}" \
  source/mbox.d source/mbox_file.d source/mbox_file_main.d \
  "$phobos_lib" "${link_flags[@]}" \
  -of=/tmp/mbox-file

"$runtime_dmd" "${common[@]}" \
  source/mbox.d source/mbox_inspect.d \
  "$phobos_lib" "${link_flags[@]}" \
  -of=/tmp/mbox-inspect

"$runtime_dmd" "${common[@]}" \
  source/mbox.d source/mbox_file.d source/file_spec_list.d \
  "$phobos_lib" "${link_flags[@]}" \
  -of=/tmp/file-spec-list

"$runtime_dmd" "${common[@]}" \
  source/mbox.d source/mbox_file.d source/mbox_conformance.d \
  "$phobos_lib" "${link_flags[@]}" \
  -of=/tmp/mbox-conformance

for executable in \
  /tmp/mbox-file \
  /tmp/mbox-inspect \
  /tmp/file-spec-list \
  /tmp/mbox-conformance
do
  test -x "$executable"
done

"$runtime_dmd" -conf= -betterC -release \
  "-I$runtime_import" \
  source/spec_list_plan_betterc.d \
  -of=/tmp/spec-list-plan-betterc

/tmp/spec-list-plan-betterc \
  fixtures/spec-list-selection.mbox \
  > /tmp/spec-list-plan.tsv \
  2> /tmp/spec-list-plan.stderr
test "$(wc -l < /tmp/spec-list-plan.tsv | tr -d ' ')" = 9
grep -Fx 'matched: 9' /tmp/spec-list-plan.stderr

/tmp/spec-list-plan-betterc \
  fixtures/empty.mbox \
  > /tmp/spec-list-empty.tsv \
  2> /tmp/spec-list-empty.stderr
test ! -s /tmp/spec-list-empty.tsv
grep -Fx 'matched: 0' /tmp/spec-list-empty.stderr

"$runtime_dmd" -conf= -betterC -release -c -fPIC \
  -target=x86_64-unknown-netbsd \
  "-I$runtime_source" \
  source/spec_list_plan_betterc.d \
  -of=/tmp/spec-list-plan-netbsd.o

readelf -h /tmp/spec-list-plan-netbsd.o \
  | tee /tmp/spec-list-plan-netbsd.elf
grep -Eq 'Class:[[:space:]]+ELF64' /tmp/spec-list-plan-netbsd.elf
grep -Eq 'Machine:[[:space:]]+Advanced Micro Devices X86-64' \
  /tmp/spec-list-plan-netbsd.elf

/tmp/mbox-inspect \
  --source fixtures/header-corners.mbox \
  --header Subject > /tmp/inspect.tsv
grep -F $'header\t' /tmp/inspect.tsv

rm -f /tmp/mbox-archive
/tmp/mbox-file \
  --source fixtures/spec-list-selection.mbox \
  --archive /tmp/mbox-archive \
  --header To \
  --header Cc \
  --header Subject \
  --pattern SPEC-LIST \
  --ignore-case > /tmp/file-plan.txt
grep -F 'dry run: no mailbox bytes changed' /tmp/file-plan.txt
test ! -e /tmp/mbox-archive

/tmp/file-spec-list --help > /tmp/spec-list-help.txt

/tmp/mbox-conformance | tee /tmp/d-core-receipt.tsv

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cp fixtures/copy-preservation.mbox "$tmp/copy-source"
/tmp/mbox-file \
  --source "$tmp/copy-source" \
  --archive "$tmp/copy-archive" \
  --header Message-ID \
  --pattern preserve@example.org \
  --move
cmp fixtures/copy-preservation.mbox "$tmp/copy-archive"
test ! -s "$tmp/copy-source"

cp fixtures/dedup-corners.mbox "$tmp/dedup-source"
/tmp/mbox-file \
  --source "$tmp/dedup-source" \
  --archive "$tmp/dedup-archive" \
  --header To \
  --pattern user@example.org \
  --move
cmp fixtures/dedup-corners.mbox "$tmp/dedup-archive"
test ! -s "$tmp/dedup-source"

cp fixtures/transactions/common/source-before.mbox "$tmp/tx-source"
cp fixtures/transactions/common/archive-before.mbox "$tmp/tx-archive"
/tmp/mbox-file \
  --source "$tmp/tx-source" \
  --archive "$tmp/tx-archive" \
  --header To \
  --pattern SPEC-LIST \
  --ignore-case \
  --move
cmp fixtures/transactions/common/expected-source.mbox "$tmp/tx-source"
cmp fixtures/transactions/common/expected-archive.mbox "$tmp/tx-archive"

{
  printf '%s\t%s\t%s\n' \
    fixture.checksums PASS 'shared fixture checksum gate'
  cat /tmp/d-core-receipt.tsv
  printf '%s\t%s\t%s\n' \
    copy.byte-identical PASS \
    'actual mbox-file move preserved the selected entry byte-for-byte'
  printf '%s\t%s\t%s\n' \
    copy.multiplicity PASS \
    'actual mbox-file move preserved all six source occurrences'
  printf '%s\t%s\t%s\n' \
    transaction.ordinary PASS \
    'actual archive-first move matched ordinary source/archive oracle'
  printf '%s\t%s\t%s\n' \
    transaction.prepared UNIMPLEMENTED \
    'no durable transaction journal'
  printf '%s\t%s\t%s\n' \
    transaction.mid-archive UNIMPLEMENTED \
    'no durable transaction journal'
  printf '%s\t%s\t%s\n' \
    transaction.archive-fsynced UNIMPLEMENTED \
    'no durable transaction journal'
  printf '%s\t%s\t%s\n' \
    transaction.new-source-tail UNIMPLEMENTED \
    'no durable transaction journal'
  printf '%s\t%s\t%s\n' \
    transaction.mutated-prefix-refuse UNIMPLEMENTED \
    'no durable transaction journal'
} > tests/conformance/receipt.tsv

sh tests/conformance/check-receipt.sh \
  tests/conformance/cases.tsv \
  tests/conformance/receipt.tsv

LC_ALL=C sort tests/conformance/expected.tsv > /tmp/expected.sorted
LC_ALL=C sort tests/conformance/receipt.tsv > /tmp/receipt.sorted
cmp /tmp/expected.sorted /tmp/receipt.sorted

if test -n "${GITHUB_STEP_SUMMARY:-}"; then
  cat >> "$GITHUB_STEP_SUMMARY" <<'EOF'
PASS: mbox D sources compiled and unit tests executed with pinned ICK DMD
ac15b23e75755773809ada172ed378555b0adffe and matching v2.113
druntime/Phobos on Linux amd64.

PASS: mbox-file, mbox-inspect, file-spec-list, mbox-conformance, and the
BetterC SPEC-LIST planner executed their shared fixture paths.

PASS: the BetterC SPEC-LIST planner produced a NetBSD amd64 ELF object through
the same pinned ICK DMD target.

OUT OF SCOPE: NetBSD normal-D druntime/Phobos linking and native SDF execution.
EOF
fi
