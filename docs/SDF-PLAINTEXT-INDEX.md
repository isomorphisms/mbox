# SDF plaintext mailbox indices

This is a read-only index of the byte content of /var/mail/isomorphisms,
not a mail mover and not a Mutt cache.

On the SDF shell (where ~/opt/mbox already exists):

    cd "$HOME/opt/mbox"
    git pull --ff-only
    python -m unittest discover -s tests -p 'test_plaintext_index.py'
    python bin/plaintext-index.py build --source /var/mail/isomorphisms --out "$HOME/opt/mbox/index"
    python bin/plaintext-index.py verify --source /var/mail/isomorphisms --out "$HOME/opt/mbox/index"

SDF has previously exposed Python as 'python' rather than 'python3'.
This tool needs Python 3.7 or later, its standard library, and a POSIX
filesystem supporting flock and fsync. If the version check or Git update
fails, stop instead of substituting an untested interpreter.

The script scans in 1 MiB blocks, hashes all bytes in the same pass, and
keeps only the bounded header prefix for each message. Progress appears on
stderr at 256 MiB increments. Verification performs a separate complete
read of the indexed source bytes, checking per-occurrence digests,
byte-range coverage without gaps or overlaps, inner mboxo delimiters,
SPEC-LIST selection evidence, derived index counts, full-source SHA-256,
and manifest/index file hashes.

## Output

    ~/opt/mbox/index/                     (mode 0700)
      CURRENT                             (atomic pointer to a snapshot)
      snapshots/<generation>/
        source.state                      (source identity, digests, counts)
        messages.tsv                      (every occurrence in source order)
        lists.tsv                         (SPEC-LIST header evidence)
        senders.tsv                       (sorted From header)
        dates.tsv                         (sorted UTC Date if parseable, else ~)
        subjects.tsv                      (sorted Subject header)

All files created by the CLI are owner-readable only (mode 0600).
/index/ is ignored by Git because sender and subject fields are private
mail metadata. Keep these files off public GitHub.

TSV columns (all offsets are zero-based; end is exclusive):

- messages.tsv: ordinal, start, end, byte_count, entry_sha256,
  matched_headers or '-'.
- lists.tsv: 'spec-list', ordinal, start, end, entry_sha256,
  matched_headers.
- senders.tsv, dates.tsv, subjects.tsv: sort_key, zero-padded ordinal,
  start, display_value. Display values have tabs, newlines, escape
  characters and invalid UTF-8 escaped; long display values are
  truncated at 1,024 bytes. Header selection still examines the complete
  unfolded value, and no message bytes are changed.
- source.state: schema, full source identity, opening byte count, scan
  interval, full-source SHA-256, SPEC-LIST counts/bytes, and SHA-256 of each TSV.

Selection matches the ASCII-insensitive substring SPEC-LIST in From, Sender,
Reply-To, To, Cc or Subject, exactly as the existing spec-list-inventory.py
scanner does. An occurrence is indexed once even when several headers match.
Byte-identical messages at distinct offsets remain distinct occurrences.

To inspect the current lists file:

    snapshot="$HOME/opt/mbox/index/snapshots/$(cat "$HOME/opt/mbox/index/CURRENT")"
    head -5 "$snapshot/lists.tsv"
    cat "$snapshot/source.state"

## Stability and safety

The index is a snapshot, not a continually updated mailbox database.
If the mailbox grows or is rewritten during the build, the builder refuses
to publish. If source identity changes between build and verification,
the verifier refuses as SOURCE_CHANGED. New mail arriving later also makes
the snapshot stale. Rebuild and verify the current snapshot.

The builder never opens the mailbox for writing, takes no delivery lock,
performs no copying/moving/deleting, and never modifies Mutt's state.
It publishes each complete new snapshot through an atomic CURRENT pointer.
Older snapshots are retained for comparison and recovery; do not use old
offsets after the mailbox changes.

SDF baseline observed October 23, 2026:
4,433,379,238 bytes, 70,478 messages, 28,243 SPEC-LIST occurrences,
1,785,441,062 SPEC-LIST bytes. These are observations, not constants;
delivery may change them.

Only after a current index and independent inventory agree should a separate,
lock-qualified archival operation use lists.tsv to copy and verify SPEC-LIST
occurrences. No destructive filing is authorized here.
