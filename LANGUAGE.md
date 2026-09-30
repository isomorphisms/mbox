# Idriç standard-bearer branch

This is the reference executable line for `isomorphisms/mbox`.

It is **not** the format specification.  `CONTRACT.md` and the shared corpus on
`main` remain authoritative when an implementation and the contract disagree.

## Why Idriç leads

Mail is a useful test of the language because it needs both sides of Idriç:

- byte-level, streaming systems work where accidental text conversion is wrong;
- semantic types for source identity, ranges, cursors, headers, addresses, and
  mutation order;
- resumability and invariants that are meaningful enough for Agda to cross-check;
- a small real command that can replace the current Python mailbox refiler.

The intended implementation order is:

1. mboxo streaming/framing;
2. exact message/envelope/header/body byte ranges;
3. folded and repeated RFC header fields;
4. the recipient-address grammar required by the refiler;
5. a read/inspect/copy refiler command;
6. append locking and durable copy-before-delete movement;
7. broader MIME/RFC support only when a real caller needs it.

## Current state

`src/Mail/Mbox.idric` now contains the first incremental framing state machine.

Its state crosses arbitrary input chunks, recognizes only line-leading ASCII
`From `, emits the previous-message end at the next envelope boundary, and
keeps raw mail in a semantic byte type rather than decoding it as text.

This is source-level implementation work only.  It has not yet earned a
compilation or runtime receipt against the current Idriç compiler, and header,
address, refiler, locking, and write paths are still incomplete.

## Standard-bearer acceptance

A feature becomes part of the reference behavior only after:

- it is exercised by shared fixtures on `main`;
- the exact Idriç compiler revision is recorded;
- the Idriç source compiles through the maintained compiler path;
- the produced executable is run on the corpus;
- the same corpus contains at least one deliberately hostile case that would
  fail a plausible broken implementation;
- D and/or another independent implementation are compared where that can catch
  shared misunderstandings.

Python's standard library remains useful as an external behavioral oracle for
ordinary cases, but Python is not a dependency and is not allowed to override
the repository's explicit byte-preservation contract.
