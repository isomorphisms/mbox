# RFC 5322 lexical fixtures

These fixtures are intentionally below whole-message parsing.  They exercise
the exact boundaries where a plausible recognizer commonly consumes too much
input or silently treats storage-tolerated LF as RFC 5322 CRLF.

`fws.tsv` expresses octets in hexadecimal.  `NO_MATCH` means the recognizer
must leave the cursor unchanged.  When a leading run of WSP is itself valid
FWS but a following attempted fold is incomplete, the parser returns the
single-line FWS and leaves the CRLF untouched.

These cases are independent acceptance data.  They are not generated from the
Idriç implementation.
