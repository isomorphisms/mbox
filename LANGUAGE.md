# Idris branch

This branch gives the shared mail contract a byte-level Idris 2 surface.

`src/Mbox.idr` currently contains:

- byte offsets/ranges;
- raw header/message/address types;
- source-bound resume cursors;
- incremental framer state/events;
- executable recognition of a line-leading ASCII `From ` prefix;
- ASCII-case comparison and domain-folded addr-spec comparison.

It deliberately uses `Bits8`, not `String`, for raw mail.

The next implementation boundary is the total incremental `feed` function,
then header folding and the v0 address grammar.  Until those exist, this branch
is a typed implementation skeleton rather than a complete parser.
