# mbox

A small, byte-preserving email library.

The first target is the Unix mbox + RFC-message slice needed to inspect and
refile a long-lived mailbox without depending on Python.  Python's standard
`mailbox` and `email` modules are a behavioral reference, not the API to copy.

## First contract

The library is split at a hard boundary:

1. **mbox framing**
   - consume bytes incrementally;
   - identify the Unix envelope line beginning with `From `;
   - expose exact message byte ranges and the exact envelope line;
   - do not decode MIME or text while finding message boundaries;
   - preserve raw bytes and offsets.

2. **RFC message headers**
   - find the header/body separator;
   - preserve every raw header field and its folding;
   - expose case-insensitive lookup;
   - expose an unfolded logical value separately from the raw bytes;
   - parse address-bearing fields such as `To` and `Cc` without changing the
     stored message.

The first useful application is the SDF mailbox refiler: stream
`/var/mail/isomorphisms`, inspect recipient headers, and copy selected messages
to another mbox while retaining their original bytes.

## Deliberate scope

The first milestone is read/inspect/copy, not a complete clone of Python's
mailbox package.  Maildir, MH, Babyl, MMDF, MIME body decoding, SMTP, IMAP, and
message rewriting are later layers.

For mbox compatibility the initial format is **mboxo**:

- a message begins at a line whose first five bytes are `From `;
- `Content-Length` does not determine framing;
- body lines beginning `>From ` are not silently rewritten on read;
- writers escape body lines beginning `From ` before appending.

Concurrent modification is a separate correctness problem.  A writer must use
an explicit lock policy; the parser itself never pretends a changing source is
a stable snapshot.

## Branches

Parallel implementations live on language branches:

- `Idriç` — **standard-bearer/reference executable** for the library;
- `D` — independent systems implementation and performance cross-check;
- `Agda` — executable/type-level model of the framing and header invariants;
- `Idris` — ordinary Idris compatibility/comparison implementation;
- further language branches may share the same corpus and semantics.

"Standard bearer" does not make Idriç the specification.  `CONTRACT.md` and
the shared corpus on `main` remain language-neutral.  Idriç is simply the
implementation that should reach new complete behavior first; the other
branches must be able to disagree with it when the corpus or contract shows that
it is wrong.

No branch is allowed to redefine the wire format merely to make its own tests
pass. Cross-language fixtures and differential receipts belong on `main`.

Every language branch receives the same `fixtures/` tree and
`tests/conformance/cases.tsv`. Language-specific runners report each case as
`PASS`, `FAIL`, `UNIMPLEMENTED`, or `BLOCKED`; there are no silent skips.
A fixture discovered by one implementation therefore becomes a test input for
all of them.

## Core semantic values

```text
ByteOffset
ByteRange = [start, end)
EnvelopeLine
RawHeaderField
HeaderName
UnfoldedHeaderValue
Address
MessageView = envelope + header range + body range + whole-message range
MboxCursor = source identity + next byte offset
```

A useful implementation may allocate strings for convenience, but the semantic
contract is in bytes and offsets.  Decoded text is a view, never the authority
for copying or resuming.

## Acceptance direction

The shared corpus should exercise at least:

- CRLF and LF input;
- folded headers;
- repeated `To`/`Cc` fields;
- quoted display names and commas;
- empty bodies;
- body text containing escaped `>From `;
- malformed-but-preservable headers;
- chunk boundaries at every byte around `From ` and header separators;
- interruption/resume at every message boundary;
- byte-for-byte copy of selected messages.

The existing mail translation acceptance work in `isomorphisms/ai-ci` should
consume this repository once the implementations are far enough along; it
should not invent substitute mailbox behavior.
