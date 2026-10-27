/// The classify and report modes, for tuning on mail you already have.
module jevfilter.eval;

import std.algorithm : canFind, count, map, sort;
import std.array : array, join;
import std.file : SpanMode, dirEntries, isDir, read;
import std.format : format;
import std.json : JSONType, JSONValue, parseJSON;
import std.stdio : File, stderr, stdout;
import std.string : lastIndexOf, strip;

import jevfilter.config : Config, canonicalJson, number;
import jevfilter.jev : Verdict, classify, decide;
import jevfilter.message : messageInfo;
import jevfilter.text : truncate;
import jevfilter.util : filterVersion, headerSafe, readStdin;

void runClassify(ref Config config, string tag, string[] files)
{
    foreach (file; files)
    {
        JSONValue[string] result;
        if (tag.length)
            result["tag"] = JSONValue(tag);
        if (file != "-")
            result["file"] = JSONValue(file);

        try
        {
            auto message = file == "-" ? readStdin() : cast(ubyte[]) read(file);
            auto info = messageInfo(message);
            result["message_id"] = JSONValue(info.messageId);
            result["from"] = JSONValue(truncate(info.from, 200));
            result["subject"] = JSONValue(truncate(info.subject, 200));

            auto classification = classify(config, message, 6);
            result["prompt"] = JSONValue(config.promptHash);
            result["filter_version"] = JSONValue(filterVersion());
            result["model"] = JSONValue(classification.model);
            result["input_tokens"] = JSONValue(classification.inputTokens);
            result["answers"] = classification.answers;
            result["folder"] = JSONValue(classification.verdict.folder.length ? classification.verdict.folder : "INBOX");
            result["rule"] = JSONValue(classification.verdict.ruleId);
            result["flags"] = JSONValue(classification.verdict.flags);
        }
        catch (Exception e)
        {
            result["error"] = JSONValue(e.msg);
        }

        stdout.writeln(canonicalJson(JSONValue(result)));
        stdout.flush();
    }
}

void runReport(ref Config config, string[] listFolders, string[] paths)
{
    struct Group
    {
        size_t total, errors, stale, unusable;
        size_t[string] folders;
        size_t[string] rules;
        double[][string] nouls;
        size_t[string][string] choices;
    }

    // Results are grouped by their tag without the last part: Junk/1234 is in Junk
    Group[string] groups;
    string[] order;

    foreach (path; paths)
    {
        auto files = isDir(path) ? dirEntries(path, "*.json*", SpanMode.shallow).map!(e => e.name).array.sort.release : [path];
        foreach (file; files)
            foreach (line; File(file).byLineCopy)
            {
                if (!line.strip.length)
                    continue;

                auto result = parseJSON(line);
                auto tag = textField(result, "tag");
                auto slash = tag.lastIndexOf('/');
                auto name = slash < 0 ? (tag.length ? tag : file) : tag[0 .. slash];
                if (name !in groups)
                {
                    groups[name] = Group.init;
                    order ~= name;
                }
                auto group = &groups[name];

                group.total++;
                if ("error" in result)
                {
                    group.errors++;
                    continue;
                }
                if (textField(result, "prompt") != config.promptHash)
                    group.stale++;

                auto answers = result["answers"];
                Verdict verdict;
                try
                    verdict = decide(config, answers);
                catch (Exception)
                {
                    group.unusable++;
                    continue;
                }

                auto folder = verdict.folder.length ? verdict.folder : "INBOX";
                auto rule = verdict.ruleId.length ? verdict.ruleId : "(none)";
                group.folders[folder]++;
                group.rules[rule]++;
                foreach (question, answer; answers.object)
                {
                    if (answer["type"].str == "noul")
                        group.nouls[question] ~= number(answer["noul"]);
                    else if (answer["type"].str == "choice")
                        group.choices[question][answer["choice"].str]++;
                }

                // --list takes folders and rule ids
                if (listFolders.canFind(folder) || listFolders.canFind(rule))
                    stdout.writefln("%s\t%s\t%s\t%s\t%s\t%s", tag, folder, rule, verdict.summary.join(" "),
                        headerSafe(textField(result, "from")), headerSafe(textField(result, "subject")));
            }
    }

    // With --list the summary goes to stderr, so the list can be piped
    auto output = listFolders.length ? stderr : stdout;
    foreach (name; order)
    {
        auto group = groups[name];
        output.writefln("%s: %d messages, %d errors", name, group.total, group.errors);
        if (group.stale)
            output.writefln("  warning: %d were classified with other questions, model or body length", group.stale);
        if (group.unusable)
            output.writefln("  warning: %d lack answers the rules need, classify them again", group.unusable);

        auto routed = group.total - group.errors - group.unusable;
        if (!routed)
            continue;
        foreach (folder; group.folders.keys.sort!((a, b) => group.folders[a] > group.folders[b]))
            output.writefln("  -> %-14s %6d %6.1f%%", folder, group.folders[folder], 100.0 * group.folders[folder] / routed);
        output.writefln("  rules: %s", group.rules.keys.sort!((a, b) => group.rules[a] > group.rules[b])
            .map!(rule => format("%s %d", rule, group.rules[rule])).join(", "));

        foreach (question; group.nouls.keys.sort)
        {
            auto values = group.nouls[question];
            output.writef("  %-17s", question);
            foreach (threshold; [0.5, 0.7, 0.8, 0.9, 0.95, 0.99])
                output.writef(" >=%.2f %5.1f%%", threshold, 100.0 * values.count!(v => v >= threshold) / values.length);
            output.writeln();
        }
        foreach (question; group.choices.keys.sort)
        {
            auto counts = group.choices[question];
            output.writefln("  %-17s %s", question, counts.keys.sort!((a, b) => counts[a] > counts[b])
                .map!(choice => format("%s %d", choice, counts[choice])).join(", "));
        }
    }
}

string textField(JSONValue object, string name)
{
    auto value = name in object;
    return value && value.type == JSONType.string ? value.str : "";
}
