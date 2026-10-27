/// What Jev gets to see of a message: the main headers and the readable part
/// of the body.
module jevfilter.message;

import std.algorithm : among, canFind, countUntil, map, min, startsWith;
import std.array : array, join, replace, split;
import std.ascii : isAlphaNum;
import std.format : format;
import std.json : JSONValue;
import std.string : indexOf, lastIndexOf, representation, strip;
import std.uni : toLower;

import jevfilter.mime;
import jevfilter.text : collectUrlDomains, htmlToText, normalizeWhitespace, truncate;

struct MessageInfo
{
    string messageId;
    string from;
    string subject;
}

MessageInfo messageInfo(Bytes message)
{
    BodyParts parts;
    collectBodyParts(message, parts, 0);

    auto fields = parseFields(splitEntity(message).header);
    return MessageInfo(toUtf8(fieldValue(fields, "message-id")).strip,
        normalizeWhitespace(decodeWords(fieldValue(fields, "from"), parts.charset)),
        normalizeWhitespace(decodeWords(fieldValue(fields, "subject"), parts.charset)));
}

JSONValue messageState(Bytes message, size_t maxBodyChars, string authservId = null)
{
    JSONValue[string] state;

    BodyParts parts;
    collectBodyParts(message, parts, 0);

    auto fields = parseFields(splitEntity(message).header);
    foreach (name; ["from", "reply-to", "to", "cc", "subject"])
    {
        auto value = normalizeWhitespace(decodeWords(fieldValue(fields, name), parts.charset));
        if (value.length)
            state[name.replace("-", "_")] = JSONValue(truncate(value, 500));
    }

    if (auto authentication = authenticationSummary(fields, authservId))
        state["authentication"] = JSONValue(authentication);
    if (auto server = sendingServer(fields, authservId))
        state["sending_server"] = JSONValue(server);

    // Prefer the HTML part: that's what a mail client shows, and spam often
    // hides behind an innocent text/plain alternative.
    string text;
    string[] linkDomains;
    if (parts.html.length)
        text = normalizeWhitespace(htmlToText(parts.html, linkDomains));
    if (!text.length)
        text = normalizeWhitespace(parts.plain);
    collectUrlDomains(text, linkDomains);

    state["body"] = JSONValue(truncate(text, maxBodyChars));
    if (parts.attachments.length)
        state["attachments"] = JSONValue(parts.attachments[0 .. min($, 20)]);
    if (linkDomains.length)
        state["link_domains"] = JSONValue(linkDomains);

    return JSONValue(state);
}

struct BodyParts
{
    string plain;
    string html;
    string[] attachments;
    int count;

    /// Of the first text part. Headers with raw 8-bit text are usually in it too.
    string charset;
}

void collectBodyParts(Bytes entity, ref BodyParts parts, int depth)
{
    if (depth > 8 || ++parts.count > 200)
        return;

    auto split = splitEntity(entity);
    auto fields = parseFields(split.header);
    auto contentType = parseParams(fieldValue(fields, "content-type"));
    auto type = contentType.value.length ? contentType.value : "text/plain";

    if (type.startsWith("multipart/"))
    {
        foreach (part; multipartParts(split.body_, contentType.params.get("boundary", null)))
            collectBodyParts(part, parts, depth + 1);
        return;
    }
    if (type == "message/rfc822")
    {
        collectBodyParts(split.body_, parts, depth + 1);
        return;
    }

    auto disposition = parseParams(fieldValue(fields, "content-disposition"));
    auto filename = disposition.params.get("filename", contentType.params.get("name", null));
    if (disposition.value == "inline" && type.startsWith("image/"))
        return;
    if (disposition.value == "attachment" || (filename.length && !type.startsWith("text/")))
    {
        parts.attachments ~= format("%s (%s)", filename.length ? decodeWords(filename.representation) : "unnamed", type);
        return;
    }

    auto target = type == "text/plain" ? &parts.plain : type == "text/html" ? &parts.html : null;
    if (!target || (*target).length)
        return;

    auto encoding = fieldValue(fields, "content-transfer-encoding").toUtf8.strip.toLower;
    auto data = decodeTransfer(split.body_[0 .. min($, 1 << 20)], encoding);
    auto charset = contentType.params.get("charset", null);
    if (!charset.length && type == "text/html")
        charset = htmlCharset(data);
    // Undeclared 8-bit text is most likely Western European
    if (!charset.length && !isValidUtf8(data))
        charset = "windows-1252";
    *target = toUtf8(data, charset);
    if (!parts.charset.length)
        parts.charset = charset;
}

