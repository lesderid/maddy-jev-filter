/// Just enough MIME to get at the text of a message: header fields, multipart
/// bodies, transfer encodings, encoded words and charsets.
module jevfilter.mime;

import std.algorithm : among, canFind, countUntil, min, splitter, startsWith;
import std.array : appender;
import std.ascii : isAlphaNum, isHexDigit;
import std.base64 : Base64;
import std.encoding : sanitize;
import std.string : indexOf, representation, strip, toStringz;
import std.uni : toLower;

alias Bytes = const(ubyte)[];

struct Entity
{
    Bytes header;
    Bytes body_;
}

Entity splitEntity(Bytes data)
{
    size_t pos = 0;
    while (pos < data.length)
    {
        auto newline = data[pos .. $].countUntil('\n');
        auto lineEnd = newline < 0 ? data.length : pos + newline;
        auto line = trimCR(data[pos .. lineEnd]);
        if (!line.length)
            return Entity(data[0 .. pos], data[min(lineEnd + 1, $) .. $]);
        pos = lineEnd + 1;
    }
    return Entity(data, null);
}

struct Field
{
    string name;
    Bytes value;
}

Field[] parseFields(Bytes header)
{
    Field[] fields;
    foreach (line; header.splitter('\n'))
    {
        line = trimCR(line);
        if (line.length && (line[0] == ' ' || line[0] == '\t'))
        {
            if (fields.length)
                fields[$ - 1].value ~= line;
            continue;
        }
        auto colon = line.countUntil(':');
        if (colon > 0)
            fields ~= Field(toUtf8(line[0 .. colon]).strip.toLower, line[colon + 1 .. $]);
    }
    return fields;
}

Bytes fieldValue(Field[] fields, string name)
{
    foreach (field; fields)
        if (field.name == name)
            return field.value;
    return null;
}

Bytes[] multipartParts(Bytes data, string boundary)
{
    if (!boundary.length)
        return null;

    auto delimiter = ("--" ~ boundary).representation;
    Bytes[] parts;
    ptrdiff_t partStart = -1;
    size_t pos = 0;
    while (pos < data.length)
    {
        auto newline = data[pos .. $].countUntil('\n');
        auto lineEnd = newline < 0 ? data.length : pos + newline;
        auto line = trimCR(data[pos .. lineEnd]);

        if (line.startsWith(delimiter))
        {
            auto rest = line[delimiter.length .. $];
            auto closing = rest.startsWith("--".representation);
            if (closing || !rest.canFind!(c => c != ' ' && c != '\t'))
            {
                if (partStart >= 0)
                    parts ~= data[partStart .. pos];
                if (closing)
                    return parts;
                partStart = min(lineEnd + 1, data.length);
            }
        }
        pos = lineEnd + 1;
    }
    if (partStart >= 0)
        parts ~= data[partStart .. $];
    return parts;
}

struct Params
{
    string value;
    string[string] params;
}

/// Parses `value; key=value; key="quoted value"` header fields like Content-Type.
Params parseParams(Bytes raw)
{
    auto text = toUtf8(raw);
    Params result;

    auto semicolon = text.indexOf(';');
    result.value = (semicolon < 0 ? text : text[0 .. semicolon]).strip.toLower;
    if (semicolon < 0)
        return result;

    auto rest = text[semicolon + 1 .. $];
    while (rest.length)
    {
        auto eq = rest.indexOf('=');
        auto end = rest.indexOf(';');
        if (eq < 0 || (end >= 0 && end < eq))
        {
            rest = end < 0 ? null : rest[end + 1 .. $];
            continue;
        }

        auto key = rest[0 .. eq].strip.toLower;
        rest = rest[eq + 1 .. $].strip;
        string value;
        if (rest.startsWith('"'))
        {
            auto quoted = appender!string;
            size_t i = 1;
            for (; i < rest.length && rest[i] != '"'; i++)
            {
                if (rest[i] == '\\' && i + 1 < rest.length)
                    i++;
                quoted.put(rest[i]);
            }
            value = quoted[];
            rest = rest[min(i + 1, $) .. $];
            auto next = rest.indexOf(';');
            rest = next < 0 ? null : rest[next + 1 .. $];
        }
        else
        {
            end = rest.indexOf(';');
            value = (end < 0 ? rest : rest[0 .. end]).strip;
            rest = end < 0 ? null : rest[end + 1 .. $];
        }

        // RFC 2231 extended value without continuations: charset'language'percent-encoded
        if (key.length > 1 && key[$ - 1] == '*')
        {
            key = key[0 .. $ - 1];
            auto firstQuote = value.indexOf('\'');
            auto secondQuote = firstQuote < 0 ? -1 : value.indexOf('\'', firstQuote + 1);
            if (secondQuote >= 0)
                value = toUtf8(decodePercent(value[secondQuote + 1 .. $].representation), value[0 .. firstQuote]);
        }

        result.params[key] = value;
    }
    return result;
}

