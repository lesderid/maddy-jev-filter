#!/usr/bin/env rdmd
/*
 * maddy-jev-filter: sorts incoming mail into IMAP folders using TypeSafe's Jev.
 *
 * maddy runs it twice for every message:
 *
 *   check MSG_ID [--sender=S] [--rcpts=R] [--auth-user=U] [--source-ip=IP]
 *     As check.command (run_on body) in the pipeline that delivers to local
 *     mailboxes, once per message. Reads the message on stdin, asks Jev the
 *     configured questions and applies the rules. It prints two header fields,
 *     which maddy prepends to the message: X-Maddy-Jev-Filter with the answers,
 *     and X-Maddy-Jev-Filter-Action with what happens to the message and which
 *     rule decided. Mail
 *     from logged-in users and maddy's own bounces (no source IP) is skipped.
 *
 *   route MSG_ID
 *     As imap.filter.command, once per local recipient. Finds the
 *     X-Maddy-Jev-Filter-Action header that the check stage added for this
 *     delivery and prints its folder and flags.
 *
 * Both headers carry maddy's internal message ID, which senders can't know in
 * advance, so headers forged by the sender are never used for routing.
 *
 * Both stages exit 0 when classification fails: the header then carries an
 * error instead of a folder and the message goes to INBOX.
 *
 * Two more modes help tune the questions and rules on mail you already have:
 *
 *   classify [--tag=TAG] FILE|-...
 *     Asks Jev about each message and prints one JSON line per message.
 *
 *   report [--list=FOLDER]... RESULTS...
 *     Applies the configured rules to classify output again, without asking
 *     Jev, and summarises where the messages would go.
 *
 *   state FILE|-
 *     Prints what Jev would be sent about a message, without sending it.
 *
 *   questions FILE|-
 *     Prints the questions Jev would get for a message, with the examples
 *     picked for its sender.
 */
module maddy_jev_filter;

import std.algorithm : filter, min, splitter, startsWith;
import std.array : array, join;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.file : read;
import std.format : format;
import std.getopt : getopt, getoptConfig = config;
import std.stdio : stderr, stdout;
import std.string : indexOf, strip;
import std.uni : toLower;

import jevfilter.config : loadConfig, withSenderExamples;
import jevfilter.examples : parseSender;
import jevfilter.eval : runClassify, runReport;
import jevfilter.jev : Verdict, actionParams, classify;
import jevfilter.message : MessageInfo, messageInfo, messageState;
import jevfilter.mime : parseFields, splitEntity, toUtf8;
import jevfilter.text : truncate;
import jevfilter.util : filterVersion, headerSafe, log, readStdin;

enum headerName = "X-Maddy-Jev-Filter";
enum actionHeaderName = "X-Maddy-Jev-Filter-Action";
enum defaultConfigPath = "/etc/maddy/jev-filter.json";

enum usageText = "usage: maddy-jev-filter.d [--config=PATH] check MSG_ID [--sender=S] [--rcpts=R] [--auth-user=U] [--source-ip=IP]
       maddy-jev-filter.d route MSG_ID
       maddy-jev-filter.d [--config=PATH] classify [--tag=TAG] FILE|-...
       maddy-jev-filter.d [--config=PATH] report [--list=FOLDER]... RESULTS...
       maddy-jev-filter.d [--config=PATH] state FILE|-
       maddy-jev-filter.d [--config=PATH] questions FILE|-";

int main(string[] args)
{
    // Options must come before the stage, so {sender} can't be mistaken for one.
    string configPath = defaultConfigPath;
    getopt(args, getoptConfig.stopOnFirstNonOption, "config|c", &configPath);

    auto stage = args.length > 1 ? args[1] : null;
    auto stageArgs = args[min(1, $) .. $];

    if (stage == "check")
    {
        // maddy.conf passes these as --name={placeholder}, so a value starting
        // with a dash can't be taken for an option. Not with getopt: it reads
        // an empty --name= as "the value is the next argument".
        Envelope envelope;
        string rcpts;
        string[] positional;
        foreach (arg; stageArgs[1 .. $])
        {
            auto eq = arg.indexOf('=');
            auto value = eq > 0 ? arg[eq + 1 .. $] : null;
            switch (arg.startsWith("--") && eq > 2 ? arg[2 .. eq] : null)
            {
            case "sender":
                envelope.sender = value;
                break;
            case "rcpts":
                rcpts = value;
                break;
            case "auth-user":
                envelope.authUser = value;
                break;
            case "source-ip":
                envelope.sourceIp = value;
                envelope.sourceIpKnown = true;
                break;
            default:
                positional ~= arg;
            }
        }
        if (positional.length != 1)
        {
            stderr.writeln(usageText);
            return 64;
        }
        envelope.msgId = positional[0];
        envelope.rcpts = rcpts.splitter('\n').filter!(r => r.length).array;
        runCheck(configPath, envelope);
    }
    else if (stage == "route" && stageArgs.length == 2)
        runRoute(stageArgs[1]);
    else if (stage == "classify")
    {
        string tag;
        getopt(stageArgs, "tag", &tag);
        auto config = loadConfig(configPath);
        runClassify(config, tag, stageArgs[1 .. $]);
    }
    else if (stage == "report")
    {
        string[] folders;
        getopt(stageArgs, "list", &folders);
        auto config = loadConfig(configPath, false);
        runReport(config, folders, stageArgs[1 .. $]);
    }
    else if (stage == "questions" && stageArgs.length == 2)
    {
        auto config = loadConfig(configPath, false);
        auto message = stageArgs[1] == "-" ? readStdin() : cast(ubyte[]) read(stageArgs[1]);
        auto sender = parseSender(messageInfo(message).from);
        stdout.writeln(withSenderExamples(config.questions, config, sender).toPrettyString);
    }
    else if (stage == "state" && stageArgs.length == 2)
    {
        auto config = loadConfig(configPath, false);
        auto message = stageArgs[1] == "-" ? readStdin() : cast(ubyte[]) read(stageArgs[1]);
        stdout.writeln(messageState(message, config.maxBodyChars, config.authservId).toPrettyString);
    }
    else
    {
        stderr.writeln(usageText);
        return 64;
    }
    return 0;
}

