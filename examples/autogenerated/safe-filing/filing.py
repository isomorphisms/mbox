"""Bounded read-only plans and disposable-only recoverable transactions.

No mutation of live mail is supported. Caller guarantees exclusive ownership of
the marked disposable workspace; no claim is made about local-delivery locks.
"""
import argparse
import base64
import hashlib
import os
from pathlib import Path
import stat
import sys

from framing import CHUNK, Refusal, copy_range, fields, records
from spec_list import POLICY, evidence


def encoded(value):
    return base64.b64encode(os.fsencode(value) if isinstance(value, (str, Path)) else value).decode("ascii")


def decoded(value):
    return base64.b64decode(value, validate=True)


def absolute(path):
    path = Path(path)
    if not path.is_absolute() or ".." in path.parts:
        raise Refusal("use an explicit absolute path without parent traversal")
    # Reject all symlink components, not just the leaf.
    for parent in (path,) + tuple(path.parents):
        if parent.is_symlink():
            raise Refusal("symlink path refused")
    return path


def digest_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        while True:
            data = stream.read(CHUNK)
            if not data:
                break
            digest.update(data)
    return digest.hexdigest()


def metadata(path):
    item = os.stat(path, follow_symlinks=False)
    if not stat.S_ISREG(item.st_mode) or item.st_nlink != 1:
        raise Refusal("requires a regular file with one hard link")
    return ":".join(str(n) for n in (item.st_dev, item.st_ino, item.st_size,
                     item.st_mtime_ns, item.st_ctime_ns, item.st_mode,
                     item.st_uid, item.st_gid))


def fingerprint(path):
    if not path.exists():
        return "absent"
    before = metadata(path)
    digest = digest_file(path)
    if metadata(path) != before:
        raise Refusal("file changed while fingerprinting")
    return before + ":" + digest


def executor_digest():
    digest = hashlib.sha256()
    for name in ("framing.py", "spec_list.py", "filing.py"):
        digest.update(name.encode("ascii"))
        digest.update(Path(__file__).with_name(name).read_bytes())
    return digest.hexdigest()


def check_paths(source, destination):
    source, destination = absolute(source), absolute(destination)
    if not source.is_file():
        raise Refusal("source does not exist or is not a regular file")
    if not destination.parent.is_dir():
        raise Refusal("destination directory unavailable")
    if source == destination or (destination.exists() and os.path.samefile(source, destination)):
        raise Refusal("source and destination alias")
    if destination.exists() and not destination.is_file():
        raise Refusal("destination is not a regular file")
    return source, destination


def write_plan(source, destination, mode, output, live_spool=None):
    if mode not in ("inspect", "copy", "move"):
        raise Refusal("unknown operation mode")
    source, destination = check_paths(source, destination)
    if live_spool is not None and source != absolute(live_spool):
        raise Refusal("live-spool mode requires the exact configured incoming spool")
    original = fingerprint(source)
    archive = fingerprint(destination)
    def row(*values):
        output.write("\t".join(map(str, values)) + "\n")
    row("format", "mbox-plan-v1")
    row("source", encoded(source), original, ascii(str(source)))
    row("destination", encoded(destination), archive, ascii(str(destination)))
    row("mode", mode)
    row("policy", POLICY)
    row("executor", executor_digest())
    row("mailbox-mutation", "none")
    row("locking", "unqualified-live;exclusive-disposable-only")
    row("record-columns", "ordinal,start,end,sha256,selected,envelope-base64,message-id-base64,evidence-base64,envelope-display,message-id-display,evidence-display")
    row("summary-columns", "source-count,selected-count,selected-octets,expected-source-count,expected-source-octets")
    count = selected = selected_size = 0
    with open(source, "rb") as stream:
        for item in records(stream):
            header_fields = tuple(fields(item.header))
            matches = evidence(header_fields)
            identities = [value for name, value in header_fields if name.lower() == b"message-id"]
            row("record", count, item.start, item.end, item.digest,
                int(bool(matches)), encoded(item.envelope),
                encoded(b"\x00".join(identities)),
                encoded(b"\x00".join(name + b":" + value for name, value in matches)),
                ascii(item.envelope), ascii(identities), ascii(matches))
            count += 1
            if matches:
                selected += 1
                selected_size += item.end - item.start
    if fingerprint(source) != original or fingerprint(destination) != archive:
        raise Refusal("mailbox changed during planning; discard incomplete plan")
    size = source.stat().st_size
    row("summary", count, selected, selected_size,
        count - selected if mode == "move" else count,
        size - selected_size if mode == "move" else size)


