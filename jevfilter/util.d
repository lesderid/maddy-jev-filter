/// Small helpers shared by the stages.
module jevfilter.util;

import std.array : appender;
import std.encoding : sanitize;
import std.stdio : stderr, stdin;
import std.string : strip, toStringz;

import jevfilter.text : truncate;

/// Makes a value safe to use in the X-Maddy-Jev-Filter header and as a log line.
string headerSafe(string value)
{
    auto result = appender!string;
    foreach (dchar c; sanitize(value))
        result.put(c == ';' ? ',' : c < ' ' || c == '\x7F' ? ' ' : c);
    return truncate(result[].strip, 200);
}

ubyte[] readStdin()
{
    auto data = appender!(ubyte[]);
    foreach (chunk; stdin.byChunk(64 * 1024))
        data.put(chunk);
    return data[];
}

void log(string message)
{
    import core.sys.posix.syslog : LOG_INFO, LOG_MAIL, LOG_PID, openlog, syslog;

    openlog("maddy-jev-filter", LOG_PID, LOG_MAIL);
    syslog(LOG_INFO, "%s", message.toStringz);
    stderr.writeln(message);
}

/// The commit this copy of the filter comes from. tools/install.sh writes it
/// to VERSION; in a git checkout, git is asked instead.
string filterVersion()
{
    static string cached;
    if (cached is null)
        cached = findVersion();
    return cached;
}

private string findVersion()
{
    import std.file : readText;
    import std.path : buildPath, dirName;
    import std.process : execute;

    auto root = dirName(dirName(__FILE_FULL_PATH__));
    try
        return readText(buildPath(root, "VERSION")).strip;
    catch (Exception)
    {
    }

    try
    {
        auto git = execute(["git", "-C", root, "describe", "--always", "--dirty", "--abbrev=12"]);
        if (git.status == 0)
            return git.output.strip;
    }
    catch (Exception)
    {
    }
    return "unknown";
}
