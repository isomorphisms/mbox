# Mail standards mirror

The Idriç mail implementation is derived from the standards, not from an
implementation-shaped approximation of them.

Before adding parser behavior, read the standards mirrored here and model their
named grammar and semantic objects explicitly. The goal is deliberately close
to the documents: an RFC ABNF production should normally have a corresponding
Idriç semantic type, and a field whose RFC gives it special meaning should not
collapse back into an untyped string or octet list.

## Authority

The copies under `standards/rfc/` are exact downloads from the RFC Editor.
They are references, not edited local specifications. `SOURCES.tsv` records
the canonical source and why the document is in scope.

The current IANA message-header and media-type registries are mirrored under
`standards/iana/`. They matter because the set of registered fields and
media types changes independently of old RFC snapshots.

The EMAILCORE revisions are mirrored separately under `standards/drafts/`.
They remain Internet-Drafts until the RFC Editor publishes their successor
RFCs. They must not silently replace the published RFCs in the executable
model.

## Design rule

Keep three things distinct:

1. exact source material and exact source slices;
2. RFC syntax/semantic values represented by Idriç types;
3. policy chosen by a caller such as the SPEC-LIST refiler.

The implementation may use compact machine representations underneath those
types. Representation is not the semantic API.

See `SEMANTIC_MODEL.md` before changing `src/Mail/`.

## Refresh

Run:

    ./tools/sync-rfcs

The sync is idempotent and writes through temporary files before replacement.
