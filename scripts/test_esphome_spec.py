# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Holds the ESPHome family to the rule that stops one product eating a platform.

`_esphomelib._tcp.local.` is the service type of the ESPHome FIRMWARE, so every
node that runs it — thermometer, plug, bluetooth proxy, garage-door controller
— advertises it. A consumer that resolves a service type to a spec therefore
labels the whole platform with whichever spec claimed the service type first,
and for a while that spec was `ratgdo`: every ESPHome device on the LAN rendered
as a garage-door opener, with open/close controls aimed at entities the node
does not have.

The fix is a contract, and this module is what keeps it:

* a product spec on the platform narrows itself with `txt_match` (project_name),
* exactly one spec is the deliberate catch-all (`platform_fallback: true`),
* and the catch-all does not pretend to know a node's entities.

The same shape applies to any shared service type (`_hap._tcp`, `_http._tcp`);
ESPHome is the family it is enforced on because it is the one with a documented
matcher for every claimant.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
SPECS_DIR = REPO_ROOT / "device-specs" / "devices"
SCHEMA_PATH = REPO_ROOT / "device-specs" / "schema.json"

ESPHOME_SERVICE = "_esphomelib._tcp.local."


@pytest.fixture(scope="module")
def specs() -> dict:
    """Every device spec, keyed by filename stem."""
    out = {}
    for path in sorted(SPECS_DIR.glob("*.yaml")):
        out[path.stem] = yaml.safe_load(path.read_text(encoding="utf-8"))
    return out


@pytest.fixture(scope="module")
def esphome(specs) -> dict:
    return specs["esphome-device"]


@pytest.fixture(scope="module")
def ratgdo(specs) -> dict:
    return specs["ratgdo"]


def _mdns_methods(spec: dict, service_type: str) -> list:
    methods = (spec["device"].get("discovery") or {}).get("methods") or []
    return [
        m["mdns"]
        for m in methods
        if m.get("type") == "mdns" and (m.get("mdns") or {}).get("service_type") == service_type
    ]


def _claimants(specs: dict, service_type: str) -> dict:
    """Every spec claiming `service_type`, by either block, keyed by device id.

    Deliberately not discovery-only. `identification` is the block a scanner
    matches on, so a spec naming the service type there and nowhere else claims
    the platform just as effectively — and would slip past a check that only
    walked `discovery.methods`.
    """
    out = {}
    for device_id, spec in specs.items():
        methods = _mdns_methods(spec, service_type)
        identification = spec["device"].get("identification") or {}
        if methods or identification.get("mdns_service_type") == service_type:
            out[device_id] = methods
    return out


# ── The platform rule ────────────────────────────────────────────────────────


def test_every_esphome_claimant_either_narrows_or_declares_itself_the_fallback(specs):
    """A spec browsing the platform service type says which of the two it is.

    Without this a second product spec can land on `_esphomelib._tcp` with no
    matcher, and the ordering that decides which spec a node gets is whatever
    the consumer's file listing happens to be — which is how every ESPHome node
    became a garage door in the first place.
    """
    claimants = _claimants(specs, ESPHOME_SERVICE)
    assert claimants, "no spec claims the ESPHome service type any more — did one get renamed?"

    for device_id, methods in claimants.items():
        spec = specs[device_id]
        identification = spec["device"].get("identification") or {}

        assert methods, (
            f"{device_id}: names {ESPHOME_SERVICE} in `identification` but has "
            "no matching discovery method. The identification block is the one "
            "a scanner reads, so this claims the whole platform with no "
            "evidence behind it and nowhere to put a matcher."
        )

        for mdns in methods:
            narrowed = bool(mdns.get("txt_match"))
            fallback = mdns.get("platform_fallback") is True
            assert narrowed or fallback, (
                f"{device_id}: claims {ESPHOME_SERVICE} with neither a "
                "`txt_match` that narrows it to this product nor "
                "`platform_fallback: true`. Every ESPHome node advertises this "
                "service type, so an unqualified claim labels the whole "
                "platform as this device."
            )

        if all(m.get("txt_match") for m in methods):
            assert identification.get("mdns_txt_match"), (
                f"{device_id}: narrows {ESPHOME_SERVICE} in `discovery` but "
                "not in `identification` — the block the scanner reads would "
                "still match every ESPHome node."
            )


