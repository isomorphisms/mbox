module file_spec_list;

import mbox_file : runMboxFile;

string[] specListArguments(scope const string[] userArguments)
{
    string[] forwarded = [
        "file-spec-list",
        "--source", "/var/mail/isomorphisms",
        "--archive", "~/Mail/spec-list",
        "--header", "From",
        "--header", "Sender",
        "--header", "Reply-To",
        "--header", "To",
        "--header", "Cc",
        "--header", "Subject",
        "--pattern", "SPEC-LIST",
        "--ignore-case",
    ];

    forwarded ~= userArguments;
    return forwarded;
}

int main(string[] arguments)
{
    const userArguments =
        arguments.length > 1 ? arguments[1 .. $] : [];
    return runMboxFile(specListArguments(userArguments));
}

unittest {
    const args = specListArguments(["--move"]);
    assert(args[0] == "file-spec-list");
    assert(args[$ - 1] == "--move");

    size_t sourceCount;
    size_t headerCount;
    foreach (arg; args) {
        if (arg == "--source")
            ++sourceCount;
        if (arg == "--header")
            ++headerCount;
    }

    assert(sourceCount == 1);
    assert(headerCount == 6);
}
