module spec_list_plan_betterc;

import core.stdc.stdio :
    FILE,
    fclose,
    ferror,
    fopen,
    fprintf,
    printf,
    stderr;
import core.stdc.stdlib : free;
import core.sys.posix.stdio : getline;
import core.sys.posix.sys.types : ssize_t;

private char asciiLower(char c) nothrow @nogc
{
    if (c >= 'A' && c <= 'Z')
        return cast(char)(c + ('a' - 'A'));
    return c;
}

private bool startsWith(
    const(char)* line,
    size_t length,
    const(char)* prefix,
    size_t prefixLength
) nothrow @nogc
{
    if (length < prefixLength)
        return false;

    foreach (i; 0 .. prefixLength)
        if (line[i] != prefix[i])
            return false;

    return true;
}

private bool asciiEqualInsensitive(
    const(char)* left,
    size_t leftLength,
    const(char)* right,
    size_t rightLength
) nothrow @nogc
{
    if (leftLength != rightLength)
        return false;

    foreach (i; 0 .. leftLength)
        if (asciiLower(left[i]) != asciiLower(right[i]))
            return false;

    return true;
}

private bool asciiContainsInsensitive(
    const(char)* haystack,
    size_t haystackLength,
    const(char)* needle,
    size_t needleLength
) nothrow @nogc
{
    if (needleLength == 0)
        return true;
    if (haystackLength < needleLength)
        return false;

    foreach (start; 0 .. haystackLength - needleLength + 1) {
        bool same = true;
        foreach (i; 0 .. needleLength) {
            if (asciiLower(haystack[start + i]) != asciiLower(needle[i])) {
                same = false;
                break;
            }
        }
        if (same)
            return true;
    }

    return false;
}

private bool selectedHeaderName(
    const(char)* name,
    size_t length
) nothrow @nogc
{
    static immutable from = "From";
    static immutable sender = "Sender";
    static immutable replyTo = "Reply-To";
    static immutable to = "To";
    static immutable cc = "Cc";
    static immutable subject = "Subject";

    return
        asciiEqualInsensitive(name, length, from.ptr, from.length) ||
        asciiEqualInsensitive(name, length, sender.ptr, sender.length) ||
        asciiEqualInsensitive(name, length, replyTo.ptr, replyTo.length) ||
        asciiEqualInsensitive(name, length, to.ptr, to.length) ||
        asciiEqualInsensitive(name, length, cc.ptr, cc.length) ||
        asciiEqualInsensitive(name, length, subject.ptr, subject.length);
}

private bool blankLine(const(char)* line, size_t length) nothrow @nogc
{
    return
        (length == 1 && line[0] == '\n') ||
        (length == 2 && line[0] == '\r' && line[1] == '\n');
}

private size_t headerColon(const(char)* line, size_t length) nothrow @nogc
{
    foreach (i; 0 .. length) {
        if (line[i] == ':')
            return i;
        if (line[i] == '\r' || line[i] == '\n')
            break;
    }
    return size_t.max;
}

private void emitMatch(
    size_t messageNumber,
    size_t entryStart,
    size_t entryEnd,
    ref size_t matched
) nothrow @nogc
{
    ++matched;
    printf("%zu\t%zu\t%zu\n", messageNumber, entryStart, entryEnd);
}

extern(C) int main(int argc, char** argv) nothrow @nogc
{
    static immutable defaultMailbox = "/var/mail/isomorphisms";
    static immutable readMode = "rb";
    static immutable envelopePrefix = "From ";
    static immutable pattern = "SPEC-LIST";

    if (argc > 2) {
        fprintf(stderr, "usage: spec-list-plan-betterc [MBOX]\n");
        return 2;
    }

    const(char)* path =
        argc == 2 ? cast(const(char)*) argv[1] : defaultMailbox.ptr;

    FILE* source = fopen(path, readMode.ptr);
    if (source is null) {
        fprintf(stderr, "spec-list-plan-betterc: cannot open mailbox\n");
        return 1;
    }
    scope(exit) fclose(source);

    char* line = null;
    size_t capacity;
    scope(exit) free(line);

    size_t offset;
    size_t entryStart;
    size_t messageNumber;
    size_t matched;
    bool inEntry;
    bool inHeaders;
    bool selectedCurrentHeader;
    bool entryMatches;

    while (true) {
        const ssize_t count = getline(&line, &capacity, source);
        if (count < 0)
            break;

        const size_t length = cast(size_t) count;
        const size_t lineStart = offset;
        offset += length;

        if (startsWith(
                line,
                length,
                envelopePrefix.ptr,
                envelopePrefix.length
            )) {
            if (inEntry && entryMatches)
                emitMatch(
                    messageNumber,
                    entryStart,
                    lineStart,
                    matched
                );

            ++messageNumber;
            entryStart = lineStart;
            inEntry = true;
            inHeaders = true;
            selectedCurrentHeader = false;
            entryMatches = false;
            continue;
        }

        if (!inEntry || !inHeaders)
            continue;

        if (blankLine(line, length)) {
            inHeaders = false;
            selectedCurrentHeader = false;
            continue;
        }

        if (line[0] == ' ' || line[0] == '\t') {
            if (selectedCurrentHeader &&
                asciiContainsInsensitive(
                    line,
                    length,
                    pattern.ptr,
                    pattern.length
                ))
                entryMatches = true;
            continue;
        }

        const size_t colon = headerColon(line, length);
        if (colon == size_t.max) {
            selectedCurrentHeader = false;
            continue;
        }

        selectedCurrentHeader =
            selectedHeaderName(line, colon);

        if (selectedCurrentHeader &&
            asciiContainsInsensitive(
                line + colon + 1,
                length - colon - 1,
                pattern.ptr,
                pattern.length
            ))
            entryMatches = true;
    }

    if (ferror(source)) {
        fprintf(stderr, "spec-list-plan-betterc: mailbox read failed\n");
        return 1;
    }

    if (inEntry && entryMatches)
        emitMatch(
            messageNumber,
            entryStart,
            offset,
            matched
        );

    fprintf(stderr, "matched: %zu\n", matched);
    return 0;
}

unittest
{
    static immutable mixed = "sPeC-lIsT";
    static immutable pattern = "SPEC-LIST";
    assert(asciiContainsInsensitive(
        mixed.ptr,
        mixed.length,
        pattern.ptr,
        pattern.length
    ));

    static immutable subject = "Subject";
    assert(selectedHeaderName(subject.ptr, subject.length));

    static immutable wrong = "X-Spec-List";
    assert(!selectedHeaderName(wrong.ptr, wrong.length));
}
