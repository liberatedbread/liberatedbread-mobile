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
      "manufacturer":        <device.manufacturer>,
      "manufacturer_status": <device.manufacturer_status>,
      "openness":            <device.openness.status, present only if set>,
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

Usage:
    python scripts/generate_index.py
"""
from __future__ import annotations

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
    helpful_urls = doc.get("helpful_urls")
    if helpful_urls is not None:
        entry["helpful_urls"] = helpful_urls
    helpful_videos = doc.get("helpful_videos")
    if helpful_videos is not None:
        entry["helpful_videos"] = helpful_videos
    entry["schema_version"] = version
    return entry


def main() -> int:
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

    if invalid:
        print(
            f"ERROR: {invalid} invalid spec(s); refusing to write a partial index.",
            file=sys.stderr,
        )
        return 1

    # Sort by path for deterministic, idempotent output.
    entries.sort(key=lambda e: e["path"])

    # Trailing newline + sorted-nothing (we control key order) => stable bytes.
    text = json.dumps(entries, indent=2, ensure_ascii=False) + "\n"
    INDEX_PATH.write_text(text, encoding="utf-8")
    print(f"Wrote {INDEX_PATH.relative_to(REPO_ROOT)} with {len(entries)} spec(s).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
