"""SPEC-LIST policy, independent of framing and filesystem effects."""
SEARCH_HEADERS = (b"from", b"sender", b"reply-to", b"to", b"cc", b"subject")
POLICY = "six-headers-ascii-substring-v1"


def evidence(fields):
    # Substring matching is the established policy. SPEC-LISTS therefore matches;
    # SPEC LIST and SPEC_LIST do not. Never silently strengthen this to tokens.
    return [(name, value) for name, value in fields
            if name.lower() in SEARCH_HEADERS and b"spec-list" in value.lower()]
