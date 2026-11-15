# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Tests for scripts/generate_pack.py — the mobile app's spec-pack manifest.

The app fetches pack.json and, for each listed spec, resolves the path
SAME-ORIGIN against the manifest URL and fetches it as raw YAML. So the shape
and the path form are a contract with a shipped consumer, not a convenience:
an absolute path or a URL would break `manifestUri.resolve(specFile)`, and a
missing device would be one the app never loads.
"""
from __future__ import annotations

import json

import generate_pack
from validate_specs import REPO_ROOT

DEVICES_DIR = REPO_ROOT / "device-specs" / "devices"


def test_pack_lists_every_device_spec_exactly_once():
    """The generator must see every device spec on disk, and no more.

    Deliberately checks the generator's output, not a committed pack.json:
    that file is written by CI on main (see the publish-index job), so on a
    branch it is expected to be absent or a commit behind. What must hold is
    that the generator names exactly the device specs that exist.
    """
    specs, invalid = generate_pack.collect_spec_paths()
    assert invalid == 0, "invalid specs are already reported by validate_specs.py"

    on_disk = sorted(
        p.relative_to(REPO_ROOT).as_posix()
        for p in (set(DEVICES_DIR.glob("*.yaml")) | set(DEVICES_DIR.glob("*.yml")))
    )
    assert specs == on_disk
    assert len(specs) == len(set(specs)), "duplicate pack entries"


def test_pack_paths_resolve_same_origin():
    """Every spec path is relative, so manifestUri.resolve() reaches it.

    A leading slash would resolve against the host root and an absolute URL
    against nothing — either way the app would fetch from the wrong place.
    Each path must also point into device-specs/devices/ and name a real file.
    """
    specs, _ = generate_pack.collect_spec_paths()
    assert specs, "the pack is empty"
    for path in specs:
        assert not path.startswith("/"), f"{path!r} is host-absolute"
        assert "://" not in path, f"{path!r} is an absolute URL, not same-origin"
        assert path.startswith("device-specs/devices/"), path
        assert path.endswith((".yaml", ".yml")), path
        assert (REPO_ROOT / path).is_file(), f"{path} names no file on disk"


def test_manifest_has_the_shape_the_app_expects():
    """{"name": str, "version": str, "specs": [str, ...]} — nothing else needed."""
    specs, _ = generate_pack.collect_spec_paths()
    version = generate_pack.resolve_version(specs, None)
    manifest = generate_pack.build_manifest(specs, version)

    assert set(manifest) == {"name", "version", "specs"}
    assert manifest["name"] == "Liberated Bread Device Specs"
    assert isinstance(manifest["version"], str) and manifest["version"]
    assert isinstance(manifest["specs"], list)
    assert all(isinstance(p, str) for p in manifest["specs"])

    # It must be JSON-serialisable to exactly what render() emits.
    round_trip = json.loads(generate_pack.render(manifest))
    assert round_trip == manifest


def test_version_is_stable_not_a_timestamp():
    """Two builds of an unchanged spec set produce byte-identical output.

    The CI publish step commits pack.json only when it changes; a wall-clock
    version would make every push a commit. The default version is the spec
    count, and an env/arg override is honoured.
    """
    specs, _ = generate_pack.collect_spec_paths()
    first = generate_pack.render(
        generate_pack.build_manifest(specs, generate_pack.resolve_version(specs, None))
    )
    second = generate_pack.render(
        generate_pack.build_manifest(specs, generate_pack.resolve_version(specs, None))
    )
    assert first == second

    assert generate_pack.resolve_version(specs, None) == str(len(specs))
    assert generate_pack.resolve_version(specs, "2026.08") == "2026.08"
