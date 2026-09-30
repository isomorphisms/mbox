# Mail contract v0

This file is normative for the language branches.

## 1. Source bytes

A parser accepts an ordered stream of octets.  It may be fed the entire file or
arbitrary chunks.  Chunking must not change the messages produced.

Offsets are zero-based byte offsets into the source snapshot.  Ranges are
half-open: `[start, end)`.

## 2. mbox framing

Version 0 recognizes mboxo framing.

A separator is a complete line beginning with the five ASCII octets
`46 72 6f 6d 20` ("From ") at the start of the file or immediately after a
line ending.

The separator line belongs to the message's envelope metadata.  The RFC message
starts with the following byte and continues up to, but not including, the next
separator or EOF.

`Content-Length` never changes framing.

A body line beginning `>From ` is ordinary body data.  Reading never removes
the leading `>`.

## 3. Message view

For each message expose:

```text
envelope_range
message_range
header_range
body_range
```

All ranges point into the original source bytes.  Copying a message must be
possible without regenerating its RFC representation.

The message range excludes the envelope line.  An implementation may also expose
a whole-entry range including the envelope.

## 4. Header parsing

The header section ends at the first empty line.  Accept LF and CRLF.

A physical line beginning with SP or HTAB continues the preceding field.  Keep:

- raw field bytes, including original folding and line endings;
- field name bytes;
- raw field-value bytes;
- an unfolded logical value where each fold is represented by one ASCII space.

Header names compare ASCII-case-insensitively.  Repeated fields remain repeated
and ordered.

A malformed line that cannot be attached to a valid field is retained as raw
header material and reported as a defect; it is not silently discarded.

## 5. Address view

Address parsing is a derived view.  It must not alter raw header bytes.

Version 0 needs enough RFC mailbox syntax for recipient filtering:

- bare `local@example.org`;
- `Display Name <local@example.org>`;
- quoted display names, including commas;
- comma-separated mailbox lists;
- repeated address-bearing header fields.

The parser returns display-name bytes/text separately from the addr-spec.
Comparison for the current refiler may ASCII-case-fold the domain; preserving
the original spelling remains mandatory.

Groups, comments, obsolete route syntax, encoded words, and internationalized
addresses are explicit later work unless a language branch implements them with
tests.

## 6. Streaming

A streaming implementation may retain a bounded look-behind sufficient to decide
whether a candidate `From ` begins a line.

For a stable source snapshot:

```text
parse(bytes) == concatenate(parse(chunks(bytes)))
```

for every partition of the input bytes.

A resumable cursor contains at least the source identity and next byte offset.
A cursor from a different source snapshot must not be accepted as proof that
resume is safe.

## 7. Writing

Version 0 append semantics:

- acquire the caller-selected mailbox lock before mutation;
- write one complete entry;
- escape RFC message body lines beginning `From ` as `>From `;
- flush according to the durability policy before reporting success;
- never rewrite an existing entry merely to normalize formatting.

Destructive move/refile is copy-then-confirm-then-delete/compact, not
delete-then-copy.

## 8. Cross-language conformance

A language branch is conformant to v0 only when the shared fixtures demonstrate:

- identical framing under adversarial chunking;
- identical header field order and lookup;
- identical selected recipient addr-specs for the v0 grammar;
- byte-identical copy output for unchanged messages;
- explicit rejection/reporting where the branch has not implemented a later
  feature.

Implementation convenience is not a reason to change this contract.
