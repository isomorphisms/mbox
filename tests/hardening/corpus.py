"""Independent byte construction and declared expectations, not parser output.

Ranges are the sums of the declared entry lengths. No parser generates an oracle.
Each entry carries a separately declared selection value and expected header block.
"""
from dataclasses import dataclass


@dataclass
class Entry:
    raw: bytes
    selected: bool
    header: bytes
    envelope: bytes


def entry(header=b"To: keep@example.org\n", body=b"body\n", selected=False,
          envelope=b"From same@example.org Tue Oct 06 08:00:00 2026\n", blank=b"\n"):
    return Entry(envelope + header + blank + body, selected, header + blank, envelope)


def cases():
    keep = entry()
    chosen = entry(b"Subject: SPEC-LIST\nMessage-ID: <same>\n", selected=True)
    found = {
        "empty": [], "one-keep": [keep], "one-selected": [chosen],
        "normal": [keep, chosen, keep], "first": [chosen, keep],
        "last": [keep, chosen], "all": [chosen, chosen], "none": [keep, keep],
        "interleaved": [chosen, keep, chosen, keep, chosen],
        "same-sender": [keep, chosen, keep],
        "repeated-id": [chosen, entry(b"Message-ID: <same>\nTo: x\n"), chosen],
        "missing-id": [entry(b"Subject: SPEC-LIST\n", selected=True)],
        "duplicate-id-headers": [entry(b"Message-ID: <one>\nMessage-ID: <two>\nSubject: SPEC-LIST\n", selected=True)],
        "folded": [entry(b"Subject: prefix\n\tSPEC-LIST\n", selected=True)],
        "fold-breaks-marker": [entry(b"Subject: SPEC-\n LIST\n")],
        "duplicate": [entry(b"To: keep\nTo: SPEC-LIST\n", selected=True)],
        "empty-header": [entry(b"Subject:\nTo:\n")],
        "malformed": [entry(b"bad line\n SPEC-LIST\n: SPEC-LIST\nSubject : SPEC-LIST\n")],
        "malformed-between-folds": [entry(b"Subject: keep\nbad\n SPEC-LIST\n")],
        "very-long-header": [entry(b"Subject: " + b"x" * 262144 + b"SPEC-LIST\n", selected=True)],
        "utf8": [entry("Subject: café SPEC-LIST λ\n".encode(), selected=True)],
        "8bit": [entry(b"Subject: \xffSPEC-LIST\x80\n", b"\x00\xff\xfe\n", True)],
        "mixed-endings": [entry(b"Subject: SPEC-LIST\r\nTo: x\n", b"x\r\ny\n", True, blank=b"\r\n")],
        "no-final-newline": [entry(b"Subject: SPEC-LIST\n", b"last", True)],
        "empty-body": [entry(b"Subject: SPEC-LIST\n", b"", True)],
        "large-body": [entry(b"Subject: SPEC-LIST\n", b"q" * (8 * 1024 * 1024), True)],
        "escaped": [entry(body=b">From x\n>>From y\nSPEC-LIST\n")],
        "selected-escaped": [entry(b"Subject: SPEC-LIST\n", b">From x\n>>From y\n", True)],
        "body-only": [entry(body=b"Subject: SPEC-LIST\nSPEC-LIST\n")],
        "wrong-header": [entry(b"List-ID: SPEC-LIST\nDelivered-To: SPEC-LIST\nX-List: SPEC-LIST\n")],
        "near": [entry(b"Subject: SPEC LIST SPEC_LIST SPEC-LIS SPECLIST\n")],
        "substring-is-policy": [entry(b"Subject: XSPEC-LISTS\n", selected=True)],
        # These alleged body lines are explicit mboxo boundaries, not date-validated.
        "unescaped-body": [entry(body=b"body\n"), entry(b"Subject: SPEC-LIST\n", selected=True, envelope=b"From body-looking\n")],
        "consecutive-from": [entry(b"", b"", envelope=b"From \n", blank=b""), entry(b"", b"", envelope=b"From invalid date\n", blank=b""), chosen],
        "invalid-date": [entry(b"Subject: SPEC-LIST\n", selected=True, envelope=b"From x Tue Feb 99 99:99:99 2026\n")],
        "bad-envelope-near": [entry(body=b"From\nFromx sender\n From sender\n")],
        "partial-envelope": [entry(b"", b"", envelope=b"From eof", blank=b"")],
    }
    for header in (b"From", b"Sender", b"Reply-To", b"To", b"Cc", b"Subject"):
        found[header.decode() + "-alone"] = [entry(header + b": SPEC-LIST\n", selected=True)]
        found[header.decode() + "-case"] = [entry(header.upper() + b": sPeC-lIsT\n", selected=True)]
    return found


def expected_ranges(entries):
    offset = 0
    for item in entries:
        end = offset + len(item.raw)
        yield (offset, end)
        offset = end