/// What maddy tells the check stage about a delivery, besides the message itself
struct Envelope
{
    string msgId;
    string sender;
    string[] rcpts;
    string authUser;
    string sourceIp;
    bool sourceIpKnown;
}

void runCheck(string configPath, Envelope envelope)
{
    auto timer = StopWatch(AutoStart.yes);
    auto message = readStdin();

    // Mail from local users and bounces maddy generates itself pass through here too
    if (envelope.authUser.length || (envelope.sourceIpKnown && !envelope.sourceIp.length))
    {
        log(format("skip id=%s; %s", headerSafe(envelope.msgId),
            envelope.authUser.length ? "user=" ~ headerSafe(envelope.authUser) : "generated by maddy"));
        return;
    }

    MessageInfo info;
    long tokens;
    auto id = "id=" ~ headerSafe(envelope.msgId);
    string[] params = [id];
    string[] action = ["folder=INBOX", "read=no", "rule=none", "error=yes"];
    try
    {
        info = messageInfo(message);
        auto config = loadConfig(configPath);
        auto result = classify(config, message, 2);
        params ~= result.verdict.summary;
        params ~= "model=" ~ headerSafe(result.model);
        tokens = result.inputTokens;
        action = actionParams(result.verdict);
    }
    // Catching everything keeps a parsing bug from rejecting mail: exit code 1
    // means "reject" to check.command unless maddy.conf maps it to ignore.
    catch (Throwable e)
    {
        params ~= "error=" ~ headerSafe(e.msg);
    }
    // The recipients before any rewriting, which maddy doesn't store otherwise
    if (envelope.rcpts.length)
        params ~= "rcpt=" ~ headerSafe(envelope.rcpts.join(","));

    auto value = params.join("; ");
    auto actionValue = ([id] ~ action ~ ["version=" ~ headerSafe(filterVersion())]).join("; ");
    stdout.write(headerName, ": ", value, "\r\n", actionHeaderName, ": ", actionValue, "\r\n\r\n");
    stdout.flush();

    // Metadata only: enough to find the message and judge the verdict
    log(format("check %s; action %s; tokens=%d; %dms; sender=%s; from=%s; subject=%s; message_id=%s",
        value, actionValue[id.length + 2 .. $], tokens, timer.peek.total!"msecs", headerSafe(envelope.sender), headerSafe(truncate(info.from, 100)),
        headerSafe(truncate(info.subject, 80)), headerSafe(info.messageId)));
}

void runRoute(string msgId)
{
    auto message = readStdin();
    if (!msgId.length)
        return;

    foreach (field; parseFields(splitEntity(message).header))
    {
        if (field.name != actionHeaderName.toLower)
            continue;

        string[string] params;
        foreach (param; toUtf8(field.value).splitter(';'))
        {
            auto eq = param.indexOf('=');
            if (eq > 0)
                params[param[0 .. eq].strip] = param[eq + 1 .. $].strip;
        }
        if (params.get("id", null) != msgId)
            continue;

        // A first line with the folder, even if empty, then one flag per line
        auto folder = params.get("folder", "INBOX");
        auto flags = (params.get("read", "no") == "yes" ? [`\Seen`] : [])
            ~ params.get("flags", "").splitter(',').filter!(flag => flag.length).array;
        if (folder != "INBOX" || flags.length)
            stdout.writeln(folder == "INBOX" ? "" : folder);
        foreach (flag; flags)
            stdout.writeln(flag);
        log(format("route id=%s; folder=%s; flags=%s", msgId, folder, flags.join(",")));
        return;
    }
}
