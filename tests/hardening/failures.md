# Failures found and repaired while qualifying this candidate

2026-10-06, disposable Linux execution only.

- The first mutation run reported 12 killed / 1 survived. Its initial stale-plan
  mutant removed several snapshot checks, but the backup-digest and final commit
  checks still rejected it. The strengthened mutant rebinds the source fingerprint
  to current bytes while retaining old ranges and bypassing fresh plan validation.
  The stale-source regression rejects that actual broken rewrite. All 13 final
  variants are killed. This was a weak mutant, not proof of live safety.
- Review found that archive verification originally compared against the backup
  copy of the old archive. A damaged backup could therefore become its own oracle.
  The implementation now verifies the backup digest against the planned baseline
  and compares the prepared archive directly with the unchanged original archive.
  `test_baseline_backup_corruption_and_failures` injects actual persisted corruption,
  asserts unchanged source/archive, and then checks recovery.
- Review found the first fsync-injection loop included a call number beyond the
  absent-archive transaction's actual calls. It did not assert that injection ran.
  The corrected regression uses a preexisting archive (23 actual sync calls) and
  requires every declared failure to be reached. A missed point is a test failure.
- The original abrupt-write fixture exited before any bytes were written. It now
  uses multiple 64 KiB writes and exits at the second write. It explicitly proves
  the prepared archive/source file contains a nonzero incomplete byte prefix
  before checking restart, exact archive bytes and keeper preservation.
- Header unfolding used repeated byte concatenation. It now joins fragments once;
  huge body lines use bounded fragments and do not enter header state.
- The prior Cat Food non-Termux cloud default survives only as a known-bad
  counterpart in its host regression; positive platform/distro evidence replaces it.

These repairs are bound by the final code/fixture hashes and execution receipts.
No fixture outcome has been relabeled as Idriç, D, NetBSD or SDF-live acceptance.
