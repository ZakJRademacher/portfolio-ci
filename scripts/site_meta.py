"""Check a live page's social preview tags.

    python site_meta.py https://example.com/ [https://example.com/about ...]

For every page: the response is 200, and it has og:title, og:image and a
description (meta name="description", or og:description as a fallback). The
og:image URL (resolved against the page) must return 200 with an image/* type.
Exit 1 if any check fails. Standard library only.
"""

from __future__ import annotations

import sys
import urllib.error
import urllib.request
from html.parser import HTMLParser
from urllib.parse import urljoin

UA = "portfolio-ci-site-quality/1 (+https://github.com/ZakJRademacher/portfolio-ci)"


class Meta(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.tags: dict[str, str] = {}

    def handle_starttag(self, tag, attrs):
        if tag != "meta":
            return
        a = {k.lower(): (v or "") for k, v in attrs}
        key = (a.get("property") or a.get("name") or "").lower()
        if key and key not in self.tags:
            self.tags[key] = a.get("content", "").strip()


def fetch(url: str, method: str = "GET"):
    req = urllib.request.Request(url, method=method, headers={"User-Agent": UA})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            body = r.read() if method == "GET" else b""
            return r.status, r.headers.get("Content-Type", ""), body, r.geturl()
    except urllib.error.HTTPError as e:
        return e.code, e.headers.get("Content-Type", ""), b"", url
    except Exception as e:  # DNS, TLS, timeout
        return 0, str(e), b"", url


def check_page(url: str) -> list[str]:
    status, ctype, body, final = fetch(url)  # final = the URL after redirects
    if status != 200:
        return [f"{url} returned {status or ctype}"]
    m = Meta()
    m.feed(body.decode("utf-8", "replace"))
    t = m.tags
    problems = []
    if not t.get("og:title"):
        problems.append(f"{url}: missing og:title")
    if not (t.get("description") or t.get("og:description")):
        problems.append(f"{url}: missing meta description")
    image = t.get("og:image")
    if not image:
        problems.append(f"{url}: missing og:image")
    else:
        img = urljoin(final, image)
        s, ct, _, _ = fetch(img, "HEAD")
        if s in (403, 405, 501):  # some hosts refuse HEAD
            s, ct, _, _ = fetch(img)
        if s != 200:
            problems.append(f"{url}: og:image {img} returned {s or ct}")
        elif not ct.lower().startswith("image/"):
            problems.append(f"{url}: og:image {img} is {ct or 'no content type'}, not an image")
    if not problems:
        print(f"ok  {url}  og:title={t['og:title']!r}  og:image={urljoin(final, image)}")
    return problems


def main(urls: list[str]) -> int:
    if not urls:
        print("usage: site_meta.py URL [URL ...]")
        return 2
    problems = [p for u in urls for p in check_page(u)]
    for p in problems:
        print(f"::error title=social preview::{p}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
