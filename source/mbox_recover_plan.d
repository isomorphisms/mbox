module mbox_recover_plan;

import std.algorithm.comparison : min;
import std.conv : to;
import std.digest : toHexString;
import std.digest.sha : SHA256;
import std.exception : enforce;
import std.file : readText;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : buildPath, dirName, isAbsolute;
import std.stdio : File, stderr, stdout;
import std.string : toLower;

import mbox : ByteRange;

enum ioChunk = 1024 * 1024;

private ulong jsonUlong(scope const JSONValue value)
{
    final switch (value.type)
    {
    case JSONType.integer:
        enforce(value.integer >= 0, "negative byte count in journal");
        return cast(ulong) value.integer;
    case JSONType.uinteger:
        return value.uinteger;
    default:
        throw new Exception("journal byte count is not an integer");
    }
}

private string lowerHash(string value)
{
    return value.toLower;
}

private string hashRange(ref File file, ulong start, ulong end)
{
    enforce(end >= start, "invalid hash range");
    file.seek(cast(long) start);

    SHA256 digest;
    digest.start();

    auto buffer = new ubyte[](ioChunk);
    ulong remaining = end - start;

    while (remaining != 0)
    {
        const wanted = cast(size_t) min(
            remaining,
            cast(ulong) buffer.length
        );
        auto got = file.rawRead(buffer[0 .. wanted]);
        enforce(got.length == wanted, "short read while hashing mailbox");
        digest.put(got);
        remaining -= got.length;
    }

    return toHexString(digest.finish()).toLower;
}

private string resolveObservedPath(string journalPath, string observed)
{
    if (isAbsolute(observed))
        return observed;
    return buildPath(dirName(journalPath), observed);
}

private ByteRange[] selectedRanges(scope const JSONValue root)
{
    ByteRange[] ranges;

    foreach (entry; root["selected"].array)
    {
        const pair = entry["source_range"].array;
        enforce(pair.length == 2, "selected source_range must contain two offsets");

        const start = jsonUlong(pair[0]);
        const end = jsonUlong(pair[1]);
        enforce(end >= start, "selected source_range is reversed");

        ranges ~= ByteRange(start, end);
    }

    foreach (i; 1 .. ranges.length)
        enforce(
            ranges[i - 1].end <= ranges[i].start,
            "selected source ranges are not ordered"
        );

    return ranges;
}

private ulong totalSelectedBytes(scope const ByteRange[] ranges)
{
    ulong total;
    foreach (range; ranges)
        total += range.length;
    return total;
}

private bool compareExpectedArchivePrefix(
    ref File source,
    ref File archive,
    scope const ByteRange[] selected,
    ulong archiveStart,
    ulong bytesToCompare
)
{
    auto sourceBuffer = new ubyte[](ioChunk);
    auto archiveBuffer = new ubyte[](ioChunk);

    ulong archiveOffset = archiveStart;
    ulong remaining = bytesToCompare;

    foreach (range; selected)
    {
        if (remaining == 0)
            break;

        ulong sourceOffset = range.start;
        ulong occurrenceRemaining = min(range.length, remaining);

        while (occurrenceRemaining != 0)
        {
            const wanted = cast(size_t) min(
                occurrenceRemaining,
                cast(ulong) sourceBuffer.length
            );

            source.seek(cast(long) sourceOffset);
            archive.seek(cast(long) archiveOffset);

            auto sourceGot = source.rawRead(sourceBuffer[0 .. wanted]);
            auto archiveGot = archive.rawRead(archiveBuffer[0 .. wanted]);

            if (sourceGot.length != wanted || archiveGot.length != wanted)
                return false;
            if (sourceGot != archiveGot)
                return false;

            sourceOffset += wanted;
            archiveOffset += wanted;
            occurrenceRemaining -= wanted;
            remaining -= wanted;
        }
    }

    return remaining == 0;
}

struct RecoveryPlan
{
    string action;
    ulong sourceSnapshotBytes;
    ulong sourceTailBytes;
    ulong archiveBaselineBytes;
    ulong transactionBytesPresent;
    ulong transactionBytesExpected;
}

