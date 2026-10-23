#!/usr/bin/env python3
"""Read-only SPEC-LIST inventory of a Unix mboxo mailbox (Python 3.9+).

No mailbox/archive locks, writes, copying, filing, or message decoding.
Matches an ASCII-case-insensitive b'SPEC-LIST' substring only in the six
established headers. A changed source is reported as a provisional count.
"""
import argparse
from collections import deque
import os
import stat
import sys

CHUNK = 65536
HEADER_LIMIT = 4 * 1024 * 1024
ENVELOPE_LIMIT = 4096
SEARCH_HEADERS = (b"from", b"sender", b"reply-to", b"to", b"cc", b"subject")
SHOW_HEADERS = (b"message-id", b"date", b"from", b"to", b"subject")


class Refusal(Exception):
    pass


def fields(header):
    """The mailbox hardening reference's ASCII field/folding rule."""
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


def identity(info):
    return (info.st_dev, info.st_ino, info.st_size,
            info.st_mtime_ns, info.st_ctime_ns)


def printable(value):
    """Escape control characters; don't emit untrusted mail bytes to terminal."""
    if value is None:
        return "-"
    return repr(value[:120]) + ("..." if len(value) > 120 else "")


def scan(path, example_limit=10):
    """Scan precisely the file size observed at opening; never write a file."""
    if example_limit < 0 or example_limit > 100:
        raise Refusal("examples must be between 0 and 100")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    with os.fdopen(descriptor, "rb") as source:
        before = os.fstat(source.fileno())
        if not stat.S_ISREG(before.st_mode):
            raise Refusal("source is not a regular file")
        remaining = before.st_size
        offset = 0
        line_start = True
        start = None
        envelope_bytes = 0
        header = bytearray()
        header_line = bytearray()
        in_envelope = False
        in_header = False
        total = selected = selected_octets = 0
        by_header = {name: 0 for name in SEARCH_HEADERS}
        first = []
        last = deque(maxlen=example_limit)

        def finish(end):
            nonlocal total, selected, selected_octets
            if start is None:
                return
            total += 1
            parsed = tuple(fields(bytes(header)))
            names = {name.lower() for name, value in parsed
                     if name.lower() in SEARCH_HEADERS and b"spec-list" in value.lower()}
            if not names:
                return
            selected += 1
            selected_octets += end - start
            for name in names:
                by_header[name] += 1
            if example_limit:
                shown = {}
                for name, value in parsed:
                    if name.lower() in SHOW_HEADERS and name.lower() not in shown:
                        shown[name.lower()] = value
                row = (total, start, end, ",".join(sorted(n.decode("ascii") for n in names)),
                       *(printable(shown.get(name)) for name in SHOW_HEADERS))
                if len(first) < example_limit:
                    first.append(row)
                else:
                    last.append(row)

        while remaining:
            fragment = source.readline(min(CHUNK, remaining))
            if not fragment:
                raise Refusal("source shortened while reading its opening size")
            remaining -= len(fragment)
            if line_start and fragment.startswith(b"From "):
                finish(offset)
                start = offset
                envelope_bytes = 0
                header.clear()
                header_line.clear()
                in_envelope, in_header = True, False
            if start is None:
                raise Refusal("nonempty preamble before first mbox envelope")
            if in_envelope:
                envelope_bytes += len(fragment)
                if envelope_bytes > ENVELOPE_LIMIT:
                    raise Refusal("envelope exceeds 4096 octets")
                if fragment.endswith(b"\n"):
                    in_envelope, in_header = False, True
            elif in_header:
                if len(header) + len(fragment) > HEADER_LIMIT:
                    raise Refusal("header section exceeds 4 MiB")
                header.extend(fragment)
                header_line.extend(fragment)
                if fragment.endswith(b"\n"):
                    if header_line in (b"\n", b"\r\n"):
                        in_header = False
                    header_line.clear()
            offset += len(fragment)
            line_start = fragment.endswith(b"\n")
        finish(offset)
        after = os.fstat(source.fileno())
    try:
        at_path = os.stat(path, follow_symlinks=False)
        unchanged = identity(before) == identity(after) == identity(at_path)
    except OSError:
        unchanged = False
    return dict(source=path, stable=unchanged, opened_bytes=before.st_size,
                total=total, selected=selected, selected_octets=selected_octets,
                by_header=by_header, first=first, last=list(last))


def report(result, output=sys.stdout):
    print("status\t" + ("STABLE" if result["stable"] else "CHANGED_DURING_SCAN"), file=output)
    print("source\t" + os.fspath(result["source"]), file=output)
    print("opening_bytes\t" + str(result["opened_bytes"]), file=output)
    print("messages\t" + str(result["total"]), file=output)
    print("spec_list_messages\t" + str(result["selected"]), file=output)
    print("other_messages\t" + str(result["total"] - result["selected"]), file=output)
    print("spec_list_bytes\t" + str(result["selected_octets"]), file=output)
    for name in SEARCH_HEADERS:
        print("matching_header_messages\t%s\t%d" %
              (name.decode("ascii"), result["by_header"][name]), file=output)
    print("example_columns\tordinal\tstart_byte\tend_byte\tmatching_headers\tmessage-id\tdate\tfrom\tto\tsubject", file=output)
    for sample in result["first"] + result["last"]:
        print("example\t" + "\t".join(map(str, sample)), file=output)
    if not result["stable"]:
        print("warning\tCounts are provisional: mailbox metadata changed during the scan.", file=output)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", default="/var/mail/isomorphisms")
    parser.add_argument("--examples", type=int, default=10,
                        help="show first and last N matching messages (0..100)")
    arguments = parser.parse_args(argv)
    try:
        result = scan(arguments.source, arguments.examples)
        report(result)
        return 0 if result["stable"] else 3
    except (OSError, Refusal) as error:
        print("REFUSED: " + str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
