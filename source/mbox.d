module mbox;

import std.stdio : File;

/*
 * Byte-preserving mboxo + RFC-header core.
 *
 * This deliberately treats D strings as byte arrays.  It does not decode
 * message bodies, MIME, or RFC 2047.  Raw ranges always refer to the original
 * source buffer.
 */

alias ByteOffset = ulong;

struct ByteRange {
    ByteOffset start;
    ByteOffset end;

    @property ByteOffset length() const pure nothrow @safe {
        return end - start;
    }
}

struct HeaderField {
    ByteRange raw;
    ByteRange nameRaw;
    string name;              // ASCII-lowercased lookup key
    string unfoldedValue;     // derived view, never copy authority
    bool malformed;
}

struct MessageView {
    ByteRange envelopeRange;
    ByteRange messageRange;
    ByteRange headerRange;
    ByteRange bodyRange;
    HeaderField[] headers;
}

struct Address {
    string displayName;
    string addrSpec;
}

struct MboxRecord {
    ByteRange envelopeRange;
    ByteRange messageRange;
    ByteRange headerRange;
    ByteRange bodyRange;

    @property ByteRange wholeRange() const pure nothrow @safe {
        return ByteRange(envelopeRange.start, messageRange.end);
    }
}

private bool startsWithAt(scope const(char)[] bytes, size_t at, scope const(char)[] needle)
    pure nothrow @safe
{
    if (at + needle.length > bytes.length)
        return false;
    foreach (i; 0 .. needle.length)
        if (bytes[at + i] != needle[i])
            return false;
    return true;
}

private size_t lineEnd(scope const(char)[] bytes, size_t at, size_t stop)
    pure nothrow @safe
{
    size_t i = at;
    while (i < stop && bytes[i] != '\n')
        ++i;
    return i;
}

private size_t nextLine(scope const(char)[] bytes, size_t end, size_t stop)
    pure nothrow @safe
{
    return end < stop && bytes[end] == '\n' ? end + 1 : end;
}

private size_t logicalLineEnd(scope const(char)[] bytes, size_t begin, size_t end)
    pure nothrow @safe
{
    if (end > begin && bytes[end - 1] == '\r')
        return end - 1;
    return end;
}

private string asciiLower(scope const(char)[] s) @safe
{
    auto out = new char[](s.length);
    foreach (i, c; s) {
        if (c >= 'A' && c <= 'Z')
            out[i] = cast(char)(c + ('a' - 'A'));
        else
            out[i] = c;
    }
    return cast(string) out;
}

private string trimAsciiCopy(scope const(char)[] s) @safe
{
    size_t a = 0;
    size_t b = s.length;
    while (a < b && (s[a] == ' ' || s[a] == '\t'))
        ++a;
    while (b > a && (s[b - 1] == ' ' || s[b - 1] == '\t'))
        --b;
    return s[a .. b].idup;
}

private string appendFold(string previous, scope const(char)[] continuation) @safe
{
    auto tail = trimAsciiCopy(continuation);
    if (previous.length == 0)
        return tail;
    auto out = new char[](previous.length + 1 + tail.length);
    out[0 .. previous.length] = previous[];
    out[previous.length] = ' ';
    out[previous.length + 1 .. $] = tail[];
    return cast(string) out;
}

private HeaderField[] parseHeaders(
    scope const(char)[] bytes,
    size_t begin,
    size_t end,
    out size_t headerEnd,
    out size_t bodyBegin
) @safe
{
    HeaderField[] fields;
    size_t pos = begin;

    while (pos < end) {
        const eol = lineEnd(bytes, pos, end);
        const next = nextLine(bytes, eol, end);
        const logicalEnd = logicalLineEnd(bytes, pos, eol);

        if (logicalEnd == pos) {
            headerEnd = next;
            bodyBegin = next;
            return fields;
        }

        const continuation = bytes[pos] == ' ' || bytes[pos] == '\t';
        if (continuation && fields.length != 0 && !fields[$ - 1].malformed) {
            fields[$ - 1].raw.end = next;
            fields[$ - 1].unfoldedValue =
                appendFold(fields[$ - 1].unfoldedValue, bytes[pos .. logicalEnd]);
            pos = next;
            continue;
        }

        size_t colon = pos;
        while (colon < logicalEnd && bytes[colon] != ':')
            ++colon;

        if (colon == logicalEnd || continuation) {
            fields ~= HeaderField(
                ByteRange(pos, next),
                ByteRange(pos, pos),
                "",
                trimAsciiCopy(bytes[pos .. logicalEnd]),
                true
            );
            pos = next;
            continue;
        }

        const rawName = bytes[pos .. colon];
        fields ~= HeaderField(
            ByteRange(pos, next),
            ByteRange(pos, colon),
            asciiLower(rawName),
            trimAsciiCopy(bytes[colon + 1 .. logicalEnd]),
            false
        );
        pos = next;
    }

    headerEnd = end;
    bodyBegin = end;
    return fields;
}