RecoveryPlan inspectRecovery(string journalPath)
{
    const root = parseJSON(readText(journalPath));

    enforce(root["version"].integer == 1, "unsupported journal version");

    const sourcePath = resolveObservedPath(
        journalPath,
        root["observed_state"]["source"].str
    );
    const archivePath = resolveObservedPath(
        journalPath,
        root["observed_state"]["archive"].str
    );

    const sourceSnapshotBytes =
        jsonUlong(root["source_snapshot"]["bytes"]);
    const sourceSnapshotHash =
        lowerHash(root["source_snapshot"]["sha256"].str);

    const archiveBaselineBytes =
        jsonUlong(root["archive_baseline"]["bytes"]);
    const archiveBaselineHash =
        lowerHash(root["archive_baseline"]["sha256"].str);

    const selected = selectedRanges(root);
    const expectedAppendBytes = totalSelectedBytes(selected);

    auto source = File(sourcePath, "rb");
    auto archive = File(archivePath, "rb");

    const currentSourceBytes = cast(ulong) source.size;
    const currentArchiveBytes = cast(ulong) archive.size;

    if (currentSourceBytes < sourceSnapshotBytes)
        return RecoveryPlan(
            "refuse",
            sourceSnapshotBytes,
            0,
            archiveBaselineBytes,
            0,
            expectedAppendBytes
        );

    if (currentArchiveBytes < archiveBaselineBytes)
        return RecoveryPlan(
            "refuse",
            sourceSnapshotBytes,
            currentSourceBytes - sourceSnapshotBytes,
            archiveBaselineBytes,
            0,
            expectedAppendBytes
        );

    if (hashRange(source, 0, sourceSnapshotBytes) != sourceSnapshotHash)
        return RecoveryPlan(
            "refuse",
            sourceSnapshotBytes,
            currentSourceBytes - sourceSnapshotBytes,
            archiveBaselineBytes,
            0,
            expectedAppendBytes
        );

    if (hashRange(archive, 0, archiveBaselineBytes) != archiveBaselineHash)
        return RecoveryPlan(
            "refuse",
            sourceSnapshotBytes,
            currentSourceBytes - sourceSnapshotBytes,
            archiveBaselineBytes,
            0,
            expectedAppendBytes
        );

    const archiveTailBytes = currentArchiveBytes - archiveBaselineBytes;
    const transactionBytesPresent = min(
        archiveTailBytes,
        expectedAppendBytes
    );

    if (!compareExpectedArchivePrefix(
            source,
            archive,
            selected,
            archiveBaselineBytes,
            transactionBytesPresent
        ))
        return RecoveryPlan(
            "refuse",
            sourceSnapshotBytes,
            currentSourceBytes - sourceSnapshotBytes,
            archiveBaselineBytes,
            transactionBytesPresent,
            expectedAppendBytes
        );

    if (transactionBytesPresent < expectedAppendBytes)
    {
        enforce(
            archiveTailBytes == transactionBytesPresent,
            "unreachable archive tail classification"
        );
        return RecoveryPlan(
            "recover",
            sourceSnapshotBytes,
            currentSourceBytes - sourceSnapshotBytes,
            archiveBaselineBytes,
            transactionBytesPresent,
            expectedAppendBytes
        );
    }

    const sourceTailBytes = currentSourceBytes - sourceSnapshotBytes;

    return RecoveryPlan(
        sourceTailBytes == 0
            ? "finish_source"
            : "finish_source_preserve_tail",
        sourceSnapshotBytes,
        sourceTailBytes,
        archiveBaselineBytes,
        transactionBytesPresent,
        expectedAppendBytes
    );
}

int main(string[] arguments)
{
    try
    {
        enforce(
            arguments.length == 2,
            "usage: mbox-recover-plan JOURNAL.json"
        );

        const plan = inspectRecovery(arguments[1]);

        stdout.writeln("action\t", plan.action);
        stdout.writeln(
            "source_snapshot_bytes\t",
            plan.sourceSnapshotBytes
        );
        stdout.writeln("source_tail_bytes\t", plan.sourceTailBytes);
        stdout.writeln(
            "archive_baseline_bytes\t",
            plan.archiveBaselineBytes
        );
        stdout.writeln(
            "transaction_bytes_present\t",
            plan.transactionBytesPresent
        );
        stdout.writeln(
            "transaction_bytes_expected\t",
            plan.transactionBytesExpected
        );

        return plan.action == "refuse" ? 2 : 0;
    }
    catch (Exception error)
    {
        stderr.writeln(error.msg);
        return 1;
    }
}
