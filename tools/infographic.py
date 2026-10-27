#!/usr/bin/env python3
"""Draws the infographic in docs/ as an SVG.

    tools/infographic.py [--folder NAME --folder-text TEXT] FONT OUT.svg

FONT is Fredoka's variable font (SIL Open Font License), from
https://github.com/google/fonts/tree/main/ofl/fredoka. The SVG embeds a
subset of it, so it looks the same where web fonts can't load, as in
GitHub's READMEs. --folder and --folder-text describe the fourth folder
card, the example config's last rule. Needs fontTools and brotli.
"""
import argparse
import base64
import io
import sys
from xml.sax.saxutils import escape

from fontTools import subset
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer

parser = argparse.ArgumentParser()
parser.add_argument("--folder", default="Sports")
parser.add_argument("--folder-text", default="an example of sorting by topic")
parser.add_argument("font")
parser.add_argument("out")
args = parser.parse_args()
FONT, out_path = args.font, args.out

W, M = 1000, 40
INNER = W - 2 * M
BG, INK, MUTED, SHADOW = "#FFF9F2", "#4B4453", "#7D7488", "#F1E6D8"
PINK = ("#FFD6E0", "#F2A7BA")
PEACH = ("#FFE3C8", "#F2B98A")
BUTTER = ("#FFF2C2", "#E6CC6A")
MINT = ("#D4F2E3", "#8FCFAE")
SKY = ("#D6E9FB", "#93BFE8")
LAVENDER = ("#E7DEFB", "#B7A4EC")

_static = {}


def static(weight):
    if weight not in _static:
        _static[weight] = instancer.instantiateVariableFont(TTFont(FONT), {"wght": weight, "wdth": 100})
    return _static[weight]


def text_width(s, size, weight=400):
    font = static(weight)
    cmap, hmtx, upm = font.getBestCmap(), font["hmtx"], font["head"].unitsPerEm
    return sum(hmtx[cmap.get(ord(c), cmap[ord("?")])][0] for c in s) * size / upm


def wrap(s, size, max_width, weight=400):
    lines, line = [], ""
    for word in s.split():
        candidate = f"{line} {word}".strip()
        if text_width(candidate, size, weight) <= max_width or not line:
            line = candidate
        else:
            lines.append(line)
            line = word
    return lines + [line]


used = set()
parts = []


def add(svg):
    parts.append(svg)


def text(x, y, s, size, weight=400, fill=INK, anchor="start", mono=False):
    if not mono:
        used.update(s)
    cls = ' class="mono"' if mono else ""
    add(f'<text x="{x:.1f}" y="{y:.1f}" font-size="{size}" font-weight="{weight}" fill="{fill}" '
        f'text-anchor="{anchor}"{cls}>{escape(s)}</text>')


def lines(x, y, rows, size, weight=400, fill=INK, anchor="middle", leading=1.3):
    for i, row in enumerate(rows):
        text(x, y + i * size * leading, row, size, weight, fill, anchor)
    return y + len(rows) * size * leading


def card(x, y, w, h, colors, r=20, shadow=True):
    fill, stroke = colors
    if shadow:
        add(f'<rect x="{x + 5}" y="{y + 6}" width="{w}" height="{h}" rx="{r}" fill="{SHADOW}"/>')
    add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" fill="{fill}" stroke="{stroke}" stroke-width="2.5"/>')


def chip(cx, y, label, colors, size=14):
    w = text_width(label, size, 500) + 22
    add(f'<rect x="{cx - w / 2:.1f}" y="{y}" width="{w:.1f}" height="{size + 12}" rx="{(size + 12) / 2}" '
        f'fill="#FFFFFF" stroke="{colors[1]}" stroke-width="2"/>')
    text(cx, y + size + 3, label, size, 500, INK, "middle")


def sparkle(cx, cy, r, fill):
    k = r * 0.28
    add(f'<path d="M{cx} {cy - r} Q{cx + k} {cy - k} {cx + r} {cy} Q{cx + k} {cy + k} {cx} {cy + r} '
        f'Q{cx - k} {cy + k} {cx - r} {cy} Q{cx - k} {cy - k} {cx} {cy - r} Z" fill="{fill}"/>')


def arrow(x1, y, x2, color="#C7BBD6"):
    add(f'<line x1="{x1}" y1="{y}" x2="{x2 - 7}" y2="{y}" stroke="{color}" stroke-width="4" stroke-linecap="round"/>')
    add(f'<path d="M{x2 - 10} {y - 8} L{x2} {y} L{x2 - 10} {y + 8}" fill="none" stroke="{color}" '
        f'stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/>')


