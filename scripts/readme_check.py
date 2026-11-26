"""Check that a README opens with a screenshot and a live link.

    python readme_check.py README.md [--top-lines 15] [--live-url URL] [--no-live-link]

Rules:
  * The first block of content after the title (a "# " heading) and any badge lines
    must be an image: Markdown ![alt](src), <img ...> or <picture>. Badges
    (shields.io, GitHub workflow badges) do not count as screenshots.
  * A live link must appear within the first --top-lines lines: an http(s) link that
    is not a badge, an image, or a github.com page. With --live-url, that exact URL
    (ignoring a trailing slash) must appear instead.
Exit 1 with a message per failed rule.
"""

from __future__ import annotations

import argparse
import re
import sys

IMG_MD = re.compile(r"!\[[^\]]*\]\(\s*<?([^)\s>]+)")
IMG_HTML = re.compile(r"<img\b[^>]*\bsrc\s*=\s*[\"']([^\"']+)", re.I)
PICTURE = re.compile(r"<picture\b", re.I)
LINK = re.compile(r"https?://[^\s)\"'<>\]]+")
BADGE_HOSTS = ("img.shields.io", "shields.io", "badgen.net", "badge.fury.io", "codecov.io")


def is_badge(src: str) -> bool:
    s = src.lower()
    path = s.split("?")[0]
    return any(h in s for h in BADGE_HOSTS) or path.endswith(("/badge", "badge.svg"))


def is_badge_line(line: str) -> bool:
    srcs = IMG_MD.findall(line) + IMG_HTML.findall(line)
    return bool(srcs) and all(is_badge(s) for s in srcs)


def has_screenshot(line: str) -> bool:
    srcs = IMG_MD.findall(line) + IMG_HTML.findall(line)
    return any(not is_badge(s) for s in srcs) or bool(PICTURE.search(line))


def live_links(lines: list[str]) -> list[str]:
    out = []
    for line in lines:
        images = set(IMG_MD.findall(line) + IMG_HTML.findall(line))
        for url in LINK.findall(line):
            u = url.rstrip(".,;")
            host = re.sub(r"^https?://", "", u).split("/")[0].lower()
            if u in images or is_badge(u) or host in ("github.com", "www.github.com"):
                continue
            if re.search(r"\.(png|jpe?g|gif|webp|svg)(\?|$)", u, re.I):
                continue
            out.append(u)
    return out


def visible(text: str) -> str:
    """Blank out HTML comments, fenced code blocks and inline code, keeping line numbers."""
    text = re.sub(r"<!--.*?-->", lambda m: "\n" * m.group(0).count("\n"), text, flags=re.S)
    out, fence = [], None
    for line in text.split("\n"):
        m = re.match(r"^\s*(```|~~~)", line)
        if fence:
            out.append("")
            if m and m.group(1) == fence:
                fence = None
        elif m:
            fence = m.group(1)
            out.append("")
        else:
            out.append(re.sub(r"`[^`]*`", "", line))
    return "\n".join(out)


def check(text: str, top_lines: int, live_url: str | None, need_live: bool) -> list[str]:
    lines = visible(text.replace("\r\n", "\n")).split("\n")
    problems = []

    first = None
    for line in lines:
        s = line.strip()
        if not s or re.match(r"^#\s", s) or re.match(r"^<h1\b", s, re.I) or is_badge_line(s):
            continue
        if re.match(r"^</?(p|div|a)\b[^>]*>$", s, re.I):  # wrapper tags around an image
            continue
        first = s
        break
    if first is None or not has_screenshot(first):
        problems.append(
            "README should start with a screenshot: after the title and badges, the first "
            f"content should be an image, but it is: {first!r}"
        )

    top = lines[:top_lines]
    if live_url:
        want = live_url.rstrip("/")
        if not any(want == u.rstrip("/") for u in live_links(top)):
            problems.append(f"README should link to the live site {live_url} in its first {top_lines} lines.")
    elif need_live and not live_links(top):
        problems.append(
            f"README should link to the live site (an https link that is not GitHub or a badge) "
            f"in its first {top_lines} lines."
        )
    return problems


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("readme")
    p.add_argument("--top-lines", type=int, default=15)
    p.add_argument("--live-url", default="")
    p.add_argument("--no-live-link", action="store_true", help="skip the live link rule")
    a = p.parse_args()
    try:
        text = open(a.readme, encoding="utf-8").read()
    except FileNotFoundError:
        print(f"::error title=readme::{a.readme} not found")
        return 1
    problems = check(text, a.top_lines, a.live_url or None, not a.no_live_link)
    for msg in problems:
        print(f"::error file={a.readme},title=readme::{msg}")
    if not problems:
        print(f"{a.readme}: starts with a screenshot and a live link.")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
