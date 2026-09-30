# Grease branch

This branch implements the v0 mailbox contract in Grease, on the current
Oils/YSH-derived line.

Current code: `source/mbox.grease`.

Implemented:

- whole-buffer mboxo framing over YSH byte strings;
- exact envelope, message, header, body, field, name, and raw-value byte ranges;
- NUL and non-UTF-8-safe raw storage: YSH `Str` length, indexing, and slicing are
  byte operations on the current Grease line;
- LF and CRLF headers;
- folded and repeated fields;
- malformed-header retention;
- ASCII-case-insensitive generic header lookup;
- the v0 `To`/`Cc` address grammar, including quoted display-name commas;
- domain-case-folded addr-spec comparison;
- byte-for-byte views of complete entries and RFC messages.

`test/basic.grease` consumes the shared corpus and also exercises CRLF input,
folding, malformed header material, and a NUL byte in the body.

Not yet implemented:

- incremental feed and resumable cursors;
- mailbox locking and append;
- mutation/compaction;
- MIME body parsing or RFC 2047;
- group/comment/obsolete address grammar.

The executable source stays inside syntax implemented by the current Grease
line. Grease's existing readable boolean aliases remain available where command
boolean syntax is needed; this parser does not pretend that experimental
spellings such as `←` or `≟` are already current Grease semantics.
