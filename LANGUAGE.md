# D branch

This branch implements the v0 mailbox contract and the generic mailbox filer in D.

Current code:

- `source/mbox.d`: byte-preserving mboxo framing and RFC-header core;
- `source/mbox_file.d`: reusable generic dry-run/refile engine;
- `source/mbox_file_main.d`: generic `mbox-file` command front end;
- `source/file_spec_list.d`: native D SPEC-LIST policy front end;
- `source/mbox_inspect.d`: read-only TSV mailbox/header inspector;
- `source/mbox_conformance.d`: shared-fixture executable conformance runner;
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
- shared-fixture cases for byte ranges, LF/CRLF framing, arbitrary chunk splits,
  folded/repeated/malformed headers, raw header bytes, address forms, exact
  SPEC-LIST selection, byte-identical copying, duplicate multiplicity, and the
  ordinary archive-first transaction.

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

## Build and execution gate

Do not quietly substitute ordinary DMD/GDC.  This branch's execution workflow
pins ICK DMD revision
`ac15b23e75755773809ada172ed378555b0adffe`.

That ICK revision already has independent green evidence for:

- building the owned DMD v2.113 compiler;
- NetBSD amd64 BetterC object generation;
- Linux normal-D druntime and Phobos;
- Icky-D Unicode/compiler qualification.

The `D implementation` workflow reconstructs the matching v2.113
druntime/Phobos with that exact ICK DMD, compiles this repository's D sources,
runs the unit tests, builds `mbox-file`, `mbox-inspect`,
`file-spec-list`, and `mbox-conformance`, and executes the shared fixtures.
A PASS is claimed only from that executed workflow, not from source presence or
this document.

The historical GDC revision
`22b41425cb478754346637db87ebd42e43b42863` still exposes a real ICK
polar-complex optimizer defect in libgcc `__multc3`/`__divtc3` at `-O2`,
but it is no longer the selected compiler path for this D mailbox work.

### NetBSD/SDF deployment boundary

The remaining deployment gap is full normal-D druntime/Phobos qualification on
NetBSD amd64.  The existing NetBSD receipt proves BetterC object generation and
native ABI execution, while the normal-D runtime receipt is currently Linux.
Track the missing combined boundary in
`dilapidated-shed/ick#61`, **Qualify normal-D runtime and Phobos on NetBSD
amd64**.

Do not infer SDF execution from the Linux full-D receipt or from the NetBSD
BetterC receipt.

## Transaction fixture status

The ordinary transaction fixture is executable: selected source occurrences are
copied one-for-one, archive bytes are made durable before source replacement,
and byte-identical duplicates retain their multiplicity.

Crash/retry states remain deliberately `UNIMPLEMENTED` until a durable
transaction journal exists:

- prepared;
- partially appended archive;
- archive fsynced before source replacement;
- append-only source tail discovered during recovery;
- mutated source prefix, which must refuse recovery.

Do not weaken those cases or replace occurrence identity with content
deduplication merely to obtain a green receipt.
