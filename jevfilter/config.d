/// The configuration file: questions for Jev and the rules that pick a folder.
module jevfilter.config;

import std.algorithm : all, among, canFind, map, sort, splitter;
import std.array : array, join;
import std.ascii : isAlphaNum;
import std.conv : to;
import std.digest : toHexString;
import std.digest.sha : sha1Of;
import std.exception : enforce;
import std.file : exists, readText;
import std.path : buildPath, dirName;
import std.format : format;
import std.json : JSONType, JSONValue, parseJSON;
import std.string : strip;

import jevfilter.examples : Sender, examplesFor, parseSender, senderKey;
import jevfilter.util : headerSafe;

enum defaultEndpoint = "https://api.typesafe.ai/v1/systemone";

/// What the filter knows about a message without asking Jev, usable in rules
/// like answers. sender_kept is 1 if the recipient has kept mail from the
/// sender before, sender_junked is 1 if mail from the sender is in Junk;
/// otherwise 0.
enum facts = ["sender_kept", "sender_junked"];

/// The facts that come from a list of senders, and the setting with its file
struct SenderList
{
    string fact;
    string setting;
}

immutable senderLists = [
    SenderList("sender_kept", "kept_senders_file"),
    SenderList("sender_junked", "junked_senders_file"),
];

struct Condition
{
    string question;
    string choice;
    double min = -double.infinity;
    double max = double.infinity;
}

/// When all conditions hold, a message goes to `folder` with `flags` added.
/// The first matching rule wins.
struct Rule
{
    /// Short and header-friendly, such as spam-certain
    string id;
    /// For people, such as "spam Jev is sure about"
    string description;
    /// Empty keeps the message in INBOX
    string folder;
    /// IMAP flags to add, such as \Seen
    string[] flags;
    Condition[] when;
}

struct Config
{
    string endpoint = defaultEndpoint;
    string apiKey;
    string model = "jev-latest";
    int timeoutSeconds = 10;
    size_t maxBodyChars = 6000;

    /// The host name maddy uses in its Authentication-Results and Received
    /// fields. Only fields with it are trusted; without it, the topmost are.
    string authservId;

    JSONValue questions;
    Rule[] rules;

    /// The files named by include_for_sender, by path
    JSONValue[string] senderExamples;

    /// The senders behind each fact in senderLists, as senderKey values. A
    /// fact whose file is missing isn't here, and is unknown.
    bool[string][string] senderLists;

    /// Changes whenever Jev would be asked something else, to tell old results apart
    string promptHash;
}

Config loadConfig(string path, bool needsKey = true)
{
    auto json = parseJSON(readText(path));
    Config config;

    if (auto endpoint = "endpoint" in json)
        config.endpoint = endpoint.str;
    if (needsKey)
        config.apiKey = readText(json["api_key_file"].str).strip;
    if (auto model = "model" in json)
        config.model = model.str;
    if (auto timeout = "timeout_seconds" in json)
        config.timeoutSeconds = timeout.integer.to!int;
    if (auto maxBodyChars = "max_body_chars" in json)
        config.maxBodyChars = maxBodyChars.integer.to!size_t;
    if (auto authservId = "authserv_id" in json)
        config.authservId = authservId.str;
    foreach (list; senderLists)
    {
        auto setting = list.setting in json;
        if (!setting)
            continue;
        auto file = buildPath(dirName(path), setting.str);
        if (!exists(file))
            continue;
        bool[string] senders;
        foreach (line; readText(file).splitter('\n'))
            if (line.strip.length)
                senders[senderKey(parseSender(line.strip))] = true;
        config.senderLists[list.fact] = senders;
    }

    config.questions = expandIncludes(json["questions"], dirName(path), config.senderExamples);
    enforce(config.questions.type == JSONType.object && config.questions.object.length,
        "config: questions must be a non-empty object");

    foreach (i, rule; json["rules"].array)
    {
        Rule r;
        r.id = "id" in rule ? rule["id"].str : format("rule-%d", i + 1);
        enforce(r.id.length && r.id.all!(c => isAlphaNum(c) || c.among('-', '_')),
            "config: rule ids may only contain letters, digits, - and _: " ~ r.id);
        enforce(r.id != "none", "config: \"none\" means no rule matched and can't be a rule id");
        enforce(!config.rules.canFind!(other => other.id == r.id), "config: two rules are called " ~ r.id);
        if (auto description = "description" in rule)
            r.description = description.str;

        if (auto folder = "folder" in rule)
            r.folder = folder.str;
        if (auto flags = "flags" in rule)
            r.flags = flags.array.map!(flag => flag.str).array;
        foreach (name; r.folder ~ r.flags)
            enforce(headerSafe(name) == name && !name.canFind(','),
                "config: folders and flags must not contain ';', ',' or control characters: " ~ name);
        foreach (flag; r.flags)
            enforce(flag.length && !flag.canFind(' '), "config: flags can't be empty or contain spaces: " ~ flag);
        enforce(r.folder.length || r.flags.length, "config: rule " ~ r.id ~ " has neither a folder nor flags");

        foreach (name, condition; rule["when"].object)
        {
            auto question = name in config.questions.object;
            enforce(question || facts.canFind(name), "config: rule for unknown question " ~ name);

            auto c = Condition(name);
            if (auto choice = "choice" in condition)
                c.choice = choice.str;
            if (auto lower = "min" in condition)
                c.min = number(*lower);
            if (auto upper = "max" in condition)
                c.max = number(*upper);

            auto isChoice = question && (*question)["type"].str == "choice";
            enforce(isChoice == (c.choice !is null),
                "config: conditions on choice questions need a choice, other conditions must not have one");
            enforce(!isChoice || c.choice in (*question)["criteria"].object,
                "config: unknown choice " ~ c.choice ~ " for question " ~ name);
            r.when ~= c;
        }
        enforce(r.when.length, "config: rule " ~ r.id ~ " has no conditions");

        config.rules ~= r;
    }

    // Changing authserv_id changes what Jev sees, but leaving it out keeps
    // the hash of configs from before it existed.
    auto digest = sha1Of(canonicalJson(config.questions) ~ config.model ~ config.maxBodyChars.to!string
        ~ (config.authservId.length ? "authserv_id=" ~ config.authservId : "")
        ~ config.senderExamples.keys.sort.map!(file => file ~ canonicalJson(config.senderExamples[file])).join);
    char[40] hex = toHexString(digest);
    config.promptHash = hex[0 .. 12].idup;

    return config;
}