def badge(cx, cy, n, colors):
    add(f'<circle cx="{cx}" cy="{cy}" r="17" fill="{colors[0]}" stroke="{colors[1]}" stroke-width="2.5"/>')
    text(cx, cy + 7, str(n), 19, 600, INK, "middle")


def section(y, n, title, colors):
    badge(M + 17, y - 8, n, colors)
    text(M + 46, y, title, 26, 600)


# Icons, drawn around a centre point

def envelope(cx, cy, w, colors, face=False):
    h = w * 0.68
    x, y = cx - w / 2, cy - h / 2
    add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{w * 0.1}" fill="#FFFFFF" stroke="{colors[1]}" stroke-width="2.5"/>')
    add(f'<path d="M{x + 4} {y + 5} L{cx} {y + h * 0.52} L{x + w - 4} {y + 5}" fill="none" stroke="{colors[1]}" '
        f'stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"/>')
    if face:
        ey = y + h * 0.72
        for dx in (-w * 0.13, w * 0.13):
            add(f'<circle cx="{cx + dx}" cy="{ey}" r="{w * 0.035}" fill="{INK}"/>')
        for dx in (-w * 0.25, w * 0.25):
            add(f'<ellipse cx="{cx + dx}" cy="{ey + w * 0.05}" rx="{w * 0.06}" ry="{w * 0.035}" fill="{PINK[1]}"/>')
        add(f'<path d="M{cx - w * 0.05} {ey + w * 0.05} Q{cx} {ey + w * 0.1} {cx + w * 0.05} {ey + w * 0.05}" '
            f'fill="none" stroke="{INK}" stroke-width="2" stroke-linecap="round"/>')


def magnifier(cx, cy, colors):
    add(f'<circle cx="{cx - 5}" cy="{cy - 5}" r="15" fill="#FFFFFF" stroke="{colors[1]}" stroke-width="3"/>')
    add(f'<line x1="{cx + 6}" y1="{cy + 6}" x2="{cx + 17}" y2="{cy + 17}" stroke="{colors[1]}" stroke-width="5" stroke-linecap="round"/>')


def bubble(cx, cy, colors):
    add(f'<path d="M{cx - 24} {cy - 18} h48 a8 8 0 0 1 8 8 v20 a8 8 0 0 1 -8 8 h-30 l-10 9 v-9 h-8 '
        f'a8 8 0 0 1 -8 -8 v-20 a8 8 0 0 1 8 -8 z" fill="#FFFFFF" stroke="{colors[1]}" stroke-width="2.5" stroke-linejoin="round"/>')
    text(cx, cy + 8, "?", 22, 600, INK, "middle")


def checklist(cx, cy, colors):
    for i, dy in enumerate((-14, 0, 14)):
        y = cy + dy
        add(f'<path d="M{cx - 22} {y} l4 4 l7 -8" fill="none" stroke="{colors[1]}" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/>')
        add(f'<line x1="{cx - 4}" y1="{y}" x2="{cx + 22 - i * 6}" y2="{y}" stroke="{colors[1]}" stroke-width="3" stroke-linecap="round"/>')


def folder(cx, cy, w, colors, fill="#FFFFFF"):
    h = w * 0.72
    x, y = cx - w / 2, cy - h / 2
    add(f'<path d="M{x} {y + 6} a6 6 0 0 1 6 -6 h{w * 0.3} l{w * 0.08} {h * 0.14} h{w * 0.62 - 12} a6 6 0 0 1 6 6 '
        f'v{h * 0.86 - 6} a6 6 0 0 1 -6 6 h{-(w - 12)} a6 6 0 0 1 -6 -6 z" fill="{fill}" stroke="{colors[1]}" '
        f'stroke-width="2.5" stroke-linejoin="round"/>')
    add(f'<line x1="{x + 3}" y1="{y + h * 0.3}" x2="{x + w - 3}" y2="{y + h * 0.3}" stroke="{colors[1]}" stroke-width="2"/>')


def loop(cx, cy, colors):
    s = colors[1]
    add(f'<path d="M{cx - 18} {cy + 2} a18 18 0 0 1 32 -11" fill="none" stroke="{s}" stroke-width="4" stroke-linecap="round"/>')
    add(f'<path d="M{cx + 7} {cy - 16} l8 6 l2 -10" fill="none" stroke="{s}" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/>')
    add(f'<path d="M{cx + 18} {cy - 2} a18 18 0 0 1 -32 11" fill="none" stroke="{s}" stroke-width="4" stroke-linecap="round"/>')
    add(f'<path d="M{cx - 7} {cy + 16} l-8 -6 l-2 10" fill="none" stroke="{s}" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/>')


