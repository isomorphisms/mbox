module mbox_conformance;

import std.conv : to;\nimport std.exception : enforce;
import std.file;
import std.regex : regex;\nimport std.string : indexOf;
import std.stdio : File, stdout;

import mbox :
    Address,
    ByteRange,
    FrameEvent,
    HeaderField,
    MessageView,
    addrSpecMatchesDomainFold,
    frameMboxBytes,
    frameMboxChunks,
    headerValues,
    parseHeaderBlock,
    parseMbox,
    recipients;

import mbox_file : selectMessages;

private string loadBytes(string path)
{
    return cast(string) std.file.read(path);
}

private string slice(scope const(char)[] bytes, ByteRange range)
{
    enforce(range.end >= range.start);
    enforce(range.end <= bytes.length);
    return bytes[cast(size_t) range.start .. cast(size_t) range.end].idup;
}

private void requireCase(bool condition, string caseId, string detail)
{
    enforce(condition, caseId ~ ": " ~ detail);
}

private void pass(string caseId, string evidence)
{
    stdout.write(caseId, "\tPASS\t", evidence, "\n");
}

private void expectRange(
    scope const ByteRange actual,
    ulong start,
    ulong end,
    string caseId
)
{
    requireCase(
        actual.start == start && actual.end == end,
        caseId,
        "unexpected byte range"
    );
}

private string onlyHeader(scope const MessageView message, string name, string caseId)
{
    auto values = headerValues(message, name);
    requireCase(values.length == 1, caseId, "expected exactly one header");
    return values[0];
}

private HeaderField findField(
    scope const MessageView message,
    string name,
    string caseId
)
{
    foreach (field; message.headers)
        if (!field.malformed && field.name == name)
            return field;
    throw new Exception(caseId ~ ": missing header " ~ name);
}

private void expectAddress(
    scope const Address actual,
    string display,
    string addrSpec,
    string caseId
)
{
    requireCase(actual.displayName == display, caseId, "display name mismatch");
    requireCase(actual.addrSpec == addrSpec, caseId, "addr-spec mismatch");
}

private string readRange(ref File source, ByteRange range)
{
    enforce(range.end >= range.start);
    enforce(range.length <= size_t.max);

    source.seek(cast(long) range.start);
    auto bytes = new char[](cast(size_t) range.length);
    auto got = source.rawRead(bytes);
    enforce(got.length == bytes.length, "short read");
    return cast(string) bytes;
}

private string messageIdForRecord(ref File source, ByteRange headerRange)
{
    const headerBytes = readRange(source, headerRange);
    const fields = parseHeaderBlock(headerBytes);

    foreach (field; fields)
        if (!field.malformed && field.name == "message-id")
            return field.unfoldedValue;

    throw new Exception("selected record has no Message-ID");
}

