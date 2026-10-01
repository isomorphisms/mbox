module file_spec_list;

import mbox_file : runMboxFile;

int main(string[] arguments)
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

    if (arguments.length > 1)
        forwarded ~= arguments[1 .. $];

    return runMboxFile(forwarded);
}
