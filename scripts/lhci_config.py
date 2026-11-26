"""Write a Lighthouse CI config from workflow inputs.

    python lhci_config.py OUT.json --urls "u1 u2" --runs 3 --preset desktop \
        --performance 0.8 --accessibility 0.9 --best-practices 0.9 --seo 0.9 --level error

Scores are 0-1; a threshold of 0 (or below) turns that category's assertion off.
Assertions use the median run, so one slow run does not fail the job.
"""

from __future__ import annotations

import argparse
import json


def build(a: argparse.Namespace) -> dict:
    urls = [u for u in a.urls.replace(",", " ").split() if u]
    if not urls:
        raise SystemExit("no URLs given")
    assertions = {}
    for cat in ("performance", "accessibility", "best-practices", "seo"):
        score = getattr(a, cat.replace("-", "_"))
        if not 0 <= score <= 1:
            raise SystemExit(f"{cat} threshold must be between 0 and 1, got {score}")
        if score > 0:
            assertions[f"categories:{cat}"] = [a.level, {"minScore": score, "aggregationMethod": "median-run"}]
    settings = {"preset": a.preset} if a.preset == "desktop" else {}
    return {
        "ci": {
            "collect": {"url": urls, "numberOfRuns": a.runs, "settings": settings},
            "assert": {"assertions": assertions},
            "upload": {"target": "filesystem", "outputDir": ".lighthouseci/reports"},
        }
    }


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("out")
    p.add_argument("--urls", required=True)
    p.add_argument("--runs", type=int, default=3)
    p.add_argument("--preset", choices=("desktop", "mobile"), default="desktop")
    p.add_argument("--performance", type=float, default=0.8)
    p.add_argument("--accessibility", type=float, default=0.9)
    p.add_argument("--best-practices", type=float, default=0.9)
    p.add_argument("--seo", type=float, default=0.9)
    p.add_argument("--level", choices=("error", "warn"), default="error")
    a = p.parse_args()
    if a.runs < 1:
        raise SystemExit("runs must be at least 1")
    with open(a.out, "w", encoding="utf-8") as f:
        json.dump(build(a), f, indent=2)
    print(json.dumps(build(a), indent=2))


if __name__ == "__main__":
    main()
