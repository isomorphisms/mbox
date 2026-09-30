# Transaction and duplicate fixtures

These fixtures define destructive mbox refile recovery semantics.

The rule under test is **occurrence identity, not content deduplication**. Two
byte-identical mbox entries are two occurrences. A byte-identical entry that
already existed in the archive before a transaction is not evidence that a
selected source occurrence was copied by this transaction.

The JSON files are semantic recovery oracles, not a required on-disk journal
encoding. A language implementation may use another representation, but it must
be able to prove the same facts before deleting source bytes.

## Common mailbox

`common/source-before.mbox` contains five entries:

1. keep-before
2. selected A
3. selected duplicate
4. another byte-identical selected duplicate
5. keep-after

`common/archive-before.mbox` already contains one byte-identical copy of the
selected duplicate from an older, unrelated event.

A successful fresh transaction therefore appends **three** occurrences, not two.
The final archive contains three byte-identical duplicate entries total: one old
one plus two from the source.

## Recovery scenarios

- `ordinary.json`: no crash. All three selected occurrences are appended.
- `prepared.json`: journal is durable but nothing has been appended.
- `mid-archive.json`: only selected occurrence 0 was appended before the crash.
  Recovery must append occurrences 1 and 2, even though identical bytes already
  exist elsewhere in the archive.
- `archive-fsynced.json`: all three transaction occurrences are durably in the
  archive. Recovery must not append them again; it finishes source removal.
- `new-source-tail.json`: same as archive-fsynced, but new mail was appended to
  the source after the snapshot. Recovery may remove recorded ranges from the
  verified original prefix and must preserve the new tail.
- `source-prefix-mutated.json`: the original source prefix changed rather than
  merely gaining an append-only tail. Recovery must refuse and leave both files
  byte-for-byte unchanged.

A content hash is useful to verify a recorded occurrence or byte range. It is
not a substitute for transaction identity.

Run `sh tests/transaction-fixtures.sh` to check the fixture equations.
