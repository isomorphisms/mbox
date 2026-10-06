# Recovered implementation and policy (2026-10-06)

GitHub repository search and a fresh full clone resolved `isomorphisms/mbox`
with default `main`; no open mbox PRs were returned before this work.

| Branch | Recovered revision | Actual surface |
| --- | --- | --- |
| main | eff2c6e5f0985e9105729fffeadf8090b689f380 | Shared format contract, byte fixtures, manifests, recovery-state examples and cross-language receipt checks |
| Idriç | 0bd666cde6b7f78fdaa9c4c765b927fa2a01d899 | Streaming framer, header selector, six-header policy, binary read-only scanner; pure recovery decision module |
| D | 07337a5b85a23a4b2f65317a302b14d38e21fc45 | Independent parser/scanner, dry planner, legacy move implementation and wrappers |
| D-transaction-journal | 6aff20d440d043436f6238ce25977a15be44c5e0 | Additional byte-evidence recovery planner; CLI still uses the legacy writer |
| Grease | f4ca491f2476022d71a4c27ec3fb31340aa75104 | Separate source/mbox.grease language experiment; not promoted to live transaction executor |

Kitchen recovered main `b8be8b1de05827422bbf127b44720e0e2c7acc1e` has the
SDF task policy, promotion stages, read-only legacy host probe, requirements-first
handoff rules and unsafe specimens. The six fields and occurrence semantics
are explicit there and in Idriç's policy, not inferred from the mailing list name.

Cat Food recovered main `602a2862d248dcfd9629c48c442574f1959513aa` still had
the unsafe non-Termux cloud default. Its stage-zero shell boundary is explicitly
recorded in `ci/shell-boundary.tsv`. This job repairs that boundary with positive
Linux + Debian/Ubuntu detection and adds SDF host evidence without provisioning SDF.

Read current Kitchen issues 8 (byte/envelope preservation), 9 (executed receipts),
11 (copy/move/failure/restart), Cat Food issue 88 (NetBSD target assumption), and
AICI issue 185 (consequence-sensitive operational-script review). They document
an unqualified recommendation/near miss, not proven live data loss.

The new executable reference owns mechanism separately from SPEC-LIST policy.
It is an independent corpus consumer, not a port accepted by comparison to itself.
The old D CLI lacks archive readback and durable occurrence-bound journaling;
a separate source guard PR disables its move dispatch. D source inspection is
not a D runtime test, and an unmerged guard does not change a deployed binary.

No SDF connection, live mailbox read, live scan or live mutation occurred here.
No local delivery policy or current spool size/permissions was invented.
