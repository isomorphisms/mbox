module mbox_file;

import core.stdc.stdio : SEEK_END;
import core.sys.posix.fcntl : O_CREAT, O_EXCL, O_RDONLY, O_RDWR, O_WRONLY, open;
import core.sys.posix.sys.stat : S_IRUSR, S_IWUSR, fstat, stat_t;
import core.sys.posix.unistd : close, fsync;

import std.algorithm : min;
import std.conv : to;
import std.exception : enforce;
import std.file :
    exists,
    getAttributes,
    getAvailableDiskSpace,
    remove,
    rename,
    setAttributes;
import std.getopt : defaultGetoptPrinter, getopt;
import std.path : dirName;
import std.process : environment, thisProcessID;
import std.regex : matchFirst, regex;
import std.stdio : File, LockType, stderr, stdout;
import std.string : toStringz;

import mbox :
    ByteOffset,
    ByteRange,
    MboxRecord,
    parseHeaderBlock,
    scanMbox;

enum rewriteHeadroom = 64UL * 1024 * 1024;
enum maxHeaderBytes = 4UL * 1024 * 1024;
enum ioChunk = 1024 * 1024;

struct DotLock {
    string path;
    bool held;
}

private string expandUser(string path)
{
    if (path.length >= 2 && path[0 .. 2] == "~/") {
        const home = environment.get("HOME");
        enforce(home !is null && home.length != 0,
            "mbox-file: HOME is not set");
        return home ~ path[1 .. $];
    }
    return path;
}

private string asciiLowerCopy(scope const(char)[] value)
{
    auto result = new char[](value.length);
    foreach (i, c; value) {
        if (c >= 'A' && c <= 'Z')
            result[i] = cast(char)(c + ('a' - 'A'));
        else
            result[i] = c;
    }
    return cast(string) result;
}

private string readRange(ref File source, ByteRange range)
{
    enforce(range.length <= size_t.max,
        "mbox-file: header block is too large for this process");

    source.seek(cast(long) range.start);
    auto bytes = new char[](cast(size_t) range.length);
    auto got = source.rawRead(bytes);
    enforce(got.length == bytes.length,
        "mbox-file: short read while reading headers");
    return cast(string) bytes;
}

private void copyRange(
    ref File source,
    ref File sink,
    ByteOffset start,
    ByteOffset end
)
{
    enforce(end >= start, "mbox-file: invalid byte range");

    source.seek(cast(long) start);
    auto buffer = new ubyte[](ioChunk);
    ByteOffset remaining = end - start;

    while (remaining != 0) {
        const wanted = cast(size_t) min(
            remaining,
            cast(ByteOffset) buffer.length
        );
        auto got = source.rawRead(buffer[0 .. wanted]);
        enforce(got.length == wanted,
            "mbox-file: short read while copying mailbox");
        sink.rawWrite(got);
        remaining -= got.length;
    }
}

private bool sameFile(ref File a, ref File b)
{
    stat_t left;
    stat_t right;
    enforce(fstat(a.fileno, &left) == 0,
        "mbox-file: cannot stat source mailbox");
    enforce(fstat(b.fileno, &right) == 0,
        "mbox-file: cannot stat archive mailbox");
    return left.st_dev == right.st_dev && left.st_ino == right.st_ino;
}

private File createExclusive(string path)
{
    const fd = open(
        toStringz(path),
        O_CREAT | O_EXCL | O_RDWR,
        S_IRUSR | S_IWUSR
    );
    enforce(fd >= 0, "mbox-file: cannot create " ~ path);

    File result;
    try {
        result.fdopen(fd, "w+b");
    } catch (Exception error) {
        close(fd);
        throw error;
    }
    return result;
}

private void acquireDotLock(ref DotLock lock, string mailbox)
{
    lock.path = mailbox ~ ".lock";
    const fd = open(
        toStringz(lock.path),
        O_CREAT | O_EXCL | O_WRONLY,
        S_IRUSR | S_IWUSR
    );
    enforce(fd >= 0,
        "mbox-file: mailbox dotlock already exists or cannot be created: " ~
        lock.path);
    close(fd);
    lock.held = true;
}