/// Replaces every `{"include": "PATH"}` in `value` with the JSON in PATH,
/// relative to `baseDir`. A missing file counts as an empty list, so that
/// questions about a list of examples work before there are any.
///
/// `{"include_for_sender": "PATH"}` stays, with PATH made absolute, and the
/// file goes into `senderExamples`: those are filled in for each message with
/// only the examples from its sender (see withSenderExamples).
JSONValue expandIncludes(JSONValue value, string baseDir, ref JSONValue[string] senderExamples)
{
    switch (value.type)
    {
    case JSONType.object:
        auto object = value.object;
        if (object.length == 1 && "include" in object && object["include"].type == JSONType.string)
            return readExamples(buildPath(baseDir, object["include"].str));
        if (object.length == 1 && "include_for_sender" in object && object["include_for_sender"].type == JSONType.string)
        {
            auto file = buildPath(baseDir, object["include_for_sender"].str);
            senderExamples[file] = readExamples(file);
            return JSONValue(["include_for_sender": file]);
        }
        JSONValue[string] result;
        foreach (key, item; object)
            result[key] = expandIncludes(item, baseDir, senderExamples);
        return JSONValue(result);
    case JSONType.array:
        return JSONValue(value.array.map!(item => expandIncludes(item, baseDir, senderExamples)).array);
    default:
        return value;
    }
}

JSONValue readExamples(string file)
{
    return exists(file) ? parseJSON(readText(file)) : parseJSON("[]");
}

/// The questions for a message from `sender`: each include_for_sender
/// replaced with the examples from that sender, often none.
JSONValue withSenderExamples(JSONValue value, ref Config config, Sender sender)
{
    switch (value.type)
    {
    case JSONType.object:
        auto object = value.object;
        if (object.length == 1 && "include_for_sender" in object)
            return examplesFor(config.senderExamples.get(object["include_for_sender"].str, parseJSON("[]")), sender);
        JSONValue[string] result;
        foreach (key, item; object)
            result[key] = withSenderExamples(item, config, sender);
        return JSONValue(result);
    case JSONType.array:
        return JSONValue(value.array.map!(item => withSenderExamples(item, config, sender)).array);
    default:
        return value;
    }
}

double number(JSONValue value)
{
    switch (value.type)
    {
    case JSONType.integer:
        return value.integer;
    case JSONType.uinteger:
        return value.uinteger;
    case JSONType.float_:
        return value.floating;
    default:
        throw new Exception("expected a number, got " ~ value.toString);
    }
}

/// Serialises JSON with sorted keys, so equal values always give the same text.
string canonicalJson(JSONValue value)
{
    switch (value.type)
    {
    case JSONType.object:
        return "{" ~ value.object.keys.sort.map!(key => JSONValue(key).toString ~ ":" ~ canonicalJson(value[key])).join(",") ~ "}";
    case JSONType.array:
        return "[" ~ value.array.map!(item => canonicalJson(item)).join(",") ~ "]";
    // std.json writes 0.98 as 0.979999999999999982, which tools that compare
    // decimals exactly (like jq 1.7) read as less than 0.98.
    case JSONType.float_:
        return format("%.10g", value.floating);
    default:
        return value.toString;
    }
}
