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
- framing events and feed results.

The next executable step is `feed : Framer → List Byte → FeedResult`, followed
by a chunking-equivalence proof.  That is intentionally not postulated here:
until the function and proof exist, this branch does not claim to parse mail.

The types mirror `CONTRACT.md`; they do not model MIME text as the authority for
the underlying message bytes.