/// Finds the charset an HTML document declares in a <meta> tag.
string htmlCharset(Bytes html)
{
    auto start = html[0 .. min($, 4096)].map!(c => cast(ubyte)(c >= 'A' && c <= 'Z' ? c | 0x20 : c)).array;
    auto i = start.countUntil("charset=".representation);
    if (i < 0)
        return null;

    auto rest = start[i + "charset=".length .. $];
    while (rest.length && rest[0].among('"', '\'', ' '))
        rest = rest[1 .. $];
    auto end = rest.countUntil!(c => !(isAlphaNum(c) || c.among('-', '_', ':', '.')));
    return cast(string)(end < 0 ? rest : rest[0 .. end]).idup;
}

/// Sums up the Authentication-Results field our own server added, for example
/// "spf=pass (em.example.com); dkim=pass (example.com); dmarc=pass (example.com)".
/// Senders can add such fields too, but maddy puts its own on top.
string authenticationSummary(Field[] fields, string authservId)
{
    foreach (field; fields)
    {
        if (field.name != "authentication-results")
            continue;
        auto parts = normalizeWhitespace(toUtf8(field.value)).split(';').map!(part => part.strip).array;
        if (!parts.length || (authservId.length && parts[0].toLower != authservId.toLower))
            continue;

        string[] results;
        foreach (part; parts[1 .. $])
        {
            auto tokens = part.split;
            if (!tokens.length || tokens[0].indexOf('=') <= 0)
                continue;
            auto result = tokens[0].toLower;
            auto method = result[0 .. result.indexOf('=')];

            // The domain each method vouches for
            string domain;
            foreach (token; tokens[1 .. $])
            {
                auto eq = token.indexOf('=');
                if (eq <= 0)
                    continue;
                auto key = token[0 .. eq].toLower;
                auto value = token[eq + 1 .. $].strip(`"`);
                if ((method == "spf" && key == "smtp.mailfrom") || (method == "dkim" && key == "header.d")
                    || (method == "dmarc" && key == "header.from"))
                    domain = value[value.lastIndexOf('@') + 1 .. $];
            }
            results ~= domain.length ? format("%s (%s)", result, domain) : result;
        }
        return results.join("; ");
    }
    return null;
}

/// Names the server that handed the message to ours, from the Received field
/// our server added: "from HELO (RDNS [IP]) by OUR-HOST ...".
string sendingServer(Field[] fields, string authservId)
{
    foreach (field; fields)
    {
        if (field.name != "received")
            continue;
        auto value = normalizeWhitespace(toUtf8(field.value));
        if (authservId.length && !value.toLower.canFind(" by " ~ authservId.toLower))
            continue;
        if (!value.startsWith("from "))
            return null;

        auto rest = value["from ".length .. $];
        auto space = rest.indexOf(' ');
        auto helo = space < 0 ? rest : rest[0 .. space];
        string rdns;
        auto open = rest.indexOf('(');
        auto close = rest.indexOf(')');
        if (open >= 0 && close > open)
        {
            auto inside = rest[open + 1 .. close].strip;
            auto bracket = inside.indexOf('[');
            rdns = (bracket < 0 ? inside : inside[0 .. bracket]).strip;
        }

        if (!rdns.length)
            return format("%s (no reverse DNS)", helo);
        return rdns.toLower == helo.toLower ? rdns : format("%s (introduced itself as %s)", rdns, helo);
    }
    return null;
}
