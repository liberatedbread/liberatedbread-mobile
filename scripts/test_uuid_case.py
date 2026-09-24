#!/usr/bin/env python3
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Style check: every 128-bit UUID in the specs and the docs is lowercase.

The schema's ``uuid`` definition already rejects an uppercase UUID in a
structured field. This covers the rest: UUIDs quoted in ``notes``,
``description`` and step text, and in the published ``docs/`` pages, where a
consumer that greps or copies a value should find it spelled the one way the
fields spell it.

A string that only looks like a UUID and whose case is significant (it is
hashed or compared byte-for-byte, not parsed) goes in ``CASE_SIGNIFICANT``
with the reason.
"""
from __future__ import annotations

import re
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent

UUID_RE = re.compile(
    r"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b"
)

# (repo-relative path, string) -> why its case must be kept.
CASE_SIGNIFICANT = {
    (path, value): "Roku client-id secret: hashed as a literal string by ECP-2 auth"
    for path in ("device-specs/devices/roku-ecp.yaml", "docs/devices/roku-ecp.md")
    for value in (
        "95E610D0-7C29-44EF-FB0F-97F1FCE4C297",
        "F3A278B8-1C6F-44A9-9D89-F1979CA4C6F1",
    )
}


def _checked_files() -> list[Path]:
    specs = REPO_ROOT / "device-specs" / "devices"
    files = set(specs.rglob("*.yaml")) | set(specs.rglob("*.yml"))
    files |= set((REPO_ROOT / "docs").rglob("*.md"))
    return sorted(files)


@pytest.mark.parametrize(
    "path", _checked_files(), ids=lambda p: str(p.relative_to(REPO_ROOT))
)
def test_uuids_are_lowercase(path: Path) -> None:
    rel = path.relative_to(REPO_ROOT).as_posix()
    offenders = []
    for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        for match in UUID_RE.finditer(line):
            value = match.group(0)
            if value != value.lower() and (rel, value) not in CASE_SIGNIFICANT:
                offenders.append(f"{rel}:{lineno}: {value} -> {value.lower()}")
    assert not offenders, "UUIDs must be lowercase:\n" + "\n".join(offenders)


def test_case_significant_entries_still_exist() -> None:
    """An allowlist entry whose string has gone is stale and should be dropped."""
    for rel, value in CASE_SIGNIFICANT:
        assert value in (REPO_ROOT / rel).read_text(encoding="utf-8"), (rel, value)
