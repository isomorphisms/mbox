#!/usr/bin/env python3
"""Read-only SPEC-LIST inventory of a Unix mboxo mailbox (Python 3.9+).

No mailbox/archive locks, writes, copying, filing, or message decoding.
Matches an ASCII-case-insensitive b'SPEC-LIST' substring only in the six
established headers. Bodies are scanned in large blocks, never line-by-line.
A changed source is reported as a provisional count.
"""
import argparse
from collections import deque
import os
import stat
import sys

CHUNK = 1024 * 1024
HEADER_READ = 65536
SEPARATOR = b"\nFrom "
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


def scan_body(source, end, progress):
    """Find the next mboxo envelope without iterating over body lines.

    A preceding LF detects a separator at the start of an empty body;
    retaining five bytes catches the separator across arbitrary read blocks.
    """
    lookbehind = b"\n"
    while source.tell() < end:
        fragment = source.read(min(CHUNK, end - source.tell()))
        if not fragment:
            raise Refusal("source shortened while reading its opening size")
        start = source.tell() - len(fragment) - len(lookbehind)
        block = lookbehind + fragment
        marker = block.find(SEPARATOR)
        if marker >= 0:
            next_start = start + marker + 1
            source.seek(next_start)
            return next_start
        lookbehind = block[-(len(SEPARATOR) - 1):]
        progress(source.tell())
    return end


def read_entry(source, start, end, progress):
    """Return (header bytes, next entry offset), bounded independently of body."""
    source.seek(start)
    envelope = source.readline(min(ENVELOPE_LIMIT + 1, end - start))
    if not envelope or not envelope.startswith(b"From "):
        raise Refusal("nonempty preamble before first mbox envelope")
    if len(envelope) > ENVELOPE_LIMIT:
        raise Refusal("envelope exceeds 4096 octets")
    if not envelope.endswith(b"\n"):
        if source.tell() < end:
            raise Refusal("envelope exceeds 4096 octets")
        return b"", end

    header = bytearray()
    header_line = bytearray()
    line_start = True
    while source.tell() < end:
        line_offset = source.tell()
        fragment = source.readline(min(HEADER_READ, end - line_offset))
        if not fragment:
            raise Refusal("source shortened while reading its opening size")
        if line_start and fragment.startswith(b"From "):
            # A new mboxo envelope also wins if the header separator is absent.
            source.seek(line_offset)
            return bytes(header), line_offset
        if len(header) + len(fragment) > HEADER_LIMIT:
            raise Refusal("header section exceeds 4 MiB")
        header.extend(fragment)
        header_line.extend(fragment)
        if fragment.endswith(b"\n"):
            if header_line in (b"\n", b"\r\n"):
                return bytes(header), scan_body(source, end, progress)
            header_line.clear()
            line_start = True
        else:
            line_start = False
        progress(source.tell())
    return bytes(header), end


def scan(path, example_limit=10, progress_mib=256, progress_output=sys.stderr):
    """Scan the source's opening size; never write, copy, or refile mail."""
    if not 0 <= example_limit <= 100:
        raise Refusal("examples must be between 0 and 100")
    if progress_mib < 0:
        raise Refusal("progress-mib must be nonnegative")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    with os.fdopen(descriptor, "rb") as source:
        before = os.fstat(source.fileno())
        if not stat.S_ISREG(before.st_mode):
            raise Refusal("source is not a regular file")
        end = before.st_size
        next_progress = progress_mib * (1024 * 1024) if progress_mib else None

        def progress(done):
            nonlocal next_progress
            if next_progress is not None and done >= next_progress:
                print("progress\t%d/%d bytes" % (done, end),
                      file=progress_output, flush=True)
                next_progress = (done // (progress_mib * 1024 * 1024) + 1) * (progress_mib * 1024 * 1024)

        total = selected = selected_octets = 0
        by_header = {name: 0 for name in SEARCH_HEADERS}
        first = []
        last = deque(maxlen=example_limit)
        offset = 0
        while offset < end:
            parsed_header, next_offset = read_entry(source, offset, end, progress)
            if next_offset <= offset:
                raise Refusal("scanner did not advance")
            total += 1
            parsed = tuple(fields(parsed_header))
            names = {name.lower() for name, value in parsed
                     if name.lower() in SEARCH_HEADERS and b"spec-list" in value.lower()}
            if names:
                selected += 1
                selected_octets += next_offset - offset
                for name in names:
                    by_header[name] += 1
                if example_limit:
                    shown = {}
                    for name, value in parsed:
                        if name.lower() in SHOW_HEADERS and name.lower() not in shown:
                            shown[name.lower()] = value
                    row = (total, offset, next_offset,
                           ",".join(sorted(n.decode("ascii") for n in names)),
                           *(printable(shown.get(name)) for name in SHOW_HEADERS))
                    if len(first) < example_limit:
                        first.append(row)
                    else:
                        last.append(row)
            offset = next_offset
            progress(offset)
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
    parser.add_argument("--progress-mib", type=int, default=256,
                        help="report progress on stderr every N MiB (0 disables)")
    arguments = parser.parse_args(argv)
    try:
        result = scan(arguments.source, arguments.examples, arguments.progress_mib)
        report(result)
        return 0 if result["stable"] else 3
    except (OSError, Refusal) as error:
        print("REFUSED: " + str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
