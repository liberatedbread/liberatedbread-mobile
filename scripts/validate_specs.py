#!/usr/bin/env python3
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Validate every device spec YAML against device-specs/schema.json.

Discovers all ``device-specs/**/*.yaml`` files (top-level, ``examples/`` and
``devices/``), validates each against the JSON Schema (draft 2020-12), and
prints a per-file ``PASS``/``FAIL`` line. On failure the offending JSON path
and message are printed. Exits non-zero if any spec fails so it can gate CI.

Usage:
    python scripts/validate_specs.py
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import yaml
from jsonschema import Draft202012Validator

REPO_ROOT = Path(__file__).resolve().parent.parent
DEVICE_SPECS_DIR = REPO_ROOT / "device-specs"
SCHEMA_PATH = DEVICE_SPECS_DIR / "schema.json"


def load_schema() -> dict:
    """Load and return the parsed device-spec JSON Schema."""
    with SCHEMA_PATH.open(encoding="utf-8") as fh:
        return json.load(fh)


def discover_specs() -> list[Path]:
    """Return every spec YAML under device-specs/, sorted by path.

    Covers the top level plus every subdirectory (``examples/``, ``devices/``,
    …). ``schema.json`` is not a YAML file so it is naturally excluded.
    """
    specs = sorted(
        set(DEVICE_SPECS_DIR.rglob("*.yaml")) | set(DEVICE_SPECS_DIR.rglob("*.yml"))
    )
    return specs


def validate_spec(path: Path, validator: Draft202012Validator) -> list[str]:
    """Validate one spec file. Return a list of human-readable error strings.

    An empty list means the spec is valid.
    """
    try:
        with path.open(encoding="utf-8") as fh:
            doc = yaml.safe_load(fh)
    except yaml.YAMLError as exc:
        return [f"YAML parse error: {exc}"]

    if doc is None:
        return ["empty document"]

    errors = sorted(validator.iter_errors(doc), key=lambda e: list(e.absolute_path))
    return [f"{err.json_path}: {err.message}" for err in errors]


def main() -> int:
    if not SCHEMA_PATH.exists():
        print(f"ERROR: schema not found at {SCHEMA_PATH}", file=sys.stderr)
        return 2

    schema = load_schema()
    # Surface schema authoring mistakes early rather than as opaque failures.
    Draft202012Validator.check_schema(schema)
    validator = Draft202012Validator(schema)

    specs = discover_specs()
    if not specs:
        print(f"ERROR: no spec YAML files found under {DEVICE_SPECS_DIR}", file=sys.stderr)
        return 2

    failures = 0
    for path in specs:
        rel = path.relative_to(REPO_ROOT)
        errors = validate_spec(path, validator)
        if errors:
            failures += 1
            print(f"FAIL  {rel}")
            for err in errors:
                print(f"        {err}")
        else:
            print(f"PASS  {rel}")

    total = len(specs)
    print()
    print(f"{total - failures}/{total} specs passed.")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
