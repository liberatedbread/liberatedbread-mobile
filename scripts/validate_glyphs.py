#!/usr/bin/env python3
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Validate the instruction glyph store against the specs that reference it.

``glyphs/`` holds small original drawings of the physical things a setup, reset
or pairing step refers to: which button, where it is, what the LED does when
the step takes. Specs point at them by path with ``glyph`` / ``indicator_glyph``
(``$defs/glyph_ref`` in the schema), and the schema can only check the shape of
that string. Four things it cannot check are what actually goes wrong:

* a reference to a file nobody drew — the spec renders a broken image;
* a file nobody references — dead weight in an LFS store that only grows;
* a file with no manifest entry — no alt text, and no clean-room attestation;
* an SVG that reaches outside itself — a script, a remote image, a font the
  consumer does not have. A glyph is rendered inside other people's apps, so
  it has to be inert and self-contained.

Usage:
    python scripts/validate_glyphs.py
"""
from __future__ import annotations

import re
import xml.etree.ElementTree as ET
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
GLYPHS_DIR = REPO_ROOT / "glyphs"
MANIFEST_PATH = GLYPHS_DIR / "MANIFEST.yaml"
DEVICE_SPECS_DIR = REPO_ROOT / "device-specs"

# The keys whose values are glyph paths. Kept here rather than derived from the
# schema because the schema expresses the type ($defs/glyph_ref), not the key
# name, and a $ref can be reused under any name a future block chooses. A new
# glyph-bearing key must be added here or its references go unchecked --
# test_glyphs.py asserts this list still covers every glyph_ref in the schema.
GLYPH_KEYS = {"glyph", "indicator_glyph"}

PATH_PATTERN = re.compile(r"^[a-z0-9][a-z0-9._/-]*\.(svg|png)$")

# Anything that makes a glyph reach outside its own file, or depend on the
# host's fonts. `text` is banned for the same reason as a font reference: a
# glyph with words in it is a glyph that renders wrong in the next locale and
# in any consumer whose font stack differs.
FORBIDDEN_SVG_TAGS = {
    "script",
    "image",
    "foreignObject",
    "text",
    "use",
    "animate",
    "set",
}
SVG_NS = "{http://www.w3.org/2000/svg}"
XLINK_HREF = "{http://www.w3.org/1999/xlink}href"

MAX_BYTES = 64 * 1024
ALLOWED_ORIGINS = {"original_drawing"}
MIN_ALT_CHARS = 30


def load_manifest() -> dict:
    if not MANIFEST_PATH.exists():
        return {}
    doc = yaml.safe_load(MANIFEST_PATH.read_text(encoding="utf-8")) or {}
    return doc.get("glyphs") or {}


def iter_glyph_refs(node, trail: tuple[str, ...] = ()):
    """Yield (glyph_path, json-ish trail) for every glyph reference in a spec."""
    if isinstance(node, dict):
        for key, value in node.items():
            if key in GLYPH_KEYS and isinstance(value, str):
                yield value, trail + (key,)
            else:
                yield from iter_glyph_refs(value, trail + (str(key),))
    elif isinstance(node, list):
        for index, item in enumerate(node):
            yield from iter_glyph_refs(item, trail + (f"[{index}]",))


def collect_references() -> dict[str, list[str]]:
    """Map each referenced glyph path to the spec locations that point at it."""
    references: dict[str, list[str]] = {}
    specs = sorted(
        set(DEVICE_SPECS_DIR.rglob("*.yaml")) | set(DEVICE_SPECS_DIR.rglob("*.yml"))
    )
    for path in specs:
        doc = yaml.safe_load(path.read_text(encoding="utf-8"))
        for glyph, trail in iter_glyph_refs(doc):
            where = f"{path.relative_to(REPO_ROOT)}:{'.'.join(trail)}"
            references.setdefault(glyph, []).append(where)
    return references


def stored_glyphs() -> list[str]:
    """Every glyph file in the store, as manifest-relative paths."""
    found = []
    for path in sorted(GLYPHS_DIR.rglob("*")):
        if path.is_file() and path.suffix.lower() in {".svg", ".png", ".webp"}:
            found.append(path.relative_to(GLYPHS_DIR).as_posix())
    return found


def check_svg(path: Path) -> list[str]:
    """Structural checks on one SVG. Returns human-readable problems."""
    problems: list[str] = []
    raw = path.read_text(encoding="utf-8", errors="replace")

    # An LFS pointer is not an SVG. Say so plainly rather than failing on a
    # parse error, because the fix is `git lfs pull`, not editing the file.
    if raw.startswith("version https://git-lfs"):
        return ["is an unfetched Git LFS pointer — run `git lfs pull`"]

    try:
        root = ET.fromstring(raw)
    except ET.ParseError as exc:
        return [f"is not parseable XML: {exc}"]

    if root.tag != f"{SVG_NS}svg":
        problems.append(f"root element is {root.tag}, expected an <svg>")
    if not root.get("viewBox"):
        problems.append("has no viewBox, so it cannot scale to a consumer's layout")

    titles = root.findall(f"{SVG_NS}title")
    if not titles or not (titles[0].text or "").strip():
        problems.append("has no non-empty <title>")

    for element in root.iter():
        tag = element.tag.replace(SVG_NS, "")
        if tag in FORBIDDEN_SVG_TAGS:
            problems.append(f"contains a <{tag}> element, which glyphs may not use")
        for attr in ("href", XLINK_HREF):
            target = element.get(attr)
            if target and not target.startswith("#"):
                problems.append(f"references something outside itself: {target}")
        for attr, value in element.attrib.items():
            if attr.startswith("on"):
                problems.append(f"carries the event handler {attr}")
            if "url(http" in str(value):
                problems.append(f"{attr} points at a remote URL")

    if "@font-face" in raw:
        problems.append("embeds a font; glyphs must not depend on one")

    return problems


def main() -> int:
    if not GLYPHS_DIR.exists():
        print("no glyphs/ directory; nothing to validate")
        return 0

    manifest = load_manifest()
    references = collect_references()
    on_disk = set(stored_glyphs())

    failures: list[str] = []

    for glyph in sorted(references):
        where = references[glyph]
        if not PATH_PATTERN.match(glyph):
            failures.append(f"{glyph}: not a well-formed glyph path ({where[0]})")
            continue
        if glyph not in on_disk:
            failures.append(
                f"{glyph}: referenced by {', '.join(where)} but no such file "
                f"under glyphs/"
            )
        if glyph not in manifest:
            failures.append(f"{glyph}: referenced but has no glyphs/MANIFEST.yaml entry")

    for glyph in sorted(manifest):
        if glyph not in on_disk:
            failures.append(f"{glyph}: in MANIFEST.yaml but no such file under glyphs/")

    for glyph in sorted(on_disk):
        if glyph not in manifest:
            failures.append(f"{glyph}: on disk but missing from MANIFEST.yaml")
        if glyph not in references:
            failures.append(
                f"{glyph}: in the store but referenced by no spec — either point "
                f"a spec at it or delete it"
            )

    for glyph, entry in sorted(manifest.items()):
        entry = entry or {}
        label = f"{glyph} (MANIFEST.yaml)"
        if not (entry.get("title") or "").strip():
            failures.append(f"{label}: needs a title")
        alt = (entry.get("alt") or "").strip()
        if len(alt) < MIN_ALT_CHARS:
            failures.append(
                f"{label}: alt text must describe the drawing for a reader who "
                f"cannot see it (at least {MIN_ALT_CHARS} characters)"
            )
        origin = entry.get("origin")
        if origin not in ALLOWED_ORIGINS:
            failures.append(
                f"{label}: origin {origin!r} is not accepted — glyphs must be "
                f"{sorted(ALLOWED_ORIGINS)[0]!r}, never derived from vendor artwork"
            )

    for glyph in sorted(on_disk):
        path = GLYPHS_DIR / glyph
        size = path.stat().st_size
        if size > MAX_BYTES:
            failures.append(f"{glyph}: {size} bytes exceeds the {MAX_BYTES}-byte cap")
        if path.suffix.lower() == ".svg":
            for problem in check_svg(path):
                failures.append(f"{glyph}: {problem}")

    for glyph in sorted(on_disk):
        status = "PASS" if not any(f.startswith(glyph) for f in failures) else "FAIL"
        print(f"{status}  glyphs/{glyph}")

    if failures:
        print()
        for failure in failures:
            print(f"  {failure}")
        print()
        print(f"{len(failures)} glyph problem(s).")
        return 1

    print()
    print(
        f"{len(on_disk)} glyph(s) in the store, "
        f"{sum(len(v) for v in references.values())} reference(s) from specs, all resolved."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