def plan_rows(path):
    with open(path, "r", encoding="ascii", newline="") as stream:
        while True:
            line = stream.readline(24 * 1024 * 1024 + 1)
            if not line:
                break
            if len(line) > 24 * 1024 * 1024:
                raise Refusal("plan row too large")
            yield line.rstrip("\n").split("\t")


def plan_metadata(path):
    result = {}
    seen_records = False
    summary = False
    for row in plan_rows(path):
        if summary:
            raise Refusal("data after plan summary")
        if row[0] == "record":
            seen_records = True
            continue
        if row[0] == "summary":
            if len(row) != 6:
                raise Refusal("invalid summary")
            summary = True
        elif seen_records:
            raise Refusal("metadata after records")
        if row[0] in result:
            raise Refusal("duplicate plan metadata")
        result[row[0]] = row[1:]
    required = {"format", "source", "destination", "mode", "policy", "executor",
                "mailbox-mutation", "locking", "record-columns", "summary-columns", "summary"}
    if set(result) != required or not summary or result["format"] != ["mbox-plan-v1"]:
        raise Refusal("invalid or incomplete plan")
    if result["executor"] != [executor_digest()] or result["policy"] != [POLICY]:
        raise Refusal("executor or selector changed after planning")
    return result


def sync_directory(path):
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def save_state(directory, state, hook):
    temporary = directory / "state.next"
    # Only this transaction owns these names. A previous incomplete state write
    # is discarded; all committed data and the previous state remain intact.
    temporary.unlink(missing_ok=True)
    with open(temporary, "x", encoding="ascii") as stream:
        for key in sorted(state):
            stream.write(key + "\t" + state[key] + "\n")
        stream.flush()
        hook("state-fsync")
        os.fsync(stream.fileno())
        hook("state-close")
    os.replace(temporary, directory / "state.tsv")
    sync_directory(directory)


def load_state(directory):
    state = {}
    with open(directory / "state.tsv", encoding="ascii") as stream:
        for line in stream:
            key, value = line.rstrip("\n").split("\t")
            if key in state:
                raise Refusal("duplicate transaction state")
            state[key] = value
    return state


def disposable_paths(root, paths):
    root = absolute(root)
    marker = absolute(root / "DISPOSABLE-MAILBOX-TEST-ONLY")
    if not marker.is_file():
        raise Refusal("marked disposable workspace required; live mail mutation disabled")
    for path in paths:
        path = absolute(path)
        if path == root or root not in path.parents or path.parts[:3] == ("/", "var", "mail"):
            raise Refusal("mutation outside disposable workspace refused")


def verify_plan(path, meta, directory):
    source = Path(os.fsdecode(decoded(meta["source"][0])))
    destination = Path(os.fsdecode(decoded(meta["destination"][0])))
    check_paths(source, destination)
    if fingerprint(source) != meta["source"][1] or fingerprint(destination) != meta["destination"][1]:
        raise Refusal("stale plan: source or archive changed")
    # Regenerate the exact plan using the actual selector and parser, rather than
    # trusting editable ranges or an old manifest with current fingerprints.
    regenerated = directory / "validated-plan.tsv"
    regenerated.unlink(missing_ok=True)
    with open(regenerated, "x", encoding="ascii", newline="") as output:
        write_plan(source, destination, meta["mode"][0], output)
    if digest_file(regenerated) != digest_file(path):
        raise Refusal("plan differs from fresh read-only validation")


def copy_records(plan, source, sink, selected):
    for row in plan_rows(plan):
        if row[0] == "record" and bool(int(row[5])) == selected:
            copy_range(source, sink, int(row[2]), int(row[3]))


def verify_composition(path, baseline, source, plan, selected, hook, stage):
    """Compare exact expected concatenation through a bounded checking sink."""
    hook(stage + "-verify")
    with open(path, "rb") as actual:
        class ComparingSink:
            def write(self, data):
                if actual.read(len(data)) != data:
                    raise Refusal(stage + " byte verification failed")
                return len(data)
        sink = ComparingSink()
        if baseline is not None and baseline.exists():
            with open(baseline, "rb") as stream:
                copy_range(stream, sink, 0, baseline.stat().st_size)
        with open(source, "rb") as stream:
            copy_records(plan, stream, sink, selected)
        if actual.read(1):
            raise Refusal(stage + " contains unrelated trailing bytes")
    # A second framing read checks boundaries and count independently of hashes.
    expected_count = 0
    if baseline is not None and baseline.exists():
        with open(baseline, "rb") as stream:
            expected_count += sum(1 for _ in records(stream))
    for row in plan_rows(plan):
        if row[0] == "record" and bool(int(row[5])) == selected:
            expected_count += 1
    with open(path, "rb") as stream:
        if sum(1 for _ in records(stream)) != expected_count:
            raise Refusal(stage + " record count changed")


