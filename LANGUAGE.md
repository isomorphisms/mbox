# Agda branch

This branch is the proof/model side of the shared mail contract.

`src/Mbox.agda` defines:

- octets as `Fin 256`;
- half-open byte ranges and their ordering witness;
- raw header fields plus malformed/orphan-fold defects;
- message views with envelope/header/body/message ranges;
- address views;
- source-bound resume cursors;
- the bounded state of an incremental mboxo framer;
- framing events and feed results;
- executable `step`, `feed`, and explicit-EOF `finish`.

The framer recognizes only a line-leading byte sequence `From `.  A partial
candidate is retained across calls to `feed`, so a chunk may end after any of
the five separator bytes without changing the eventual framing.  Header and
MIME interpretation remain outside framing.

The next proof obligation is chunking equivalence: feeding `x` and then `y`
must have the same final state and ordered event stream as feeding `x ++ y`.
That proof must be constructive; this branch should not postulate it.

After framing is typechecked and the chunking theorem is in place, the next
executable layer is raw RFC-header parsing with exact ranges/folding, followed
by the deliberately small recipient-address grammar in `CONTRACT.md`.

The types mirror `CONTRACT.md`; decoded text is never the authority for the
underlying message bytes.
