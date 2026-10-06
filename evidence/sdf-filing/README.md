# Executed filing receipts — 2026-10-06

Source: isomorphisms/mbox `13584adf188b8a93f5328484f59a0c9230ea496f`.
Fixture revision: that same commit. Corpus SHA-256:
`e6259f11befa6e02c3d4719001ee36404b6338df87f8cb43e6d65e3b02e6b30d`.
Test SHA-256: `e955b2d4ecc0f47a55b67673e570586b5bd7379b8d3cf0d1434c4db478ae4ccb`.
Executor SHA-256: `6e044f57408f3f27febca48e6a1b1c16e690bb329a7c558b8b2a48b4f2d34069`.
Original manifest SHA-256: `b0ac25ac69e934169e94059ff7a64e8176f4d15778af8dd196181cd62f4ebd73`.

Local host: Linux 6.18.44 x86_64; Python 3.12.14; Git 2.51.1;
`sh` is dash 0.5.12-6ubuntu5. No compiler was used for Python execution.

| Exact local command | Results |
| --- | --- |
| `python3 /workspace/scratch/2d7520fd064e/mbox/tests/hardening/test_filing.py` | 23 passed, 0 failures, 0 skips in normal qualification |
| `python3 /workspace/scratch/2d7520fd064e/mbox/tests/hardening/mutations.py` | 13 killed, 0 survived; each mutant executed a named real regression |
| `sh /workspace/scratch/2d7520fd064e/mbox/tests/shared-fixtures.sh` | Both shared checksum and transaction-equation gates passed; script does not report an individual assertion count |

The first two commands ran under Kitchen's qualifier, with the exact interpreter
path and commands retained in `qualification-execution.txt`. That run used the
published source HEAD, not a synthetic merge. It exercised 49 corpus cases,
23 reached fsync failure points, ten abrupt process exits and byte/keeper recovery.
Resource run: 128 MiB single body line + 100,000 selected messages; peak Python
allocations 221,909 and 234,926 bytes respectively. Elapsed resource work 10.62 s.
These are measurements of this fixture/host, not a maximum-memory guarantee for
every allowed header block or a live-spool throughput claim.

Hosted exact-head run: https://github.com/isomorphisms/mbox/actions/runs/37465571546
completed successfully. Retrieved logs confirm explicit checkout of the source
SHA above, Python 3.9.25 and 3.12.14, 23 passes per version, 13 killed mutants per
version and no normal-suite skips. Concise extracted log receipts are adjacent.
Shared-fixture run: https://github.com/isomorphisms/mbox/actions/runs/37465571718
also completed successfully.

Idriç compilation/runtime, D compilation/runtime, actual NetBSD execution,
SDF host preflight, SDF live scan and SDF live filing: NOT_RUN. The required
compiler/runtime was unavailable locally; no SDF session was established.
Fake NetBSD platform fixtures are not actual NetBSD execution. Process-exit
tests do not prove power-loss recovery. Live mutation is disabled in this executor.

Read-only scan candidate: locally and hosted Python-qualified, awaiting actual
SDF interpreter/path/readability checks. Live archive/move: BLOCKED on delivery
locks, target transaction qualification and standard-bearer filesystem effects.
No live mailbox was read or mutated. PR: https://github.com/isomorphisms/mbox/pull/1.

Publication preserved the exact Git tree of the local tested source commit
`1613811a5d28f9a1152f122feeb37d9e4fdecdf0`; the connected GitHub commit has
different commit metadata. The published HEAD was then fetched and the full
qualification rerun. Later receipt-only commits leave these source/test bytes
unchanged; they are not falsely called the execution trigger.