def test_no_method_is_both_narrowed_and_a_fallback(specs):
    """`txt_match` gates a method; `platform_fallback` is what you reach for
    when no gate was satisfied. A method carrying both has no single reading —
    and read the wrong way it is the platform-claiming bug again, one service
    type over: an ESPHome spec that is the catch-all for `_http._tcp` claims
    every printer, router and NAS on the link that fails its TXT condition.
    """
    for device_id, spec in specs.items():
        methods = (spec["device"].get("discovery") or {}).get("methods") or []
        for method in methods:
            mdns = method.get("mdns") or {}
            if not mdns:
                continue
            if mdns.get("txt_match") and mdns.get("platform_fallback") is True:
                raise AssertionError(
                    f"{device_id}: the {mdns.get('service_type')} method is both "
                    "narrowed by `txt_match` and marked `platform_fallback`. "
                    "Pick one: a conditional claim, or the catch-all for a "
                    "service type this firmware actually owns."
                )


def test_exactly_one_esphome_fallback(specs):
    """Two catch-alls for one service type is a coin toss, not a fallback."""
    fallbacks = sorted(
        device_id
        for device_id, methods in _claimants(specs, ESPHOME_SERVICE).items()
        if any(m.get("platform_fallback") is True for m in methods)
    )
    assert fallbacks == ["esphome-device"], (
        "exactly one spec may be the ESPHome platform fallback and it is "
        f"esphome-device; found {fallbacks}"
    )


def test_the_fallback_does_not_invent_a_device(esphome):
    """The generic spec cannot know a node's entities, so it declares none.

    Its whole job is to let a node describe itself. A static `entities` list
    here would draw controls for hardware the node may not have — the failure
    it exists to prevent, one level up.
    """
    assert "entities" not in esphome, (
        "esphome-device must not declare entities: a consumer enumerates them "
        "from the node's own /events stream (or ListEntities)"
    )
    assert esphome["device"]["category"] == "other"
    assert esphome["device"]["type"] == "esphome-node"


def test_the_fallback_documents_how_to_enumerate(esphome):
    """A fallback that cannot enumerate leaves the consumer with nothing."""
    paths = {e["path"] for e in esphome["http_endpoints"]}
    assert "/events" in paths, (
        "the generic spec must document /events — it is the only way to "
        "enumerate an ESPHome node over HTTP"
    )
    events = next(e for e in esphome["http_endpoints"] if e["path"] == "/events")
    assert "connect" in events["description"], (
        "say that every entity's state arrives on connect; that is what makes "
        "/events an enumeration and not just a subscription"
    )


# ── ratgdo, the product that used to claim the platform ──────────────────────


def test_ratgdo_matches_only_ratgdo_firmware(ratgdo):
    """ratgdo identifies itself by project_name, in both blocks that matter."""
    for mdns in _mdns_methods(ratgdo, ESPHOME_SERVICE):
        matchers = mdns.get("txt_match")
        assert matchers, "ratgdo's discovery method must carry a txt_match"
        assert any(
            m["key"] == "project_name"
            and m.get("match") == "prefix"
            and m["value"] == "ratgdo."
            for m in matchers
        ), f"expected a project_name prefix matcher on 'ratgdo.', got {matchers}"

    identification = ratgdo["device"]["identification"]
    assert identification.get("mdns_service_type") == ESPHOME_SERVICE
    matchers = identification.get("mdns_txt_match")
    assert matchers, (
        "identification is the block a scanner matches on cheaply — a "
        "txt_match that lives only in `discovery` does not reach it, which is "
        "exactly how every ESPHome node became a ratgdo"
    )
    assert any(
        m["key"] == "project_name" and m.get("match") == "prefix" and m["value"] == "ratgdo."
        for m in matchers
    )


def test_ratgdo_keeps_a_path_for_older_firmware(ratgdo):
    """The name form is current; the object_id form is what is on the wall.

    ESPHome moved from addressing entities by slugified object_id to addressing
    them by name, and dropped the old form entirely in 2026.7. A spec that
    states only one of the two is wrong for half the boards in service — so
    every command that names a path carries the legacy one as `path_fallback`,
    and every entity's `state_topic` carries `state_topic_fallback`. Dropping
    them is a silent 404 on a board that was working yesterday.
    """
    for name, command in ratgdo["commands"].items():
        path = command.get("path")
        if not path:
            continue
        fallback = command.get("path_fallback")
        assert fallback, (
            f"ratgdo: command {name!r} states {path!r} with no `path_fallback` "
            "— a board on ESPHome <= 2025.12 answers that path with a 404"
        )
        assert fallback != path, f"ratgdo: command {name!r} falls back to itself"
        assert fallback.islower(), (
            f"ratgdo: command {name!r} fallback {fallback!r} is not the "
            "slugified object_id form the older firmware matches"
        )

    for entity in ratgdo["entities"]:
        topic = entity.get("state_topic")
        if not topic:
            continue
        assert entity.get("state_topic_fallback"), (
            f"ratgdo: entity {entity['name']!r} states {topic!r} with no "
            "`state_topic_fallback` for older firmware"
        )


