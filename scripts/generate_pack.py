#!/usr/bin/env python3
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Generate pack.json, the spec-pack manifest the mobile app fetches.

The mobile app's spec-pack feature fetches a JSON manifest of shape

    {"name": <string>, "version": <string>, "specs": [<relative-YAML-path>, ...]}

and, for each entry, resolves the path SAME-ORIGIN against the manifest URL
(`manifestUri.resolve(specFile)`) and fetches the result as raw YAML. So the
manifest must sit at the repo ROOT and list each spec as a repo-relative path:
served from raw.githubusercontent.com/<owner>/<repo>/<ref>/pack.json, the entry
``device-specs/devices/foo.yaml`` resolves to
``raw.githubusercontent.com/<owner>/<repo>/<ref>/device-specs/devices/foo.yaml``,
the raw YAML for that device.

Only the device specs under ``device-specs/devices/`` are listed — those are the
files the app renders as devices. Each is validated against schema.json (reusing
``validate_specs``); an invalid spec is reported and left out, because a manifest
that points the app at a spec it cannot parse is worse than one that omits it.

The version string is STABLE: byte-identical output on re-run, so a committed
pack.json shows no diff unless the spec set actually changed. It never calls
datetime.now() (a timestamp would make CI commit a new pack on every push).
By default it is the number of specs in the pack; override with ``--version`` or
the ``PACK_VERSION`` environment variable for a release tag.

CI owns the published pack (mirroring device-specs/index.json): the
`publish-pack` job in `.github/workflows/ci.yml` runs this on every push to main,
uploads pack.json as a build artifact, and commits it so the app can fetch it
from raw.githubusercontent.com. Contributors do not carry pack.json in a branch.
Running it locally is fine — just don't commit the result.

Usage:
    python scripts/generate_pack.py            # write pack.json at the repo root
    python scripts/generate_pack.py --check    # report staleness, write nothing
    python scripts/generate_pack.py --version 2026.08  # pin an explicit version
"""
from __future__ import annotations

import argparse
import json
import os
import sys

from jsonschema import Draft202012Validator

# When run as ``python scripts/generate_pack.py`` the script's own directory is
# on sys.path[0], so the sibling module imports cleanly.
from validate_specs import (  # noqa: E402
    DEVICE_SPECS_DIR,
    REPO_ROOT,
    load_schema,
    validate_spec,
)

PACK_PATH = REPO_ROOT / "pack.json"
DEVICES_DIR = DEVICE_SPECS_DIR / "devices"
PACK_NAME = "Liberated Bread Device Specs"


def collect_spec_paths() -> tuple[list[str], int]:
    """Return (repo-relative device-spec paths, invalid_count).

    Enumerates ``device-specs/devices/*.yaml`` (and ``*.yml``), validates each
    against schema.json, and returns the valid ones as repo-relative POSIX
    paths sorted for deterministic output. Invalid specs are reported on stderr
    and left out — the caller decides whether a partial set is usable.
    """
    schema = load_schema()
    Draft202012Validator.check_schema(schema)
    validator = Draft202012Validator(schema)

    paths: list[str] = []
    invalid = 0
    candidates = sorted(
        set(DEVICES_DIR.glob("*.yaml")) | set(DEVICES_DIR.glob("*.yml"))
    )
    for path in candidates:
        rel = path.relative_to(REPO_ROOT)
        errors = validate_spec(path, validator)
        if errors:
            invalid += 1
            print(f"SKIP (invalid) {rel}", file=sys.stderr)
            for err in errors:
                print(f"    {err}", file=sys.stderr)
            continue
        paths.append(rel.as_posix())

    paths.sort()
    return paths, invalid


def resolve_version(specs: list[str], override: str | None) -> str:
    """The manifest version — stable, never a wall-clock timestamp.

    Precedence: explicit --version, then $PACK_VERSION, then the spec count.
    The count changes only when a spec is added or removed, which is the signal
    a consumer cares about, and it keeps the output byte-identical between runs.
    """
    chosen = override or os.environ.get("PACK_VERSION") or str(len(specs))
    return str(chosen)


def build_manifest(specs: list[str], version: str) -> dict:
    return {"name": PACK_NAME, "version": version, "specs": specs}


def render(manifest: dict) -> str:
    """Serialize to the exact bytes pack.json carries (stable, key order fixed)."""
    return json.dumps(manifest, indent=2, ensure_ascii=False) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--check",
        action="store_true",
        help="report whether the committed pack.json matches the specs; write nothing",
    )
    parser.add_argument(
        "--version",
        dest="version",
        default=None,
        help="explicit version string (else $PACK_VERSION, else the spec count)",
    )
    args = parser.parse_args(argv)

    specs, invalid = collect_spec_paths()
    if invalid:
        print(
            f"ERROR: {invalid} invalid spec(s); refusing to build a pack manifest.",
            file=sys.stderr,
        )
        return 1

    version = resolve_version(specs, args.version)
    text = render(build_manifest(specs, version))
    rel = PACK_PATH.relative_to(REPO_ROOT)

    if args.check:
        current = PACK_PATH.read_text(encoding="utf-8") if PACK_PATH.exists() else None
        if current == text:
            print(f"{rel} is up to date ({len(specs)} spec(s)).")
            return 0
        print(
            f"{rel} is stale ({len(specs)} spec(s) on disk). CI rebuilds it on "
            "main — no need to commit it here.",
            file=sys.stderr,
        )
        return 1

    PACK_PATH.write_text(text, encoding="utf-8")
    print(f"Wrote {rel} with {len(specs)} spec(s) (version {version}).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
