#!/usr/bin/env python3
"""Render .github/release-notes-template.md into a GitHub Release body.

The template carries the functional description, download and verification
instructions, the "Code signing policy" heading and the SignPath attribution
that the SignPath Foundation terms require on every download page.

Inputs come from the environment so the workflow stays declarative:

  GITHUB_REPOSITORY   owner/repo
  GITHUB_REF_NAME     the tag, e.g. v0.1.1
  WINDOWS_SIGNED      "true" when the Windows artifacts were signed

Reads  dist/SHA256SUMS.txt and generated-notes.md
Writes release-notes.md
"""
from __future__ import annotations

import os
import pathlib
import sys

TEMPLATE = pathlib.Path(".github/release-notes-template.md")
CHECKSUMS = pathlib.Path("dist/SHA256SUMS.txt")
GENERATED = pathlib.Path("generated-notes.md")
OUTPUT = pathlib.Path("release-notes.md")

TOKENS = (
    "@@REPO@@",
    "@@TAG@@",
    "@@VERSION@@",
    "@@SIGNING_STATUS@@",
    "@@CHECKSUMS@@",
    "@@GENERATED_NOTES@@",
)

SIGNED_STATUS = """The Windows installers and the application binary in this release are \
Authenticode signed, with an RFC 3161 timestamp so the signature stays \
verifiable after the signing certificate expires. Windows shows **SignPath \
Foundation** as the publisher, because the certificate is issued to the \
Foundation rather than to this project.

> [!IMPORTANT]
> The macOS build in this release is **not** notarized by Apple."""

UNSIGNED_STATUS = """> [!WARNING]
> The Windows installers in this release are **not** code signed. The SignPath \
Foundation application is still pending, so Windows will show a SmartScreen \
warning on first run. Verify the SHA256 checksum above before installing.

> [!IMPORTANT]
> The macOS build in this release is **not** notarized by Apple."""


def main() -> int:
    try:
        repo = os.environ["GITHUB_REPOSITORY"]
        tag = os.environ["GITHUB_REF_NAME"]
    except KeyError as exc:
        print(f"::error::missing required environment variable {exc}")
        return 1

    version = tag[1:] if tag.startswith("v") else tag
    signed = os.environ.get("WINDOWS_SIGNED") == "true"

    if not TEMPLATE.is_file():
        print(f"::error::template not found: {TEMPLATE}")
        return 1
    if not CHECKSUMS.is_file():
        print(f"::error::checksums not found: {CHECKSUMS}")
        return 1

    checksums = CHECKSUMS.read_text().rstrip("\n")
    generated = GENERATED.read_text() if GENERATED.is_file() else ""

    body = TEMPLATE.read_text()
    for token, value in {
        "@@REPO@@": repo,
        "@@TAG@@": tag,
        "@@VERSION@@": version,
        "@@SIGNING_STATUS@@": SIGNED_STATUS if signed else UNSIGNED_STATUS,
        "@@CHECKSUMS@@": f"```\n{checksums}\n```",
        "@@GENERATED_NOTES@@": generated,
    }.items():
        body = body.replace(token, value)

    leftover = [t for t in TOKENS if t in body]
    if leftover:
        print(f"::error::unsubstituted template tokens: {', '.join(leftover)}")
        return 1

    OUTPUT.write_text(body)
    print(f"Wrote {OUTPUT} ({len(body)} bytes, signed={signed})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
