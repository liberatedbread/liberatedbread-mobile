#!/usr/bin/env python3
"""Build a machine-consumable JSON API from device-spec YAML files.

Discovers all ``device-specs/devices/*.yaml`` files, validates each against
``device-specs/schema.json`` (JSON Schema draft 2020-12), and emits:

* ``site/api/v1/devices/<id>.json`` — the YAML spec normalized to JSON
* ``site/api/v1/manifest.json`` — a registry index with checksums, timestamps, URLs

Usage::

    python scripts/build_index.py          # generate site/api/v1/*
    python scripts/build_index.py --check  # validate only, no output

The generated JSON is deterministic: devices are sorted alphabetically by id
and JSON keys are sorted.  The ``updated_at`` timestamp is extracted from
``git log -1 --format=%aI`` for each YAML file; if the repo is not a git
checkout the current UTC time is used as a fallback.
"""

from __future__ import annotations

import argparse
import glob
import hashlib
import json
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List

import jsonschema
import yaml


REPO_ROOT = Path(__file__).resolve().parent.parent
SPECS_DIR = REPO_ROOT / "device-specs" / "devices"
SCHEMA_PATH = REPO_ROOT / "device-specs" / "schema.json"
DEFAULT_API_DIR = REPO_ROOT / "site" / "api" / "v1"


@dataclass(frozen=True)
class Spec:
    """A loaded, validated device spec with its serialization pre-computed.

    *raw* is the parsed YAML dict.
    *json_text* is the exact string written to the per-device JSON file
    (normalized JSON plus a trailing newline).
    *checksum* is ``sha256:<hex>`` of *json_text* encoded as UTF-8.
    *id* is the filename stem.
    *path* is the source YAML ``Path``.
    """

    raw: Dict[str, Any]
    json_text: str
    checksum: str
    id: str
    path: Path


def load_schema() -> Dict[str, Any]:
    """Load the JSON Schema and return it as a dict."""
    with open(SCHEMA_PATH, encoding="utf-8") as f:
        return json.load(f)


def discover_specs() -> List[str]:
    """Return sorted list of YAML spec file paths under SPECS_DIR."""
    return sorted(glob.glob(str(SPECS_DIR / "*.yaml")))


def load_yaml(path: Path) -> Dict[str, Any]:
    """Load a YAML file and return its contents as a dict."""
    with open(path, encoding="utf-8") as f:
        data = yaml.safe_load(f)
    if not isinstance(data, dict):
        raise ValueError(f"Expected a YAML mapping in {path}, got {type(data).__name__}")
    return data


def validate_spec(spec: Dict[str, Any], schema: Dict[str, Any], path: Path) -> None:
    """Validate *spec* against *schema*; raise on failure."""
    validator_cls = jsonschema.validators.validator_for(schema)
    validator_cls.check_schema(schema)
    errors = list(validator_cls(schema).iter_errors(spec))
    if errors:
        lines = [f"Validation failed for {path.relative_to(REPO_ROOT)}:"]
        for err in errors:
            lines.append(f"  {err.json_path}: {err.message}")
        raise jsonschema.ValidationError("\n".join(lines))


def git_last_modified(path: Path, fallback: str) -> str:
    """Return ISO-8601 timestamp of the last git commit touching *path*.

    Falls back to *fallback* when ``git log`` fails (e.g. no git repo).
    """
    try:
        result = subprocess.run(
            ["git", "log", "-1", "--format=%aI", "--", str(path)],
            cwd=str(REPO_ROOT),
            capture_output=True,
            text=True,
            timeout=10,
        )
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        pass
    return fallback


def json_dumps(obj: Any) -> str:
    """Serialize *obj* to deterministic, pretty-printed JSON."""
    return json.dumps(obj, indent=2, sort_keys=True, ensure_ascii=False)


def _normalize_for_json(obj: Any) -> Any:
    """Recursively convert Python objects to JSON-safe equivalents.

    In particular, YAML integer dict keys become Python ``int`` keys, but
    JSON only supports string keys.  We convert them so that
    ``json.dumps`` is lossless on round-trip through ``json.loads``.
    """
    if isinstance(obj, dict):
        return {
            str(k) if isinstance(k, int) else k: _normalize_for_json(v)
            for k, v in obj.items()
        }
    if isinstance(obj, list):
        return [_normalize_for_json(v) for v in obj]
    if isinstance(obj, tuple):
        return [_normalize_for_json(v) for v in obj]
    return obj


def serialize_device_spec(spec: Dict[str, Any]) -> tuple[str, str]:
    """Serialize *spec* to JSON and compute its checksum.

    Returns ``(json_text, checksum)`` where *json_text* includes a trailing
    newline — the exact bytes written to ``<id>.json`` on disk.  *checksum*
    is ``sha256:<hex>`` of those bytes.
    """
    normalized = _normalize_for_json(spec)
    json_text = json_dumps(normalized) + "\n"
    checksum = f"sha256:{hashlib.sha256(json_text.encode('utf-8')).hexdigest()}"
    return json_text, checksum