MessageView[] parseMbox(scope const(char)[] bytes) @safe
{
    MessageView[] out;
    size_t pos = 0;

    while (pos < bytes.length) {
        if (!startsWithAt(bytes, pos, "From ")) {
            // v0 is fail-closed about leading junk: find the next legal
            // beginning-of-line separator without manufacturing a message.
            while (pos < bytes.length) {
                const eol = lineEnd(bytes, pos, bytes.length);
                pos = nextLine(bytes, eol, bytes.length);
                if (pos < bytes.length && startsWithAt(bytes, pos, "From "))
                    break;
            }
            if (pos >= bytes.length)
                break;
        }

        const envelopeStart = pos;
        const envelopeEol = lineEnd(bytes, pos, bytes.length);
        const messageStart = nextLine(bytes, envelopeEol, bytes.length);

        size_t scan = messageStart;
        size_t nextEnvelope = bytes.length;
        while (scan < bytes.length) {
            const eol = lineEnd(bytes, scan, bytes.length);
            const next = nextLine(bytes, eol, bytes.length);
            if (startsWithAt(bytes, scan, "From ")) {
                nextEnvelope = scan;
                break;
            }
            if (next == scan)
                break;
            scan = next;
        }

        size_t headerEnd;
        size_t bodyBegin;
        auto headers = parseHeaders(
            bytes,
            messageStart,
            nextEnvelope,
            headerEnd,
            bodyBegin
        );

        out ~= MessageView(
            ByteRange(envelopeStart, messageStart),
            ByteRange(messageStart, nextEnvelope),
            ByteRange(messageStart, headerEnd),
            ByteRange(bodyBegin, nextEnvelope),
            headers
        );

        pos = nextEnvelope;
    }

    return out;
}

HeaderField[] parseHeaderBlock(scope const(char)[] bytes) @safe
{
    size_t headerEnd;
    size_t bodyBegin;
    return parseHeaders(bytes, 0, bytes.length, headerEnd, bodyBegin);
}

// Stream an mboxo file without materializing the mailbox or message bodies.
// The caller controls locking.  Every physical line beginning "From " is a
// separator, matching the v0 contract.
void scanMbox(ref File source, scope void delegate(in MboxRecord) emit)
{
    enum ScanState {
        beforeFirst,
        headers,
        body,
    }

    source.seek(0);

    ScanState state = ScanState.beforeFirst;
    MboxRecord record;
    ByteOffset position;
    ByteOffset lineStart;

    void finish(ByteOffset end)
    {
        record.messageRange.end = end;
        if (state == ScanState.headers) {
            record.headerRange.end = end;
            record.bodyRange.start = end;
        }
        record.bodyRange.end = end;
        emit(record);
    }

    while (true) {
        const line = source.readln();
        if (line.length == 0)
            break;

        const next = position + line.length;

        if (startsWithAt(line, 0, "From ")) {
            if (state != ScanState.beforeFirst) {
                finish(lineStart);
                // The callback may inspect this record by seeking the same
                // File. Resume after the separator line already read above.
                source.seek(cast(long) next);
            }

            record = MboxRecord.init;
            record.envelopeRange = ByteRange(lineStart, next);
            record.messageRange.start = next;
            record.headerRange.start = next;
            state = ScanState.headers;
        } else if (state == ScanState.headers &&
                   (line == "\n" || line == "\r\n")) {
            record.headerRange.end = next;
            record.bodyRange.start = next;
            state = ScanState.body;
        }

        position = next;
        lineStart = next;
    }

    if (state != ScanState.beforeFirst)
        finish(position);
}

string[] headerValues(scope const MessageView message, scope const(char)[] name) @safe
{
    string[] out;
    const wanted = asciiLower(name);
    foreach (field; message.headers)
        if (!field.malformed && field.name == wanted)
            out ~= field.unfoldedValue;
    return out;
}

private string unquoteDisplay(scope const(char)[] input) @safe
{
    auto s = trimAsciiCopy(input);
    if (s.length < 2 || s[0] != '"' || s[$ - 1] != '"')
        return s;

    char[] out;
    bool escape = false;
    foreach (c; s[1 .. $ - 1]) {
        if (escape) {
            out ~= c;
            escape = false;
        } else if (c == '\\') {
            escape = true;
        } else {
            out ~= c;
        }
    }
    if (escape)
        out ~= '\\';
    return cast(string) out;
}

private Address parseMailboxToken(scope const(char)[] token) @safe
{
    auto s = trimAsciiCopy(token);
    size_t lt = s.length;
    size_t gt = s.length;

    bool quoted = false;
    bool escaped = false;
    foreach (i, c; s) {
        if (escaped) {
            escaped = false;
            continue;
        }
        if (quoted && c == '\\') {
            escaped = true;
            continue;
        }
        if (c == '"') {
            quoted = !quoted;
            continue;
        }
        if (!quoted && c == '<' && lt == s.length)
            lt = i;
        else if (!quoted && c == '>' && lt != s.length) {
            gt = i;
            break;
        }
    }

    if (lt != s.length && gt > lt) {
        return Address(
            unquoteDisplay(s[0 .. lt]),
            trimAsciiCopy(s[lt + 1 .. gt])
        );
    }

    return Address("", trimAsciiCopy(s));
}

