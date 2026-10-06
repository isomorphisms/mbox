# Block the legacy D CLI move (2026-10-06)

The existing `runMove` appends entries, fsyncs, and rewrites the source without
an archive byte readback or an occurrence-bound durable transaction journal.
Its local dotlock/fcntl combination does not establish the SDF delivery lock.
The recovery planner on `D-transaction-journal` does not make this CLI a
transaction executor.

`runMboxFile` now rejects `--move` immediately after option/help parsing, before
source/archive expansion or file mutation. Dry inspection remains available.
This change is a safety block, not an accepted implementation of filing.

D/ICK compilation and D runtime tests were NOT_RUN: no qualified D compiler
executable was available in this workspace. Source inspection confirms the
guard precedes the only `runMove` dispatch; this is weaker evidence than runtime
acceptance. The main-branch Python reference corpus tests different executable
bytes and must never be used to claim that this D path passed.

The unmerged `D-transaction-journal` branch needs this guard reconciled before
it is ever used as an operational executor. No deployed binary was changed by
this source patch. Re-enable only after the same transactional fault corpus and
actual host delivery-lock qualification pass for the exact D executable.