private void releaseDotLock(ref DotLock lock)
{
    if (!lock.held)
        return;

    try {
        if (exists(lock.path))
            remove(lock.path);
    } catch (Exception) {
        // Cleanup failure is reported by the caller's next mailbox operation;
        // do not mask an earlier exception.
    }
    lock.held = false;
}

private void syncFile(ref File file, string description)
{
    file.flush();
    enforce(fsync(file.fileno) == 0,
        "mbox-file: fsync failed for " ~ description);
}

private void syncParentDirectory(string path)
{
    auto parent = dirName(path);
    if (parent.length == 0)
        parent = ".";

    const fd = open(toStringz(parent), O_RDONLY);
    enforce(fd >= 0,
        "mbox-file: cannot open parent directory for fsync: " ~ parent);
    scope(exit) close(fd);

    enforce(fsync(fd) == 0,
        "mbox-file: fsync failed for parent directory: " ~ parent);
}

private void requireSameOwnerGroup(
    ref File source,
    ref File replacement
)
{
    stat_t oldStat;
    stat_t newStat;
    enforce(fstat(source.fileno, &oldStat) == 0,
        "mbox-file: cannot stat source mailbox");
    enforce(fstat(replacement.fileno, &newStat) == 0,
        "mbox-file: cannot stat replacement mailbox");
    enforce(
        oldStat.st_uid == newStat.st_uid &&
        oldStat.st_gid == newStat.st_gid,
        "mbox-file: adjacent replacement would change source owner/group; refusing"
    );
}

private void probeRewrite(ref File source, string sourcePath)
{
    const probePath =
        sourcePath ~ ".mbox-file-probe." ~ to!string(thisProcessID());

    auto probe = createExclusive(probePath);
    scope(exit) {
        if (probe.isOpen)
            probe.close();
        if (exists(probePath))
            remove(probePath);
    }

    requireSameOwnerGroup(source, probe);
}

private bool recordMatches(R)(
    ref File source,
    in MboxRecord record,
    ref bool[string] wantedHeaders,
    ref R matcher
)
{
    enforce(record.headerRange.length <= maxHeaderBytes,
        "mbox-file: unreasonably large header at source byte " ~
        to!string(record.messageRange.start));

    const headerBytes = readRange(source, record.headerRange);
    const fields = parseHeaderBlock(headerBytes);

    foreach (field; fields) {
        if (field.malformed)
            continue;
        if ((field.name in wantedHeaders) is null)
            continue;
        if (matchFirst(field.unfoldedValue, matcher))
            return true;
    }
    return false;
}

MboxRecord[] selectMessages(R)(
    ref File source,
    ref bool[string] wantedHeaders,
    ref R matcher
)
{
    MboxRecord[] selected;

    scanMbox(source, (in MboxRecord record) {
        if (recordMatches(source, record, wantedHeaders, matcher))
            selected ~= record;
    });

    return selected;
}

private void printPlan(scope const MboxRecord[] selected)
{
    stdout.writeln("matched: ", selected.length);
    stdout.writeln("would append: ", selected.length);
    stdout.writeln("would remove from source: ", selected.length);
}

private void rewriteSource(
    ref File source,
    string sourcePath,
    scope const MboxRecord[] selected,
    ByteOffset sourceSize
)
{
    const tempPath =
        sourcePath ~ ".mbox-file-rewrite." ~ to!string(thisProcessID());

    auto temp = createExclusive(tempPath);
    bool keepTemp = true;
    scope(exit) {
        try {
            if (temp.isOpen)
                temp.close();
        } catch (Exception) {
        }
        if (keepTemp) {
            try {
                if (exists(tempPath))
                    remove(tempPath);
            } catch (Exception) {
            }
        }
    }

    requireSameOwnerGroup(source, temp);

    ByteOffset cursor;
    foreach (message; selected) {
        const whole = message.wholeRange;
        enforce(whole.start >= cursor && whole.end <= sourceSize,
            "mbox-file: selected ranges are not ordered");

        if (cursor < whole.start)
            copyRange(source, temp, cursor, whole.start);
        cursor = whole.end;
    }

    if (cursor < sourceSize)
        copyRange(source, temp, cursor, sourceSize);

    setAttributes(tempPath, getAttributes(sourcePath));
    syncFile(temp, "rewritten source mailbox");
    temp.close();

    rename(tempPath, sourcePath);
    syncParentDirectory(sourcePath);
    keepTemp = false;
}