ubyte[] decodeTransfer(Bytes data, string encoding)
{
    switch (encoding)
    {
    case "base64":
        return decodeBase64(data);
    case "quoted-printable":
        return decodeQuotedPrintable(data);
    default:
        return data.dup;
    }
}

ubyte[] decodeBase64(Bytes data)
{
    auto clean = appender!(char[]);
    foreach (c; data)
        if (isAlphaNum(c) || c == '+' || c == '/')
            clean.put(cast(char) c);

    auto encoded = clean[];
    if (encoded.length % 4 == 1)
        encoded = encoded[0 .. $ - 1];
    while (encoded.length % 4)
        encoded ~= '=';
    return Base64.decode(encoded);
}

ubyte[] decodeQuotedPrintable(Bytes data, bool underscoreIsSpace = false)
{
    auto result = appender!(ubyte[]);
    for (size_t i = 0; i < data.length; i++)
    {
        auto c = data[i];
        if (c == '_' && underscoreIsSpace)
        {
            result.put(cast(ubyte) ' ');
            continue;
        }
        if (c != '=')
        {
            result.put(c);
            continue;
        }

        if (i + 2 < data.length && isHexDigit(data[i + 1]) && isHexDigit(data[i + 2]))
        {
            result.put(cast(ubyte)(hexValue(data[i + 1]) << 4 | hexValue(data[i + 2])));
            i += 2;
            continue;
        }

        // Soft line break, possibly with trailing whitespace before the newline
        auto j = i + 1;
        while (j < data.length && (data[j] == ' ' || data[j] == '\t'))
            j++;
        if (j < data.length && data[j] == '\r')
            j++;
        if (j < data.length && data[j] == '\n')
            i = j;
        else if (j < data.length)
            result.put(c);
    }
    return result[];
}

ubyte[] decodePercent(Bytes data)
{
    auto result = appender!(ubyte[]);
    for (size_t i = 0; i < data.length; i++)
    {
        if (data[i] == '%' && i + 2 < data.length && isHexDigit(data[i + 1]) && isHexDigit(data[i + 2]))
        {
            result.put(cast(ubyte)(hexValue(data[i + 1]) << 4 | hexValue(data[i + 2])));
            i += 2;
        }
        else
            result.put(data[i]);
    }
    return result[];
}

ubyte hexValue(ubyte c)
{
    return cast(ubyte)(c <= '9' ? c - '0' : (c | 0x20) - 'a' + 10);
}

