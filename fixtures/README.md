# Shared mbox fixtures

These files are byte fixtures for every language branch. They are not examples
to normalize or prettify. `fixtures/*.mbox` is marked `-text` in
`.gitattributes` so Git must not rewrite line endings.

`manifest.json` records the expected behavior and SHA-256 of every fixture.
When a test concerns copying, the relevant bytes must compare exactly rather
than after reparsing or reserialization.

## Corpus

- `empty.mbox` — zero-message mailbox.
- `spec-list-selection.mbox` — the SDF refiler rule: case-insensitive
  `SPEC-LIST` only in `From`, `Sender`, `Reply-To`, `To`, `Cc`, or `Subject`.
  It includes body-only and wrong-header false positives, folding, repeated
  fields, and case variation.
- `header-corners.mbox` — field-name case, folding with SP/HTAB, repeated
  fields, empty values, colons inside values, trailing whitespace, and a
  malformed-but-preservable header line.
- `mboxo-lf.mbox` — LF framing, lying `Content-Length`, escaped `>From` and
  `>>From`, empty body, and EOF without a final newline.
- `mboxo-crlf.mbox` — the same framing boundary exercised with CRLF.
- `unescaped-from-splits.mbox` — demonstrates the deliberately simple mboxo
  rule: any line beginning exactly `From ` at a line boundary starts another
  entry even if it looks like body text or a strange envelope.
- `address-view.mbox` — bare addresses, display names, quoted commas, folded
  lists, repeated `To`/`Cc`, and preserved domain case.
- `dedup-corners.mbox` — reused Message-ID values, equal RFC messages under
  different envelope lines, and two byte-identical whole entries. This exists
  specifically to catch accidental set-based deduplication that destroys
  mailbox multiplicity.
- `copy-preservation.mbox` — odd spacing, tabs, folding, trailing spaces,
  escaped `>From`, and blank lines that must survive unchanged.

## Required ways to exercise them

Framing tests should not feed only a whole file. For each small fixture, run
at least:

1. the complete byte string in one chunk;
2. one byte per chunk;
3. every single split point `bytes[:i]`, `bytes[i:]`;
4. splits immediately before, inside, and after `From `, LF/CRLF endings, the
   blank header/body separator, and folded-header whitespace.

For an unchanged copy operation, compare bytes. A parser that produces the
same decoded values after rewriting spacing, folding, line endings, envelope
lines, or body escaping has still failed the copy contract.

For a destructive refiler, multiplicity matters. Six source entries must
remain six archived entries after a successful move even when some entries
share Message-ID or complete byte sequences. Crash/retry behavior needs its
own transaction tests; do not pretend a set of hashes proves it safe.

`fixtures/transactions/` adds crash/retry and duplicate-occurrence states for destructive refiling. Those fixtures deliberately include preexisting and selected byte-identical entries so a set/hash-based deduplication algorithm fails.

`SHA256SUMS` is included so a checkout can detect accidental fixture
normalization before language-specific tests run.
