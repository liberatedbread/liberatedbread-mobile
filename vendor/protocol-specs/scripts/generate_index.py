#!/usr/bin/env python3
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Generate device-specs/index.json, a machine-consumable manifest of specs.

Enumerates every VALID device spec (validated against schema.json, reusing
``validate_specs``) and emits a JSON array sorted by path. Each entry has:

    {
      "name":                <device.name>,
      "path":                <repo-relative path to the YAML>,
      "protocol":            <device.protocol>,
      "category":            <device.category>,
      "manufacturer":        <device.manufacturer>,
      "manufacturer_status": <device.manufacturer_status>,
      "openness":            <device.openness.status, present only if set>,
      "testing_status":      <device.testing.status, present only if set>,
      "testing_detail":      <device.testing.detail, present only if set>,
      "helpful_urls":        <top-level helpful_urls, present only if set>,
      "helpful_videos":      <top-level helpful_videos, present only if set>,
      "protocol_handler":    <top-level protocol_handler, present only if set>,
      "schema_version":      <JSON Schema dialect version, e.g. "2020-12">
    }

This lets consumers (the mobile app, Home Assistant, tooling) enumerate specs
automatically instead of hardcoding a file list.

The script is idempotent: running it repeatedly produces byte-identical output,
so a committed index.json shows no diff on re-run. Exits non-zero if any spec
is invalid (a valid manifest cannot be built from invalid specs).

CI owns the committed index: the `publish-index` job in
`.github/workflows/ci.yml` runs this on every push to main and commits the
result, so contributors never carry index.json in a branch (that file is the
one every parallel spec PR used to conflict on). Running it locally is still
fine — just don't commit the result.

Usage:
    python scripts/generate_index.py           # write device-specs/index.json
    python scripts/generate_index.py --check   # report staleness, write nothing
"""
from __future__ import annotations

import argparse
import json
import re
import sys

import yaml
from jsonschema import Draft202012Validator

# When run as ``python scripts/generate_index.py`` the script's own directory is
# on sys.path[0], so the sibling module imports cleanly.
from validate_specs import (  # noqa: E402
    REPO_ROOT,
    discover_specs,
    load_schema,
    validate_spec,
)

INDEX_PATH = REPO_ROOT / "device-specs" / "index.json"


def schema_version(schema: dict) -> str:
    """Derive a stable schema-version string from the schema's $schema dialect.

    e.g. "https://json-schema.org/draft/2020-12/schema" -> "2020-12". Falls
    back to the raw $schema value (or "unknown") if the pattern is absent.
    """
    dialect = schema.get("$schema", "")
    match = re.search(r"/draft/([^/]+)/", dialect)
    if match:
        return match.group(1)
    return dialect or "unknown"


def build_entry(path, doc: dict, version: str) -> dict:
    """Build one manifest entry from a parsed, valid spec document."""
    device = doc.get("device", {})
    entry = {
        "name": device.get("name"),
        "path": path.relative_to(REPO_ROOT).as_posix(),
        "protocol": device.get("protocol"),
        "category": device.get("category"),
        "manufacturer": device.get("manufacturer"),
        "manufacturer_status": device.get("manufacturer_status"),
    }
    handler = doc.get("protocol_handler")
    if handler is not None:
        entry["protocol_handler"] = handler
    # Only emitted when the spec states it. An absent key means the schema
    # default, `undocumented` — the same convention protocol_handler uses, and
    # it keeps the common case from carrying a field that says nothing.
    openness = device.get("openness")
    if openness is not None:
        entry["openness"] = openness.get("status")
    # Spec-level hardware-testing verdict. Emitted as flat keys (not the whole
    # block) so a consumer ranking scan results does not have to parse notes.
    testing = device.get("testing")
    if testing is not None:
        entry["testing_status"] = testing.get("status")
        if testing.get("detail") is not None:
            entry["testing_detail"] = testing["detail"]
    helpful_urls = doc.get("helpful_urls")
    if helpful_urls is not None:
        entry["helpful_urls"] = helpful_urls
    helpful_videos = doc.get("helpful_videos")
    if helpful_videos is not None:
        entry["helpful_videos"] = helpful_videos
    entry["schema_version"] = version
    return entry


def collect_entries() -> tuple[list[dict], int]:
    """Build every index entry from the specs on disk, touching no files.

    Returns ``(entries, invalid_count)``. Invalid specs are reported on stderr
    and left out — the caller decides whether a partial set is usable (writing
    the index is not, a test asking "does the generator see every spec?" is).
    """
    schema = load_schema()
    Draft202012Validator.check_schema(schema)
    validator = Draft202012Validator(schema)
    version = schema_version(schema)

    entries = []
    invalid = 0
    for path in discover_specs():
        errors = validate_spec(path, validator)
        rel = path.relative_to(REPO_ROOT)
        if errors:
            invalid += 1
            print(f"SKIP (invalid) {rel}", file=sys.stderr)
            for err in errors:
                print(f"    {err}", file=sys.stderr)
            continue
        with path.open(encoding="utf-8") as fh:
            doc = yaml.safe_load(fh)
        entries.append(build_entry(path, doc, version))

    # Sort by path for deterministic, idempotent output.
    entries.sort(key=lambda e: e["path"])
    return entries, invalid


def render(entries: list[dict]) -> str:
    """Serialize entries to the exact bytes the index file carries."""
    # Trailing newline + sorted-nothing (we control key order) => stable bytes.
    return json.dumps(entries, indent=2, ensure_ascii=False) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--check",
        action="store_true",
        help="report whether the committed index matches the specs; write nothing",
    )
    args = parser.parse_args(argv)

    entries, invalid = collect_entries()
    if invalid:
        print(
            f"ERROR: {invalid} invalid spec(s); refusing to build an index.",
            file=sys.stderr,
        )
        return 1

    text = render(entries)
    rel = INDEX_PATH.relative_to(REPO_ROOT)

    if args.check:
        current = INDEX_PATH.read_text(encoding="utf-8") if INDEX_PATH.exists() else None
        if current == text:
            print(f"{rel} is up to date ({len(entries)} spec(s)).")
            return 0
        # Not a failure a contributor has to fix: CI regenerates and commits
        # this on main. Say so, and say it loudly enough to not be mistaken
        # for a broken spec.
        print(
            f"{rel} is stale ({len(entries)} spec(s) on disk). CI rebuilds it on "
            "main — no need to commit it here.",
            file=sys.stderr,
        )
        return 1

    INDEX_PATH.write_text(text, encoding="utf-8")
    print(f"Wrote {rel} with {len(entries)} spec(s).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
