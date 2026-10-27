/// Asking Jev, and turning its answers into a folder.
module jevfilter.jev;

import core.thread : Thread;
import core.time : seconds;
import std.algorithm : among, canFind, filter, min, sort;
import std.exception : enforce;
import std.array : array, join;
import std.format : format;
import std.json : JSONValue, parseJSON;
import std.net.curl : CurlException, HTTP;

import jevfilter.config : Config, facts, number, withSenderExamples;
import jevfilter.examples : parseSender, senderKey;
import jevfilter.message : messageInfo, messageState;
import jevfilter.mime : Bytes, toUtf8;
import jevfilter.text : truncate;
import jevfilter.util : headerSafe;

struct Classification
{
    JSONValue answers;
    string model;
    long inputTokens;
    Verdict verdict;
}

Classification classify(ref Config config, Bytes message, int attempts)
{
    auto sender = parseSender(messageInfo(message).from);
    auto questions = withSenderExamples(config.questions, config, sender);
    auto response = askJev(config, messageState(message, config.maxBodyChars, config.authservId), questions, attempts);

    Classification result;
    result.answers = response["answers"];
    foreach (fact, senders; config.senderLists)
        result.answers.object[fact] = JSONValue([
            "type": JSONValue("fact"),
            "value": JSONValue(senderKey(sender) in senders ? 1 : 0),
        ]);
    result.model = response["model"].str;
    if (auto tokenUsage = "usage" in response)
        result.inputTokens = (*tokenUsage)["input_tokens"].integer;
    result.verdict = decide(config, result.answers);
    return result;
}

JSONValue askJev(ref Config config, JSONValue state, JSONValue questions, int attempts)
{
    JSONValue request = [
        "model": JSONValue(config.model),
        "state": state,
        "questions": questions,
    ];
    auto requestBody = request.toString;

    for (int attempt = 1;; attempt++)
    {
        ushort status;
        string responseText;
        try
        {
            auto http = HTTP(config.endpoint);
            http.connectTimeout = min(5, config.timeoutSeconds).seconds;
            http.operationTimeout = config.timeoutSeconds.seconds;
            http.addRequestHeader("Authorization", "Bearer " ~ config.apiKey);
            http.setPostData(requestBody, "application/json");

            ubyte[] responseBody;
            http.onReceive = (ubyte[] data) {
                responseBody ~= data;
                return data.length;
            };
            http.perform();
            status = http.statusLine.code;
            responseText = toUtf8(responseBody);
        }
        catch (CurlException e)
        {
            if (attempt >= attempts)
                throw e;
            Thread.sleep((1 << (attempt - 1)).seconds);
            continue;
        }

        // Rate limited or overloaded: back off and try again
        if (status.among(429, 529) && attempt < attempts)
        {
            Thread.sleep((1 << (attempt - 1)).seconds);
            continue;
        }

        enforce(status == 200, format("Jev returned HTTP %d: %s", status, truncate(responseText, 300)));
        return parseJSON(responseText);
    }
}

struct Verdict
{
    string folder;
    string[] flags;
    string ruleId;
    string ruleDescription;
    string[] summary;
}

Verdict decide(ref Config config, JSONValue answers)
{
    Verdict verdict;

    foreach (name; config.questions.object.keys.sort)
    {
        auto answer = answers[name];
        auto type = answer["type"].str;
        if (type == "choice")
        {
            auto choice = answer["choice"].str;
            verdict.summary ~= format("%s=%s:%.3f", name, headerSafe(choice), answerValue(answer, choice));
        }
        else
            verdict.summary ~= format(type == "noul" ? "%s=%.3f" : "%s=%.2f", name, answerValue(answer, null));
    }
    foreach (name; facts)
        if (auto fact = name in answers)
            verdict.summary ~= format("%s=%s", name, answerValue(*fact, null) ? "yes" : "no");

    foreach (rule; config.rules)
    {
        auto matches = true;
        foreach (condition; rule.when)
        {
            // A fact the filter doesn't know, such as sender_kept without a
            // kept_senders_file, matches nothing
            auto answer = condition.question in answers;
            if (!answer && facts.canFind(condition.question))
            {
                matches = false;
                continue;
            }
            auto value = answerValue(answers[condition.question], condition.choice);
            matches &= value >= condition.min && value <= condition.max;
        }
        if (matches)
        {
            verdict.folder = rule.folder;
            verdict.flags = rule.flags.dup;
            verdict.ruleId = rule.id;
            verdict.ruleDescription = rule.description;
            break;
        }
    }

    return verdict;
}

/// The probability of yes for a Noul, the score for a Score, the probability of `choice` for a Choice
double answerValue(JSONValue answer, string choice)
{
    switch (answer["type"].str)
    {
    case "noul":
        return number(answer["noul"]);
    case "score":
        return number(answer["score"]);
    case "fact":
        return number(answer["value"]);
    case "choice":
        return number(answer["probabilities"][choice]);
    default:
        throw new Exception("unexpected answer type " ~ answer["type"].str);
    }
}

/// What happens to a message, for the X-Maddy-Jev-Filter-Action header:
/// where it goes, whether it's marked as read, other flags, and why.
string[] actionParams(Verdict verdict)
{
    auto flags = verdict.flags.filter!(flag => flag != `\Seen`).array;
    string[] params = ["folder=" ~ (verdict.folder.length ? verdict.folder : "INBOX"),
        "read=" ~ (verdict.flags.canFind(`\Seen`) ? "yes" : "no")];
    if (flags.length)
        params ~= "flags=" ~ flags.join(",");
    params ~= "rule=" ~ (verdict.ruleId.length ? verdict.ruleId : "none");
    return params;
}
