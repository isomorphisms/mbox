"""mboxo source views. No decoding, normalization, or body res serialization."""
import hashlib
from dataclasses import dataclass

CHUNK = 65536
HEADER_LIMIT = 4 * 1024 * 1024
ENVELOPE_LIMIT = 4096


class Refusal(Exception):
    pass


@dataclass
class Record:
    start: int
    end: int
    envelope: bytes
    header: bytes
    digest: str


def fields(header):
    """Unfold valid fields; malformed lines break continuation attachment.

    Raw material stays in the record bytes. RFC field names are printable ASCII
    except colon; empty/whitespace/non-ASCII names are malformed.
    """
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


def records(stream):
    """Memory O(header limit + envelope limit + fixed I/O fragments).

    readline(size) is deliberately bounded, even for a single enormous body line.
    Every line-leading From-space frames an entry, including invalid dates and
    body-looking lines. Short/incomplete envelope prefixes do not frame an entry.
    Nonempty preamble is unsupported and refused rather than lost on rewrite.
    """
    offset = 0
    line_start = True
    start = None
    envelope = bytearray()
    header = bytearray()
    in_envelope = False
    in_header = False
    header_line = bytearray()
    digest = None
    while True:
        fragment = stream.readline(CHUNK)
        if not fragment:
            break
        if line_start and fragment.startswith(b"From "):
            if start is not None:
                yield Record(start, offset, bytes(envelope), bytes(header), digest.hexdigest())
            start = offset
            envelope = bytearray()
            header = bytearray()
            header_line = bytearray()
            in_envelope = True
            in_header = False
            digest = hashlib.sha256()
        if start is None:
            raise Refusal("nonempty preamble before first mbox envelope")
        digest.update(fragment)
        if in_envelope:
            envelope.extend(fragment)
            if len(envelope) > ENVELOPE_LIMIT:
                raise Refusal("envelope exceeds 4096 octets")
            if fragment.endswith(b"\n"):
                in_envelope = False
                in_header = True
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
    if start is not None:
        yield Record(start, offset, bytes(envelope), bytes(header), digest.hexdigest())


def copy_range(source, sink, start, end):
    source.seek(start)
    remaining = end - start
    if remaining < 0:
        raise Refusal("invalid byte range")
    while remaining:
        data = source.read(min(CHUNK, remaining))
        if not data:
            raise Refusal("short source read")
        written = sink.write(data)
        if written != len(data):
            raise Refusal("short destination write")
        remaining -= len(data)