Address[] parseAddresses(scope const string[] fieldValues) @safe
{
    Address[] out;

    foreach (value; fieldValues) {
        size_t start = 0;
        bool quoted = false;
        bool escaped = false;
        size_t angleDepth = 0;

        foreach (i, c; value) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (quoted && c == '\\') {
                escaped = true;
                continue;
            }
            if (c == '"') {
                quoted = !quoted;
                continue;
            }
            if (!quoted) {
                if (c == '<')
                    ++angleDepth;
                else if (c == '>' && angleDepth != 0)
                    --angleDepth;
                else if (c == ',' && angleDepth == 0) {
                    auto token = trimAsciiCopy(value[start .. i]);
                    if (token.length)
                        out ~= parseMailboxToken(token);
                    start = i + 1;
                }
            }
        }

        auto token = trimAsciiCopy(value[start .. $]);
        if (token.length)
            out ~= parseMailboxToken(token);
    }

    return out;
}

Address[] recipients(scope const MessageView message) @safe
{
    string[] values;
    foreach (field; message.headers) {
        if (field.malformed)
            continue;
        if (field.name == "to" || field.name == "cc")
            values ~= field.unfoldedValue;
    }
    return parseAddresses(values);
}

private bool asciiEqualInsensitive(scope const(char)[] a, scope const(char)[] b)
    pure nothrow @safe
{
    if (a.length != b.length)
        return false;
    foreach (i; 0 .. a.length) {
        char x = a[i];
        char y = b[i];
        if (x >= 'A' && x <= 'Z') x = cast(char)(x + 32);
        if (y >= 'A' && y <= 'Z') y = cast(char)(y + 32);
        if (x != y)
            return false;
    }
    return true;
}

bool addrSpecMatchesDomainFold(scope const(char)[] a, scope const(char)[] b)
    pure nothrow @safe
{
    size_t aa = a.length;
    size_t bb = b.length;
    foreach_reverse (i; 0 .. a.length)
        if (a[i] == '@') { aa = i; break; }
    foreach_reverse (i; 0 .. b.length)
        if (b[i] == '@') { bb = i; break; }

    if (aa == a.length || bb == b.length)
        return a == b;

    if (a[0 .. aa] != b[0 .. bb])
        return false;
    return asciiEqualInsensitive(a[aa + 1 .. $], b[bb + 1 .. $]);
}

unittest {
    enum sample =
        "From alice@example.org Tue Sep 29 12:00:00 2026\n" ~
        "From: Alice <alice@example.org>\n" ~
        "To: SPEC-LIST <spec-list@example.org>\n" ~
        "Subject: first\n\n" ~
        "alpha\n" ~
        ">From this is body text\n" ~
        "From bob@example.org Tue Sep 29 12:01:00 2026\r\n" ~
        "From: Bob <bob@example.org>\r\n" ~
        "To: \"Example, Person\" <person@example.org>,\r\n" ~
        " SPEC-LIST <spec-list@example.org>\r\n" ~
        "Cc: other@example.org\r\n" ~
        "Subject: folded recipients\r\n\r\n" ~
        "beta\r\n";

    auto messages = parseMbox(sample);
    assert(messages.length == 2);
    assert(headerValues(messages[0], "SUBJECT") == ["first"]);

    auto r0 = recipients(messages[0]);
    assert(r0.length == 1);
    assert(r0[0].addrSpec == "spec-list@example.org");

    auto r1 = recipients(messages[1]);
    assert(r1.length == 3);
    assert(r1[0].displayName == "Example, Person");
    assert(r1[0].addrSpec == "person@example.org");
    assert(r1[1].addrSpec == "spec-list@example.org");
    assert(r1[2].addrSpec == "other@example.org");

    assert(addrSpecMatchesDomainFold(
        "spec-list@EXAMPLE.ORG",
        "spec-list@example.org"
    ));
}


unittest {
    enum sample =
        "junk before first message\n" ~
        "From alice@example.org Tue Sep 29 12:00:00 2026\n" ~
        "From: Alice <alice@example.org>\n" ~
        "To: SPEC-LIST <spec-list@example.org>\n" ~
        "Subject: first\n\n" ~
        "alpha\n" ~
        ">From quoted body text\n" ~
        "From bob@example.org Tue Sep 29 12:01:00 2026\r\n" ~
        "From: Bob <bob@example.org>\r\n" ~
        "Subject: second\r\n\r\n" ~
        "beta\r\n";

    auto expected = parseMbox(sample);

    auto file = File.tmpfile();
    file.rawWrite(cast(const(ubyte)[]) sample);
    file.flush();

    MboxRecord[] streamed;
    scanMbox(file, (in MboxRecord record) {
        streamed ~= record;
        if (streamed.length == 1)
            file.seek(0); // scanner must recover from callback inspection seeks
    });

    assert(streamed.length == expected.length);
    foreach (i; 0 .. streamed.length) {
        assert(streamed[i].envelopeRange == expected[i].envelopeRange);
        assert(streamed[i].messageRange == expected[i].messageRange);
        assert(streamed[i].headerRange == expected[i].headerRange);
        assert(streamed[i].bodyRange == expected[i].bodyRange);
    }
}