private int runDry(
    string sourcePath,
    string archivePath,
    ref bool[string] wantedHeaders,
    string pattern,
    bool ignoreCase
)
{
    auto matcher = regex(pattern, ignoreCase ? "i" : "");
    auto source = File(sourcePath, "rb");
    const initialSourceSize = source.size;

    auto selected = selectMessages(source, wantedHeaders, matcher);

    enforce(source.size == initialSourceSize,
        "mbox-file: source mailbox changed during dry run; rerun");
    printPlan(selected);
    stdout.writeln("dry run: no mailbox bytes changed");
    return 0;
}

private int runMove(
    string sourcePath,
    string archivePath,
    ref bool[string] wantedHeaders,
    string pattern,
    bool ignoreCase
)
{
    auto matcher = regex(pattern, ignoreCase ? "i" : "");

    auto source = File(sourcePath, "r+b");
    bool sourceLocked;
    DotLock sourceDot;

    scope(exit) {
        releaseDotLock(sourceDot);
        if (sourceLocked) {
            try source.unlock();
            catch (Exception) {}
        }
    }

    source.lock(LockType.readWrite);
    sourceLocked = true;
    acquireDotLock(sourceDot, sourcePath);

    const sourceSize = cast(ByteOffset) source.size;
    auto selected = selectMessages(source, wantedHeaders, matcher);

    if (selected.length == 0) {
        stdout.writeln("matched: 0");
        stdout.writeln("nothing to move");
        return 0;
    }

    const available = getAvailableDiskSpace(sourcePath);
    enforce(available >= sourceSize + rewriteHeadroom,
        "mbox-file: not enough free space beside source mailbox; need source size + 64 MiB");

    probeRewrite(source, sourcePath);

    const archiveExisted = exists(archivePath);
    auto archive = File(archivePath, "a+b");
    enforce(!sameFile(source, archive),
        "mbox-file: source and archive are the same file");

    bool archiveLocked;
    DotLock archiveDot;

    scope(exit) {
        releaseDotLock(archiveDot);
        if (archiveLocked) {
            try archive.unlock();
            catch (Exception) {}
        }
    }

    archive.lock(LockType.readWrite);
    archiveLocked = true;
    acquireDotLock(archiveDot, archivePath);

    printPlan(selected);
    requireAppendBoundary(archive);

    archive.seek(0, SEEK_END);
    foreach (message; selected) {
        const whole = message.wholeRange;
        copyRange(source, archive, whole.start, whole.end);
    }

    // Source deletion is not allowed until every needed archive append is
    // flushed through the filesystem.
    syncFile(archive, "archive mailbox");
    if (!archiveExisted)
        syncParentDirectory(archivePath);

    rewriteSource(source, sourcePath, selected, sourceSize);

    // The old source descriptor still locks the old inode after rename.
    // Lock the replacement before dropping the dotlock, so an fcntl-only
    // mailbox writer cannot slip through the inode replacement boundary.
    auto replacement = File(sourcePath, "r+b");
    replacement.lock(LockType.readWrite);
    scope(exit) {
        try replacement.unlock();
        catch (Exception) {}
    }

    stdout.writeln("move complete");
    return 0;
}

