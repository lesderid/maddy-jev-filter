/// Examples grouped by sender, as tools/update-examples.sh writes them, and
/// picking the ones that belong to the sender of a message.
module jevfilter.examples;

import std.algorithm : among, canFind, filter, map;
import std.array : array, join, split;
import std.json : JSONType, JSONValue;
import std.string : indexOf, lastIndexOf, strip;
import std.uni : toLower;

/// Who a From field says sent the message
struct Sender
{
    string address;
    /// The part of the domain an organisation registers: example.com for email3.example.com
    string domain;
    string name;
}

Sender parseSender(string from)
{
    string address, name;
    auto open = from.lastIndexOf('<');
    auto close = from.lastIndexOf('>');
    if (open >= 0 && close > open)
    {
        address = from[open + 1 .. close];
        name = from[0 .. open];
    }
    else
    {
        foreach (word; from.split)
            if (word.canFind('@'))
                address = word;
    }

    Sender sender;
    sender.address = address.strip.strip(`"'<>()`).toLower;
    sender.name = name.strip.strip(`"'`).strip.toLower;
    auto at = sender.address.lastIndexOf('@');
    if (at >= 0)
        sender.domain = registrableDomain(sender.address[at + 1 .. $]);
    return sender;
}

/// A rough registrable domain: the last two labels, or three under a
/// country's second level such as co.uk or com.au.
string registrableDomain(string host)
{
    auto labels = host.toLower.split('.').filter!(label => label.length).array;
    if (labels.length <= 2)
        return labels.join(".");
    auto underCountry = labels[$ - 1].length == 2
        && labels[$ - 2].among("co", "com", "net", "org", "ac", "gov", "edu", "ne", "or", "go");
    return labels[$ - (underCountry ? 3 : 2) .. $].join(".");
}

/// The entries of `examples` (a list of {"from", "to", "subjects"}) from the
/// same address, domain or display name as `sender`, at most `limit` of them.
JSONValue examplesFor(JSONValue examples, Sender sender, size_t limit = 5)
{
    JSONValue[] matches;
    if (examples.type != JSONType.array)
        return JSONValue(matches);

    foreach (entry; examples.array)
    {
        auto from = "from" in entry;
        if (!from || from.type != JSONType.string)
            continue;
        auto other = parseSender(from.str);
        if (sameSender(sender, other))
            matches ~= entry;
        if (matches.length == limit)
            break;
    }
    return JSONValue(matches);
}

/// What identifies a sender for "have we seen them before": their domain,
/// or their address at a free mail provider.
string senderKey(Sender sender)
{
    return sender.domain.length && !isFreeMail(sender.domain) ? sender.domain : sender.address;
}

bool sameSender(Sender a, Sender b)
{
    if (a.address.length && a.address == b.address)
        return true;
    // At a mail provider anyone can sign up for, the domain says nothing
    if (a.domain.length && a.domain == b.domain && !isFreeMail(a.domain))
        return true;
    // Names say little when every company uses them
    return a.name.length >= 4 && a.name == b.name
        && !a.name.among("noreply", "no-reply", "no reply", "support", "info", "admin", "newsletter",
            "service", "customer service", "team", "notifications", "mailer-daemon");
}

bool isFreeMail(string domain)
{
    return domain.among("gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com", "msn.com",
        "yahoo.com", "ymail.com", "aol.com", "icloud.com", "me.com", "mac.com", "proton.me", "protonmail.com",
        "pm.me", "gmx.com", "gmx.net", "gmx.de", "web.de", "mail.com", "yandex.com", "yandex.ru", "mail.ru",
        "qq.com", "163.com", "126.com", "yeah.net", "sina.com", "foxmail.com", "naver.com", "daum.net",
        "hanmail.net", "nate.com", "telenet.be", "skynet.be", "hotmail.be", "outlook.be") != 0;
}

unittest
{
    assert(registrableDomain("email3.example.com") == "example.com");
    assert(registrableDomain("mail.example.co.uk") == "example.co.uk");
    assert(registrableDomain("services.agency.go.jp") == "agency.go.jp");
    assert(registrableDomain("example.com") == "example.com");

    auto s = parseSender(`"Consumer News" <maillist@e-mailing.consumer.example>`);
    assert(s.address == "maillist@e-mailing.consumer.example" && s.domain == "consumer.example" && s.name == "consumer news");
    assert(parseSender("someone@example.org").domain == "example.org");
    assert(sameSender(parseSender("EXAMPLE.COM <newsletter@email3.example.com>"), parseSender("Example <hello@example.com>")));
    assert(!sameSender(parseSender("noreply <a@one.example>"), parseSender("noreply <b@two.example>")));
    assert(!sameSender(parseSender("Alice <alice@gmail.com>"), parseSender("Bob <bob@gmail.com>")));
    assert(sameSender(parseSender("Alice <alice@gmail.com>"), parseSender("alice@gmail.com")));
    assert(senderKey(parseSender("Example <newsletter@email3.example.com>")) == "example.com");
    assert(senderKey(parseSender("Alice <Alice@Gmail.com>")) == "alice@gmail.com");
}