/// Decodes RFC 2047 encoded words (`=?charset?B?...?=`) in a header field value.
/// Other text that isn't valid UTF-8 is read as `fallbackCharset`.
string decodeWords(Bytes value, string fallbackCharset = null)
{
    auto result = appender!string;
    Bytes pendingSpace;
    bool afterWord = false;

    size_t i = 0;
    while (i < value.length)
    {
        if (value[i .. $].startsWith("=?".representation))
        {
            string word;
            size_t length;
            if (decodeWord(value[i .. $], word, length))
            {
                // Whitespace between two encoded words is not part of the text
                if (!afterWord)
                    result.put(toUtf8(pendingSpace));
                pendingSpace = null;
                result.put(word);
                afterWord = true;
                i += length;
                continue;
            }
        }

        auto start = i;
        if (value[i] == ' ' || value[i] == '\t')
        {
            while (i < value.length && (value[i] == ' ' || value[i] == '\t'))
                i++;
            pendingSpace = value[start .. i];
            continue;
        }

        i++;
        while (i < value.length && value[i] != ' ' && value[i] != '\t' && !value[i .. $].startsWith("=?".representation))
            i++;
        auto text = value[start .. i];
        result.put(toUtf8(pendingSpace));
        result.put(toUtf8(text, isValidUtf8(text) ? null : fallbackCharset));
        pendingSpace = null;
        afterWord = false;
    }
    result.put(toUtf8(pendingSpace));
    return result[];
}

bool isValidUtf8(Bytes data)
{
    import std.utf : UTFException, validate;

    try
        validate(cast(const(char)[]) data);
    catch (UTFException)
        return false;
    return true;
}

bool decodeWord(Bytes data, out string word, out size_t length)
{
    auto charsetEnd = data[2 .. $].countUntil('?');
    if (charsetEnd <= 0)
        return false;
    auto charset = toUtf8(data[2 .. 2 + charsetEnd]);
    auto rest = data[2 + charsetEnd + 1 .. $];
    if (rest.length < 2 || rest[1] != '?')
        return false;

    auto encoding = rest[0] | 0x20;
    auto payloadStart = 2 + charsetEnd + 3;
    auto payloadLength = data[payloadStart .. $].countUntil("?=".representation);
    if (payloadLength < 0 || !encoding.among('b', 'q'))
        return false;
    auto payload = data[payloadStart .. payloadStart + payloadLength];

    // A charset can carry an RFC 2231 language suffix: utf-8*en
    auto star = charset.indexOf('*');
    if (star >= 0)
        charset = charset[0 .. star];

    word = toUtf8(encoding == 'b' ? decodeBase64(payload) : decodeQuotedPrintable(payload, true), charset);
    length = payloadStart + payloadLength + 2;
    return true;
}

/// Converts text in `charset` to UTF-8 with iconv, replacing what it can't convert.
string toUtf8(Bytes data, string charset = null)
{
    import core.stdc.errno : E2BIG, errno;
    import core.sys.posix.iconv : iconv, iconv_close, iconv_open, iconv_t;

    charset = charset.strip.toLower;
    if (charset.among(null, "utf-8", "utf8", "us-ascii", "ascii"))
        return sanitize(cast(string) data.idup);

    // Names mail clients use that iconv doesn't know, or supersets that decode more
    switch (charset)
    {
    case "ks_c_5601-1987", "ks_c_5601", "euc-kr":
        charset = "cp949";
        break;
    case "gb2312", "gbk", "x-gbk":
        charset = "gb18030";
        break;
    case "shift_jis", "sjis", "x-sjis":
        charset = "cp932";
        break;
    case "iso-8859-8-i":
        charset = "iso-8859-8";
        break;
    default:
        break;
    }

    auto cd = iconv_open("UTF-8", charset.toStringz);
    if (cd == cast(iconv_t) -1)
        return sanitize(cast(string) data.idup);
    scope (exit)
        iconv_close(cd);

    auto output = new char[data.length * 4 + 16];
    auto input = cast(char*) data.ptr;
    auto inputLeft = data.length;
    auto out_ = output.ptr;
    auto outputLeft = output.length;
    while (inputLeft)
    {
        if (iconv(cd, &input, &inputLeft, &out_, &outputLeft) != cast(size_t) -1 || errno == E2BIG)
            break;
        // Invalid or incomplete sequence: replace one byte and carry on
        input++;
        inputLeft--;
        if (outputLeft < 3)
            break;
        out_[0 .. 3] = "�";
        out_ += 3;
        outputLeft -= 3;
    }
    return sanitize(output[0 .. $ - outputLeft].idup);
}

Bytes trimCR(Bytes line)
{
    return line.length && line[$ - 1] == '\r' ? line[0 .. $ - 1] : line;
}
