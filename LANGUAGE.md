# D branch

This branch implements the v0 contract in D.

Current code: `source/mbox.d`.

Implemented:

- mboxo framing over an immutable byte/string buffer;
- exact envelope/message/header/body byte ranges;
- LF and CRLF headers;
- folded and repeated headers;
- ASCII-case-insensitive header lookup;
- the v0 `To`/`Cc` address grammar, including quoted display-name commas;
- domain-case-folded addr-spec comparison;
- unit fixtures for framing, folds, address extraction, and `>From` body text.

Not yet implemented:

- incremental feed/resume;
- mailbox locking and append;
- mutation/compaction;
- MIME body parsing or RFC 2047;
- group/comment/obsolete address grammar.

There is intentionally no CI compiler invocation yet.  The repository build
policy requires an ICK- or NDK-declared path; adding DMD/GDC as a quiet fallback
would violate that policy.  The source is therefore implementation evidence, not
a claim of a successful build.
