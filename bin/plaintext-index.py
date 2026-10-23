#!/usr/bin/env python3
"""Private, read-only, snapshot-bound plaintext sidecar indices for mboxo.

Python 3 standard library only. Never mutates the source mailbox. BUILD and
VERIFY both read the entire indexed source extent. Uses bounded-memory scanning,
external merge sort, per-occurrence SHA-256, and atomic CURRENT publication.
"""
import argparse
from contextlib import ExitStack
from datetime import timezone
from email.utils import parsedate_to_datetime
import fcntl
import hashlib
import heapq
import os
from pathlib import Path
import re
import shutil
import stat
import sys
import tempfile
import time

CHUNK = 1024 * 1024
HEADER_LIMIT = 4 * 1024 * 1024
ENVELOPE_LIMIT = 4096
FIELD_DISPLAY_LIMIT = 1024
MATCH_FIELDS = (b"from", b"sender", b"reply-to", b"to", b"cc", b"subject")
FILES = ("messages.tsv", "lists.tsv", "senders.tsv", "dates.tsv", "subjects.tsv")
SCHEMA = "mboxo-plaintext-index-v1"


class Refusal(Exception):
    pass


def identity(s):
    return (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns)


def open_source(path):
    fd = os.open(str(path), os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    source = os.fdopen(fd, "rb")
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        source.close()
        raise Refusal("source is not a regular file")
    return source


def fields(header):
    """Same ASCII folding/field selection contract as spec-list-inventory.py."""
    current = None
    for line in header.split(b"\n"):
        line = line[:-1] if line.endswith(b"\r") else line
        if not line:
            break
        if line[:1] in (b" ", b"\t"):
            if current is not None:
                current[1].append(b" " + line.lstrip(b" \t"))
            continue
        if current is not None:
            yield current[0], b"".join(current[1])
        current = None
        name, colon, value = line.partition(b":")
        if colon and name and all(33 <= c <= 126 and c != 58 for c in name):
            current = [name, [value.lstrip(b" \t")]]
    if current is not None:
        yield current[0], b"".join(current[1])


def describe_header(header):
    attrs = {}
    matched = set()
    for name, value in fields(header):
        key = name.lower()
        if key in MATCH_FIELDS and b"spec-list" in value.lower():
            matched.add(key.decode("ascii"))
        if key in (b"from", b"date", b"subject") and key not in attrs:
            attrs[key] = value
    return ",".join(sorted(matched)), attrs


def plain(raw):
    """Human-readable TSV text, escaping untrusted controls; never raw tabs/LFs."""
    text = raw[:FIELD_DISPLAY_LIMIT].decode("utf-8", "backslashreplace")
    out = []
    for ch in text:
        o = ord(ch)
        if ch == "\\":
            out.append("\\\\")
        elif ch == "\t":
            out.append("\\t")
        elif ch == "\r":
            out.append("\\r")
        elif ch == "\n":
            out.append("\\n")
        elif o < 32 or o == 127:
            out.append("\\x%02x" % o)
        else:
            out.append(ch)
    return "".join(out) + ("…" if len(raw) > FIELD_DISPLAY_LIMIT else "")


def date_key(raw):
    try:
        parsed = parsedate_to_datetime(raw.decode("utf-8", "replace"))
        if parsed.tzinfo is None:
            return "~"
        return parsed.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    except (ValueError, TypeError, OverflowError, IndexError):
        return "~"


class Entry:
    def __init__(self, start):
        self.start = start
        self.length = 0
        self.digest = hashlib.sha256()
        self.prefix = bytearray()
        self.header_finished = False

    def consume(self, data, source_digest):
        if not data:
            return
        self.length += len(data)
        self.digest.update(data)
        source_digest.update(data)
        if self.header_finished:
            return
        self.prefix.extend(data)
        # The first blank physical header line: LF LF or LF CR LF.
        lf = self.prefix.find(b"\n\n")
        crlf = self.prefix.find(b"\n\r\n")
        candidates = [i for i in (lf, crlf) if i >= 0]
        if candidates:
            i = min(candidates)
            self.prefix = self.prefix[:i + (3 if i == crlf else 2)]
            self.header_finished = True
        else:
            env_end = self.prefix.find(b"\n")
            if env_end < 0:
                if len(self.prefix) > ENVELOPE_LIMIT:
                    raise Refusal("envelope exceeds 4096 octets at byte %d" % self.start)
            elif env_end + 1 > ENVELOPE_LIMIT:
                raise Refusal("oversized envelope at byte %d" % self.start)
            elif len(self.prefix) - env_end - 1 > HEADER_LIMIT:
                raise Refusal("oversized header at byte %d" % self.start)

    def finish(self):
        prefix = bytes(self.prefix)
        if not prefix.startswith(b"From "):
            raise Refusal("missing mboxo envelope at byte %d" % self.start)
        env_end = prefix.find(b"\n")
        if env_end < 0:
            if len(prefix) > ENVELOPE_LIMIT:
                raise Refusal("oversized envelope at byte %d" % self.start)
            header = b""
        else:
            if env_end + 1 > ENVELOPE_LIMIT:
                raise Refusal("oversized envelope at byte %d" % self.start)
            header = prefix[env_end + 1:]
            if len(header) > HEADER_LIMIT:
                raise Refusal("oversized header at byte %d" % self.start)
        matched, attrs = describe_header(header)
        return (matched, attrs, self.digest.hexdigest())


def scan(source, opening_size, on_entry, progress_mib=256):
    """One streaming pass: find separators, hash entries, retain headers only."""
    offset = read_size = 0
    whole = hashlib.sha256()
    entry = Entry(0) if opening_size else None
    tail = b""
    count = 0
    next_progress = progress_mib * 1024 * 1024 if progress_mib else None

    def consume(data):
        nonlocal offset
        if data:
            entry.consume(data, whole)
            offset += len(data)

    def finish():
        nonlocal count
        matched, attrs, digest = entry.finish()
        count += 1
        on_entry(count, entry.start, offset, digest, matched, attrs)

    while read_size < opening_size:
        piece = source.read(min(CHUNK, opening_size - read_size))
        if not piece:
            raise Refusal("source shortened during scan")
        read_size += len(piece)
        data = tail + piece
        position = 0
        while True:
            mark = data.find(b"\nFrom ", position)
            if mark == -1:
                break
            cut = mark + 1  # preceding LF belongs to previous occurrence
            consume(data[position:cut])
            finish()
            entry = Entry(offset)
            position = cut
        last_safe = max(position, len(data) - 5)
        consume(data[position:last_safe])
        tail = data[last_safe:]
        if next_progress is not None and read_size >= next_progress:
            print("progress\t%d/%d bytes" % (read_size, opening_size), file=sys.stderr, flush=True)
            next_progress = (read_size // (progress_mib * 1024 * 1024) + 1) * (progress_mib * 1024 * 1024)
    if entry is not None:
        consume(tail)
        finish()
    if offset != opening_size:
        raise Refusal("coverage mismatch: indexed %d, opened %d" % (offset, opening_size))
    return count, whole.hexdigest()


def sync_file(f):
    f.flush()
    os.fsync(f.fileno())


def sync_dir(path):
    fd = os.open(str(path), os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def make_private_directory(path):
    path = Path(path)
    if path.is_symlink():
        raise Refusal("index directory cannot be a symlink")
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    if not path.is_dir():
        raise Refusal("index path is not a directory")
    os.chmod(str(path), 0o700)


def sort_tsv(src, dst, stage):
    """Bounded-memory lexical sort; no dependency on GNU or BSD sort flags."""
    runs = []
    with open(str(src), "rb") as stream:
        while True:
            batch = []
            size = 0
            while size < 4 * 1024 * 1024:
                line = stream.readline()
                if not line:
                    break
                batch.append(line)
                size += len(line)
            if not batch:
                break
            batch.sort()
            path = stage / (".run-%s-%d" % (dst.stem, len(runs)))
            with open(str(path), "wb") as out:
                out.writelines(batch)
            runs.append(path)
    with ExitStack() as stack:
        inputs = [stack.enter_context(open(str(path), "rb")) for path in runs]
        with open(str(dst), "wb") as out:
            for line in heapq.merge(*inputs):
                out.write(line)
            sync_file(out)
    for path in runs:
        path.unlink()
    src.unlink()


def sha_file(path):
    sha = hashlib.sha256()
    with open(str(path), "rb") as f:
        while True:
            block = f.read(CHUNK)
            if not block:
                break
            sha.update(block)
    return sha.hexdigest()


def parse_state(path):
    state = {}
    with open(str(path), "r", encoding="utf-8") as f:
        for line in f:
            name, tab, value = line.rstrip("\n").partition("\t")
            if not tab or not name or name in state:
                raise Refusal("invalid state manifest")
            state[name] = value
    if state.get("schema") != SCHEMA:
        raise Refusal("unsupported index schema")
    return state


def write_state(path, state):
    with open(str(path), "w", encoding="utf-8", newline="\n") as f:
        for key, val in state.items():
            f.write("%s\t%s\n" % (key, val))
        sync_file(f)


def build(source_path, root, progress):
    os.umask(0o077)
    make_private_directory(root)
    snapshots = root / "snapshots"
    make_private_directory(snapshots)
    with open(str(root / ".index.lock"), "a+") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        stage = Path(tempfile.mkdtemp(prefix=".pending-", dir=str(snapshots)))
        try:
            with open_source(source_path) as source:
                before = os.fstat(source.fileno())
                started_ns = time.time_ns()
                total = selected = selected_bytes = 0
                with ExitStack() as stack:
                    files = {n: stack.enter_context(open(str(stage / n), "w", encoding="utf-8", newline="\n"))
                             for n in ("messages.tsv", "lists.tsv")}
                    unsorted = {n: stack.enter_context(open(str(stage / (n + ".unsorted")), "w", encoding="utf-8", newline="\n"))
                                for n in ("senders", "dates", "subjects")}
                    def on_entry(ordinal, start, end, digest, matched, attrs):
                        nonlocal total, selected, selected_bytes
                        total += 1
                        length = end - start
                        if matched:
                            selected += 1
                            selected_bytes += length
                        files["messages.tsv"].write("%d\t%d\t%d\t%d\t%s\t%s\n" %
                                                   (ordinal, start, end, length, digest, matched or "-"))
                        if matched:
                            files["lists.tsv"].write("spec-list\t%d\t%d\t%d\t%s\t%s\n" %
                                                     (ordinal, start, end, digest, matched))
                        # Numeric fixed-width ordinals make lexical sorting stable.
                        order = "%012d" % ordinal
                        for n, key in (("senders", b"from"), ("subjects", b"subject")):
                            raw = attrs.get(key, b"")
                            display = plain(raw)
                            unsorted[n].write("%s\t%s\t%d\t%s\n" %
                                              (display.casefold() or "~", order, start, display))
                        raw = attrs.get(b"date", b"")
                        unsorted["dates"].write("%s\t%s\t%d\t%s\n" %
                                                (date_key(raw), order, start, plain(raw)))
                    scanned, full_digest = scan(source, before.st_size, on_entry, progress)
                    for f in list(files.values()) + list(unsorted.values()):
                        sync_file(f)
                after = os.fstat(source.fileno())
                try:
                    at_path = os.stat(str(source_path), follow_symlinks=False)
                except OSError:
                    raise Refusal("source vanished during scan")
                if identity(before) != identity(after) or identity(before) != identity(at_path):
                    raise Refusal("CHANGED_DURING_SCAN: no index published; rerun on stable mailbox")
                if scanned != total:
                    raise Refusal("entry accounting mismatch")
                finished_ns = time.time_ns()
            for name in ("senders", "dates", "subjects"):
                sort_tsv(stage / (name + ".unsorted"), stage / (name + ".tsv"), stage)
            state = dict(schema=SCHEMA, source_path=str(source_path),
                         device=before.st_dev, inode=before.st_ino, bytes=before.st_size,
                         mtime_ns=before.st_mtime_ns, ctime_ns=before.st_ctime_ns,
                         scan_started_ns=started_ns, scan_finished_ns=finished_ns,
                         sha256=full_digest, messages=total,
                         spec_list_messages=selected, spec_list_bytes=selected_bytes)
            for name in FILES:
                state["sha256." + name] = sha_file(stage / name)
            write_state(stage / "source.state", state)
            # Mail may arrive while sorting. Never publish a known-stale build.
            try:
                publish_source = os.stat(str(source_path), follow_symlinks=False)
            except OSError:
                raise Refusal("source vanished before index publication")
            if identity(publish_source) != identity(before):
                raise Refusal("CHANGED_BEFORE_PUBLICATION: no index published")
            sync_dir(stage)
            name = "%d-%d-%s" % (finished_ns, os.getpid(), full_digest[:12])
            target = snapshots / name
            os.rename(str(stage), str(target))
            sync_dir(snapshots)
            temp_current = root / (".CURRENT-%d" % os.getpid())
            with open(str(temp_current), "w", encoding="ascii") as pointer:
                pointer.write(name + "\n")
                sync_file(pointer)
            os.replace(str(temp_current), str(root / "CURRENT"))
            sync_dir(root)
            print("BUILT\t%s\nmessages\t%d\nspec_list_messages\t%d\nspec_list_bytes\t%d\nsha256\t%s" %
                  (target, total, selected, selected_bytes, full_digest))
        finally:
            if stage.exists():
                shutil.rmtree(str(stage))


def current_snapshot(root):
    name = (root / "CURRENT").read_text(encoding="ascii").strip()
    if not re.fullmatch(r"[A-Za-z0-9-]+", name):
        raise Refusal("invalid CURRENT pointer")
    snapshot = root / "snapshots" / name
    if snapshot.is_symlink() or not snapshot.is_dir():
        raise Refusal("CURRENT snapshot missing or a symlink")
    return snapshot


def verify(source_path, root, progress):
    snapshot = current_snapshot(root)
    state = parse_state(snapshot / "source.state")
    if os.path.abspath(state["source_path"]) != os.path.abspath(str(source_path)):
        raise Refusal("source path differs from indexed source")
    for name in FILES:
        if sha_file(snapshot / name) != state["sha256." + name]:
            raise Refusal("INDEX_CORRUPTED: " + name)
    with open_source(source_path) as source:
        before = os.fstat(source.fileno())
        if tuple(map(int, (state["device"], state["inode"], state["bytes"],
                           state["mtime_ns"], state["ctime_ns"]))) != identity(before):
            raise Refusal("SOURCE_CHANGED: index snapshot is stale; rebuild")
        whole = hashlib.sha256()
        total = selected = selected_bytes = next_start = 0
        with open(str(snapshot / "messages.tsv"), "r", encoding="utf-8") as entries, \
             open(str(snapshot / "lists.tsv"), "r", encoding="utf-8") as selected_index:
            expected_selected = next(selected_index, None)
            for row in entries:
                values = row.rstrip("\n").split("\t")
                if len(values) != 6:
                    raise Refusal("malformed messages.tsv")
                ordinal, start, end, length = map(int, values[:4])
                expected_digest, matched = values[4:]
                if ordinal != total + 1 or start != next_start or end <= start or length != end - start:
                    raise Refusal("INDEX_GAP_OR_OVERLAP near occurrence %d" % ordinal)
                if end > before.st_size:
                    raise Refusal("indexed range beyond source extent")
                source.seek(start)
                sha = hashlib.sha256()
                remaining = length
                prefix = bytearray()
                header_done = False
                carry = b""
                while remaining:
                    block = source.read(min(CHUNK, remaining))
                    if not block:
                        raise Refusal("source shortened during verification")
                    remaining -= len(block)
                    sha.update(block)
                    whole.update(block)
                    # Independent framing check: no inner mboxo boundary.
                    if b"\nFrom " in carry + block:
                        raise Refusal("unindexed internal envelope in occurrence %d" % ordinal)
                    carry = (carry + block)[-5:]
                    if not header_done:
                        prefix.extend(block)
                        matches = [i for i in (prefix.find(b"\n\n"), prefix.find(b"\n\r\n")) if i >= 0]
                        if matches:
                            point = min(matches)
                            width = 2 if prefix[point:point + 2] == b"\n\n" else 3
                            prefix = prefix[:point + width]
                            header_done = True
                        elif len(prefix) > HEADER_LIMIT + ENVELOPE_LIMIT + CHUNK:
                            raise Refusal("oversized header in source")
                if sha.hexdigest() != expected_digest:
                    raise Refusal("SOURCE_DIGEST_MISMATCH at occurrence %d" % ordinal)
                header_start = prefix.find(b"\n")
                if not prefix.startswith(b"From "):
                    raise Refusal("invalid source envelope")
                actual_match, _ = describe_header(bytes(prefix[header_start + 1:]) if header_start >= 0 else b"")
                if (actual_match or "-") != matched:
                    raise Refusal("selector mismatch at occurrence %d" % ordinal)
                if actual_match:
                    wanted = ("spec-list\t%d\t%d\t%d\t%s\t%s\n" %
                              (ordinal, start, end, expected_digest, actual_match))
                    if expected_selected != wanted:
                        raise Refusal("lists.tsv occurrence mismatch at %d" % ordinal)
                    expected_selected = next(selected_index, None)
                    selected += 1
                    selected_bytes += length
                total += 1
                next_start = end
                if progress and next_start // (progress * 1024 * 1024) > start // (progress * 1024 * 1024):
                    print("verify_progress\t%d/%d bytes" % (next_start, before.st_size), file=sys.stderr, flush=True)
            if expected_selected is not None:
                raise Refusal("lists.tsv contains extra occurrences")
        after = os.fstat(source.fileno())
        try:
            path_state = os.stat(str(source_path), follow_symlinks=False)
        except OSError:
            raise Refusal("source removed during verify")
        if identity(before) != identity(after) or identity(before) != identity(path_state):
            raise Refusal("SOURCE_CHANGED_DURING_VERIFY")
        if next_start != before.st_size or whole.hexdigest() != state["sha256"]:
            raise Refusal("source extent or full digest mismatch")
        if (total, selected, selected_bytes) != tuple(map(int, (state["messages"],
                                                           state["spec_list_messages"],
                                                           state["spec_list_bytes"]))):
            raise Refusal("manifest totals differ")
    for n in ("senders", "dates", "subjects"):
        count = 0
        prev = ""
        with open(str(snapshot / (n + ".tsv")), "r", encoding="utf-8") as f:
            for row in f:
                parts = row.rstrip("\n").split("\t")
                if len(parts) != 4 or row < prev or not 1 <= int(parts[1]) <= total:
                    raise Refusal("invalid or unsorted " + n + ".tsv")
                prev = row
                count += 1
        if count != total:
            raise Refusal(n + ".tsv row count differs")
    print("VERIFIED\t%s\nmessages\t%d\nspec_list_messages\t%d\nspec_list_bytes\t%d\nsha256\t%s" %
          (snapshot, total, selected, selected_bytes, state["sha256"]))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("build", "verify"))
    parser.add_argument("--source", default="/var/mail/isomorphisms")
    parser.add_argument("--out", default=str(Path.home() / "opt/mbox/index"))
    parser.add_argument("--progress-mib", type=int, default=256)
    args = parser.parse_args()
    if args.progress_mib < 0:
        parser.error("--progress-mib must be >= 0")
    os.umask(0o077)
    try:
        if args.action == "build":
            build(args.source, Path(args.out), args.progress_mib)
        else:
            verify(args.source, Path(args.out), args.progress_mib)
    except (OSError, Refusal, ValueError, KeyError) as error:
        print("REFUSED\t%s" % error, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
