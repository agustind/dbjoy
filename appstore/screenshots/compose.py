#!/usr/bin/env python3
"""Composes App Store screenshots (2880x1800, 16:10) from raw window captures in ./raw.

Usage: python3 appstore/screenshots/compose.py
Writes appstore/screenshots/<name>.png, plus 1440x900 copies in ./1440x900.
Raw captures are taken with `screencapture -o -l <window id>` of a demo instance at 1440x900 points.
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = Path(__file__).resolve().parent
RAW = HERE / "raw"
W, H = 2880, 1800
FONT = "/System/Library/Fonts/SFNS.ttf"

LIGHT = dict(top=(255, 243, 248), bottom=(238, 226, 242), title=(30, 29, 32), accent=(142, 63, 138), sub=(96, 92, 104))
DARK = dict(top=(42, 27, 43), bottom=(18, 14, 20), title=(242, 241, 244), accent=(232, 168, 228), sub=(178, 172, 184))

SHOTS = [
    # file, theme, headline (accent part in [brackets]), subtitle, layout
    ("01-browse", LIGHT, "Postgres, [beautifully native].",
     "A fast, keyboard-friendly database client made for the Mac.", "center"),
    ("02-edit", LIGHT, "Edit safely. [Commit with confidence.]",
     "Changes are staged and color-coded, then committed in one transaction.", "center"),
    ("03-review", LIGHT, "[No surprises] on production.",
     "Every write shows its SQL and waits for your OK before it runs.", "center"),
    ("04-sql", LIGHT, "A SQL editor that [keeps up].",
     "Highlighting, alias-aware completion, multiple result sets and transactions.", "center"),
    ("05-diagram", LIGHT, "See your [whole schema].",
     "ER diagrams and relations, drawn straight from your foreign keys.", "center"),
    ("06-search-dark", DARK, "Find any row [in seconds].",
     "Combine filters by column and operator, then edit the results in place.", "center"),
    ("07-connections", LIGHT, "Every environment,\n[color-coded].",
     "Folders, stars, SSH tunnels, read-only mode and passwords in the Keychain.", "side"),
    ("08-structure-dark", DARK, "Change structure [without the DDL].",
     "Columns, indexes and constraints, applied as reviewed ALTER statements.", "center"),
    ("09-assistant", LIGHT, "Ask your database [anything].",
     "The AI assistant reads your schema, runs read-only queries and answers in plain language.", "center"),
    ("10-assistant-sql-dark", DARK, "SQL, [written for you].",
     "Describe what you need. The assistant writes the query and opens it in a tab, ready to run.", "center"),
]


def font(size, weight):
    f = ImageFont.truetype(FONT, size)
    f.set_variation_by_name(weight)
    return f


def gradient(theme):
    top, bottom = theme["top"], theme["bottom"]
    column = Image.new("RGB", (1, H))
    for y in range(H):
        t = y / (H - 1)
        column.putpixel((0, y), tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)))
    return column.resize((W, H)).convert("RGBA")


def draw_rich(draw, xy, text, fnt, theme, anchor):
    """Draws one line where [bracketed] text uses the accent color. anchor: 'center' or 'left' (x is center/left)."""
    parts, accent, buf = [], False, ""
    for ch in text:
        if ch in "[]":
            if buf:
                parts.append((buf, accent))
            buf, accent = "", ch == "["
        else:
            buf += ch
    if buf:
        parts.append((buf, accent))
    total = sum(draw.textlength(p, font=fnt) for p, _ in parts)
    x, y = xy
    if anchor == "center":
        x -= total / 2
    for p, is_accent in parts:
        draw.text((x, y), p, font=fnt, fill=theme["accent"] if is_accent else theme["title"])
        x += draw.textlength(p, font=fnt)


def with_shadow(canvas, window, pos, radius=60, offset=24, opacity=110):
    alpha = window.split()[-1]
    margin = radius * 4
    mask = Image.new("L", (window.width + margin * 2, window.height + margin * 2), 0)
    mask.paste(alpha.point(lambda a: opacity if a > 0 else 0), (margin, margin))
    shadow = Image.new("RGBA", mask.size, (0, 0, 0, 0))
    shadow.putalpha(mask.filter(ImageFilter.GaussianBlur(radius)))
    # Clip to the canvas so alpha_composite accepts negative offsets.
    x, y = pos[0] - margin, pos[1] - margin + offset
    crop = shadow.crop((max(0, -x), max(0, -y), shadow.width, shadow.height))
    canvas.alpha_composite(crop, (max(0, x), max(0, y)))
    canvas.alpha_composite(window, pos)


def compose(name, theme, headline, subtitle, layout):
    canvas = gradient(theme)
    draw = ImageDraw.Draw(canvas)
    window = Image.open(RAW / f"{name}.png").convert("RGBA")
    title_font, sub_font = font(112, "Bold"), font(50, "Regular")

    if layout == "center":
        draw_rich(draw, (W / 2, 96), headline, title_font, theme, "center")
        draw.text((W / 2, 260), subtitle, font=sub_font, fill=theme["sub"], anchor="ma")
        # Fit the whole window (its bottom bar matters) between the subtitle and the bottom edge.
        top, bottom_margin = 380, 60
        scale = (H - top - bottom_margin) / window.height
        window = window.resize((round(window.width * scale), H - top - bottom_margin), Image.LANCZOS)
        with_shadow(canvas, window, ((W - window.width) // 2, top))
    else:  # text left, window right
        lines = headline.split("\n")
        y = 560
        for line in lines:
            draw_rich(draw, (200, y), line, title_font, theme, "left")
            y += 140
        y += 40
        for line in wrap(draw, subtitle, sub_font, 1100):
            draw.text((200, y), line, font=sub_font, fill=theme["sub"])
            y += 70
        scale = 1520 / window.height
        window = window.resize((round(window.width * scale), 1520), Image.LANCZOS)
        with_shadow(canvas, window, (W - window.width - 220, 180))

    out = canvas.convert("RGB")
    out.save(HERE / f"{name}.png", optimize=True)
    small = HERE / "1440x900"
    small.mkdir(exist_ok=True)
    out.resize((1440, 900), Image.LANCZOS).save(small / f"{name}.png", optimize=True)


def wrap(draw, text, fnt, width):
    lines, line = [], ""
    for word in text.split():
        trial = f"{line} {word}".strip()
        if draw.textlength(trial, font=fnt) > width and line:
            lines.append(line)
            line = word
        else:
            line = trial
    return lines + [line]


if __name__ == "__main__":
    for shot in SHOTS:
        compose(*shot)
        print("wrote", shot[0])
