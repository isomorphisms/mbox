# Safe filing: intended types and execution boundary

Source octets → ordered occurrence ranges → header evidence → read-only plan.
An occurrence is (snapshot, start, end, envelope, RFC bytes, digest), not a
Message-ID. Selection is a mathematical function; filesystem actions are effects.

Archive verification must precede source replacement. A plan binds source and
archive fingerprints, policy and executor bytes. Recovery binds one transaction,
not a set of message hashes. Changed snapshots are errors. The disposable
executor retains a durable original-source backup, including after completion.

The existing Idriç modules on `Idriç` are the first attempt. `safe-filing.idric`
uses their actual exported selector. Required next primitives include bounded
binary I/O, SHA-256, exclusive file creation, descriptor/path identity checks,
durable file and directory sync, atomic replacement and recoverable journals.
The current `Mail.Refile.Transaction` is a pure decision function, not an
implementation of these filesystem effects.

2026-10-06: `command -v edric` and `command -v idris2` returned exit 1 in the
disposable Linux workspace; no compiler/runtime was available. The Idriç attempt
is NOT_RUN, not accepted. An earlier attempted relative compiler invocation
failed with missing executable; that guessed location is not host evidence.
The source requires the existing `Idriç` branch's Mail modules.

Python 3.9+ is the narrow reference/test executor fallback. It does not promote
Python or D to the live standard bearer. All mutation entrypoints require a
marked disposable directory and refuse live spools. It establishes executable
filesystem requirements for the Idriç implementation and a reusable independent
corpus; its successes are never reported as Idriç successes.

First language acceptance target: compile this selector through the maintained
Idriç compiler, then implement durable exclusive-create/write/sync/replace
actions and run the same interruption corpus. Availability alone would not
qualify live mail.
