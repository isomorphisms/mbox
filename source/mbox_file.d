module mbox_file;

import core.stdc.stdio : SEEK_END;
import core.sys.posix.fcntl : O_CREAT, O_EXCL, O_RDONLY, O_RDWR, O_WRONLY, open;
import core.sys.posix.sys.stat : S_IRUSR, S_IWUSR, fstat, stat_t;
import core.sys.posix.unistd : close, fsync;

import std.algorithm : min;
import std.conv : to;
import std.digest.sha : SHA256;
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

struct SelectedMessage {
    MboxRecord record;
    string digest;
}

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
    auto out = new char[](value.length);
    foreach (i, c; value) {
        if (c >= 'A' && c <= 'Z')
            out[i] = cast(char)(c + ('a' - 'A'));
        else
            out[i] = c;
    }
    return cast(string) out;
}

private string hexDigest(ubyte[32] digest)
{
    enum digits = "0123456789abcdef";
    auto out = new char[](64);
    foreach (i, b; digest) {
        out[i * 2] = digits[b >> 4];
        out[i * 2 + 1] = digits[b & 0x0f];
    }
    return cast(string) out;
}

private string sha256Range(ref File source, ByteRange range)
{
    source.seek(cast(long) range.start);

    SHA256 sha;
    sha.start();

    auto buffer = new ubyte[](ioChunk);
    ByteOffset remaining = range.length;

    while (remaining != 0) {
        const wanted = cast(size_t) min(
            remaining,
            cast(ByteOffset) buffer.length
        );
        auto got = source.rawRead(buffer[0 .. wanted]);
        enforce(got.length == wanted,
            "mbox-file: short read while hashing mailbox");
        sha.put(got);
        remaining -= got.length;
    }

    return hexDigest(sha.finish());
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

private MboxRecord[] records(ref File mailbox)
{
    MboxRecord[] result;
    scanMbox(mailbox, (in MboxRecord record) {
        result ~= record;
    });
    return result;
}

private bool[string] digestIndex(ref File archive)
{
    bool[string] result;
    const all = records(archive);
    foreach (record; all)
        result[sha256Range(archive, record.messageRange)] = true;
    return result;
}

private SelectedMessage[] selectMessages(R)(
    ref File source,
    ref bool[string] wantedHeaders,
    ref R matcher
)
{
    SelectedMessage[] selected;
    const all = records(source);

    foreach (record; all) {
        if (!recordMatches(source, record, wantedHeaders, matcher))
            continue;

        selected ~= SelectedMessage(
            record,
            sha256Range(source, record.messageRange)
        );
    }

    return selected;
}

private void printPlan(
    scope const SelectedMessage[] selected,
    ref bool[string] archived
)
{
    size_t alreadyArchived;
    bool[string] seen = archived.dup;

    foreach (message; selected) {
        if (message.digest in seen) {
            ++alreadyArchived;
        } else {
            seen[message.digest] = true;
        }
    }

    stdout.writeln("matched: ", selected.length);
    stdout.writeln("already archived: ", alreadyArchived);
    stdout.writeln("would append: ", selected.length - alreadyArchived);
    stdout.writeln("would remove from source: ", selected.length);
}

private void rewriteSource(
    ref File source,
    string sourcePath,
    scope const SelectedMessage[] selected,
    ByteOffset sourceSize
)
{
    const tempPath =
        sourcePath ~ ".mbox-file-rewrite." ~ to!string(thisProcessID());

    auto temp = createExclusive(tempPath);
    requireSameOwnerGroup(source, temp);
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

    ByteOffset cursor;
    foreach (message; selected) {
        const whole = message.record.wholeRange;
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

    bool[string] archived;
    if (exists(archivePath)) {
        auto archive = File(archivePath, "rb");
        archived = digestIndex(archive);
    }

    enforce(source.size == initialSourceSize,
        "mbox-file: source mailbox changed during dry run; rerun");
    printPlan(selected, archived);
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

    enforce(!sameFile(source, archive),
        "mbox-file: source and archive are the same file");

    auto archived = digestIndex(archive);
    printPlan(selected, archived);

    archive.seek(0, SEEK_END);
    foreach (message; selected) {
        if (message.digest in archived)
            continue;

        const whole = message.record.wholeRange;
        copyRange(source, archive, whole.start, whole.end);
        archived[message.digest] = true;
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

int main(string[] arguments)
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