private void framingCases()
{
    {
        const bytes = loadBytes("fixtures/empty.mbox");
        const messages = parseMbox(bytes);
        requireCase(messages.length == 0, "framing.empty", "empty mailbox parsed a message");
        pass("framing.empty", "fixtures/empty.mbox parsed as zero messages");
    }

    {
        const bytes = loadBytes("fixtures/mboxo-lf.mbox");
        const messages = parseMbox(bytes);
        requireCase(messages.length == 3, "framing.lf-ranges", "expected three LF messages");

        expectRange(messages[0].envelopeRange, 0, 46, "framing.lf-ranges");
        expectRange(messages[0].messageRange, 46, 250, "framing.lf-ranges");
        expectRange(messages[1].envelopeRange, 250, 296, "framing.lf-ranges");
        expectRange(messages[1].messageRange, 296, 396, "framing.lf-ranges");
        expectRange(messages[2].envelopeRange, 396, 444, "framing.lf-ranges");
        expectRange(messages[2].messageRange, 444, 568, "framing.lf-ranges");
        pass("framing.lf-ranges", "published LF byte ranges matched");

        requireCase(
            onlyHeader(messages[0], "Content-Length", "framing.content-length-ignored") == "1",
            "framing.content-length-ignored",
            "fixture Content-Length changed"
        );
        requireCase(
            messages[0].messageRange.end == 250,
            "framing.content-length-ignored",
            "Content-Length affected mbox framing"
        );
        pass("framing.content-length-ignored", "Content-Length did not affect entry boundary");

        const firstBody = slice(bytes, messages[0].bodyRange);
        requireCase(
            firstBody.indexOf(">From this is escaped body data") >= 0 &&
            firstBody.indexOf(">>From this also stays body data") >= 0,
            "framing.escaped-from-preserved",
            "escaped From body bytes not preserved"
        );
        pass("framing.escaped-from-preserved", ">From and >>From remained body data");

        requireCase(
            messages[1].bodyRange.start == messages[1].bodyRange.end,
            "framing.empty-body",
            "second LF message body was not empty"
        );
        pass("framing.empty-body", "empty body retained as zero-byte body range");

        requireCase(
            messages[2].messageRange.end == bytes.length &&
            bytes[$ - 1] == 'e',
            "framing.eof-no-newline",
            "EOF-without-newline boundary changed"
        );
        pass("framing.eof-no-newline", "last message ended exactly at EOF");

        const whole = frameMboxBytes(bytes);
        foreach (split; 0 .. bytes.length + 1) {
            const chunked = frameMboxChunks(
                bytes[0 .. split],
                bytes[split .. $]
            );
            requireCase(
                chunked == whole,
                "streaming.chunk-equivalence",
                "framing changed at split " ~ split.to!string
            );
        }
        pass("streaming.chunk-equivalence", "all split points matched whole-buffer framing");
    }

    {
        const bytes = loadBytes("fixtures/mboxo-crlf.mbox");
        const messages = parseMbox(bytes);
        requireCase(messages.length == 2, "framing.crlf-ranges", "expected two CRLF messages");
        expectRange(messages[0].envelopeRange, 0, 49, "framing.crlf-ranges");
        expectRange(messages[0].messageRange, 49, 178, "framing.crlf-ranges");
        expectRange(messages[1].envelopeRange, 178, 227, "framing.crlf-ranges");
        expectRange(messages[1].messageRange, 227, 333, "framing.crlf-ranges");
        pass("framing.crlf-ranges", "published CRLF byte ranges matched");
    }

    {
        const bytes = loadBytes("fixtures/unescaped-from-splits.mbox");
        const messages = parseMbox(bytes);
        requireCase(
            messages.length == 2,
            "framing.unescaped-from-splits",
            "line-leading From did not split entry"
        );
        expectRange(messages[0].envelopeRange, 0, 48, "framing.unescaped-from-splits");
        expectRange(messages[0].messageRange, 48, 157, "framing.unescaped-from-splits");
        expectRange(messages[1].envelopeRange, 157, 208, "framing.unescaped-from-splits");
        expectRange(messages[1].messageRange, 208, 275, "framing.unescaped-from-splits");
        pass("framing.unescaped-from-splits", "raw mboxo From line split exactly as specified");
    }
}

private void headerCases()
{
    const bytes = loadBytes("fixtures/header-corners.mbox");
    const messages = parseMbox(bytes);
    requireCase(messages.length == 4, "headers.case-insensitive", "expected four messages");

    requireCase(
        onlyHeader(messages[0], "subject", "headers.case-insensitive") ==
            onlyHeader(messages[0], "SUBJECT", "headers.case-insensitive"),
        "headers.case-insensitive",
        "header lookup was case-sensitive"
    );
    pass("headers.case-insensitive", "mixed-case names matched ASCII-insensitively");

    requireCase(
        onlyHeader(messages[0], "subject", "headers.fold") ==
            "folded with spaces and tab",
        "headers.fold",
        "folded Subject unfolded incorrectly"
    );
    pass("headers.fold", "folded Subject unfolded to one logical value");

    requireCase(
        headerValues(messages[0], "to").length == 2 &&
        headerValues(messages[0], "cc").length == 2,
        "headers.repeated",
        "repeated To/Cc fields were collapsed"
    );
    pass("headers.repeated", "repeated fields retained order and multiplicity");

    requireCase(
        onlyHeader(messages[0], "x-empty", "headers.empty-value").length == 0 &&
        onlyHeader(messages[2], "subject", "headers.empty-value").length == 0,
        "headers.empty-value",
        "empty header value was not preserved"
    );
    pass("headers.empty-value", "empty values remained empty");

    requireCase(
        onlyHeader(messages[0], "x-colon", "headers.colon-in-value") ==
            "left:right:still-value",
        "headers.colon-in-value",
        "colons after the first were lost"
    );
    pass("headers.colon-in-value", "colon-bearing value preserved");

    bool foundMalformed;
    foreach (field; messages[1].headers) {
        if (!field.malformed)
            continue;
        foundMalformed = true;
        requireCase(
            slice(bytes, field.raw) == "Broken header line without colon\n",
            "headers.malformed-preserved",
            "malformed raw bytes changed"
        );
    }
    requireCase(foundMalformed, "headers.malformed-preserved", "malformed header not reported");
    pass("headers.malformed-preserved", "malformed physical header retained as raw defect");

    const preserve = loadBytes("fixtures/copy-preservation.mbox");
    const preservedMessages = parseMbox(preserve);
    requireCase(
        preservedMessages.length == 1,
        "headers.raw-byte-preservation",
        "copy fixture did not parse as one message"
    );

    const subject = findField(
        preservedMessages[0],
        "subject",
        "headers.raw-byte-preservation"
    );
    requireCase(
        slice(preserve, subject.raw) ==
            "Subject: keep raw folding\n\tfirst continuation\n  second continuation  \n",
        "headers.raw-byte-preservation",
        "raw folded Subject bytes changed"
    );

    const weird = findField(
        preservedMessages[0],
        "x-weird",
        "headers.raw-byte-preservation"
    );
    requireCase(
        slice(preserve, weird.raw) == "X-Weird: a  b\tc\n",
        "headers.raw-byte-preservation",
        "raw whitespace bytes changed"
    );
    pass("headers.raw-byte-preservation", "raw field ranges reproduce fixture bytes exactly");
}

