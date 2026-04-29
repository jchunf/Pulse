#!/usr/bin/env python3
"""F-44 / dev-channel — splice the latest stable <item> into the dev
appcast in place.

Used by `.github/workflows/package.yml` "Generate + upload dev appcast"
step. The previous awk-based splice (PR #128) intermittently failed on
the macOS runner because BSD awk's `-v` flag interprets backslash
escapes in the variable's value, and the EdSignature in the spliced
item contains `+`, `/`, and `=` characters that can confuse the
escape parser. Replacing awk with Python's stdlib regex eliminates
the variation between BSD and GNU awks and removes the multi-line
quoting hazard entirely.

Why we splice at all: the rolling dev appcast contains only the
just-built dev item. A user on the dev channel who flips the
preference back to stable would otherwise hit the dev feed once
before Sparkle refreshes and silently miss the latest stable
release. Sparkle picks the highest `sparkle:version` on parse, so
combining the two items in one feed produces the right answer
without any client-side change.

Exit codes:
    0 — splice succeeded; dev_path was overwritten with the merged feed
    1 — splice could not run (no `<item>` in stable, or no
        `</channel>` in dev). Caller should treat this as
        non-fatal — the unspliced dev appcast is still valid.
"""

from __future__ import annotations

import re
import sys


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(
            "usage: splice_stable_into_dev_appcast.py "
            "<dev_appcast.xml> <stable_appcast.xml>",
            file=sys.stderr,
        )
        return 1
    dev_path, stable_path = argv[1], argv[2]

    with open(stable_path, encoding="utf-8") as f:
        stable = f.read()
    match = re.search(r"<item>.*?</item>", stable, re.DOTALL)
    if not match:
        print("==> no <item> found in stable appcast — skipping splice", file=sys.stderr)
        return 1
    stable_item = match.group(0)

    with open(dev_path, encoding="utf-8") as f:
        dev = f.read()
    if "</channel>" not in dev:
        print("==> no </channel> in dev appcast — skipping splice", file=sys.stderr)
        return 1

    # Insert the stable item right before </channel> so the dev item
    # (which already lives inside <channel>) and the stable item
    # become siblings under the same <channel>.
    spliced = dev.replace(
        "</channel>",
        f"{stable_item}\n  </channel>",
        1,
    )
    with open(dev_path, "w", encoding="utf-8") as f:
        f.write(spliced)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