int runMboxFile(string[] arguments)
{
    string sourcePath;
    string archivePath;
    string[] headerNames;
    string pattern;
    bool ignoreCase;
    bool move;

    try {
        auto options = getopt(
            arguments,
            "source", &sourcePath,
            "archive", &archivePath,
            "header", &headerNames,
            "pattern", &pattern,
            "ignore-case", &ignoreCase,
            "move", &move
        );

        if (options.helpWanted) {
            defaultGetoptPrinter(
                "mbox-file --source PATH --archive PATH --header NAME ... --pattern REGEX [--ignore-case] [--move]",
                options.options
            );
            return 0;
        }

        enforce(arguments.length == 1,
            "mbox-file: unexpected positional arguments");
        enforce(sourcePath.length != 0,
            "mbox-file: --source is required");
        enforce(archivePath.length != 0,
            "mbox-file: --archive is required");
        enforce(headerNames.length != 0,
            "mbox-file: at least one --header is required");
        enforce(pattern.length != 0,
            "mbox-file: --pattern is required");

        sourcePath = expandUser(sourcePath);
        archivePath = expandUser(archivePath);

        enforce(sourcePath != archivePath,
            "mbox-file: source and archive paths are the same");

        bool[string] wantedHeaders;
        foreach (name; headerNames)
            wantedHeaders[asciiLowerCopy(name)] = true;

        if (move)
            return runMove(
                sourcePath,
                archivePath,
                wantedHeaders,
                pattern,
                ignoreCase
            );

        return runDry(
            sourcePath,
            archivePath,
            wantedHeaders,
            pattern,
            ignoreCase
        );
    } catch (Exception error) {
        stderr.writeln(error.msg);
        return 1;
    }
}


unittest {
    enum sample =
        "From one@example.org Wed Sep 30 00:00:00 2026\n" ~
        "From: one@example.org\n" ~
        "To: SPEC-LIST <spec-list@example.org>\n" ~
        "Subject: ordinary\n\n" ~
        "body\n" ~
        "From two@example.org Wed Sep 30 00:01:00 2026\n" ~
        "From: two@example.org\n" ~
        "Subject: weekly Spec-List digest\n\n" ~
        "body\n" ~
        "From three@example.org Wed Sep 30 00:02:00 2026\n" ~
        "From: three@example.org\n" ~
        "List-Id: SPEC-LIST\n" ~
        "Subject: unrelated\n\n" ~
        "SPEC-LIST appears only in an unsearched header and body\n" ~
        "From four@example.org Wed Sep 30 00:03:00 2026\n" ~
        "From: four@example.org\n" ~
        "To: first@example.org\n" ~
        "To: second@example.org,\n" ~
        " SPEC-LIST <spec-list@example.org>\n" ~
        "Subject: folded repeated recipient\n\n" ~
        "body\n";

    auto source = File.tmpfile();
    source.rawWrite(sample);
    source.flush();

    bool[string] wantedHeaders;
    foreach (name; ["from", "sender", "reply-to", "to", "cc", "subject"])
        wantedHeaders[name] = true;

    auto matcher = regex("SPEC-LIST", "i");
    auto selected = selectMessages(source, wantedHeaders, matcher);

    assert(selected.length == 3);
    assert(selected[0].envelopeRange.start == 0);

    MboxRecord oversized;
    oversized.messageRange.start = 123;
    oversized.headerRange = ByteRange(0, maxHeaderBytes + 1);

    bool rejected;
    try {
        recordMatches(source, oversized, wantedHeaders, matcher);
    } catch (Exception) {
        rejected = true;
    }
    assert(rejected);
}

unittest {
    enum sample =
        "From exact@example.org Tue Sep 29 05:04:00 2026\n" ~
        "From: exact@example.org\n" ~
        "To: SPEC-LIST@example.org\n" ~
        "Message-ID: <exact-duplicate@example.org>\n" ~
        "Subject: exact duplicate entry\n\n" ~
        "same exact body\n" ~
        "From exact@example.org Tue Sep 29 05:04:00 2026\n" ~
        "From: exact@example.org\n" ~
        "To: SPEC-LIST@example.org\n" ~
        "Message-ID: <exact-duplicate@example.org>\n" ~
        "Subject: exact duplicate entry\n\n" ~
        "same exact body\n";

    auto source = File.tmpfile();
    source.rawWrite(sample);
    source.flush();

    bool[string] wantedHeaders;
    wantedHeaders["to"] = true;
    auto matcher = regex("SPEC-LIST", "i");

    const selected = selectMessages(source, wantedHeaders, matcher);

    // Equal mailbox entries remain separate occurrences.
    assert(selected.length == 2);
    assert(selected[0].wholeRange.length == selected[1].wholeRange.length);
}