private void addressCases()
{
    const bytes = loadBytes("fixtures/address-view.mbox");
    const messages = parseMbox(bytes);
    requireCase(messages.length == 2, "addresses.bare-and-display", "expected two messages");

    const one = recipients(messages[0]);
    requireCase(one.length == 4, "addresses.bare-and-display", "first recipient count mismatch");
    expectAddress(one[0], "", "bare@example.org", "addresses.bare-and-display");
    expectAddress(one[1], "Display Name", "display@example.net", "addresses.bare-and-display");
    pass("addresses.bare-and-display", "bare and display-name mailboxes parsed");

    expectAddress(one[2], "Doe, Jane", "jane@example.com", "addresses.quoted-comma");
    expectAddress(one[3], "John", "john@EXAMPLE.COM", "addresses.quoted-comma");
    requireCase(
        addrSpecMatchesDomainFold("john@EXAMPLE.COM", "john@example.com"),
        "addresses.quoted-comma",
        "domain case-fold comparison failed"
    );
    pass("addresses.quoted-comma", "quoted comma and domain spelling handled");

    const two = recipients(messages[1]);
    requireCase(two.length == 5, "addresses.folded-repeated", "second recipient count mismatch");
    expectAddress(two[0], "", "first@example.org", "addresses.folded-repeated");
    expectAddress(two[1], "", "second@example.org", "addresses.folded-repeated");
    expectAddress(two[2], "Comma, Name", "third@example.org", "addresses.folded-repeated");
    expectAddress(two[3], "", "fourth@example.org", "addresses.folded-repeated");
    expectAddress(two[4], "Fifth Person", "fifth@example.org", "addresses.folded-repeated");
    pass("addresses.folded-repeated", "folded and repeated address fields retained all mailboxes");
}

private void selectionCases()
{
    auto source = File("fixtures/spec-list-selection.mbox", "rb");

    bool[string] wantedHeaders;
    foreach (name; ["from", "sender", "reply-to", "to", "cc", "subject"])
        wantedHeaders[name] = true;

    auto matcher = regex("SPEC-LIST", "i");
    const selected = selectMessages(source, wantedHeaders, matcher);

    requireCase(
        selected.length == 9,
        "selection.spec-list-positive",
        "expected exactly nine selected entries"
    );

    string[] ids;
    foreach (record; selected)
        ids ~= messageIdForRecord(source, record.headerRange);

    const expected = [
        "<from-match@example.org>",
        "<sender-match@example.org>",
        "<reply-fold-match@example.org>",
        "<to-match@example.org>",
        "<cc-match@example.org>",
        "<subject-match@example.org>",
        "<case-match@example.org>",
        "<folded-subject@example.org>",
        "<repeated-to@example.org>",
    ];

    requireCase(ids == expected, "selection.spec-list-positive", "selected Message-ID sequence differed");
    pass("selection.spec-list-positive", "all nine policy-positive entries selected in source order");

    requireCase(
        !("<body-only@example.org>" in ids),
        "selection.body-only-negative",
        "body-only mention selected"
    );
    pass("selection.body-only-negative", "body-only SPEC-LIST mention did not select");

    foreach (wrong; [
        "<x-list-only@example.org>",
        "<delivered-only@example.org>",
        "<wrong-header@example.org>",
    ]) {
        bool present;
        foreach (id; ids)
            if (id == wrong)
                present = true;
        requireCase(!present, "selection.wrong-header-negative", wrong ~ " selected");
    }
    pass("selection.wrong-header-negative", "unsearched headers did not select");
}

int main()
{
    framingCases();
    headerCases();
    addressCases();
    selectionCases();
    return 0;
}
