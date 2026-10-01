# D branch

This branch implements the v0 mailbox contract and the generic mailbox filer in D.

Current code:

- `source/mbox.d`: byte-preserving mboxo framing and RFC-header core;
- `source/mbox_file.d`: reusable generic dry-run/refile engine;
- `source/mbox_file_main.d`: generic `mbox-file` command front end;
- `source/file_spec_list.d`: native D SPEC-LIST policy front end;
- `source/mbox_inspect.d`: read-only TSV mailbox/header inspector;
- `bin/file-spec-list`: earlier thin shell compatibility wrapper.

Implemented:

- streaming mbox scan; the complete mailbox is never materialized;
- 64-bit source offsets for mailboxes larger than 4 GiB;
- exact envelope/message/header/body byte ranges;
- LF and CRLF headers;
- folded and repeated headers;
- ASCII-case-insensitive header lookup;
- 4 MiB fail-closed header-size guard;
- regular-expression matching restricted to explicitly named headers;
- one-for-one copying of selected mbox entries; no Message-ID/hash deduplication,
  so equal source entries remain equal archive occurrences;
- dry-run by default; `--move` is required for mutation;
- source then archive locking with advisory file locks plus dotlocks;
- adjacent rewrite preflight and source-size + 64 MiB free-space gate;
- archive-first append, flush and fsync before any source removal;
- parent-directory fsync when a new archive or replacement source entry is
  created;
- fail-closed append if an existing archive does not end on a line boundary;
- atomic source replacement after writing and fsyncing the complete unmatched
  mailbox;
- source mode preservation and fail-closed owner/group verification before
  replacement;
- tests for streaming/buffer framing equivalence, folded/repeated header
  selection, body-only false positives, the 4 MiB guard, reused Message-ID
  values, and duplicate-entry multiplicity.

SPEC-LIST policy remains outside the generic filer.  The native D front end and
the older shell wrapper search only `From`, `Sender`, `Reply-To`, `To`,
`Cc`, and `Subject` for `SPEC-LIST`, case-insensitively.  They default to
`/var/mail/isomorphisms` -> `$HOME/Mail/spec-list`.  Running without
`--move` is a scan only.

`mbox-inspect` is deliberately read-only.  It streams the mailbox, refuses
header blocks above 4 MiB, reports byte ranges and malformed-header counts, and
prints selected unfolded header views as escaped TSV.  It also refuses to call
the inspection stable if the mailbox size changes during the scan.

Not implemented in this branch:

- MIME body parsing or RFC 2047 decoding for filing policy;
- group/comment/obsolete address grammar beyond the v0 address helpers;
- stale-dotlock recovery;
- an exactly-once crash/retry transaction journal. If a process dies after the
  archive fsync but before source replacement, rerunning can append duplicates;
  the current design prefers possible duplication over silently discarding a
  source occurrence.

## Build gate

Do not quietly build this branch with ordinary DMD/GDC.  The repository policy
requires ICK or NDK.

As of 2026-09-30, the current ICK `gdc-netbsd-amd64` head
`22b41425cb478754346637db87ebd42e43b42863` fails while building target
libgcc, before this repository is compiled: the compiler ICEs in
`tree-complex.cc` while compiling the complex multiply helpers.  Therefore
the filer source and tests are reviewed but are **not yet compile-verified on
the approved SDF/NetBSD path**.  No ordinary-compiler fallback has been used.

## Transaction fixture status

The shared transaction fixtures from `main` are present on this branch.

Current D behavior is expected to satisfy the fresh-run multiplicity rule:
selected occurrences are copied one-for-one and byte-identical source entries
are not collapsed.

Current D behavior is **not conformant** to the crash/retry transaction contract
yet because it has no durable transaction journal. In particular, a restart
after archive fsync but before source replacement can append the same
transaction occurrences again. The new recovery fixtures are intentionally a
red gate for that work rather than an excuse to deduplicate by content.
