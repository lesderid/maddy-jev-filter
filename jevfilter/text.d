/// Turning HTML and plain text into the tidy text Jev reads.
module jevfilter.text;

import std.algorithm : among, canFind, countUntil, startsWith;
import std.array : appender;
import std.ascii : isAlphaNum;
import std.conv : to;
import std.string : indexOf, lastIndexOf, representation, strip;
import std.typecons : No;
import std.uni : isWhite, toLower;
import std.utf : isValidDchar;

/// Converts HTML to plain text and collects the domains of its links.
string htmlToText(string html, ref string[] linkDomains)
{
    enum blockTags = ["br", "p", "div", "tr", "li", "ul", "ol", "table", "blockquote", "hr",
        "h1", "h2", "h3", "h4", "h5", "h6"];

    auto text = appender!string;
    size_t i = 0;
    while (i < html.length)
    {
        if (html[i] != '<')
        {
            auto next = html.indexOf('<', i);
            auto end = next < 0 ? html.length : next;
            text.put(decodeEntities(html[i .. end]));
            i = end;
            continue;
        }

        if (html[i .. $].startsWith("<!--"))
        {
            auto end = html.indexOf("-->", i + 4);
            i = end < 0 ? html.length : end + 3;
            continue;
        }

        auto end = html.indexOf('>', i);
        if (end < 0)
            break;
        auto tag = html[i + 1 .. end];
        i = end + 1;

        auto closing = tag.startsWith('/');
        auto nameStart = closing ? 1 : 0;
        auto nameEnd = nameStart;
        while (nameEnd < tag.length && (isAlphaNum(tag[nameEnd]) || tag[nameEnd] == '-'))
            nameEnd++;
        auto name = tag[nameStart .. nameEnd].toLower;

        if (!closing && name.among("style", "script", "head", "title"))
        {
            auto close = html.indexOf("</" ~ name, i, No.caseSensitive);
            i = close < 0 ? html.length : close;
        }
        else if (blockTags.canFind(name))
            text.put('\n');
        else if (name.among("td", "th"))
            text.put(' ');
        else if (!closing && name == "a")
            addDomain(linkDomains, decodeEntities(attribute(tag, "href")));
    }
    return text[];
}

string attribute(string tag, string name)
{
    for (ptrdiff_t i = tag.indexOf(name, No.caseSensitive); i >= 0; i = tag.indexOf(name, i + 1, No.caseSensitive))
    {
        if (i == 0 || !isWhite(tag[i - 1]))
            continue;
        auto rest = tag[i + name.length .. $].strip;
        if (!rest.startsWith('='))
            continue;
        rest = rest[1 .. $].strip;
        if (rest.length && rest[0].among('"', '\''))
        {
            auto close = rest.indexOf(rest[0], 1);
            return close < 0 ? rest[1 .. $] : rest[1 .. close];
        }
        auto space = rest.representation.countUntil!(c => c <= ' ');
        return space < 0 ? rest : rest[0 .. space];
    }
    return null;
}

void collectUrlDomains(string text, ref string[] domains)
{
    for (ptrdiff_t i = text.indexOf("http", No.caseSensitive); i >= 0; i = text.indexOf("http", i + 4, No.caseSensitive))
        addDomain(domains, text[i .. $]);
}

/// Adds the host of an http(s) URL to `domains`, at most 20 distinct ones.
void addDomain(ref string[] domains, string url)
{
    url = url.strip;
    foreach (scheme; ["http://", "https://"])
    {
        if (!url.representation.startsWith!((a, b) => (a | 0x20) == b)(scheme.representation))
            continue;

        // Browsers ignore extra slashes, which spam uses to hide links: https:////host/
        auto authority = url[scheme.length .. $];
        while (authority.length && authority[0].among('/', '\\'))
            authority = authority[1 .. $];
        auto end = authority.representation.countUntil!(c => c <= ' ' || c.among('/', '?', '#', '"', '\'', '<', '>'));
        if (end >= 0)
            authority = authority[0 .. end];
        // http://paypal.com@evil.example/ goes to evil.example
        auto at = authority.lastIndexOf('@');
        auto host = authority[at + 1 .. $];
        auto colon = host.indexOf(':');
        if (colon >= 0)
            host = host[0 .. colon];
        host = host.toLower;

        if (host.length && domains.length < 20 && !domains.canFind(host))
            domains ~= host;
        return;
    }
}

string namedEntity(string name)
{
    switch (name)
    {
    case "amp": return "&";
    case "lt": return "<";
    case "gt": return ">";
    case "quot": return "\"";
    case "apos": return "'";
    case "nbsp": return " ";
    case "zwnj", "zwj", "shy": return "";
    case "copy": return "©";
    case "reg": return "®";
    case "trade": return "™";
    case "hellip": return "…";
    case "mdash": return "—";
    case "ndash": return "–";
    case "lsquo": return "‘";
    case "rsquo": return "’";
    case "ldquo": return "“";
    case "rdquo": return "”";
    case "euro": return "€";
    case "bull": return "•";
    case "middot": return "·";
    default: return null;
    }
}

string decodeEntities(string text)
{
    if (!text.canFind('&'))
        return text;

    auto result = appender!string;
    size_t i = 0;
    while (i < text.length)
    {
        auto amp = text.indexOf('&', i);
        if (amp < 0)
        {
            result.put(text[i .. $]);
            break;
        }
        result.put(text[i .. amp]);

        auto semicolon = text.indexOf(';', amp);
        if (semicolon < 0 || semicolon - amp > 10)
        {
            result.put('&');
            i = amp + 1;
            continue;
        }

        auto entity = text[amp + 1 .. semicolon];
        auto replacement = namedEntity(entity.toLower);
        i = semicolon + 1;
        if (replacement !is null)
            result.put(replacement);
        else if (entity.startsWith('#') && entity.length > 1)
        {
            auto hex = entity[1] == 'x' || entity[1] == 'X';
            uint code;
            try
                code = entity[hex ? 2 : 1 .. $].to!uint(hex ? 16 : 10);
            catch (Exception)
                code = uint.max;
            if (isValidDchar(code))
                result.put(cast(dchar) code);
        }
        else
            result.put(text[amp .. i]);
    }
    return result[];
}

/// Drops invisible characters, collapses spaces and keeps at most one blank line.
string normalizeWhitespace(string text)
{
    auto result = appender!string;
    int newlines = 0;
    bool space = false;
    foreach (dchar c; text)
    {
        if (c.among('​', '‌', '‍', '⁠', '﻿', '­', '͏', '\r'))
            continue;
        if (c == '\n')
        {
            newlines++;
            continue;
        }
        if (isWhite(c))
        {
            space = true;
            continue;
        }

        if (result[].length)
            result.put(newlines > 1 ? "\n\n" : newlines ? "\n" : space ? " " : "");
        newlines = 0;
        space = false;
        result.put(c);
    }
    return result[];
}

string truncate(string text, size_t maxChars)
{
    size_t count = 0;
    foreach (i, dchar c; text)
        if (count++ == maxChars)
            return text[0 .. i] ~ " […]";
    return text;
}

unittest
{
    import std.array : join;

    string[] domains;
    addDomain(domains, "https:////qw.example.com////x.html");
    addDomain(domains, "http://Paypal.com@evil.example/login");
    addDomain(domains, "https://shop.example:8080/a");
    assert(domains == ["qw.example.com", "evil.example", "shop.example"], domains.join(","));
}