def heart(cx, cy, colors):
    add(f'<path d="M{cx} {cy + 15} C{cx - 30} {cy - 4} {cx - 14} {cy - 24} {cx} {cy - 9} '
        f'C{cx + 14} {cy - 24} {cx + 30} {cy - 4} {cx} {cy + 15} Z" fill="#FFFFFF" stroke="{colors[1]}" '
        f'stroke-width="2.5" stroke-linejoin="round"/>')


def bin_(cx, cy, colors):
    s = colors[1]
    add(f'<path d="M{cx - 13} {cy - 9} l3 26 a3 3 0 0 0 3 3 h14 a3 3 0 0 0 3 -3 l3 -26 z" fill="#FFFFFF" stroke="{s}" stroke-width="2.5" stroke-linejoin="round"/>')
    add(f'<line x1="{cx - 18}" y1="{cy - 10}" x2="{cx + 18}" y2="{cy - 10}" stroke="{s}" stroke-width="3" stroke-linecap="round"/>')
    add(f'<path d="M{cx - 5} {cy - 11} v-4 h10 v4" fill="none" stroke="{s}" stroke-width="2.5" stroke-linejoin="round"/>')


def shield(cx, cy, colors):
    add(f'<path d="M{cx} {cy - 20} l17 6 v10 c0 12 -8 20 -17 24 c-9 -4 -17 -12 -17 -24 v-10 z" fill="#FFFFFF" '
        f'stroke="{colors[1]}" stroke-width="2.5" stroke-linejoin="round"/>')
    add(f'<path d="M{cx - 7} {cy + 1} l5 5 l9 -10" fill="none" stroke="{colors[1]}" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/>')


# Header

envelope(M + 48, 92, 92, PINK, face=True)
sparkle(M + 104, 46, 9, BUTTER[1])
sparkle(M + 6, 136, 7, LAVENDER[1])
text(M + 125, 95, "maddy-jev-filter", 48, 600)
text(M + 127, 133, "Spam and phishing filtering for the maddy mail server, with Jev", 21, 400, MUTED)
sparkle(W - M - 30, 62, 11, MINT[1])
sparkle(W - M - 62, 98, 7, PEACH[1])

# 1. How a message flows

y = 205
section(y, 1, "How a message flows", SKY)
top, h, w, gap = y + 25, 215, 160, 30
steps = [
    (SKY, lambda cx, cy: envelope(cx, cy, 54, SKY), "Mail arrives", ["over SMTP; maddy checks SPF, DKIM and DMARC"]),
    (BUTTER, lambda cx, cy: magnifier(cx, cy, BUTTER), "check", ["maddy-jev-filter runs in the local delivery pipeline"]),
    (PINK, lambda cx, cy: bubble(cx, cy, PINK), "Jev answers", ["spam · phishing", "personal", "transactional", "topic", "not interested"]),
    (LAVENDER, lambda cx, cy: checklist(cx, cy, LAVENDER), "Rules", ["first match wins, using Jev's answers and your mailbox"]),
    (MINT, lambda cx, cy: folder(cx, cy, 50, MINT), "route", ["maddy files the message, read or unread"]),
]
for i, (colors, icon, title, body) in enumerate(steps):
    x = M + i * (w + gap)
    card(x, top, w, h, colors)
    icon(x + w / 2, top + 42)
    text(x + w / 2, top + 98, title, 21, 600, INK, "middle")
    rows = body if len(body) > 1 else wrap(body[0], 15.5, w - 26)
    lines(x + w / 2, top + 126, rows, 15.5, 400, INK, "middle", 1.32 if len(body) == 1 else 1.22)
    if i < len(steps) - 1:
        arrow(x + w + 5, top + h / 2, x + w + gap - 3)

y = top + h + 36
text(M, y, "Every message gets a header that says what happened and why:", 16, 400, MUTED)
card(M, y + 12, INNER, 46, BUTTER, r=23, shadow=False)
add(f'<text x="{M + 22}" y="{y + 41}" font-size="15.5" class="mono" fill="{INK}">'
    'X-Maddy-Jev-Filter-Action: folder=Junk; read=yes; rule=spam-certain; version=4f2a9c81d0e3</text>')

# 2. Where it goes

y += 120
section(y, 2, "Where it goes", PINK)
folders = [
    ("Junk", PINK, "spam and phishing Jev is sure about", "marked read"),
    ("Not interested", LAVENDER, "mail like what you've put there", "marked read"),
    ("Suspicious", PEACH, "probable spam and possible phishing", "unread"),
    (args.folder, MINT, args.folder_text, "unread"),
    ("INBOX", SKY, "everything else", "as usual"),
]
top, h, w, gap = y + 25, 205, 168, 20
for i, (name, colors, desc, state) in enumerate(folders):
    x = M + i * (w + gap)
    card(x, top, w, h, colors)
    folder(x + w / 2, top + 44, 58, colors)
    text(x + w / 2, top + 102, name, 20 if len(name) < 12 else 19, 600, INK, "middle")
    lines(x + w / 2, top + 128, wrap(desc, 15, w - 26), 15, 400, INK, "middle")
    chip(x + w / 2, top + h - 40, state, colors)

