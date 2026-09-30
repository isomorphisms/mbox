# Cross-language conformance

Every language branch consumes the same fixtures and the same case list in
`cases.tsv`.

The point is not to make one implementation imitate another. It is to make
disagreement explicit. When D, Grease, Agda, Idriç, Idris, or a later
implementation disagrees, keep the disagreement visible until the shared
contract/fixtures resolve it.

A language runner emits one tab-separated row for every case:

```text
case_id<TAB>status<TAB>evidence
```

Allowed statuses are:

- `PASS` — the implementation executed this case and matched the shared
  expectation;
- `FAIL` — it executed the case and disagreed;
- `UNIMPLEMENTED` — the semantic feature does not exist yet;
- `BLOCKED` — the implementation exists, but the maintained compiler/runtime
  path could not execute it.

There are no silent skips. `check-receipt.sh` rejects unknown, duplicate, or
missing cases.

Language-specific runners may use their native test frameworks, but they must
read the byte fixtures from `fixtures/` rather than copying friendly versions
into the language branch. A useful new edge case discovered in one language
belongs on `main` so every other language inherits it.

The transaction cases are intentionally allowed to be red while journal/recovery
work is incomplete. Do not weaken them to make an implementation green.
