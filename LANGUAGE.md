# D branch

This branch implements the v0 mailbox contract and the generic mailbox filer in D.

Current code:

- `source/mbox.d`: byte-preserving mboxo framing and RFC-header core;
- `source/mbox_file.d`: generic dry-run/refile command;
- `bin/file-spec-list`: thin SPEC-LIST policy wrapper.

Implemented:

- streaming mbox scan; the complete mailbox is never materialized;
- 64-bit source offsets for mailboxes larger than 4 GiB;
- exact envelope/message/header/body byte ranges;
- LF and CRLF headers;
- folded and repeated headers;
- ASCII-case-insensitive header lookup;
- 4 MiB fail-closed header-size guard;
- regular-expression matching restricted to explicitly named headers;
- multiplicity-aware retry accounting using SHA-256 of exact whole mbox entry
  bytes; equal entries remain distinct occurrences;
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

SPEC-LIST policy remains outside the generic filer.  The wrapper searches only
`From`, `Sender`, `Reply-To`, `To`, `Cc`, and `Subject` for
`SPEC-LIST`, case-insensitively.  It defaults to
`/var/mail/isomorphisms` -> `$HOME/Mail/spec-list`.  Running it without
`--move` is a scan only.

Not implemented in this branch:

- MIME body parsing or RFC 2047 decoding for filing policy;
- group/comment/obsolete address grammar beyond the v0 address helpers;
- stale-dotlock recovery.

## Build gate

Do not quietly build this branch with ordinary DMD/GDC.  The repository policy
requires ICK or NDK.

As of 2026-09-30, the current ICK `gdc-netbsd-amd64` head
`22b41425cb478754346637db87ebd42e43b42863` fails while building target
libgcc, before this repository is compiled: the compiler ICEs in
`tree-complex.cc` while compiling the complex multiply helpers.  Therefore
the filer source and tests are reviewed but are **not yet compile-verified on
the approved SDF/NetBSD path**.  No ordinary-compiler fallback has been used.