# 3. It learns from your mailbox

y = top + h + 60
section(y, 3, "It learns from your mailbox", LAVENDER)
top, h, gap = y + 25, 200, 20
w = (INNER - 2 * gap) / 3
learn = [
    (LAVENDER, loop, "Not interested",
     "Drag mail into Not interested. Every 15 minutes it becomes examples, per sender, and more of the same kind follows it there."),
    (MINT, heart, "Senders you kept",
     "Never kept anything from this sender? Then a spam score of 0.85 is enough for Junk. Throwaway domains are new every time."),
    (PINK, bin_, "Senders in Junk",
     "Their mail is in Junk and you kept none? Then a spam score of 0.5 is enough: repeat senders Jev only half suspects."),
]
for i, (colors, icon, title, body) in enumerate(learn):
    x = M + i * (w + gap)
    card(x, top, w, h, colors)
    icon(x + 44, top + 44, colors)
    text(x + 80, top + 52, title, 21, 600)
    rows = wrap(body, 15.5, w - 40)
    for j, row in enumerate(rows):
        text(x + 22, top + 94 + j * 15.5 * 1.36, row, 15.5)

# 4. How well it works

y = top + h + 60
section(y, 4, "How well it works", MINT)
top, h, gap = y + 25, 160, 20
w = (INNER - 3 * gap) / 4
stats = [
    (PINK, "96.0%", "of spam goes to Junk"),
    (MINT, "0", "of 3,595 real messages junked"),
    (PEACH, "8", "real messages in Suspicious, for a look"),
    (BUTTER, "$0.10", "Jev's cost for 1,500 messages"),
]
for i, (colors, big, caption) in enumerate(stats):
    x = M + i * (w + gap)
    card(x, top, w, h, colors, r=28)
    text(x + w / 2, top + 72, big, 50, 600, INK, "middle")
    lines(x + w / 2, top + 106, wrap(caption, 15.5, w - 30), 15.5, 400, INK, "middle")
y = top + h + 36
text(M, y, "Tested on 2,002 spam and 3,595 real messages from the author's mailbox; every experiment is in eval/NOTES.md.",
     15, 400, MUTED)

# Footer

top = y + 26
card(M, top, INNER, 78, SKY, r=39)
shield(M + 50, top + 39, SKY)
text(M + 88, top + 35, "Failures never cost mail.", 20, 600)
text(M + 88, top + 60, "If Jev is down, slow or anything else breaks, the message simply stays in INBOX.", 16, 400)
sparkle(W - M - 40, top + 39, 10, PINK[1])
sparkle(W - M - 70, top + 26, 6, BUTTER[1])
H = top + 78 + M

# The font: the weight axis only, and only the characters used

font = instancer.instantiateVariableFont(TTFont(FONT), {"wdth": 100})
cmap = font.getBestCmap()
missing = sorted(c for c in used if ord(c) not in cmap and not c.isspace())
if missing:
    sys.exit(f"missing glyphs: {missing}")
options = subset.Options()
options.flavor = "woff2"
options.layout_features = ["kern", "liga", "calt"]
subsetter = subset.Subsetter(options)
subsetter.populate(text="".join(sorted(used)))
subsetter.subset(font)
buffer = io.BytesIO()
font.flavor = "woff2"
font.save(buffer)
woff2 = base64.b64encode(buffer.getvalue()).decode()

style = (f"@font-face{{font-family:'Fredoka';font-weight:300 700;"
         f"src:url(data:font/woff2;base64,{woff2}) format('woff2');}}"
         "text{font-family:'Fredoka',sans-serif;}"
         ".mono{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,'Liberation Mono',monospace;}")
svg = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H:.0f}" viewBox="0 0 {W} {H:.0f}" '
       f'role="img" aria-label="maddy-jev-filter: how it sorts mail, how it learns from your mailbox, and how well it works">'
       f'<title>maddy-jev-filter</title><style>{style}</style>'
       f'<rect width="{W}" height="{H:.0f}" fill="{BG}"/>' + "".join(parts) + "</svg>\n")
open(out_path, "w").write(svg)
print(f"{out_path}: {W}x{H:.0f}, {len(svg) // 1024} KB, font {len(woff2) * 3 // 4 // 1024} KB, {len(used)} characters")
