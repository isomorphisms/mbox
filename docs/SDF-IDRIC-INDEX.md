# SDF / NetBSD: Idriç migration of plaintext mbox indices

Status: **NOT QUALIFIED FOR LIVE MAIL**. This branch is a read-only
cross-check milestone, not the complete Python replacement.

The `Idriç` language branch already owns the mboxo framer,
six-header SPEC-LIST policy, and pure recovery policy. This change adds:

- `Mail.Index.Plaintext`: canonical decimal parsing (arbitrary-size
  `Number`), per-message half-open range bounds, contiguous coverage,
  ordinal sequencing, SHA-256 *syntax* and sorted selector-name checking.
- `IndexRowFixtures.idric`: executable pure contract tests, including
  4,433,384,703-byte offsets and deliberate bad records.
- `IndexAudit.idric`: independently scans source mailbox bytes using the
  Idriç framer and selector, then compares each selected occurrence with the
  persisted `messages.tsv` and `lists.tsv` in the existing snapshot.
  Compares count and coverage with `source.state`.
- CI: independent Python builder/validator is **test oracle only**, never
  part of the delivered Idriç runtime.

**Current output is `INDEX_SELECTION_MATCH`, not `VERIFIED`.**
Source and per-entry SHA-256 hashes are *parsed* but not yet recomputed
in Idriç; file size is checked, but source identity/inode/nanosecond
timestamps and concurrent delivery are not. Passing the audit alone
cannot authorize copying, overwriting or removing mail.

## SDF acceptance record from 2026-10-23

Prior independently verified Python index snapshot:

```text
messages                 70481
spec_list_messages       28243
spec_list_bytes          1785441062
source_bytes             4433384703
sha256                   def9c65119993aca354f45b0c85031e59c7bf910c196482e90441b50c18842d9
```

Those are comparison expectations, **not an Idriç execution receipt**.

## NetBSD preflight — in the SDF shell

No assumption that the maintained compiler, its Chez support library, or
its runtime has a NetBSD build. The Ubuntu CI artifact is not an SDF
executable. Check without creating or changing anything:

```sh
uname -s
uname -m
for tool in idris2 edric scheme chez clang cc git sha256; do
    command -v "$tool" || :
done
```

The eventual Idriç command is:

```text
idric-index-audit SNAPSHOT_DIRECTORY SOURCE_MBOX
```

where the first argument points to the directory containing
`source.state`, `messages.tsv`, and `lists.tsv`. A snapshot name can
be read from `~/opt/mbox/index/CURRENT`; **do not** modify CURRENT
or any files in that snapshot. No SDF command to build or execute the
audit is claimed until an exact NetBSD compiler/runtime is installed
and verified.

The source scanner currently performs a decoded Idriç call for each
input octet. Its 4.4 GB SDF performance and resource use are **unknown**.
Benchmark on small disposable fixtures first, not the live mailbox.

## Remaining before retiring Python or moving mail

1. Implement **Idriç** streaming SHA-256 (or a narrowly typed, independently
   qualified native hash primitive) for the source and every occurrence.
   Verify the five TSV sidecar file hashes and a whole snapshot, not
   merely their textual formats.
2. Port `build` fully into Idriç: bounded-memory framing, exact
   occurrence hashes, header values, dates, sorted index files,
   source-identity checks, private staging and atomic publication.
3. Make index verification independent of the builder and compare
   exact sorted TSV bytes and duplicates against the existing reference.
4. Port copy-only archive staging and validate every occurrence, archive
   baseline, exact byte count, digest and duplicate multiplicity. Require
   sufficient storage and refuse an existing destination without O_EXCL.
5. Implement NetBSD/SDF delivery-compatible locking, durable transaction
   journals, fsync of files and directories, restart recovery, and
   append-only source tail preservation; **then** implement source rewrite.
6. Establish independently run NetBSD receipts through Cat Food and ai-ci.
   Retain full mailbox backup and the original plaintext index snapshot.

Don't silently run the Python or D refiler as an "Idriç" fallback. No
unsafe, partial implementation is permitted to report move success.
