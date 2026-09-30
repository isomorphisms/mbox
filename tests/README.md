# Tests

Shared tests here validate language-neutral mailbox fixtures and transaction
semantics. Language branches should add their implementation-specific tests but
must consume these same byte fixtures rather than inventing easier ones.

`transaction-fixtures.sh` checks the crash/retry fixture equations and duplicate
multiplicity without invoking a particular language implementation.
