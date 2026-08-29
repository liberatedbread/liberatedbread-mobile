"""Tests for the instruction glyph store and its validator.

scripts/validate_glyphs.py is the gate CI runs; these tests check that it is
still gating the right things. Two of them matter more than the rest:

* the validator's list of glyph-bearing keys still covers every place the
  schema says a glyph may appear — otherwise a new block's references go
  silently unchecked, which is worse than not checking at all because the
  green tick says otherwise;
* the SVG hygiene rules actually reject what they claim to. A glyph renders
  inside somebody else's application, so "inert and self-contained" has to be
  enforced rather than asked for.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest
import yaml

import validate_glyphs

REPO_ROOT = Path(__file__).resolve().parent.parent
SCHEMA_PATH = REPO_ROOT / "device-specs" / "schema.json"

GOOD_SVG = """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 96 96">
  <title>A button</title>
  <circle cx="48" cy="48" r="20" fill="none" stroke="currentColor"/>
</svg>
"""


def schema_glyph_keys() -> set[str]:
    """Every property name in schema.json whose value is a glyph_ref."""
    found: set[str] = set()

    def walk(node, key=None):
        if isinstance(node, dict):
            if node.get("$ref") == "#/$defs/glyph_ref" and key is not None:
                found.add(key)
            for k, v in node.items():
                walk(v, k)
        elif isinstance(node, list):
            for item in node:
                walk(item, key)

    walk(json.loads(SCHEMA_PATH.read_text(encoding="utf-8")))
    return found


def test_the_validator_checks_every_glyph_bearing_key():
    """A new glyph field must be added to GLYPH_KEYS or it goes unchecked.

    The schema expresses the TYPE of a glyph reference, not the name of the
    key carrying it, and a $ref can be reused under any name a future block
    picks. The validator therefore keeps its own list, and this test is what
    keeps that list honest: add `glyph` somewhere new in schema.json and this
    fails until the validator knows about it.
    """
    declared = schema_glyph_keys()
    assert declared, "no glyph_ref usages found in schema.json — did the $def move?"
    missing = declared - validate_glyphs.GLYPH_KEYS
    assert not missing, (
        f"schema.json uses glyph_ref under {sorted(missing)}, which "
        f"validate_glyphs.py does not know to look for"
    )


def test_the_store_and_the_specs_agree():
    """The real tree passes: every reference resolves, nothing is orphaned."""
    assert validate_glyphs.main() == 0


def test_every_glyph_carries_alt_text_and_an_origin():
    """The two things the image file itself cannot say."""
    manifest = validate_glyphs.load_manifest()
    assert manifest, "glyphs/MANIFEST.yaml is empty"
    for glyph, entry in manifest.items():
        assert (entry.get("alt") or "").strip(), f"{glyph}: no alt text"
        assert entry.get("origin") in validate_glyphs.ALLOWED_ORIGINS, (
            f"{glyph}: origin {entry.get('origin')!r} is not an accepted "
            f"clean-room attestation"
        )


def test_manifest_paths_match_the_schema_pattern():
    """Manifest keys are the same strings specs write, so they obey the same rule."""
    for glyph in validate_glyphs.load_manifest():
        assert validate_glyphs.PATH_PATTERN.match(glyph), (
            f"{glyph}: not a well-formed glyph path"
        )


@pytest.mark.parametrize(
    "body,expected",
    [
        ('<script>alert(1)</script>', "script"),
        ('<image href="https://example.com/a.png"/>', "image"),
        ('<text x="1" y="1">hold</text>', "text"),
        ('<circle cx="1" cy="1" r="1" onclick="x()"/>', "onclick"),
    ],
)
def test_svg_hygiene_rejects_what_it_claims_to(tmp_path, body, expected):
    """Each forbidden construct is actually caught, not just listed."""
    path = tmp_path / "bad.svg"
    path.write_text(
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 96 96">'
        f"<title>Bad</title>{body}</svg>",
        encoding="utf-8",
    )
    problems = " ".join(validate_glyphs.check_svg(path))
    assert expected in problems, f"{expected} was not reported: {problems!r}"


def test_svg_hygiene_accepts_a_well_formed_glyph(tmp_path):
    """The rules must not reject the glyphs we actually want to ship."""
    path = tmp_path / "good.svg"
    path.write_text(GOOD_SVG, encoding="utf-8")
    assert validate_glyphs.check_svg(path) == []


def test_an_unfetched_lfs_pointer_says_so(tmp_path):
    """`git lfs pull`, not a parse error.

    Glyphs live in LFS, so a clone without git-lfs installed has pointer files
    where the drawings should be. That is a setup problem with a one-line fix,
    and it must not surface as 'not parseable XML'.
    """
    path = tmp_path / "pointer.svg"
    path.write_text(
        "version https://git-lfs.github.com/spec/v1\noid sha256:0\nsize 1\n",
        encoding="utf-8",
    )
    problems = validate_glyphs.check_svg(path)
    assert problems and "git lfs pull" in problems[0]


def test_every_glyph_is_tracked_by_lfs():
    """The .gitattributes rules cover every extension in the store.

    A glyph that slipped in under an untracked extension would be committed
    into the object store itself, which is the thing the LFS setup exists to
    prevent — and nobody would notice until the repository was large.
    """
    attributes = (REPO_ROOT / ".gitattributes").read_text(encoding="utf-8")
    tracked = {
        line.split("*.")[1].split()[0]
        for line in attributes.splitlines()
        if line.startswith("glyphs/**/*.") and "filter=lfs" in line
    }
    for glyph in validate_glyphs.stored_glyphs():
        suffix = glyph.rsplit(".", 1)[-1]
        assert suffix in tracked, (
            f"{glyph}: .{suffix} is in glyphs/ but no .gitattributes rule "
            f"tracks it with LFS (tracked: {sorted(tracked)})"
        )


def test_glyph_references_are_relative_to_the_glyphs_directory():
    """A spec must not write the `glyphs/` prefix it is supposed to omit.

    The prefix is left off so a consumer can rebase the whole set at once. A
    reference that includes it resolves nowhere on the consumer's side while
    looking perfectly correct here, so catch it in the spec rather than in
    somebody's app.
    """
    offenders = []
    for glyph, where in validate_glyphs.collect_references().items():
        if glyph.startswith("glyphs/"):
            offenders.append(f"{where[0]} -> {glyph}")
    assert not offenders, (
        "glyph references must be relative to glyphs/: " + ", ".join(offenders)
    )


def test_the_manifest_is_valid_yaml_with_the_expected_shape():
    doc = yaml.safe_load((REPO_ROOT / "glyphs" / "MANIFEST.yaml").read_text("utf-8"))
    assert doc["version"] == 1
    assert doc["license"] == "Apache-2.0"
    assert isinstance(doc["glyphs"], dict)
