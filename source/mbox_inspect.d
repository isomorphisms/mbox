module mbox_inspect;

import std.conv : to;
import std.exception : enforce;
import std.getopt : defaultGetoptPrinter, getopt;
import std.stdio : File, stderr, stdout;

import mbox :
    ByteRange,
    HeaderField,
    MboxRecord,
    parseHeaderBlock,
    scanMbox;

enum maxHeaderBytes = 4UL * 1024 * 1024;

private string asciiLowerCopy(scope const(char)[] value)
{
    auto out = new char[](value.length);
    foreach (i, c; value) {
        if (c >= 'A' && c <= 'Z')
            out[i] = cast(char)(c + ('a' - 'A'));
        else
            out[i] = c;
    }
    return cast(string) out;
}

private string readRange(ref File source, ByteRange range)
{
    enforce(range.length <= maxHeaderBytes,
        "mbox-inspect: unreasonably large header at byte " ~
        to!string(range.start));
    enforce(range.length <= size_t.max,
        "mbox-inspect: header block is too large for this process");

    source.seek(cast(long) range.start);
    auto bytes = new char[](cast(size_t) range.length);
    auto got = source.rawRead(bytes);
    enforce(got.length == bytes.length,
        "mbox-inspect: short read while reading headers");
    return cast(string) bytes;
}

private string tsvEscape(scope const(char)[] value)
{
    char[] out;
    foreach (c; value) {
        switch (c) {
        case '\\':
            out ~= "\\\\";
            break;
        case '\t':
            out ~= "\\t";
            break;
        case '\r':
            out ~= "\\r";
            break;
        case '\n':
            out ~= "\\n";
            break;
        default:
            out ~= c;
        }
    }
    return cast(string) out;
}

private bool wanted(
    scope const HeaderField field,
    ref bool[string] selectedHeaders,
    bool allHeaders
)
{
    if (field.malformed)
        return false;
    if (allHeaders)
        return true;
    return (field.name in selectedHeaders) !is null;
}

int main(string[] arguments)
{
    string sourcePath;
    string[] headerNames;
    bool allHeaders;
    bool defectsOnly;

    try {
        auto options = getopt(
            arguments,
            "source", &sourcePath,
            "header", &headerNames,
            "all-headers", &allHeaders,
            "defects-only", &defectsOnly
        );

        if (options.helpWanted) {
            defaultGetoptPrinter(
                "mbox-inspect --source PATH [--header NAME ... | --all-headers] [--defects-only]",
                options.options
            );
            return 0;
        }

        enforce(arguments.length == 1,
            "mbox-inspect: unexpected positional arguments");
        enforce(sourcePath.length != 0,
            "mbox-inspect: --source is required");
        enforce(!(allHeaders && headerNames.length != 0),
            "mbox-inspect: use either --all-headers or --header, not both");

        if (!allHeaders && headerNames.length == 0)
            headerNames = ["From", "To", "Cc", "Subject", "Message-ID"];

        bool[string] selectedHeaders;
        foreach (name; headerNames)
            selectedHeaders[asciiLowerCopy(name)] = true;

        auto source = File(sourcePath, "rb");
        const initialSize = source.size;

        stdout.writeln(
            "kind\tmessage\tentry_start\tentry_end\tname\tvalue"
        );

        size_t messageNumber;
        scanMbox(source, (in MboxRecord record) {
            ++messageNumber;

            const headerBytes = readRange(source, record.headerRange);
            const fields = parseHeaderBlock(headerBytes);

            size_t defects;
            foreach (field; fields)
                if (field.malformed)
                    ++defects;

            if (defectsOnly) {
                foreach (field; fields) {
                    if (!field.malformed)
                        continue;
                    stdout.writefln(
                        "defect\t%s\t%s\t%s\tmalformed\t%s",
                        messageNumber,
                        record.wholeRange.start,
                        record.wholeRange.end,
                        tsvEscape(field.unfoldedValue)
                    );
                }
                return;
            }

            stdout.writefln(
                "message\t%s\t%s\t%s\tdefects\t%s",
                messageNumber,
                record.wholeRange.start,
                record.wholeRange.end,
                defects
            );

            foreach (field; fields) {
                if (!wanted(field, selectedHeaders, allHeaders))
                    continue;

                stdout.writefln(
                    "header\t%s\t%s\t%s\t%s\t%s",
                    messageNumber,
                    record.wholeRange.start,
                    record.wholeRange.end,
                    tsvEscape(field.name),
                    tsvEscape(field.unfoldedValue)
                );
            }
        });

        enforce(source.size == initialSize,
            "mbox-inspect: source mailbox changed during inspection; rerun");

        return 0;
    } catch (Exception error) {
        stderr.writeln(error.msg);
        return 1;
    }
}


unittest {
    assert(tsvEscape("a\tb\nc\\d") == "a\\tb\\nc\\\\d");
    assert(asciiLowerCopy("Message-ID") == "message-id");
}