def load_and_serialize_spec(path: Path, schema: Dict[str, Any]) -> Spec:
    """Load, validate, and serialize a single device spec.

    This is the single source of truth for a spec's bytes-on-disk and
    checksum.  Both manifest generation and file writing call this.
    """
    raw = load_yaml(path)
    validate_spec(raw, schema, path)
    json_text, checksum = serialize_device_spec(raw)
    return Spec(
        raw=raw,
        json_text=json_text,
        checksum=checksum,
        id=Path(path).stem,
        path=Path(path),
    )


def build_manifest(
    specs: List[Spec],
    schema: Dict[str, Any],
    generated_at: str,
) -> Dict[str, Any]:
    """Build the manifest JSON from pre-loaded, validated specs."""
    device_entries: List[Dict[str, Any]] = []

    for spec in specs:
        raw = spec.raw
        updated_at = git_last_modified(spec.path, generated_at)

        device_entries.append({
            "id": spec.id,
            "name": raw.get("device", {}).get("name", spec.id),
            "manufacturer": raw.get("device", {}).get("manufacturer", ""),
            "protocol": raw.get("device", {}).get("protocol", ""),
            "status": raw.get("device", {}).get("manufacturer_status", ""),
            **(
                {"helpful_urls": raw["helpful_urls"]}
                if "helpful_urls" in raw
                else {}
            ),
            **(
                {"helpful_videos": raw["helpful_videos"]}
                if "helpful_videos" in raw
                else {}
            ),
            "updated_at": updated_at,
            "url": f"/api/v1/devices/{spec.id}.json",
            "checksum": spec.checksum,
        })

    schema_id = schema.get("$id", "")
    return {
        "api_version": "1",
        "generated_at": generated_at,
        "schema": schema_id,
        "device_count": len(specs),
        "devices": device_entries,
    }


def write_output(
    manifest: Dict[str, Any],
    specs: List[Spec],
    api_dir: Path,
) -> None:
    """Write manifest.json and per-device JSON files to disk.

    Uses the pre-computed *json_text* from each Spec so the bytes on disk
    are guaranteed to match the checksums in the manifest.
    """
    api_dir.mkdir(parents=True, exist_ok=True)
    devices_dir = api_dir / "devices"
    devices_dir.mkdir(parents=True, exist_ok=True)

    for spec in specs:
        out_path = devices_dir / f"{spec.id}.json"
        with open(out_path, "w", encoding="utf-8") as f:
            f.write(spec.json_text)

    manifest_json = json_dumps(manifest) + "\n"
    manifest_path = api_dir / "manifest.json"
    with open(manifest_path, "w", encoding="utf-8") as f:
        f.write(manifest_json)


def run(
    generated_at: str | None = None,
    check_only: bool = False,
    output_dir: Path | None = None,
) -> int:
    """Discover, validate, and index all device specs.

    Returns 0 on success, non-zero on failure.

    Args:
        generated_at: ISO-8601 timestamp; default is now in UTC.
        check_only: Validate without writing files.
        output_dir: Root dir for api/v1/; defaults to ``site/api/v1`` under
            the repo root.  The mkdocs hook passes ``config["site_dir"]`` here.
    """
    if generated_at is None:
        generated_at = datetime.now(timezone.utc).isoformat()

    api_dir = (output_dir / "api" / "v1") if output_dir else DEFAULT_API_DIR
    schema = load_schema()
    spec_paths = discover_specs()

    if not spec_paths:
        print("No device specs found in", str(SPECS_DIR), file=sys.stderr)
        return 1

    # Load + validate + serialize every spec once
    errors: List[str] = []
    specs: List[Spec] = []
    for path in spec_paths:
        try:
            specs.append(load_and_serialize_spec(Path(path), schema))
        except (yaml.YAMLError, ValueError, jsonschema.ValidationError) as exc:
            errors.append(str(exc))

    if errors:
        for err in errors:
            print(err, file=sys.stderr)
        return 1

    if check_only:
        print(f"✓ {len(specs)} device specs validated successfully")
        return 0

    # Build manifest and write output
    manifest = build_manifest(specs, schema, generated_at)
    write_output(manifest, specs, api_dir)

    manifest_path = api_dir / "manifest.json"
    print(f"✓ Manifest: {manifest_path} ({manifest['device_count']} devices)")
    for entry in manifest["devices"]:
        dev_path = api_dir / "devices" / f"{entry['id']}.json"
        print(f"  {entry['id']}: {dev_path}")
    return 0


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Build JSON API from device-spec YAML files.",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Validate all specs without writing output files.",
    )
    args = parser.parse_args()
    sys.exit(run(check_only=args.check))


if __name__ == "__main__":
    main()