def test_the_generic_spec_needs_no_path_fallbacks(esphome):
    """The platform spec addresses entities by what the node reported.

    Its command paths are `{domain}`/`{entity}` placeholders filled from the
    node's own state payload, so there is no generation to guess at and nothing
    to fall back to — the identifier came from the device.
    """
    for name, command in esphome["commands"].items():
        assert "path_fallback" not in command, (
            f"esphome-device: command {name!r} carries a path_fallback, but "
            "its path is filled from the node's own identifier — there is no "
            "second form to try"
        )
        assert "{entity}" in command["path"], (
            f"esphome-device: command {name!r} hardcodes an entity; the "
            "platform spec cannot know one"
        )


def test_identification_and_discovery_agree(specs):
    """The cheap matcher must not claim more than the evidence block does.

    `identification` is derived from `discovery`; a spec whose discovery method
    narrows the service type while its identification block does not is one a
    consumer will over-match on, and the divergence is invisible in review.
    The reverse is checked too: a matcher in `identification` with no discovery
    method behind it is a claim with no evidence, which is how the block that
    scanners actually read drifts away from the one reviewers read.
    """
    for device_id, spec in specs.items():
        identification = spec["device"].get("identification") or {}
        service_type = identification.get("mdns_service_type")
        if not service_type:
            continue
        methods = _mdns_methods(spec, service_type)
        if identification.get("mdns_txt_match"):
            assert methods, (
                f"{device_id}: identification.mdns_txt_match narrows "
                f"{service_type}, but no discovery method documents it. The "
                "evidence for a matcher belongs in `discovery`."
            )
            assert all(m.get("txt_match") for m in methods), (
                f"{device_id}: identification narrows {service_type} but a "
                "discovery method for it does not — the two blocks state "
                "different claims about the same service type"
            )
            continue
        if methods and all(m.get("txt_match") for m in methods):
            raise AssertionError(
                f"{device_id}: every discovery method for {service_type} "
                "narrows it with txt_match, but identification.mdns_txt_match "
                "is missing — the block the matcher actually reads would match "
                "the whole service type"
            )


# ── The schema keys this rests on ────────────────────────────────────────────


def test_schema_declares_the_matcher_keys():
    """The keys must be schema keys; an undeclared one reaches no consumer."""
    schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
    assert "mdns_txt_match" in schema["$defs"]

    identification = schema["properties"]["device"]["properties"]["identification"]
    assert "mdns_txt_match" in identification["properties"]

    methods = schema["properties"]["device"]["properties"]["discovery"]["properties"][
        "methods"
    ]["items"]["oneOf"]
    mdns = next(
        branch
        for branch in methods
        if branch.get("properties", {}).get("type", {}).get("const") == "mdns"
    )
    mdns_props = mdns["properties"]["mdns"]["properties"]
    assert "txt_match" in mdns_props
    assert "platform_fallback" in mdns_props


@pytest.mark.parametrize(
    "matcher,valid",
    [
        ({"key": "project_name", "match": "prefix", "value": "ratgdo."}, True),
        ({"key": "config_hash", "match": "present"}, True),
        ({"key": "md", "value": "LIFX Z"}, True),
        # `present`/`absent` test existence; a value would have nothing to say.
        ({"key": "config_hash", "match": "present", "value": "x"}, False),
        # Everything else needs something to compare against.
        ({"key": "project_name", "match": "prefix"}, False),
        ({"match": "prefix", "value": "ratgdo."}, False),
    ],
)
def test_matcher_shape_is_enforced(matcher, valid):
    """A matcher missing its value silently matches nothing; reject it early."""
    import jsonschema

    schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
    validator = jsonschema.Draft202012Validator(
        {"$defs": schema["$defs"], "$ref": "#/$defs/mdns_txt_match"}
    )
    errors = list(validator.iter_errors(matcher))
    assert bool(errors) != valid, f"{matcher} should be {'valid' if valid else 'rejected'}"
