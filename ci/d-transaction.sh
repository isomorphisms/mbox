#!/usr/bin/env bash
set -euxo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

bash ci/d-implementation.sh

workspace=${GITHUB_WORKSPACE:-"$repo_root"}
runtime_dmd="$workspace/.runtime-dmd/generated/linux/release/64/dmd"
runtime_import="$workspace/.runtime-dmd/druntime/import"
phobos="$workspace/.runtime-phobos"
phobos_lib="$phobos/generated/linux/release/64/libphobos2.a"

"$runtime_dmd" \
  -conf= \
  -fPIC \
  "-I$runtime_import" \
  "-I$phobos" \
  -Isource \
  source/mbox.d \
  source/mbox_recover_plan.d \
  "$phobos_lib" \
  -defaultlib= \
  -debuglib= \
  -L-lpthread \
  -L-lm \
  -L-ldl \
  -of=/tmp/mbox-recover-plan

test -x /tmp/mbox-recover-plan
sh tests/recovery-plan-fixtures.sh /tmp/mbox-recover-plan

if test -n "${GITHUB_STEP_SUMMARY:-}"; then
  cat >> "$GITHUB_STEP_SUMMARY" <<'EOF'
PASS: the read-only D recovery planner classified all five transaction fixtures
from source/archive byte evidence rather than trusting their phase labels.

Mutation/recovery execution remains deliberately separate until this evidence
layer is compile- and fixture-verified.
EOF
fi
