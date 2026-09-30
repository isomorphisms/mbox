# D mail implementations worth mining

This is a research index, not a dependency list and not an endorsement of any
one implementation's semantics.

## arsd.email

`arsd.email` has broad overlap with this project:

- reading and writing email;
- MIME containers;
- transfer encodings and character sets;
- mbox input;
- SMTP sending.

Useful things to inspect closely:

- its mbox state machine and new-`From ` decision;
- header continuation handling;
- MIME multipart decomposition;
- its treatment of mbox `>From` escaping.

Important divergence to test rather than copy: its reader removes one leading
`>` from `>From` and `>>From` body lines.  Our v0 contract deliberately
preserves raw bytes while reading, so that behavior belongs in compatibility
tests, not in the reference implementation by assumption.

Repository: `dlang-libs/arsd-clone`, file `email.d`.

## opticron/mail

This older D library separates message, header, POP3, SMTP, and socket code.

Useful ideas:

- an ordered header collection that preserves repeated fields;
- separate message/header parsing layers;
- explicit MIME message parts;
- protocol separation between POP3/SMTP and message representation.

Its header parser unfolds continuation lines, and its message parser handles
several multipart content types and transfer encodings.  It is marked
unmaintained upstream, so use it as source material and a test generator rather
than as an authority.

Repository: `opticron/mail`.

## vibe.d mail

vibe.d contains an SMTP client and mail-sending API.  It is less directly
relevant to mbox framing, but useful later for:

- separating message construction from transport;
- SMTP connection/authentication/TLS boundaries;
- timeout behavior;
- multiple recipient headers.

Repository: `vibe-d/vibe.d`, mail package.

## Rule for using these

Do not collapse "the D implementation" into one codebase.  We have at least four
distinct D perspectives:

1. our `mbox` D branch;
2. `arsd.email`;
3. `opticron/mail`;
4. vibe.d's mail/SMTP implementation.

When they disagree, record the disagreement and turn it into a fixture or
property where possible.  The point of having several implementations is to
catch shared assumptions, not to vote by majority.
