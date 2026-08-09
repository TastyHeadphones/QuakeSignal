#!/usr/bin/env python3
"""Render .github/release-notes-template.md into a GitHub Release body."""
from __future__ import annotations

import os
import pathlib
import sys

TEMPLATE = pathlib.Path(".github/release-notes-template.md")
CHECKSUMS = pathlib.Path("dist/SHA256SUMS.txt")
GENERATED = pathlib.Path("generated-notes.md")
OUTPUT = pathlib.Path("release-notes.md")


def main() -> int:
    try:
        repo = os.environ["GITHUB_REPOSITORY"]
        tag = os.environ["GITHUB_REF_NAME"]
    except KeyError as exc:
        print(f"::error::missing required environment variable {exc}")
        return 1

    if not TEMPLATE.is_file() or not CHECKSUMS.is_file():
        print("::error::release-notes template or checksums are missing")
        return 1

    version = tag[1:] if tag.startswith("v") else tag
    body = TEMPLATE.read_text()
    replacements = {
        "@@REPO@@": repo,
        "@@TAG@@": tag,
        "@@VERSION@@": version,
        "@@CHECKSUMS@@": f"```\n{CHECKSUMS.read_text().rstrip()}\n```",
        "@@GENERATED_NOTES@@": GENERATED.read_text() if GENERATED.is_file() else "",
    }
    for token, value in replacements.items():
        body = body.replace(token, value)

    leftover = [token for token in replacements if token in body]
    if leftover:
        print(f"::error::unsubstituted template tokens: {', '.join(leftover)}")
        return 1

    OUTPUT.write_text(body)
    print(f"Wrote {OUTPUT} ({len(body)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
