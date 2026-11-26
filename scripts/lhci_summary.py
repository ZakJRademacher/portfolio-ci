"""Print a Markdown table of median Lighthouse scores from a .lighthouseci folder.

    python lhci_summary.py .lighthouseci
"""

from __future__ import annotations

import glob
import json
import os
import statistics
import sys
from collections import defaultdict

CATS = ("performance", "accessibility", "best-practices", "seo")


def main(folder: str) -> int:
    runs: dict[str, dict[str, list[float]]] = defaultdict(lambda: defaultdict(list))
    for path in glob.glob(os.path.join(folder, "lhr-*.json")):
        with open(path, encoding="utf-8") as f:
            lhr = json.load(f)
        url = lhr.get("finalDisplayedUrl") or lhr.get("finalUrl") or lhr.get("requestedUrl", "?")
        for cat in CATS:
            score = (lhr.get("categories", {}).get(cat) or {}).get("score")
            if score is not None:
                runs[url][cat].append(score)
    print("### Lighthouse (median of runs)\n")
    if not runs:
        print("No Lighthouse results were produced.")
        return 0
    print("| Page | " + " | ".join(CATS) + " |")
    print("| --- |" + " --- |" * len(CATS))
    for url, cats in sorted(runs.items()):
        cells = [f"{round(statistics.median(cats[c]) * 100)}" if cats[c] else "-" for c in CATS]
        print(f"| {url} | " + " | ".join(cells) + " |")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else ".lighthouseci"))