def prepare_file(path, producer, hook, stage):
    path.unlink(missing_ok=True)
    hook(stage + "-open")
    with open(path, "xb") as stream:
        os.fchmod(stream.fileno(), 0o600)
        class HookedSink:
            def write(self, data):
                hook(stage + "-write")
                return stream.write(data)
        producer(HookedSink())
        stream.flush()
        hook(stage + "-fsync")
        os.fsync(stream.fileno())
        hook(stage + "-close")
    sync_directory(path.parent)


def execute(plan, disposable_root, hook=lambda stage: None):
    plan = absolute(plan)
    meta = plan_metadata(plan)
    source = Path(os.fsdecode(decoded(meta["source"][0])))
    destination = Path(os.fsdecode(decoded(meta["destination"][0])))
    mode = meta["mode"][0]
    if mode not in ("copy", "move"):
        raise Refusal("inspect plan cannot authorize mutation")
    directory = Path(str(plan) + ".transaction")
    disposable_paths(disposable_root, (source, destination, plan, directory))
    if len({source, destination, plan, directory}) != 4:
        raise Refusal("source, archive, plan and temporary state collide")
    if any(directory in path.parents for path in (source, destination, plan)):
        raise Refusal("mailbox or plan collides with transaction outputs")
    check_paths(source, destination)
    plan_digest = digest_file(plan)
    directory.mkdir(exist_ok=True, mode=0o700)
    sync_directory(directory.parent)
    for name in ("executor.lock", "state.tsv", "state.next", "validated-plan.tsv",
                 "archive.prepared", "archive.original", "source.prepared", "source.original"):
        absolute(directory / name)
    # Cooperative exclusion only within this disposable executor, never a mail
    # delivery lock. OS releases the advisory descriptor lock on process death.
    import fcntl
    with open(directory / "executor.lock", "a+b") as lock:
        try:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            raise Refusal("transaction executor already running") from error
        state_path = directory / "state.tsv"
        if state_path.exists():
            state = load_state(directory)
            if state.get("plan") != plan_digest:
                raise Refusal("transaction belongs to a different plan")
        else:
            if any((directory / name).exists() for name in ("archive.prepared", "archive.original",
                    "source.prepared", "source.original")):
                raise Refusal("unresolved transaction outputs without a journal; retain all copies")
            verify_plan(plan, meta, directory)
            state = {"plan": plan_digest, "phase": "prepared"}
            save_state(directory, state, hook)
        archive_temp = directory / "archive.prepared"
        replacement = directory / "source.prepared"
        backup = directory / "source.original"
        archive_original = directory / "archive.original"
        phase = state["phase"]
        if phase == "done":
            if fingerprint(source) != state["source-final"] or fingerprint(destination) != state["archive-final"]:
                raise Refusal("completed transaction files changed")
            return "already-complete"
        if phase == "prepared":
            verify_plan(plan, meta, directory)
            hook("before-archive")
            # Existing archive is copied, not used as a deduplication set.
            if destination.exists():
                if destination.stat().st_size:
                    with open(destination, "rb") as stream:
                        stream.seek(-1, os.SEEK_END)
                        if stream.read(1) != b"\n":
                            raise Refusal("archive lacks final LF; raw append would merge records")
                    with open(destination, "rb") as stream:
                        for _ in records(stream):
                            pass
                prepare_file(archive_original,
                    lambda sink: copy_whole(destination, sink), hook, "archive-backup")
                if digest_file(archive_original) != meta["destination"][1].split(":")[-1]:
                    raise Refusal("archive baseline backup differs")
            else:
                archive_original.unlink(missing_ok=True)
            def archive_producer(sink):
                if archive_original.exists():
                    copy_whole(archive_original, sink)
                with open(source, "rb") as stream:
                    copy_records(plan, stream, sink, True)
            prepare_file(archive_temp, archive_producer, hook, "archive")
            hook("after-archive-write")
            verify_composition(archive_temp, destination if destination.exists() else None,
                               source, plan, True, hook, "archive")
            if destination.exists():
                old_archive, new_archive = destination.stat(), archive_temp.stat()
                if (old_archive.st_uid, old_archive.st_gid) != (new_archive.st_uid, new_archive.st_gid):
                    raise Refusal("replacement changes archive ownership")
                os.chmod(archive_temp, stat.S_IMODE(old_archive.st_mode))
                with open(archive_temp, "rb") as stream:
                    os.fsync(stream.fileno())
            # Bind the inode as well as content for recovery across rename windows.
            state.update({"archive-ready": fingerprint(archive_temp), "phase": "archive-ready"})
            save_state(directory, state, hook)
            phase = "archive-ready"
        if phase == "archive-ready":
            if matches_renamed(destination, state["archive-ready"]):
                pass  # rename succeeded before previous state receipt
            else:
                if fingerprint(source) != meta["source"][1] or fingerprint(destination) != meta["destination"][1]:
                    raise Refusal("source/archive changed before archive commit")
                if fingerprint(archive_temp) != state["archive-ready"]:
                    raise Refusal("prepared archive changed")
                hook("archive-replace")
                os.replace(archive_temp, destination)
                hook("after-archive-commit")
            sync_directory(destination.parent)
            state.update({"archive-final": fingerprint(destination), "phase": "archive-committed"})
            save_state(directory, state, hook)
            phase = "archive-committed"
        if phase == "archive-committed":
            if fingerprint(destination) != state["archive-final"]:
                raise Refusal("verified destination changed")
            if fingerprint(source) != meta["source"][1]:
                raise Refusal("source changed after archive verification")
            hook("after-archive-verification")
            if mode == "copy":
                state.update({"source-final": fingerprint(source), "phase": "done"})
                save_state(directory, state, hook)
                return "complete"
            prepare_file(backup, lambda sink: copy_whole(source, sink), hook, "source-backup")
            if digest_file(backup) != meta["source"][1].split(":")[-1]:
                raise Refusal("original source backup differs")
            def source_producer(sink):
                with open(source, "rb") as stream:
                    copy_records(plan, stream, sink, False)
            prepare_file(replacement, source_producer, hook, "source")
            verify_composition(replacement, None, source, plan, False, hook, "source")
            old = source.stat()
            new = replacement.stat()
            if (old.st_uid, old.st_gid) != (new.st_uid, new.st_gid):
                raise Refusal("replacement changes source ownership")
            os.chmod(replacement, stat.S_IMODE(old.st_mode))
            with open(replacement, "rb") as stream:
                os.fsync(stream.fileno())
            state.update({"source-ready": fingerprint(replacement), "phase": "source-ready"})
            save_state(directory, state, hook)
            phase = "source-ready"
        if phase == "source-ready":
            if fingerprint(destination) != state["archive-final"]:
                raise Refusal("destination changed before source commit")
            if not matches_renamed(source, state["source-ready"]):
                if fingerprint(source) != meta["source"][1]:
                    raise Refusal("source changed before source commit")
                if fingerprint(replacement) != state["source-ready"]:
                    raise Refusal("prepared source changed")
                hook("before-source-commit")
                # Hooks may change the source; validate again at the boundary.
                if fingerprint(source) != meta["source"][1] or fingerprint(destination) != state["archive-final"]:
                    raise Refusal("source/archive changed at commit boundary")
                hook("source-replace")
                os.replace(replacement, source)
                hook("after-source-commit")
            sync_directory(source.parent)
            state.update({"source-final": fingerprint(source), "phase": "done"})
            hook("receipt-write")
            save_state(directory, state, hook)
            return "complete"
        raise Refusal("unsupported transaction state")


def copy_whole(path, sink):
    with open(path, "rb") as stream:
        copy_range(stream, sink, 0, path.stat().st_size)


def matches_renamed(path, expected):
    actual = fingerprint(path)
    if actual == "absent":
        return False
    # Rename changes ctime on some filesystems. All other facts, including inode,
    # size, mode, owner, mtime and bytes must match the prepared file.
    left, right = actual.split(":"), expected.split(":")
    return left[:4] == right[:4] and left[5:] == right[5:]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    scan = sub.add_parser("plan")
    scan.add_argument("--source", required=True)
    scan.add_argument("--destination", required=True)
    scan.add_argument("--mode", choices=("inspect", "copy", "move"), required=True)
    scan.add_argument("--live-spool")
    run = sub.add_parser("execute-disposable")
    run.add_argument("--plan", required=True)
    run.add_argument("--disposable-root", required=True)
    arguments = parser.parse_args()
    try:
        if arguments.command == "plan":
            write_plan(arguments.source, arguments.destination, arguments.mode, sys.stdout, arguments.live_spool)
        else:
            print(execute(arguments.plan, arguments.disposable_root))
    except (Refusal, OSError, ValueError) as error:
        print("REFUSED: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
