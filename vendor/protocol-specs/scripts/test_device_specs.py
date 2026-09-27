"""Cross-spec consistency checks for device-specs/devices/*.yaml.

schema.json says what a spec *may* contain. These tests say what our specs
*should* contain to stay comparable with one another — conventions a schema
cannot express, like "always state `verified` explicitly" or "a device that
needs provisioning must document at least one step".

The point is that someone reading their second spec should already know where
to look. Every failure here is a spec that would surprise them.
"""

from __future__ import annotations

import copy
import json
import re
from pathlib import Path

import pytest
import yaml
from jsonschema import Draft202012Validator

REPO_ROOT = Path(__file__).resolve().parent.parent
DEVICES_DIR = REPO_ROOT / "device-specs" / "devices"

SPEC_PATHS = sorted(DEVICES_DIR.glob("*.yaml"))

CONFIDENCE_VALUES = {"high", "medium", "low"}
METHOD_TYPES = {
    "none",
    "softap_http",
    "softap_mqtt",
    "softap_soap",
    "softap_udp",
    "ble_provisioning",
    "ble_direct",
    "wps",
    "smartconfig",
    "wired",
    "device_ui",
    "hub_pairing",
    "button_pairing",
    "cloud_account",
}
ACTORS = {"user", "client", "device"}
PASSPHRASE_PROTECTION = {
    "plaintext",
    "device_encrypted",
    "tls",
    "unknown",
    "not_applicable",
}
NO_PROVISIONING_TYPES = {"none", "ble_direct"}


def _schema() -> dict:
    """schema.json, parsed. Shared by the vocabulary and constraint tests."""
    return json.loads(
        (REPO_ROOT / "device-specs" / "schema.json").read_text(encoding="utf-8")
    )


def schema_categories() -> set[str]:
    """The `device.category` enum, read from schema.json.

    Read rather than restated so the vocabulary has exactly one definition:
    a copy here would let the schema and the tests drift apart, and the tests
    would keep passing while doing it.
    """
    return set(_schema()["properties"]["device"]["properties"]["category"]["enum"])


def load(path: Path) -> dict:
    return yaml.safe_load(path.read_text(encoding="utf-8"))


@pytest.fixture(scope="module")
def specs() -> dict[str, dict]:
    assert SPEC_PATHS, "no device specs found"
    return {path.stem: load(path) for path in SPEC_PATHS}


def setups(specs: dict[str, dict]):
    """Yield (device_id, setup) for every spec that documents setup."""
    for device_id, spec in specs.items():
        setup = spec["device"].get("setup")
        if setup is not None:
            yield device_id, setup


def phases(method: dict):
    """Yield the phases of a method: its `stages`, or the method itself.

    A route with more than one phase carries them in `stages`, and everything
    that reads a method's `type`, `steps` or detail blocks wants the phases
    rather than the wrapper -- the wrapper's `type` names the route's defining
    act, and `cloud`, `ble` or `issues_credentials` sit on whichever phase
    owns them.
    """
    return method.get("stages") or [method]


def method_phases(setup: dict):
    """Every phase of every method in a setup block, wrappers flattened."""
    for method in setup["methods"]:
        yield from phases(method)


def method_types(setup: dict) -> set[str]:
    return {phase["type"] for phase in method_phases(setup)}


def is_reference(spec: dict) -> bool:
    """True for published-protocol references rather than devices.

    A `device.type` of 'reference-*' (SAE J1979 PIDs, ISO 14229 UDS services,
    ISO 15765-2 framing) marks a file that documents a standard other specs
    cite instead of restating. There is no hardware to set up, so the setup
    conventions below do not apply. schema.json exempts these from the
    access-surface requirement for the same reason.
    """
    return spec["device"].get("type", "").startswith("reference-")


def test_every_device_documents_setup(specs):
    """Setup is not optional in practice — 'nothing to provision' is an answer.

    A missing block is indistinguishable from nobody having looked, which is
    the ambiguity this whole section exists to remove.
    """
    missing = [
        d
        for d, spec in specs.items()
        if "setup" not in spec["device"] and not is_reference(spec)
    ]
    assert not missing, f"specs without a device.setup block: {missing}"


def test_setup_blocks_have_the_same_shape(specs):
    """Same top-level keys everywhere, so readers know where to look."""
    expected = {
        "required",
        "confidence",
        "notes",
        "methods",
        "factory_reset",
        "rejoin",
        "credentials",
    }
    for device_id, setup in setups(specs):
        assert expected <= set(setup), (
            f"{device_id}: setup missing {sorted(expected - set(setup))}"
        )
        assert isinstance(setup["required"], bool), f"{device_id}: required must be bool"
        assert setup["confidence"] in CONFIDENCE_VALUES, (
            f"{device_id}: confidence {setup['confidence']!r} not in {CONFIDENCE_VALUES}"
        )


def test_every_method_states_type_description_and_verified(specs):
    """`verified` absent reads as an oversight, not as 'not yet verified'."""
    for device_id, setup in setups(specs):
        methods = setup["methods"]
        assert methods, f"{device_id}: setup.methods is empty"
        for method in methods:
            label = f"{device_id}:{method.get('type', '?')}"
            assert method["type"] in METHOD_TYPES, f"{label}: unknown method type"
            assert method.get("description"), f"{label}: needs a description"
            assert isinstance(method.get("verified"), bool), (
                f"{label}: must state `verified` explicitly"
            )


METHOD_ROLES = {"primary", "alternative", "variant", "historical"}


def test_multi_method_setups_label_every_method(specs):
    """A list of two `type` values does not say which one the reader does.

    `type` is the mechanism -- and two methods on one device routinely share
    it (both Rachio generations are `softap_http`, both Bravia steps are
    `device_ui`). What tells them apart is `name`, and what says whether the
    reader picks one or does both is `role`. The schema requires the pair
    once a spec lists two or more methods; this checks the values are usable
    rather than merely present.
    """
    for device_id, setup in setups(specs):
        methods = setup["methods"]
        if len(methods) < 2:
            continue
        seen = set()
        for method in methods:
            label = f"{device_id}:{method.get('type', '?')}"
            name = method.get("name", "")
            assert name, f"{label}: needs a `name` -- it is the only label a reader has"
            assert name not in seen, f"{device_id}: two methods both named {name!r}"
            seen.add(name)
            assert method.get("role") in METHOD_ROLES, (
                f"{label}: role {method.get('role')!r} not in {sorted(METHOD_ROLES)}"
            )


def test_setup_methods_are_ordered_for_a_reader(specs):
    """Order is the instruction, so it has to hold top to bottom.

    Someone reads this list with the device in their hands and picks one
    entry. That only works if the route to recommend is the first thing they
    meet and what cannot be done today is the last. Which of two alternatives
    is "easier" is a judgement the ordering rule states and a test cannot
    check; the checks here are mechanical and are the ones that mislead when
    they are wrong.
    """
    rank = {"primary": 0, "alternative": 1, "variant": 2, "historical": 3}
    for device_id, setup in setups(specs):
        roles = [m.get("role") for m in setup["methods"]]
        if len(roles) < 2:
            continue
        # Named before ranked: a missing or misspelled role used to surface
        # as a bare KeyError with no device in it, aborting the loop so
        # every spec after the broken one went unchecked.
        unknown = [r for r in roles if r not in rank]
        assert not unknown, (
            f"{device_id}: methods carry role(s) {unknown} -- with two or "
            f"more methods every one needs a role from {sorted(rank)}, or "
            "the reading order below cannot be judged"
        )
        assert roles.count("primary") <= 1, (
            f"{device_id}: {roles.count('primary')} methods claim role 'primary' "
            "-- at most one route can be the one to recommend"
        )
        # Role rank never goes back up: the recommended route, then genuine
        # alternatives, then routes selected by which hardware the reader
        # owns, then what no longer works. This one check IS
        # primary-comes-first and historical-goes-last — the two used to be
        # spelled out separately above it, three assertions for one rule.
        ranked = [rank[r] for r in roles]
        assert ranked == sorted(ranked), (
            f"{device_id}: methods are ordered {roles} -- role rank "
            "(primary, alternative, variant, historical) must be "
            "non-decreasing top to bottom"
        )


def test_a_multi_phase_route_is_one_method_with_stages(specs):
    """Consecutive phases are not options, and must not be listed as options.

    "Plug in the Ethernet" and "press the link button" are both required and
    happen in that order; side by side in `methods` they read as a choice, and
    a reader does one of them. A route with more than one phase is one method
    carrying `stages`. Each stage keeps its own `type`, so folding the phases
    together does not lose that the first half of the Hue route is `wired`.
    """
    for device_id, setup in setups(specs):
        for method in setup["methods"]:
            stages = method.get("stages")
            if stages is None:
                continue
            label = f"{device_id}:{method.get('name', method['type'])}"
            assert "steps" not in method, (
                f"{label}: has both `steps` and `stages` -- a route describes "
                "its flow one way or the other"
            )
            assert len(stages) >= 2, (
                f"{label}: `stages` with {len(stages)} entry -- a single-phase "
                "route uses `steps`"
            )
            seen = set()
            for stage in stages:
                name = stage.get("name", "")
                assert name, f"{label}: a stage has no name"
                assert name not in seen, f"{label}: two stages named {name!r}"
                seen.add(name)
                assert stage.get("type") in METHOD_TYPES, (
                    f"{label}/{name}: stage type {stage.get('type')!r} is not a "
                    "known method type"
                )
                assert "role" not in stage, (
                    f"{label}/{name}: a stage has no `role` -- role is about "
                    "choosing between routes, and there is no choice inside one"
                )
                assert "stages" not in stage, (
                    f"{label}/{name}: stages do not nest"
                )


def test_verified_methods_are_high_confidence(specs):
    """A flow run against hardware cannot be low confidence."""
    for device_id, setup in setups(specs):
        for method in setup["methods"]:
            if method.get("verified"):
                assert setup["confidence"] == "high", (
                    f"{device_id}: {method['type']} is verified but the block "
                    f"claims {setup['confidence']} confidence"
                )


def test_steps_name_a_valid_actor(specs):
    """`actor` decides what a wizard can automate, so it must be meaningful."""
    for device_id, setup in setups(specs):
        step_lists = [p.get("steps", []) for p in method_phases(setup)]
        step_lists += [
            p.get("steps", [])
            for p in setup["factory_reset"].get("procedures", [])
        ]
        step_lists.append(setup["rejoin"].get("steps", []))
        for steps in step_lists:
            for step in steps:
                assert step.get("action"), f"{device_id}: a step has no action"
                actor = step.get("actor")
                assert actor is None or actor in ACTORS, (
                    f"{device_id}: step actor {actor!r} not in {ACTORS}"
                )


def test_devices_that_need_provisioning_document_the_flow(specs):
    """`required: true` with no steps anywhere is a promise the spec breaks."""
    for device_id, setup in setups(specs):
        if not setup["required"]:
            continue
        total = sum(len(p.get("steps", [])) for p in method_phases(setup))
        assert total > 0, (
            f"{device_id}: setup.required is true but no method documents steps"
        )


def test_no_provisioning_methods_are_consistent_with_required(specs):
    """A device whose only method is 'nothing to do' must not claim required."""
    for device_id, setup in setups(specs):
        types = method_types(setup)
        if types <= NO_PROVISIONING_TYPES:
            assert not setup["required"], (
                f"{device_id}: only no-provisioning methods ({sorted(types)}) "
                "but setup.required is true"
            )


def test_ble_devices_use_ble_method_types(specs):
    """A BLE-protocol device should not be described with WiFi onboarding."""
    wifi_only = {"softap_http", "softap_soap", "wps", "smartconfig", "wired"}
    for device_id, spec in specs.items():
        setup = spec["device"].get("setup")
        if not setup or spec["device"]["protocol"] != "ble":
            continue
        types = method_types(setup)
        assert not (types & wifi_only), (
            f"{device_id}: BLE device documents WiFi-only onboarding {types & wifi_only}"
        )


def test_factory_reset_is_described_not_just_declared(specs):
    """Reset is the entry point to every setup flow; it needs real detail.

    Not every device has one — a vehicle reached over a diagnostic connector
    does not. Those must say so with `applicable: false` and explain why,
    rather than carrying an invented procedure, which on safety-relevant
    hardware is worse than an admission of nothing to document.

    `applicable: unknown` is the third answer, for a device nobody has
    established a reset on. It may still list what to try — dropping a likely
    procedure throws away real knowledge, and it is the first thing someone
    holding the device should attempt — but every procedure under it is a
    candidate by definition, so each must say `verified: false` and cite a
    `basis`. That keeps it usable without letting it read as confirmed.
    """
    for device_id, setup in setups(specs):
        reset = setup["factory_reset"]
        assert reset.get("effect"), (
            f"{device_id}: factory_reset must say what it clears, or why there "
            "is nothing to clear"
        )

        if reset.get("applicable") is False:
            assert not reset.get("procedures"), (
                f"{device_id}: factory_reset is marked not applicable but "
                "still lists procedures"
            )
            continue

        unestablished = reset.get("applicable") == "unknown"
        if unestablished:
            assert reset.get("confidence") == "low", (
                f"{device_id}: an unestablished factory reset is low confidence"
            )
        else:
            assert reset.get("confidence") in CONFIDENCE_VALUES, (
                f"{device_id}: factory_reset needs a confidence level"
            )

        procedures = reset.get("procedures", [])
        # An established reset must show its work. An unestablished one need
        # not — sometimes there is genuinely nothing to suggest.
        if not unestablished:
            assert procedures, f"{device_id}: factory_reset needs at least one procedure"

        for procedure in procedures:
            label = f"{device_id}: reset procedure {procedure.get('name')!r}"
            assert procedure.get("name"), f"{device_id}: a reset procedure has no name"
            assert procedure.get("steps"), f"{label} has no steps"
            if unestablished:
                assert procedure.get("verified") is False, (
                    f"{label} sits under an unestablished reset, so it must say "
                    "`verified: false` — it is a candidate, not a confirmed flow"
                )
            # Any procedure that admits it is unverified owes the reader its
            # source: a vendor manual and a guess-by-analogy are both useful,
            # and they are not equally trustworthy.
            if procedure.get("verified") is False:
                assert procedure.get("basis"), (
                    f"{label} is unverified and must cite a `basis` saying where "
                    "it came from"
                )


def test_rejoin_answers_the_router_replacement_question(specs):
    """The everyday case: can this move networks without a physical reset?"""
    for device_id, setup in setups(specs):
        rejoin = setup["rejoin"]
        assert "requires_factory_reset" in rejoin, (
            f"{device_id}: rejoin must state requires_factory_reset"
        )
        assert isinstance(rejoin["requires_factory_reset"], bool)
        if "in_place_supported" in rejoin:
            assert isinstance(rejoin["in_place_supported"], bool)
            # These two are the same question asked twice; they must agree.
            if rejoin["in_place_supported"]:
                assert not rejoin["requires_factory_reset"], (
                    f"{device_id}: rejoin claims in-place support AND that a "
                    "factory reset is required"
                )


BLE_PROTOCOLS = {"ble", "ble_gatt"}
SECURITY_MODES = {
    "none",
    "just_works",
    "passkey_entry",
    "numeric_comparison",
    "out_of_band",
    "legacy_pin",
    "network_join",
    "app_layer",
    "unknown",
}
BONDING_VALUES = {"none", "optional", "required", "unknown"}


def pairings(specs: dict[str, dict]):
    """Yield (device_id, pairing) for every spec that documents pairing."""
    for device_id, spec in specs.items():
        pairing = spec["device"].get("pairing")
        if pairing is not None:
            yield device_id, pairing


def test_ble_devices_answer_the_pairing_question(specs):
    """A BLE spec must say whether a client has to pair, even if the answer is no.

    'No pairing, open GATT' is the most common answer and the most useful one:
    it is what tells an implementer not to go hunting for a pairing flow that
    does not exist. Silence says the same thing to a reader who assumes the
    best and the opposite to a reader who assumes the worst, which is why the
    block is required here rather than merely allowed. `required: unknown` is
    the honest third answer and satisfies this.

    WiFi and bus devices are not gated: pairing in this sense is a property of
    the radio link, and a device reached over HTTP or a diagnostic connector
    has no equivalent. Those may still carry the block (a hub with a physical
    link button does) but are not required to.
    """
    missing = [
        device_id
        for device_id, spec in specs.items()
        if spec["device"].get("protocol") in BLE_PROTOCOLS
        and not is_reference(spec)
        and "pairing" not in spec["device"]
    ]
    assert not missing, f"BLE specs without a device.pairing block: {missing}"


def test_pairing_states_required_and_confidence(specs):
    """The two fields that make the rest of the block weighable."""
    for device_id, pairing in pairings(specs):
        assert "required" in pairing, f"{device_id}: pairing must state `required`"
        required = pairing["required"]
        assert isinstance(required, bool) or required == "unknown", (
            f"{device_id}: pairing.required is {required!r}, expected a bool or 'unknown'"
        )
        assert pairing.get("confidence") in CONFIDENCE_VALUES, (
            f"{device_id}: pairing needs a confidence level"
        )
        if required == "unknown":
            assert pairing["confidence"] == "low", (
                f"{device_id}: an unestablished pairing story is low confidence"
            )


def test_pairing_vocabulary_is_the_documented_one(specs):
    """Typos in an enum are invisible to a permissive reader and to a grep."""
    for device_id, pairing in pairings(specs):
        if "security_mode" in pairing:
            assert pairing["security_mode"] in SECURITY_MODES, (
                f"{device_id}: security_mode {pairing['security_mode']!r} "
                f"not in {sorted(SECURITY_MODES)}"
            )
        if "bonding" in pairing:
            assert pairing["bonding"] in BONDING_VALUES, (
                f"{device_id}: bonding {pairing['bonding']!r} "
                f"not in {sorted(BONDING_VALUES)}"
            )


def test_pairing_required_and_security_mode_agree(specs):
    """`required: false` cannot go with a mode that needs the user's hands.

    Passkey entry, numeric comparison and OOB all require a person to read
    something off the device and act on it. None of that can happen in a flow
    the client is not required to run, so the combination describes two
    different devices.

    `just_works` is deliberately NOT in that set. 'Pairing is not required,
    but a client that pairs anyway gets Just Works, and the device will keep
    the bond' is a real and common configuration — Ember's mug and the Eqiva
    valve both behave that way — and forcing it into either `none` or
    `required: true` would lose the distinction that matters.
    """
    interactive_modes = {"passkey_entry", "numeric_comparison", "out_of_band"}
    for device_id, pairing in pairings(specs):
        mode = pairing.get("security_mode")
        if pairing["required"] is False and mode in interactive_modes:
            raise AssertionError(
                f"{device_id}: pairing.required is false but security_mode is "
                f"{mode!r}, which needs a person to complete it"
            )


def test_no_pairing_cannot_also_be_mandatory_bonding(specs):
    """`security_mode: none` and `bonding: required` cannot both be true.

    These two get conflated constantly, and the difference is the whole reason
    the fields are separate. 'none' says the device demands nothing; 'bonding:
    required' says it insists on a stored bond. A spec claiming both has
    almost certainly used 'none' to mean 'just works', which is the error this
    catches.

    `bonding: optional` alongside 'none' is left alone on purpose: it is the
    accurate description of hardware that demands no pairing but will accept
    and keep one if a central starts it — which most OS stacks will, given an
    insufficient-authentication error, without the application asking.
    """
    for device_id, pairing in pairings(specs):
        if pairing.get("security_mode") == "none":
            assert pairing.get("bonding", "none") != "required", (
                f"{device_id}: security_mode 'none' but bonding is required — "
                f"nothing pairs, so nothing can be made to bond"
            )


def test_unverified_pairing_procedures_cite_a_basis(specs):
    """Same rule the reset procedures follow, on the same shared $def."""
    for device_id, pairing in pairings(specs):
        for block in ("enter_pairing_mode", "unpair"):
            for procedure in (pairing.get(block) or {}).get("procedures", []):
                label = f"{device_id}: {block} procedure {procedure.get('name')!r}"
                assert procedure.get("name"), f"{device_id}: a {block} procedure has no name"
                assert isinstance(procedure.get("verified"), bool), (
                    f"{label} must state `verified` explicitly"
                )
                if procedure["verified"] is False:
                    assert procedure.get("basis"), (
                        f"{label} is unverified and must cite a `basis`"
                    )


def test_pairing_mode_entry_that_is_required_says_how(specs):
    """`enter_pairing_mode.required: true` with nothing else is a dead end.

    Telling a user their lock must be put into pairing mode, and not telling
    them how, is worse than silence: they now know there is a step and still
    cannot take it. A procedure or, at minimum, prose in `notes` has to follow.
    """
    for device_id, pairing in pairings(specs):
        entry = pairing.get("enter_pairing_mode")
        if not entry or entry.get("required") is not True:
            continue
        assert entry.get("procedures") or entry.get("notes"), (
            f"{device_id}: enter_pairing_mode is required but the spec does not "
            f"say how to do it"
        )


def test_a_stated_pin_is_a_product_wide_default(specs):
    """A per-unit PIN is a live credential, not a protocol fact.

    docs/CLEANROOM_RULES.md lists pairing PINs among the identifiers to scrub:
    one read off the researcher's own hardware is a key to that hardware and
    is useless to everyone else. Only a value that is the same on every unit
    of the product belongs in a spec. The schema enforces this too; the test
    is here because it is a rule about what we publish, not only about shape.
    """
    for device_id, pairing in pairings(specs):
        pin = pairing.get("pin")
        if not pin or "value" not in pin:
            continue
        assert pin.get("source") == "fixed_default", (
            f"{device_id}: pairing.pin states a value but source is "
            f"{pin.get('source')!r} — only a product-wide default may be published"
        )


def test_the_schema_itself_rejects_a_per_unit_pin_value():
    """The clean-room PIN rule is in the schema, not only in this file.

    schema.json is published for standalone consumers who never run pytest,
    and this particular rule protects somebody's front door rather than our
    tidiness. Assert the schema really carries it.
    """
    validator = Draft202012Validator(_schema())
    spec = {
        "device": {
            "name": "Test",
            "protocol": "ble",
            "pairing": {
                "required": True,
                "confidence": "low",
                "pin": {"source": "printed_label", "value": "481602"},
            },
        },
        "services": [],
    }
    errors = list(validator.iter_errors(spec))
    assert errors, "schema accepted a per-unit PIN value; it must not"


LINK_KINDS = {
    "manual",
    "vendor_support",
    "teardown",
    "protocol_writeup",
    "implementation",
    "forum",
    "standard",
    "video",
    "other",
}


def helpful_urls(specs: dict[str, dict]):
    for device_id, spec in specs.items():
        for entry in spec.get("helpful_urls") or []:
            yield device_id, entry


def test_link_kinds_come_from_the_documented_vocabulary(specs):
    """`kind` is only worth having if a consumer can switch on it."""
    for device_id, entry in helpful_urls(specs):
        kind = entry.get("kind")
        if kind is None:
            continue
        assert kind in LINK_KINDS, (
            f"{device_id}: helpful_urls kind {kind!r} not in {sorted(LINK_KINDS)}"
        )


def test_a_spec_does_not_link_the_same_url_twice(specs):
    """Two entries for one URL is a merge artefact, not a second reference."""
    for device_id, spec in specs.items():
        urls = [entry["url"] for entry in spec.get("helpful_urls") or []]
        duplicates = {url for url in urls if urls.count(url) > 1}
        assert not duplicates, f"{device_id}: helpful_urls repeats {sorted(duplicates)}"


def test_manual_links_say_which_manual(specs):
    """A bare 'manual' link is a guessing game when a spec covers a family.

    Most specs here document a family rather than one product — the Wemo
    entry spans plugs and in-wall switches, Beurer's spans a dozen monitors —
    so which model's manual this is, and whether it is vendor-hosted or an
    archived copy, is the difference between a useful link and a shrug.
    """
    for device_id, entry in helpful_urls(specs):
        if entry.get("kind") not in {"manual", "vendor_support"}:
            continue
        assert (entry.get("description") or "").strip(), (
            f"{device_id}: the manual link {entry['url']} needs a description "
            f"saying which model or edition it covers"
        )


def test_archived_links_are_kept_as_archive_urls(specs):
    """An archive.org link must be a snapshot, not the availability API.

    The API returns JSON about whether a snapshot exists; it is what
    scripts/check_links.py queries, and it is useless to a human following a
    link. Only the /web/<timestamp>/ replay form belongs in a spec.
    """
    for device_id, entry in helpful_urls(specs):
        url = entry["url"]
        if "archive.org/wayback/available" in url:
            raise AssertionError(
                f"{device_id}: {url} is the Wayback availability API, not a snapshot"
            )
        if "web.archive.org" in url:
            assert "/web/" in url, f"{device_id}: {url} is not a Wayback replay URL"


def test_credentials_declare_passphrase_handling(specs):
    """How the user's WiFi passphrase is protected is never 'unspecified'."""
    for device_id, spec in specs.items():
        setup = spec["device"].get("setup")
        if setup is None:
            continue
        credentials = setup["credentials"]
        protection = credentials.get("wifi_passphrase_protection")
        assert protection in PASSPHRASE_PROTECTION, (
            f"{device_id}: wifi_passphrase_protection {protection!r} not in "
            f"{PASSPHRASE_PROTECTION}"
        )
        # not_applicable is only honest when no passphrase crosses a link this
        # spec documents. What settles that is the method type, not the device
        # protocol: `protocol: wifi` here means "reached over IP", and plenty of
        # such devices never receive a passphrase from a client — the hue-bridge
        # is cabled, roku-ecp takes it through the TV's own on-screen UI, and
        # niu-escooter is already online when a client first meets it.
        #
        # `ble_provisioning` needs the same care in the other direction. It used
        # to be treated as proof on its own, but it covers BLE-only cases with no
        # WiFi anywhere: flashing custom firmware (xiaomi-lywsd03mmc), BLE Mesh
        # provisioning (thermopro-tempspike-bbq), lock pairing (nuki-smart-lock).
        # It only implicates a passphrase when the device has WiFi to join.
        if protection == "not_applicable":
            types = method_types(setup)
            hands_over_credentials = bool(
                types & {"softap_http", "softap_soap", "wps", "smartconfig"}
            ) or ("ble_provisioning" in types and spec["device"]["protocol"] == "wifi")
            assert not hands_over_credentials, (
                f"{device_id}: claims no passphrase is transferred, but "
                f"documents a credential-carrying method ({sorted(types)})"
            )


def test_cloud_only_onboarding_records_whether_a_local_path_exists(specs):
    """The whole point of flagging cloud_account is the recoverability answer."""
    for device_id, setup in setups(specs):
        for phase in method_phases(setup):
            if phase["type"] != "cloud_account":
                continue
            cloud = phase.get("cloud", {})
            assert cloud.get("local_alternative"), (
                f"{device_id}: cloud_account onboarding must state whether any "
                "local alternative exists — 'none known' is a valid answer"
            )


def test_empty_local_name_prefix_is_never_used(specs):
    """An empty prefix matches every BLE device when used as a scan filter."""
    for device_id, spec in specs.items():
        identification = spec["device"].get("identification", {})
        assert identification.get("local_name_prefix", "x") != "", (
            f"{device_id}: local_name_prefix is empty — omit the key instead"
        )
        for prefix in identification.get("local_name_prefixes", []):
            assert prefix != "", (
                f"{device_id}: local_name_prefixes contains an empty string — "
                "drop the entry instead"
            )


def test_mac_prefixes_are_usable_ouis(specs):
    """A prefix shorter than three octets ranks a sixteenth of all hardware.

    Consumers reject these anyway, so a spec carrying one is silently doing
    nothing rather than doing what its author intended.

    Counted in hex digits rather than octets, because IEEE's MA-M and MA-S
    blocks are 28 and 36 bits — `C4:7C:8D:6` is a legitimate prefix whose last
    group is a single nibble, and the consumer's own rule is 6..=10 digits.
    """
    for device_id, spec in specs.items():
        identification = spec["device"].get("identification", {})
        for entry in identification.get("mac_prefixes", []):
            prefix = entry if isinstance(entry, str) else entry["prefix"]
            groups = prefix.replace("-", ":").split(":")
            assert all(1 <= len(g) <= 2 and _is_hex(g) for g in groups), (
                f"{device_id}: mac_prefix {prefix!r} is not colon-separated hex"
            )
            # Only the final group may be a nibble; a short group in the middle
            # is a typo that would silently shift every digit after it.
            assert all(len(g) == 2 for g in groups[:-1]), (
                f"{device_id}: mac_prefix {prefix!r} has a half-octet before "
                "the end — only the last group may be a single hex digit"
            )
            digits = len(prefix.replace("-", "").replace(":", ""))
            assert 6 <= digits <= 10, (
                f"{device_id}: mac_prefix {prefix!r} is {digits} hex digits; "
                "an OUI is 24 (MA-L) to 36 (MA-S) bits, i.e. 6 to 10 digits"
            )


def test_high_confidence_mac_prefixes_show_their_working(specs):
    """`high` says a block is this device family's and effectively nothing
    else's. That is a claim about the world, not a default, so it has to name
    the evidence — otherwise the strongest rating is also the cheapest to
    write, which is exactly backwards.
    """
    for device_id, spec in specs.items():
        identification = spec["device"].get("identification", {})
        for entry in identification.get("mac_prefixes", []):
            if isinstance(entry, str) or entry.get("confidence") != "high":
                continue
            assert entry.get("notes", "").strip(), (
                f"{device_id}: mac_prefix {entry['prefix']!r} is rated high "
                "confidence with no notes — say how you established that"
            )


def _is_hex(octet: str) -> bool:
    return all(c in "0123456789abcdefABCDEF" for c in octet)


# `identification` sweeps unrecognised keys into an extensions map rather than
# rejecting them, which is what lets vendor-specific discovery hints live there.
# The cost is that a near-miss on a schema key is not an error, it is a silent
# no-op: consumers read the name they know and never see the value. Roku carried
# `ssdp_search_target` for exactly this reason, and its one unambiguous SSDP
# target -- `roku:ecp` -- reached no consumer at all.
#
# `local_name_prefixes` used to be on this list and is not any more: it is a
# schema key now, because inkbird-bbq-thermometer ships under eight rebadged
# names and renaming it to the singular would have dropped seven of them.
IDENTIFICATION_NEAR_MISSES = {
    "ssdp_search_target": "ssdp_search_targets",
    "service_uuid": "service_uuids",
    "mac_prefix": "mac_prefixes",
    "mdns_service_types": "mdns_service_type",
    # Two of the three R-221 spellings. The block is closed now, so these
    # fail the schema too; the table is what turns "additional properties are
    # not allowed" into the name of the key that was meant. The third,
    # `local_name_contains`, has no identification-block equivalent (a
    # substring test lives in `discovery.methods[].ble.local_name`), so it
    # gets the schema's own message and is not listed here.
    "local_name": "local_names",
    "advertisement_names": "local_names",
    "discovery_notes": "notes",
}


def test_identification_keys_are_not_near_misses(specs):
    """A singular/plural slip on an identification key is silently ignored."""
    for device_id, spec in specs.items():
        identification = spec["device"].get("identification", {})
        for wrong, right in IDENTIFICATION_NEAR_MISSES.items():
            assert wrong not in identification, (
                f"{device_id}: identification.{wrong} is not a schema key and is "
                f"silently ignored by consumers — use {right}"
            )


def test_near_miss_targets_are_real_schema_keys() -> None:
    """The table must point at keys the schema declares.

    Otherwise it does the opposite of its job: an author trips the assertion,
    renames their key as instructed, and lands on another key no consumer
    reads — which is exactly how `ssdp_search_target` became
    `ssdp_search_targets` while still reaching nothing.
    """
    import json

    schema = json.loads((REPO_ROOT / "device-specs" / "schema.json").read_text())
    declared = set(
        schema["properties"]["device"]["properties"]["identification"][
            "properties"
        ]
    )
    for wrong, right in IDENTIFICATION_NEAR_MISSES.items():
        assert right in declared, (
            f"near-miss table sends {wrong!r} to {right!r}, which schema.json "
            "does not declare under device.identification"
        )


def test_category_is_from_the_closed_vocabulary(specs):
    """Every spec states a category, spelled the way the schema spells it.

    The schema enforces this too, so this test exists for the failure message:
    a jsonschema enum error names the offending value and 25 alternatives with
    no hint about which is meant, and this is the place a spec author is
    already looking when they add a device.
    """
    allowed = schema_categories()
    for device_id, spec in specs.items():
        category = spec["device"].get("category")
        assert category, (
            f"{device_id}: device.category is missing — pick one of "
            f"{sorted(allowed)}"
        )
        assert category in allowed, (
            f"{device_id}: device.category '{category}' is not in the "
            f"vocabulary {sorted(allowed)}. Reuse an existing value if one is "
            "even roughly right; propose a new one in schema.json if none is."
        )


def test_reference_specs_are_categorised_as_references(specs):
    """`type: reference-*` and `category: reference` must agree.

    They say the same thing, and the schema keys the access-surface exemption
    off `type`. A file that is a reference by one field and a device by the
    other would be exempted from documenting an access surface and then drawn
    in the app's device list as though it were hardware.
    """
    for device_id, spec in specs.items():
        device = spec["device"]
        by_type = is_reference(spec)
        by_category = device.get("category") == "reference"
        assert by_type == by_category, (
            f"{device_id}: type={device.get('type')!r} and "
            f"category={device.get('category')!r} disagree about whether this "
            "file documents a device or a published protocol"
        )


def test_the_schema_itself_rejects_a_reference_mismatch():
    """The rule above must hold for consumers who never run these tests.

    `test_reference_specs_are_categorised_as_references` only sees specs
    checked into this repository. schema.json is published, and a standalone
    consumer validating against it should not be able to publish real hardware
    as a protocol reference — or a protocol reference as hardware. So the
    constraint lives in the schema and this pins both directions of it.
    """
    validator = Draft202012Validator(_schema())

    def errors(doc) -> int:
        return len(list(validator.iter_errors(doc)))

    device = load(DEVICES_DIR / "admore-light-bar.yaml")
    reference = load(DEVICES_DIR / "obd2-pid-reference.yaml")

    assert errors(device) == 0, "the unmodified fixtures must be valid"
    assert errors(reference) == 0

    claims_reference = copy.deepcopy(device)
    claims_reference["device"]["category"] = "reference"
    assert errors(claims_reference), (
        "a device with an ordinary type may not claim category: reference"
    )

    # …including one that states no `type` at all, which is most of them.
    no_type = copy.deepcopy(claims_reference)
    no_type["device"].pop("type", None)
    assert errors(no_type), (
        "a spec with no type may not claim category: reference either"
    )

    claims_device = copy.deepcopy(reference)
    claims_device["device"]["category"] = "vehicle"
    assert errors(claims_device), (
        "a reference- type may not claim a device category"
    )


def test_every_vocabulary_value_is_reachable(specs):
    """No category may be retired by deleting the last spec that used it.

    A value nobody uses is not automatically wrong — the vocabulary leads the
    catalogue on purpose, so 'camera' can exist before the first camera does.
    But an unused value that nobody *remembers* is how a vocabulary rots, so
    this test names them rather than failing: the list in the output is the
    review prompt.
    """
    used = {spec["device"].get("category") for spec in specs.values()}
    unused = sorted(schema_categories() - used)
    print(f"categories with no spec yet: {unused or 'none'}")
    assert used <= schema_categories()


# ---------------------------------------------------------------------------
# Undeclared keys in the blocks a client executes
# ---------------------------------------------------------------------------
#
# `test_identification_keys_are_not_near_misses` above catches a named list of
# slips under `device.identification`. The tests below generalise it to the
# three blocks a client actually runs on -- entities, characteristic `format:`
# fields, and command `parameters` -- and they do it by comparing against
# schema.json rather than a list, so a *new* invented key fails too.
#
# The failure mode is always the same and always silent. The schema is
# permissive by design (no `additionalProperties: false`, so vendor metadata
# can ride along), and every consumer parser drops what it does not recognise.
# So an entity that says `write_characteristic` where the vocabulary says
# `command_characteristic` validates, reads fine to a human, and cannot be
# written to by anything. Nothing anywhere reports it.
#
# These are the executed blocks, not the documentary ones: a bespoke key next
# to `device.notes` costs a reader nothing, while a bespoke key in an entity is
# a control that does not work.


def _entity_schema_keys() -> set[str]:
    return set(_schema()["properties"]["entities"]["items"]["properties"])


def _format_field_schema_keys() -> set[str]:
    schema = _schema()
    field = schema["properties"]["services"]["items"]["properties"][
        "characteristics"
    ]["items"]["properties"]["format"]["items"]
    # The shared number vocabulary is pulled in by $ref, so its keys are
    # declared for this block even though they are not spelled out in it.
    return set(field["properties"]) | set(
        schema["$defs"]["number_semantics"]["properties"]
    )


def _characteristics(spec: dict):
    """Yield every characteristic in a spec, service order preserved."""
    for service in spec.get("services") or []:
        for characteristic in service.get("characteristics") or []:
            yield characteristic


def test_entity_keys_are_declared_in_the_schema(specs):
    """Every key on an entity must be one schema.json defines.

    An entity is a contract with a client: draw this control, read that
    characteristic. A key outside the vocabulary is not an extension, it is a
    line of the contract nobody is on the other end of.
    """
    declared = _entity_schema_keys()
    for device_id, spec in specs.items():
        for entity in spec.get("entities") or []:
            undeclared = sorted(set(entity) - declared)
            assert not undeclared, (
                f"{device_id}: entity {entity.get('name')!r} uses "
                f"{undeclared}, which schema.json does not declare under "
                "`entities`. Consumers drop unknown keys silently, so this "
                "reaches nothing. Use the declared spelling, or add the key "
                f"to schema.json if it is genuinely new. Declared: "
                f"{sorted(declared)}"
            )


# The role vocabulary `entities[].commands` draws from, per platform. Same
# shape and same reasoning as ENTITY_KEY_VOCABULARY below: a pytest-owned list
# rather than a schema enum, so growth stays additive and a typo is caught.
#
# Why per platform and not one flat set: a role is a promise about what the
# control DOES, and the platform is what makes it meaningful. `set_brightness`
# on a cover, or `open_cover` on a light, is exactly as wrong as a misspelling
# and just as silent — a consumer looks up the roles its light card knows and
# never asks the question the spec answered.
#
# Spellings a consumer accepts as synonyms are listed beside their canonical
# form rather than collapsed, because the catalogue uses both and this file's
# job is to say what is legal, not to prefer.
ENTITY_ROLE_VOCABULARY = {
    "switch": {"turn_on", "power_on", "turn_off", "power_off",
               "toggle", "power_toggle", "press"},
    "light": {"turn_on", "power_on", "turn_off", "power_off",
              "toggle", "power_toggle", "set_brightness", "set_color",
              "set_color_temperature", "set_effect"},
    "button": {"press"},
    "select": {"select_option", "set_option"},
    "text": {"submit", "type", "press"},
    "number": {"set_value", "set_temperature", "set_target"},
    # A climate entity is a setpoint AND a machine: it turns on and off, and
    # its mode pickers are as much part of the control as the temperature.
    "climate": {"set_value", "set_temperature", "set_target",
                "turn_on", "power_on", "turn_off", "power_off",
                "toggle", "power_toggle", "set_hvac_mode", "set_fan_mode"},
    "fan": {"turn_on", "power_on", "turn_off", "power_off",
            "toggle", "power_toggle", "set_percentage", "set_speed",
            "set_value", "set_oscillating"},
    "cover": {"open_cover", "close_cover", "stop_cover",
              "set_cover_position", "set_position"},
}


def test_entity_roles_come_from_the_documented_vocabulary(specs):
    """Every key in an `entities[].commands` map is a role a consumer matches.

    The failure this catches has no other symptom. `commands` was declared as a
    bare `{"type": "object"}`, so any key validated; consumers match a closed
    set of role names and pass over the rest without a word. A binding outside
    the set therefore reads as wired, resolves nothing, and produces no error,
    no warning and no missing-control note — the entity resolved its OTHER
    roles, so nothing reports it.

    Eighteen bindings across seven specs had drifted out that way before this
    test existed: openevse's amp setpoint bound `turn_on`, the Yeelight cube
    spelled its colour roles `set_rgb` and `set_color_temp`, a name badge bound
    `set_text` to a bitmap chunk write, and both Frigidaire units bound modes
    and power on a platform whose vocabulary had only the setpoint.
    """
    for device_id, spec in specs.items():
        for entity in spec.get("entities") or []:
            platform = entity.get("platform")
            allowed = ENTITY_ROLE_VOCABULARY.get(platform)
            # A reading platform (sensor, binary_sensor, or no platform at all)
            # has no CONTROLS, but it may still have to ask for its value:
            # astral-hoops' battery gauge answers a `get_battery_level` write
            # with an `&L<n>` record, and without naming that command the
            # reading is one a consumer can display and never obtain. `poll` is
            # the BLE analogue of the network side's `state_command`, and it is
            # the only thing a reading may bind — anything else on a platform
            # with no controls is a control nothing will send.
            if allowed is None:
                stray = sorted(set(entity.get("commands") or {}) - {"poll"})
                assert not stray, (
                    f"{device_id}: entity {entity.get('name')!r} has platform "
                    f"{platform!r}, which has no controls, but binds {stray}. "
                    "Nothing will send them. A reading may bind `poll` — the "
                    "command that fetches its value — and nothing else."
                )
                continue
            for role in entity.get("commands") or {}:
                assert role in allowed, (
                    f"{device_id}: entity {entity.get('name')!r} ({platform}) "
                    f"binds the role {role!r}, which is not in the documented "
                    f"vocabulary for that platform. A consumer matches these "
                    f"names, so this binding reaches nothing and says nothing. "
                    f"Use one of {sorted(allowed)}, move the binding into "
                    f"`notes` if no role describes it, or add the role to "
                    f"ENTITY_ROLE_VOCABULARY (and the schema description) in "
                    f"the same change that teaches a consumer to draw it."
                )


# Specs that describe a control surface no entity binds. Each is a spec whose
# commands or endpoints a consumer can read but cannot draw, because the entity
# layer is what every renderer consumes; naming them here is the difference
# between a backlog and an oversight.
#
# A camera spec is NOT in this state and is exempted below: its surface is the
# `camera:` block, which a viewer consumes directly.
ENTITYLESS_CONTROL_SURFACES = {
    "chromecast-castv2": "CASTV2 is a TLS protobuf session, not a request per "
                         "command; the five commands are the vocabulary, and "
                         "what binds them is a session a renderer cannot open "
                         "yet.",
    "logitech-harmony-hub": "The local WebSocket envelope is unconfirmed "
                            "(the spec says so), so binding entities to it "
                            "would promise a control nobody has driven.",
    "parrot-arsdk-drone": "ARSDK is a binary UDP protocol after a TCP "
                          "handshake; the commands document it, and no "
                          "generic renderer reaches it.",
    "pebble-smartwatch": "Pebble Protocol over a BT Classic serial link — "
                         "outside both transports this catalogue's consumers "
                         "speak.",
    "squeezebox-slimproto": "SlimProto is a persistent binary TCP session; "
                            "the four commands name CLI verbs that ride it.",
    "vevor-vt256-thermal-imager": "Its fifteen commands ride the vendor's own "
                                  "TCP session beside the MJPEG stream; the "
                                  "stream is bindable through `camera:`, the "
                                  "commands are not bindable at all yet.",
    "xiaomi-miio": "miIO is an encrypted UDP protocol keyed by a token the "
                   "spec cannot carry; the commands document the method "
                   "names, not a surface a renderer can drive.",
    "aqara-hub": "The two commands are onboarding verbs (multicast whois, "
                 "encrypted credential push); the spec's own finding is that "
                 "no post-setup LAN control surface exists to bind.",
}


def test_a_control_surface_is_bound_to_an_entity_or_named_as_a_backlog(specs):
    """A spec with commands and no entities draws nothing, and says nothing.

    `entities` is what every consumer renders from: a command nothing binds is
    documentation, however complete. That is a legitimate state — several
    protocols here are documented long before anything can speak them — but it
    is indistinguishable from an entity layer nobody got round to writing, and
    the reader who could tell them apart is the author who moved on.

    So the state is allowed and named. A new spec in it fails until somebody
    decides which of the two it is.
    """
    unbound = []
    for device_id, spec in specs.items():
        if spec.get("entities"):
            continue
        device = spec["device"]
        # Nothing to bind: a standards reference, a device the catalogue only
        # recognises, or one whose surface is a camera stream.
        if is_reference(spec) or device.get("integration") == "identify_only":
            continue
        # A camera's surface IS the `camera:` block, which a viewer consumes
        # directly. Only when that is the WHOLE surface, though: the Vevor
        # imager declares a camera and fifteen commands, and those fifteen
        # reach nothing, which is precisely the state being named here.
        if spec.get("camera") and not spec.get("commands"):
            continue
        if not (spec.get("commands") or spec.get("http_endpoints")):
            continue
        if device_id in ENTITYLESS_CONTROL_SURFACES:
            continue
        unbound.append(device_id)

    assert not unbound, (
        f"these specs declare commands or endpoints and no entities, so a "
        f"consumer has nothing to draw: {sorted(unbound)}. Give each an "
        f"`entities` block binding its roles, or add it to "
        f"ENTITYLESS_CONTROL_SURFACES with the reason no entity can bind it."
    )


def test_the_entityless_backlog_names_only_real_specs(specs):
    """An exemption for a spec that gained entities is an exemption nobody
    notices has stopped applying — and the list is how the backlog is read."""
    stale = sorted(
        device_id
        for device_id in ENTITYLESS_CONTROL_SURFACES
        if device_id not in specs or specs[device_id].get("entities")
    )
    assert not stale, (
        f"ENTITYLESS_CONTROL_SURFACES names {stale}, which no longer need the "
        f"exemption (gained entities, or left the catalogue). Remove them."
    )


def test_an_unreliable_advertised_port_states_the_real_one(specs):
    """`advertised_port_unreliable` without `default_port` says nothing.

    The flag's whole content is "use the declared port instead of the
    announced one". A spec that raises it and declares no port has told a
    consumer to ignore the only port it has, which leaves it with none.
    """
    for device_id, spec in specs.items():
        ident = spec["device"].get("identification") or {}
        if not ident.get("advertised_port_unreliable"):
            continue
        assert ident.get("default_port"), (
            f"{device_id}: says its advertised port is unreliable and declares "
            "no `default_port`, so a consumer is left with no port at all"
        )


def test_entity_names_are_unique_per_variant(specs):
    """Two controls with one name are indistinguishable on screen and in a
    consumer's send-in-flight bookkeeping, which keys on the name.

    Not a flat uniqueness rule, because one legitimate case repeats a name:
    a family spec declares the same logical sensor once per model, each with
    its own characteristic, and `variants` says which models it applies to.
    Only one of those is ever instantiated, because a client knows which model
    it is talking to. So a name may repeat while its entities stay pairwise
    variant-disjoint. An entity with no `variants` applies to every model, so
    it collides with any sibling sharing its name.

    `instances` is a second way a name could honestly repeat -- an entity that
    stands for a set of children keyed by id. Nothing in the catalogue does
    that today, so this rule does not model it; if a spec ever needs to,
    extend the disjointness test rather than exempting the file.
    """
    for device_id, spec in specs.items():
        by_name: dict[str, list[frozenset]] = {}
        for entity in spec.get("entities") or []:
            name = entity.get("name")
            if not name:
                continue
            by_name.setdefault(name, []).append(frozenset(entity.get("variants") or []))
        for name, variant_sets in by_name.items():
            if len(variant_sets) < 2:
                continue
            for i in range(len(variant_sets)):
                for j in range(i + 1, len(variant_sets)):
                    left, right = variant_sets[i], variant_sets[j]
                    assert left and right and not (left & right), (
                        f"{device_id}: {len(variant_sets)} entities are named "
                        f"{name!r} and at least two of them can be present on "
                        f"the same device (variants {sorted(left) or 'all models'} "
                        f"and {sorted(right) or 'all models'}). A consumer keys "
                        "on the name, so it cannot tell them apart. Give them "
                        "distinct names -- a remote key alongside a stateful "
                        "control is conventionally 'Power Key' next to 'Power' "
                        "-- or scope each to the models it applies to with "
                        "`variants`."
                    )


# The semantic-key vocabulary `entities[].key` draws from. A pattern plus this
# list rather than a schema enum, on the `category` precedent: an enum would
# make every vocabulary addition a schema change that hard-fails strict
# parsers, while this list keeps growth additive and typo-checked. Grouped by
# the surface that consumes them; a key is added here the release before a
# spec first uses it.
ENTITY_KEY_VOCABULARY = frozenset(
    {
        # Remote-shaped surfaces (TVs, streaming boxes).
        "power", "power_on", "power_off",
        "back", "home", "up", "down", "left", "right", "ok",
        "replay", "options", "exit", "menu", "info",
        "rewind", "play_pause", "fast_forward",
        "volume_up", "volume_down", "mute",
        "channel_up", "channel_down",
        "search", "find_remote", "keyboard",
        "input_hdmi1", "input_hdmi2", "input_hdmi3", "input_hdmi4",
        "input_av", "input_tuner",
        # The raw power key beside a stateful Power switch (which owns
        # `power`): a keypress that toggles, not a direction.
        "power_toggle",
        # Discrete transport keys, for remotes that have them apart from (or
        # instead of) play_pause. `pause` and `stop` are shared with the
        # treadmill card below: the same verb on a different surface.
        "play", "previous", "next", "record",
        # The number pad and the four colour keys.
        "num_0", "num_1", "num_2", "num_3", "num_4",
        "num_5", "num_6", "num_7", "num_8", "num_9",
        "red", "green", "yellow", "blue",
        # Treadmill / fitness cards.
        "start", "pause", "stop", "speed",
    }
)


def _ble_name_matchers(spec):
    """Every `discovery.methods[].ble.local_name` matcher in one spec."""
    for method in (spec.get("device", {}).get("discovery", {}) or {}).get("methods") or []:
        if method.get("type") != "ble_scan":
            continue
        matcher = (method.get("ble") or {}).get("local_name")
        if isinstance(matcher, dict):
            yield matcher


def test_ble_name_matchers_state_exactly_one_needle_form(specs):
    """A `local_name` matcher gives `value` or `values`, never neither.

    A matcher with no needle matches nothing — and these matchers are load-
    bearing in both directions: the OBD adapters are FOUND by one, and the
    skimmer heads-up is WITHHELD from a configured module by one. Either way
    the failure is silent, which is why it is worth a test rather than a
    reviewer's attention.
    """
    for device_id, spec in specs.items():
        for matcher in _ble_name_matchers(spec):
            has_value = isinstance(matcher.get("value"), str) and matcher["value"] != ""
            values = matcher.get("values")
            has_values = isinstance(values, list) and any(
                isinstance(v, str) and v for v in values
            )
            assert has_value or has_values, (
                f"{device_id}: a local_name matcher states no needle "
                f"({matcher!r}) — it can never match anything"
            )


def _ble_manufacturer_matchers(spec: dict):
    methods = (spec["device"].get("discovery") or {}).get("methods") or []
    for method in methods:
        matcher = (method.get("ble") or {}).get("manufacturer_data")
        if isinstance(matcher, dict):
            yield matcher


def test_manufacturer_data_patterns_start_after_the_company_id(specs):
    """`pattern` is the payload AFTER the two company-id bytes.

    The catalogue once measured it from both origins at once (S-06): the four
    specs squatting company id 21076 wrote `54520061`-style patterns that
    repeated the id, while Braun and banlanx wrote the payload alone. A
    consumer choosing either origin mismatched half the set -- and the
    21076 family is distinguishable by nothing else. A pattern beginning with
    its own company id in little-endian wire order is the regression to catch.
    """
    for device_id, spec in specs.items():
        for matcher in _ble_manufacturer_matchers(spec):
            pattern = matcher.get("pattern")
            if not pattern:
                continue
            company_id = matcher["company_id"]
            wire_order = f"{company_id & 0xFF:02x}{company_id >> 8:02x}"
            assert not pattern.lower().startswith(wire_order), (
                f"{device_id}: manufacturer_data.pattern {pattern!r} begins with "
                f"the company id {company_id} in wire order ({wire_order}); "
                "the pattern is the payload after those two bytes, which "
                "`company_id` already matched"
            )
            mask = matcher.get("mask")
            if matcher.get("match") == "masked":
                assert mask and len(mask) == len(pattern), (
                    f"{device_id}: a masked match needs a `mask` the same "
                    f"length as its pattern ({pattern!r} vs {mask!r})"
                )


UUID_SHAPE = re.compile(
    r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
)


def _uuid_valued_fields(node, path=""):
    """Every (path, value) whose key names a UUID field and whose value is one.

    Keys are `uuid`, `characteristic`, `service_uuids` and any `*_uuid` /
    `*_characteristic`, plus the items of a list under such a key.
    """
    if isinstance(node, dict):
        for key, value in node.items():
            here = f"{path}.{key}" if path else str(key)
            named = str(key).endswith(("uuid", "uuids", "characteristic"))
            if named and isinstance(value, str) and UUID_SHAPE.match(value):
                yield here, value
            elif named and isinstance(value, list):
                for i, item in enumerate(value):
                    if isinstance(item, str) and UUID_SHAPE.match(item):
                        yield f"{here}[{i}]", item
            yield from _uuid_valued_fields(value, here)
    elif isinstance(node, list):
        for i, item in enumerate(node):
            yield from _uuid_valued_fields(item, f"{path}[{i}]")


def test_uuid_fields_are_lower_case(specs):
    """One spelling per UUID, so string comparison finds it.

    hyperice-hypervolt-plus stated its handshake characteristic in upper case
    and the same characteristic in lower case fourteen lines later (S-03). A
    consumer that compares strings -- which is every consumer that has not
    been bitten yet -- resolves one and not the other. Lower case is what the
    catalogue uses; prose may quote a UUID however the source spelt it.
    """
    wrong = [
        f"{device_id}: {path} = {value}"
        for device_id, spec in specs.items()
        for path, value in _uuid_valued_fields(spec)
        if value != value.lower()
    ]
    assert not wrong, "UUID fields must be lower-case hex:\n  " + "\n  ".join(wrong)


def _initialization_fixture() -> dict:
    """A real spec carrying an executable initialization step, for mutation."""
    for path in SPEC_PATHS:
        spec = load(path)
        steps = spec.get("initialization") or []
        if steps and any(k in steps[0] for k in ("write", "read", "subscribe")):
            return spec
    raise AssertionError("no spec carries a top-level executable initialization step")


def test_initialization_steps_accept_subscribe_and_when():
    """The keys six specs already used are declared now (S-01/S-02).

    `subscribe: true` is an operation -- a consumer that only knew `write` and
    `read` ran neither of SmartDawn's notify-channel steps and every later
    write was lost. `when: before_each_command` is the KingSmith cadence
    stated as data instead of a sentence in `notes`.
    """
    validator = Draft202012Validator(_schema())
    spec = copy.deepcopy(_initialization_fixture())
    assert not list(validator.iter_errors(spec)), "the fixture must be valid"
    spec["initialization"].append(
        {
            "characteristic": "0000fff1-0000-1000-8000-00805f9b34fb",
            "subscribe": True,
            "when": "before_each_command",
            "notes": "synthesised for the schema test",
        }
    )
    assert not list(validator.iter_errors(spec)), (
        "schema rejected an initialization step using subscribe / when / notes"
    )


@pytest.mark.parametrize(
    "mutation",
    [
        {"subscrib": True},
        {"when": "sometimes"},
        {"characteristic": "0000FFF1-0000-1000-8000-00805F9B34FB", "read": True},
    ],
    ids=["undeclared-key", "bad-when", "upper-case-uuid"],
)
def test_initialization_steps_are_closed(mutation):
    """A step's keys change what it IS, so an unknown one is an error.

    The third case is the convention (lower-case UUIDs) enforced by the
    sweep above, not by the schema, so it is asserted by the sweep's helper
    here rather than the validator.
    """
    validator = Draft202012Validator(_schema())
    spec = copy.deepcopy(_initialization_fixture())
    step = {"characteristic": "0000fff1-0000-1000-8000-00805f9b34fb"}
    step.update(mutation)
    spec["initialization"].append(step)
    if "characteristic" in mutation:
        assert any(
            value != value.lower() for _, value in _uuid_valued_fields(spec)
        ), "the sweep must see the upper-case characteristic"
    else:
        assert list(validator.iter_errors(spec)), (
            f"schema accepted an initialization step with {mutation!r}"
        )


def test_ble_name_matcher_regexes_compile(specs):
    """A `match: regex` needle is a regular expression a consumer can run.

    An uncompilable pattern is the same silent nothing as a missing needle,
    one layer down: the consumer's cache stores the failure and the matcher
    never fires again.
    """
    for device_id, spec in specs.items():
        for matcher in _ble_name_matchers(spec):
            if matcher.get("match") != "regex":
                continue
            needles = [matcher["value"]] if matcher.get("value") else []
            needles += [v for v in (matcher.get("values") or []) if v]
            for needle in needles:
                try:
                    re.compile(needle)
                except re.error as error:
                    raise AssertionError(
                        f"{device_id}: local_name regex {needle!r} does not "
                        f"compile: {error}"
                    ) from error


def test_entity_keys_come_from_the_documented_vocabulary(specs):
    """Every `entities[].key` is a token a consumer's curated layouts know.

    The key exists so a remote card can place OK in the middle of a D-pad and
    a treadmill card can find Stop without matching display names. An
    unrecognised token would simply never be consumed -- a typo'd
    `volume_upp` silently demotes the control to the leftover pile, which is
    exactly the failure the key was added to end.
    """
    for device_id, spec in specs.items():
        for entity in spec.get("entities") or []:
            key = entity.get("key")
            if key is None:
                continue
            assert key in ENTITY_KEY_VOCABULARY, (
                f"{device_id}: entity {entity.get('name')!r} declares key "
                f"{key!r}, which is not in the documented vocabulary. Reuse "
                "an existing token if one fits; otherwise add it to "
                "ENTITY_KEY_VOCABULARY (and the schema description) in the "
                "same change."
            )


def test_entity_keys_are_unique_per_variant(specs):
    """A key names a layout slot, so two co-present entities must not share
    one -- the same disjointness rule names carry, for the same reason: a
    consumer resolving `take('ok')` cannot tell two claimants apart. A name
    may repeat across variant-disjoint entities and so may a key.
    """
    for device_id, spec in specs.items():
        by_key: dict[str, list[frozenset]] = {}
        for entity in spec.get("entities") or []:
            key = entity.get("key")
            if key is None:
                continue
            by_key.setdefault(key, []).append(frozenset(entity.get("variants") or []))
        for key, variant_sets in by_key.items():
            if len(variant_sets) < 2:
                continue
            for i in range(len(variant_sets)):
                for j in range(i + 1, len(variant_sets)):
                    left, right = variant_sets[i], variant_sets[j]
                    assert left and right and not (left & right), (
                        f"{device_id}: {len(variant_sets)} entities declare "
                        f"key {key!r} and at least two of them can be present "
                        "on the same device. A layout slot has room for one "
                        "control; drop the key from all but one, or scope "
                        "each to its models with `variants`."
                    )


def test_format_field_keys_are_declared_in_the_schema(specs):
    """Same rule for the `format:` fields a client decodes bytes with.

    `description` used to appear here alongside the declared `notes`, saying
    the same thing in a spelling nothing read.
    """
    declared = _format_field_schema_keys()
    for device_id, spec in specs.items():
        for characteristic in _characteristics(spec):
            for field in characteristic.get("format") or []:
                undeclared = sorted(set(field) - declared)
                assert not undeclared, (
                    f"{device_id}: format field {field.get('name')!r} uses "
                    f"{undeclared}, which schema.json does not declare. "
                    f"Declared: {sorted(declared)}"
                )


def test_format_field_device_class_is_shared_with_entities():
    """`format[].device_class` and `entities[].device_class` are one word.

    The key exists on a format field so a consumer stops inferring a
    reading's class from substrings of its name (`battery`, `humid`, `temp`).
    That only helps if both places spell the vocabulary the same way, so the
    schema routes both through `$defs/device_class` and this test pins the
    routing: the key must be declared on the field, and it must resolve to
    the same definition the entity uses.
    """
    schema = _schema()
    field = schema["properties"]["services"]["items"]["properties"][
        "characteristics"
    ]["items"]["properties"]["format"]["items"]["properties"]
    entity = schema["properties"]["entities"]["items"]["properties"]
    assert "device_class" in field, "format fields cannot state a device class"
    assert field["device_class"].get("$ref") == "#/$defs/device_class"
    assert entity["device_class"].get("$ref") == "#/$defs/device_class"


def test_format_field_device_class_matches_the_bound_entity(specs):
    """A field's class and the class of the entity reading it must agree.

    Two statements of one fact; if they drift, a consumer that trusts the
    field registers the reading under one class and draws the tile under
    another. Also prints the vocabulary the fields use so an unfamiliar
    value gets a second look rather than passing silently.
    """
    used: set[str] = set()
    for device_id, spec in specs.items():
        fields = {}
        for characteristic in _characteristics(spec):
            for field in characteristic.get("format") or []:
                if field.get("device_class"):
                    used.add(field["device_class"])
                    fields[(characteristic["uuid"].lower(), field["name"])] = field[
                        "device_class"
                    ]
        for entity in spec.get("entities") or []:
            uuid = str(entity.get("state_characteristic") or "").lower()
            mapping = entity.get("state_mapping") or {}
            bound = fields.get((uuid, mapping.get("value")))
            if bound is None or not entity.get("device_class"):
                continue
            assert entity["device_class"] == bound, (
                f"{device_id}: entity {entity['name']!r} says device_class "
                f"{entity['device_class']!r} but the field it binds, "
                f"{mapping.get('value')!r}, says {bound!r}."
            )
    print(f"format-field device classes in use: {sorted(used) or 'none'}")


def _command_schema_keys() -> set[str]:
    schema = _schema()
    return set(
        schema["properties"]["services"]["items"]["properties"]["characteristics"][
            "items"
        ]["properties"]["commands"]["additionalProperties"]["properties"]
    )


def test_command_keys_are_declared_in_the_schema(specs):
    """A command is the most executed block there is — it becomes bytes.

    `seeblue-motorcycle-led` carried its whole envelope design in undeclared
    keys, and paid for it: nine of its commands spelled the framed byte
    sequence into `template` with `{message_length}`/`{message_index}`/
    `{checksum}` placeholders no command declared and no client could fill,
    while the packet a client could actually send sat in `payload_template`,
    which nothing reads. The spec failed to parse outright — 36 documented
    commands reaching nobody.
    """
    declared = _command_schema_keys()
    for device_id, spec in specs.items():
        for characteristic in _characteristics(spec):
            for name, command in (characteristic.get("commands") or {}).items():
                if not isinstance(command, dict):
                    continue
                undeclared = sorted(set(command) - declared)
                assert not undeclared, (
                    f"{device_id}: command {name!r} uses {undeclared}, which "
                    "schema.json does not declare. Consumers drop unknown "
                    "keys silently, so anything load-bearing there reaches "
                    f"nothing. Declared: {sorted(declared)}"
                )


def test_templates_only_reference_declared_parameters(specs):
    """Every `{placeholder}` must name a parameter of its own command.

    A template is an encoding instruction, not prose: a consumer walks it and
    substitutes. A placeholder nothing declares has no value to substitute and
    no width to reserve, so the write is either wrong or impossible — and the
    mobile parser rejects the whole spec over it rather than send bad bytes.

    Bytes that belong to a framing layer are not the command's to name: the
    characteristic's `framing.scheme` owns them and the template is the packet
    alone, which is exactly what seeblue got wrong.
    """
    placeholder = re.compile(r"^\{(.+)\}$")
    for device_id, spec in specs.items():
        for characteristic in _characteristics(spec):
            for name, command in (characteristic.get("commands") or {}).items():
                if not isinstance(command, dict):
                    continue
                template = command.get("template")
                if not isinstance(template, list):
                    continue
                declared = set(command.get("parameters") or {})
                referenced = {
                    match.group(1)
                    for element in template
                    if isinstance(element, str)
                    for match in [placeholder.match(element)]
                    if match
                }
                undeclared = sorted(referenced - declared)
                assert not undeclared, (
                    f"{device_id}: command {name!r} references {undeclared} in "
                    "its template but declares no such parameter. Either "
                    "declare it, or -- if those bytes are envelope/framing "
                    "bytes -- drop them from the template and let the "
                    "characteristic's `framing.scheme` carry them."
                )


def test_byte_parameters_state_lengths_not_value_ranges(specs):
    """`min`/`max` bound a number; a `bytes` parameter has no number.

    `fardriver-controller` wrote `data: {type: bytes, min: 1, max: 26}`
    meaning "1 to 26 bytes". Read as a value range — which is what `min`/`max`
    mean everywhere else — it is nonsense, and the consumer that said so
    rejected the parameter and lost the whole spec with it. The length
    vocabulary is `min_length`/`max_length`.

    schema.json enforces this; the test is for the failure message, which
    names the replacement.
    """
    for device_id, spec in specs.items():
        for characteristic in _characteristics(spec):
            for name, command in (characteristic.get("commands") or {}).items():
                if not isinstance(command, dict):
                    continue
                for param, definition in (command.get("parameters") or {}).items():
                    if not isinstance(definition, dict):
                        continue
                    if definition.get("type") != "bytes":
                        continue
                    numeric = sorted({"min", "max"} & set(definition))
                    assert not numeric, (
                        f"{device_id}: command {name!r} parameter {param!r} is "
                        f"`bytes` and states {numeric}. A run of octets has no "
                        "numeric range — if that was a length, say "
                        "`min_length`/`max_length`."
                    )


def test_command_parameters_are_all_parameters(specs):
    """`parameters:` has no reserved siblings — every key is a parameter.

    `color_order` used to be one: a per-command declaration of RGB channel
    order, sitting beside a `template` that already emitted the channels in an
    order. Two statements of one fact with no stated precedence, so a spec
    where they disagreed had no correct reading — and every one of the eight
    specs that carried it said `rgb` next to a template already in R,G,B
    order. The template is the byte order; a device wanting GRB is written
    `template: ["{green}", "{red}", "{blue}"]`.

    schema.json enforces this (a non-object under `parameters` fails), so this
    test is for the failure message rather than the rule.
    """
    for device_id, spec in specs.items():
        for characteristic in _characteristics(spec):
            for name, command in (characteristic.get("commands") or {}).items():
                if not isinstance(command, dict):
                    continue
                for key, value in (command.get("parameters") or {}).items():
                    assert isinstance(value, dict), (
                        f"{device_id}: command {name!r} has "
                        f"`parameters.{key}` set to a scalar ({value!r}). "
                        "Every key under `parameters` is a parameter "
                        "definition; there are no reserved siblings. If this "
                        "is byte order for a colour command, state it by the "
                        "order the template names {red}/{green}/{blue}."
                    )


def _first_templated_command(spec: dict) -> dict:
    for characteristic in _characteristics(spec):
        for command in (characteristic.get("commands") or {}).values():
            if isinstance(command, dict) and "template" in command and command.get("parameters"):
                return command
    raise AssertionError("fixture has no templated command with parameters")


def test_the_schema_rejects_a_command_with_both_value_and_template():
    """One command, one envelope.

    xkglow-chrome's set_rgb_color carried a fixed `value` beside a
    parameterised `template` (R-141/R-214). The encoder took the constant and
    the four sliders it drew wrote pure red whatever was picked; the entity
    lost its `set_color` role because the command read as fixed. The schema
    now refuses the pair so the next one is a validation error, not a light
    that ignores its colour picker.
    """
    validator = Draft202012Validator(_schema())
    spec = load(DEVICES_DIR / "xkglow-chrome.yaml")
    assert not list(validator.iter_errors(spec)), "the fixture must be valid"

    both = copy.deepcopy(spec)
    command = _first_templated_command(both)
    command["value"] = [0x00, 0x00, 0x04, 0xFF, 0x00, 0x00]
    assert list(validator.iter_errors(both)), (
        "schema accepted a BLE command declaring both `value` and `template`"
    )


def test_no_command_declares_both_value_and_template(specs):
    """The sweep behind the schema rule, for the failure message."""
    for device_id, spec in specs.items():
        for characteristic in _characteristics(spec):
            for name, command in (characteristic.get("commands") or {}).items():
                if not isinstance(command, dict):
                    continue
                assert not ("value" in command and "template" in command), (
                    f"{device_id}: command {name!r} declares both `value` and "
                    "`template`; a fixed form and a parameterised form are two "
                    "commands, each bound to its own entity role"
                )


def test_the_schema_rejects_values_on_a_ble_write_parameter():
    """A write parameter's enumeration is `allowed` + `labels`, never `values`.

    `values` reaches the BLE parameter block through $defs/number_semantics,
    where it is the decode-side code table of a reading. Nine parameters in
    three specs wrote `values: {0: off, 1: on}` (S-04) and a consumer that
    implemented what the block declares saw no constraint and drew a 0..255
    slider over a two-position switch.
    """
    validator = Draft202012Validator(_schema())
    spec = load(DEVICES_DIR / "xkglow-chrome.yaml")
    assert not list(validator.iter_errors(spec)), "the fixture must be valid"

    tabled = copy.deepcopy(spec)
    command = _first_templated_command(tabled)
    next(iter(command["parameters"].values()))["values"] = {"0": "off", "1": "on"}
    assert list(validator.iter_errors(tabled)), (
        "schema accepted `values` on a BLE command parameter"
    )


def test_ble_write_parameters_enumerate_with_allowed_and_labels(specs):
    """The sweep behind the rule above, naming the parameter."""
    for device_id, spec in specs.items():
        for characteristic in _characteristics(spec):
            for name, command in (characteristic.get("commands") or {}).items():
                if not isinstance(command, dict):
                    continue
                for key, parameter in (command.get("parameters") or {}).items():
                    if not isinstance(parameter, dict):
                        continue
                    assert "values" not in parameter, (
                        f"{device_id}: {name}.{key} carries `values`, a decode-side "
                        "code table; a write parameter says `allowed: [..]` + "
                        "`labels: [..]`"
                    )
                    allowed = parameter.get("allowed")
                    labels = parameter.get("labels")
                    if allowed is not None and len(allowed) >= 2:
                        ordered = sorted(allowed)
                        assert ordered != list(range(ordered[0], ordered[-1] + 1)), (
                            f"{device_id}: {name}.{key} lists `allowed: {allowed}`, "
                            "a contiguous run -- write it as `min: "
                            f"{ordered[0]}, max: {ordered[-1]}` (labels pair with the "
                            "range the same way); `allowed` is for sets with gaps"
                        )
                    if labels is None:
                        continue
                    # Labels name the list when there is one, else the
                    # contiguous min..max range, one per value, min first.
                    if allowed is not None:
                        assert len(allowed) == len(labels), (
                            f"{device_id}: {name}.{key} has {len(allowed)} allowed "
                            f"values but {len(labels)} labels"
                        )
                        continue
                    lo, hi = parameter.get("min"), parameter.get("max")
                    assert lo is not None and hi is not None, (
                        f"{device_id}: {name}.{key} has labels but neither an "
                        "`allowed` list nor a min..max range for them to name"
                    )
                    assert hi - lo + 1 == len(labels), (
                        f"{device_id}: {name}.{key} labels {len(labels)} values "
                        f"but its range {lo}..{hi} holds {hi - lo + 1}"
                    )


def test_locate_commands_are_never_advanced(specs):
    """A locator is a one-tap button; `advanced` means "not one tap".

    The two are mutually exclusive in schema.json for a reason worth stating
    twice: a client offering "make my device beep" has no user in the loop to
    confirm anything, and `flash_firmware` matches every name-based heuristic
    for a locator that has ever been written.
    """
    kinds = {"sound", "flash", "both"}
    seen = 0
    for device_id, spec in specs.items():
        for characteristic in _characteristics(spec):
            for name, command in (characteristic.get("commands") or {}).items():
                if not isinstance(command, dict):
                    continue
                locate = command.get("locate")
                if locate is None:
                    continue
                seen += 1
                assert locate in kinds, (
                    f"{device_id}: command {name!r} has locate={locate!r}, "
                    f"not one of {sorted(kinds)}"
                )
                assert not command.get("advanced"), (
                    f"{device_id}: command {name!r} is both `advanced` and a "
                    "`locate` action. A locator is offered without "
                    "confirmation, so it must not be a command a user needs "
                    "protecting from."
                )
    assert seen, "no command declares `locate` — the vocabulary has rotted out"


def test_the_schema_rejects_an_advanced_locator():
    """The rule above must hold for consumers who never run these tests."""
    validator = Draft202012Validator(_schema())
    spec = load(DEVICES_DIR / "xiaomi-miflora.yaml")
    assert not list(validator.iter_errors(spec)), "the fixture must be valid"

    both = copy.deepcopy(spec)
    for service in both["services"]:
        for characteristic in service.get("characteristics", []):
            command = (characteristic.get("commands") or {}).get("blink_led")
            if command is not None:
                command["advanced"] = True
                command["advanced_reason"] = "irrelevant, but required"
    assert list(validator.iter_errors(both)), (
        "a command may not be both `advanced` and a `locate` action"
    )


def test_the_schema_enforces_the_button_contract():
    """A button binds exactly `press`, and carries no state binding.

    The platform's description says so; this proves the schema *enforces* it,
    which is what a consumer validating a spec from outside this repository
    relies on. Our own pytest suite never sees those files, so a button with
    no commands — or a `turn_on` nothing renders as a button — would ship as
    a control that does nothing when pressed.
    """
    validator = Draft202012Validator(_schema())
    spec = load(DEVICES_DIR / "roku-ecp.yaml")
    assert not list(validator.iter_errors(spec)), "the fixture must be valid"

    def with_button(entity: dict) -> dict:
        broken = copy.deepcopy(spec)
        broken["entities"] = [entity]
        return broken

    good = {"platform": "button", "name": "B", "commands": {"press": "press_home"}}
    assert not list(validator.iter_errors(with_button(good)))

    for label, entity in (
        ("no commands at all", {"platform": "button", "name": "B"}),
        (
            "a role that is not press",
            {"platform": "button", "name": "B", "commands": {"turn_on": "press_home"}},
        ),
        (
            "a second role beside press",
            {
                "platform": "button",
                "name": "B",
                "commands": {"press": "press_home", "turn_on": "press_home"},
            },
        ),
        ("a state binding", {**good, "state_topic": "/query/active-app"}),
    ):
        assert list(validator.iter_errors(with_button(entity))), (
            f"the schema must reject a button with {label}"
        )


def _bound_command_name(binding):
    """The command a role binding names, whichever of its two forms it takes.

    `entities[].commands.<role>` is either the command's name or an object
    `{command: <name>, values: {<param>: <literal>}}` that fixes arguments
    as well -- FTMS's Stop and Pause are one `stop_or_pause` write told apart
    by its `control` byte. Every test that resolves a binding goes through
    here so neither form is silently skipped.
    """
    if isinstance(binding, dict):
        return binding.get("command")
    return binding


def _declared_commands(spec: dict) -> dict:
    """Name -> command body, across the top-level map and every characteristic."""
    declared = dict(spec.get("commands") or {})
    for characteristic in _characteristics(spec):
        declared.update(characteristic.get("commands") or {})
    return declared


def test_button_presses_name_a_declared_command(specs):
    """And the half a schema cannot check: the bound name resolves.

    `press: press_home` is only a control if `press_home` exists. The schema
    sees a string either way, so the binding is checked here, across every
    spec in the catalogue rather than one device's own test file.
    """
    for device_id, spec in specs.items():
        declared = set(_declared_commands(spec))
        for entity in spec.get("entities") or []:
            if entity.get("platform") != "button":
                continue
            bound = _bound_command_name((entity.get("commands") or {}).get("press"))
            assert bound in declared, (
                f"{device_id}: button {entity.get('name')!r} presses "
                f"{bound!r}, which no command declares"
            )


def test_every_role_binding_names_a_declared_command(specs):
    """Same rule for every role on every platform, in both binding forms.

    The object form `{command, values}` adds a second thing to resolve: each
    key in `values` must be a parameter the named command declares, because
    a literal bound to a parameter the template never reads is a byte that
    silently goes nowhere -- the exact failure the form exists to end.
    """
    for device_id, spec in specs.items():
        declared = _declared_commands(spec)
        for entity in spec.get("entities") or []:
            for role, binding in (entity.get("commands") or {}).items():
                name = _bound_command_name(binding)
                assert name in declared, (
                    f"{device_id}: entity {entity.get('name')!r} binds "
                    f"{role} -> {name!r}, which no command declares"
                )
                if not isinstance(binding, dict):
                    continue
                command = declared[name] if isinstance(declared[name], dict) else {}
                parameters = set(command.get("parameters") or {})
                stray = sorted(set(binding.get("values") or {}) - parameters)
                assert not stray, (
                    f"{device_id}: entity {entity.get('name')!r} role {role} "
                    f"fixes {stray} on {name!r}, which declares only "
                    f"{sorted(parameters)}"
                )


def test_the_schema_accepts_both_role_binding_forms():
    """The object form is a contract, so its shape is enforced, not described.

    A binding that misspells `values`, or names no command, must fail
    validation rather than parse as a control that never sends anything.
    """
    validator = Draft202012Validator(_schema())
    spec = load(DEVICES_DIR / "ftms-fitness-machine-service.yaml")
    assert not list(validator.iter_errors(spec)), "the fixture must be valid"

    def with_press(binding) -> dict:
        broken = copy.deepcopy(spec)
        broken["entities"] = [
            {"platform": "button", "name": "B", "commands": {"press": binding}}
        ]
        return broken

    assert not list(validator.iter_errors(with_press("start_or_resume")))
    assert not list(
        validator.iter_errors(
            with_press({"command": "stop_or_pause", "values": {"control": 1}})
        )
    )
    for label, binding in (
        ("no command", {"values": {"control": 1}}),
        ("no values", {"command": "stop_or_pause"}),
        ("empty values", {"command": "stop_or_pause", "values": {}}),
        ("a misspelled values key", {"command": "stop_or_pause", "value": {"control": 1}}),
        ("a structured literal", {"command": "stop_or_pause", "values": {"control": [1]}}),
    ):
        assert list(validator.iter_errors(with_press(binding))), (
            f"the schema must reject a role binding with {label}"
        )


def test_endianness_is_declared_the_same_way_everywhere():
    """A BLE `format` field and a bus message field ask the same question.

    Byte order was declared on bus fields only, so the six BLE fields that
    stated it were writing a key nothing defined — tolerated because the
    schema is permissive, dropped by every parser, and harmless only because
    all six said `little`, which is what the decoders assume anyway. A `big`
    one would have decoded byte-swapped with nothing to catch it: a
    big-endian 0x0100 reads as 1 rather than 256, and both are plausible
    sensor readings.

    Two definitions of one concept is how they drift, so this pins them
    together rather than merely pinning each.
    """
    schema = _schema()
    ble = schema["properties"]["services"]["items"]["properties"][
        "characteristics"
    ]["items"]["properties"]["format"]["items"]["properties"]["endianness"]
    bus = schema["properties"]["bus"]["properties"]["messages"]["items"][
        "properties"
    ]["fields"]["items"]["properties"]["endianness"]

    for key in ("type", "enum", "default"):
        assert ble[key] == bus[key], (
            f"`endianness` disagrees between BLE format fields and bus "
            f"message fields on {key!r}: {ble[key]!r} vs {bus[key]!r}"
        )
    assert ble["default"] == "little"


def test_declared_endianness_matches_the_default(specs):
    """Every stated byte order is currently `little` — say so out loud.

    Not a rule (a `big` field is legal and the point of declaring the key),
    but the moment the first one lands, the consumers that hardcode
    little-endian become wrong. The print is the review prompt.
    """
    stated = []
    for device_id, spec in specs.items():
        for characteristic in _characteristics(spec):
            for field in characteristic.get("format") or []:
                if "endianness" in field:
                    stated.append(
                        (device_id, field["name"], field["endianness"])
                    )
    big = [s for s in stated if s[2] != "little"]
    print(f"BLE format fields stating endianness: {len(stated)}, big-endian: {big or 'none'}")
    assert all(s[2] in {"little", "big"} for s in stated)


def test_generated_index_covers_every_spec():
    """The index the generator builds *now* must name exactly the specs on disk.

    Deliberately not a check on the committed `device-specs/index.json`: that
    file is written by CI on main (see the `publish-index` job), so on a branch
    that adds a spec it is expected to be one commit behind, and asserting
    otherwise would fail every spec PR. What still has to hold is that the
    generator sees every spec exactly once — a spec the index cannot name is a
    device consumers never load.
    """
    import generate_index
    from validate_specs import discover_specs

    entries, invalid = generate_index.collect_entries()
    assert invalid == 0, "invalid specs are already reported by validate_specs.py"

    indexed = [entry["path"] for entry in entries]
    on_disk = sorted(
        p.relative_to(REPO_ROOT).as_posix() for p in discover_specs()
    )
    assert sorted(indexed) == on_disk
    assert len(indexed) == len(set(indexed)), "duplicate index entries"


def test_committed_index_still_parses():
    """Whatever is checked in must at least be loadable JSON of the right shape.

    Freshness is CI's job, but the file is a shipped asset (the mobile app
    bundles it straight out of the subtree), so a truncated or hand-mangled one
    breaks a consumer with no other check standing between it and a release.
    """
    index_path = REPO_ROOT / "device-specs" / "index.json"
    index = json.loads(index_path.read_text(encoding="utf-8"))
    assert isinstance(index, list) and index, "index.json should be a non-empty array"
    assert all(isinstance(entry.get("path"), str) for entry in index), (
        "every index entry needs a `path`"
    )


# ---------------------------------------------------------------------------
# Spec-level hardware-testing status (`device.testing`)
# ---------------------------------------------------------------------------

TESTING_STATUSES = {"untested", "verified"}
TESTING_DETAILS_BY_STATUS = {
    "untested": {"capture-verified"},
    "verified": {"minimally-verified", "mostly-verified"},
}


def test_testing_block_is_coherent(specs):
    """`detail` refines `status`; a mismatched pair claims two different things.

    'capture-verified' only makes sense as a refinement of 'untested' (checked
    against traffic, never driven), and 'minimally/mostly-verified' only as
    refinements of 'verified'. A verified spec must also name its evidence in
    `notes` — the whole point of the flag is that a reviewer can check it.
    """
    for device_id, spec in specs.items():
        testing = spec["device"].get("testing")
        if testing is None:
            continue
        assert not is_reference(spec), (
            f"{device_id}: reference specs document standards, not hardware, "
            "and must not carry device.testing"
        )
        status = testing.get("status")
        assert status in TESTING_STATUSES, (
            f"{device_id}: testing.status {status!r} not in {TESTING_STATUSES}"
        )
        detail = testing.get("detail")
        if detail is not None:
            allowed = TESTING_DETAILS_BY_STATUS[status]
            assert detail in allowed, (
                f"{device_id}: testing.detail {detail!r} does not refine "
                f"status {status!r} (allowed: {sorted(allowed)})"
            )
        if status == "verified" or detail is not None:
            assert testing.get("notes"), (
                f"{device_id}: a testing claim above bare 'untested' must "
                "name its evidence in testing.notes"
            )


def _has_hardware_verified_setup(spec: dict) -> bool:
    setup = spec["device"].get("setup") or {}
    return any(m.get("verified") for m in setup.get("methods") or [])


def test_testing_status_is_stated(specs):
    """Every device spec must say whether anyone has driven hardware from it.

    Same convention as `setup.methods[].verified`: an absent block reads as an
    oversight, not as 'untested'. Two exemptions: reference specs (they
    document published standards, so hardware testing does not apply), and
    specs that predate the block whose hardware verification is already on
    record as a `verified: true` setup method — for those the absent block is
    not ambiguous, just ungraded.
    """
    missing = sorted(
        d
        for d, spec in specs.items()
        if not is_reference(spec)
        and "testing" not in spec["device"]
        and not _has_hardware_verified_setup(spec)
    )
    assert not missing, f"specs without a device.testing block: {missing}"


# --------------------------------------------------------------------------
# Schema guards for candidate reset procedures.
#
# The rules below are enforced by schema.json, not by the loops above, so they
# hold for specs nobody has written yet. They are tested by mutation: take a
# real spec, break one rule, and require the schema to notice. Without this a
# future schema edit could drop a guard and every existing spec would still
# validate, because none of them break the rule today.
# --------------------------------------------------------------------------


@pytest.fixture(scope="module")
def candidate_reset_spec() -> dict:
    """A real spec carrying an unestablished reset with a candidate procedure.

    Found rather than named. This fixture used to point at one spec by
    filename, and research resolving that device's reset to an established one
    silently took the base case out from under three mutation tests — they kept
    passing while proving nothing, which is the failure mode mutation testing
    exists to avoid. Searching for a qualifying spec means the backfill can
    resolve any device it likes without quietly disarming the guards.

    If the catalogue ever contains no unestablished reset at all — a good
    problem to have — the shape is built from a real spec instead, so the
    schema rules stay tested either way.
    """
    for path in SPEC_PATHS:
        spec = load(path)
        reset = (spec["device"].get("setup") or {}).get("factory_reset") or {}
        if reset.get("applicable") != "unknown":
            continue
        procedures = reset.get("procedures") or []
        if procedures and procedures[0].get("verified") is False and procedures[0].get("basis"):
            return spec

    spec = copy.deepcopy(load(DEVICES_DIR / "wemo-devices.yaml"))
    reset = spec["device"]["setup"]["factory_reset"]
    reset["applicable"] = "unknown"
    reset["confidence"] = "low"
    reset["procedures"] = reset["procedures"][:1]
    reset["procedures"][0]["verified"] = False
    reset["procedures"][0].setdefault("basis", "synthesised for the mutation tests")
    return spec


def test_candidate_reset_spec_is_valid_to_begin_with(candidate_reset_spec):
    """Guards the mutation tests: they prove nothing if the base is invalid."""
    validator = Draft202012Validator(_schema())
    assert not list(validator.iter_errors(candidate_reset_spec))


def test_unverified_reset_procedure_must_cite_a_basis(candidate_reset_spec):
    """'Try this' is only useful if the reader can weigh where it came from."""
    validator = Draft202012Validator(_schema())
    spec = copy.deepcopy(candidate_reset_spec)
    spec["device"]["setup"]["factory_reset"]["procedures"][0].pop("basis")
    assert list(validator.iter_errors(spec)), (
        "schema accepted an unverified reset procedure with no basis"
    )


def test_unestablished_reset_cannot_hold_a_verified_procedure(candidate_reset_spec):
    """The whole point of `applicable: unknown` is that nothing under it is confirmed."""
    validator = Draft202012Validator(_schema())
    spec = copy.deepcopy(candidate_reset_spec)
    spec["device"]["setup"]["factory_reset"]["procedures"][0]["verified"] = True
    assert list(validator.iter_errors(spec)), (
        "schema accepted a verified procedure under an unestablished reset"
    )


# --------------------------------------------------------------------------
# The closed top level.
#
# schema.json rejects any undeclared key at the root and under `device:`. Same
# mutation approach as above: a guard nothing currently violates is a guard
# that can be deleted without a single test going red.
# --------------------------------------------------------------------------


@pytest.fixture(scope="module")
def closed_world_spec() -> dict:
    """A plain, valid LAN spec to mutate against the closure rules."""
    return load(DEVICES_DIR / "hue-bridge.yaml")


def test_closed_world_spec_is_valid_to_begin_with(closed_world_spec):
    validator = Draft202012Validator(_schema())
    assert not list(validator.iter_errors(closed_world_spec))


def test_an_undeclared_top_level_key_is_rejected(closed_world_spec):
    """A bespoke block belongs under `protocol_details`, not at the root."""
    validator = Draft202012Validator(_schema())
    spec = copy.deepcopy(closed_world_spec)
    spec["hue_lan_protocol"] = {"notes": "bespoke"}
    assert list(validator.iter_errors(spec)), (
        "schema accepted an undeclared top-level key"
    )


def test_an_undeclared_device_key_is_rejected(closed_world_spec):
    """The case this closure exists for: a standard field spelled wrong."""
    validator = Draft202012Validator(_schema())
    spec = copy.deepcopy(closed_world_spec)
    spec["device"]["transprot"] = "http"
    assert list(validator.iter_errors(spec)), "schema accepted a typo'd device key"


def test_the_schema_shapes_managed_by(closed_world_spec):
    """`device.managed_by` is read by key by a consumer answering "is this
    driven elsewhere, and where" -- so its shape is enforced, not described."""
    validator = Draft202012Validator(_schema())

    def with_managed_by(block) -> dict:
        spec = copy.deepcopy(closed_world_spec)
        spec["device"]["managed_by"] = block
        return spec

    good = {
        "spec": "ubiquiti-unifi-device",
        "discovery": {"platform_prefixes": ["UNVR"]},
    }
    assert not list(validator.iter_errors(with_managed_by(good)))
    for label, block in (
        ("no spec", {"discovery": {"platform_prefixes": ["UNVR"]}}),
        ("a spec that is not a slug", {**good, "spec": "ubiquiti-unifi-device.yaml"}),
        ("an empty discovery block", {**good, "discovery": {}}),
        ("an unknown discovery signal", {**good, "discovery": {"platform": "UNVR"}}),
        ("a bare mdns service type", {**good, "discovery": {"mdns_service_type": "_hap._tcp"}}),
        ("an undeclared key", {**good, "controller": "nvr"}),
    ):
        assert list(validator.iter_errors(with_managed_by(block))), (
            f"the schema must reject managed_by with {label}"
        )


def test_managed_by_and_platform_tables_resolve(specs):
    """The half the schema cannot check: the controller's spec exists, and the
    prefixes a device says to look for are rows of that spec's platform
    table. A dangling reference here is a consumer that tells the user "this
    is managed elsewhere" and cannot say where."""
    for device_id, spec in specs.items():
        ident = spec["device"].get("identification") or {}
        for row in ident.get("platform_prefixes") or []:
            if row.get("spec"):
                assert row["spec"] in specs, (
                    f"{device_id}: platform prefix {row['prefix']!r} hands off "
                    f"to spec {row['spec']!r}, which does not exist"
                )
        managed = spec["device"].get("managed_by")
        if not managed:
            continue
        controller = specs.get(managed["spec"])
        assert controller is not None, (
            f"{device_id}: managed_by names spec {managed['spec']!r}, which "
            "does not exist"
        )
        wanted = (managed.get("discovery") or {}).get("platform_prefixes") or []
        if not wanted:
            continue
        table = (controller["device"].get("identification") or {}).get(
            "platform_prefixes"
        ) or []
        known = {row["prefix"] for row in table}
        missing = sorted(set(wanted) - known)
        assert not missing, (
            f"{device_id}: managed_by looks for platform prefixes {missing}, "
            f"which {managed['spec']}'s identification.platform_prefixes does "
            f"not list (it has {sorted(known)})"
        )


def test_the_schema_shapes_verdict_bands(closed_world_spec):
    """`entities[].bands` is the vendor's green/yellow/red as data; a band with
    no bound, or a level outside the three, is a verdict nothing can draw."""
    validator = Draft202012Validator(_schema())

    def with_bands(bands) -> dict:
        spec = copy.deepcopy(closed_world_spec)
        spec["entities"] = [
            {"platform": "sensor", "name": "Radon", "unit": "Bq/m³", "bands": bands}
        ]
        return spec

    assert not list(
        validator.iter_errors(
            with_bands(
                [
                    {"level": "good", "below": 100},
                    {"level": "fair", "above": 100, "below": 150},
                    {"level": "poor", "above": 150},
                ]
            )
        )
    )
    for label, bands in (
        ("an empty list", []),
        ("a band with no bound", [{"level": "poor"}]),
        ("a level outside good/fair/poor", [{"level": "red", "above": 150}]),
        ("a bound that is not a number", [{"level": "poor", "above": "150"}]),
        ("an undeclared key", [{"level": "poor", "above": 150, "colour": "red"}]),
    ):
        assert list(validator.iter_errors(with_bands(bands))), (
            f"the schema must reject bands with {label}"
        )


def test_the_schema_shapes_outcome_envelopes(closed_world_spec):
    """`payload_formats.<name>.envelope` is what lets a client decode "HTTP 200,
    read the body" from the spec instead of a hand-mirrored parser."""
    validator = Draft202012Validator(_schema())
    good = copy.deepcopy(closed_world_spec["payload_formats"]["V1Envelope"]["envelope"])

    def with_envelope(envelope) -> dict:
        spec = copy.deepcopy(closed_world_spec)
        spec["payload_formats"]["V1Envelope"]["envelope"] = envelope
        return spec

    assert not list(validator.iter_errors(with_envelope(good)))
    for label, mutate in (
        ("no container", lambda e: e.pop("container")),
        ("an unknown container", lambda e: e.update(container="list")),
        ("no error type path", lambda e: e.pop("error_type_path")),
        ("an unknown error class", lambda e: e["error_types"]["101"].update({"class": "ignore"})),
        ("an error type with no class", lambda e: e["error_types"]["101"].pop("class")),
        ("an undeclared key", lambda e: e.update(status_key="ok")),
    ):
        envelope = copy.deepcopy(good)
        mutate(envelope)
        assert list(validator.iter_errors(with_envelope(envelope))), (
            f"the schema must reject an envelope with {label}"
        )


@pytest.mark.parametrize(
    "key,value",
    [
        ("local_name_contains", ["Gerbing"]),
        ("advertisement_names", ["BT-912"]),
        ("identity_keys", {"primary": "udn"}),
    ],
)
def test_an_undeclared_identification_key_is_rejected(closed_world_spec, key, value):
    """`device.identification` is closed: a scanner reads it by key.

    Three specs carried their advertised names under keys nothing read
    (R-221) and validated; forty carried a duplicate of `discovery.identity`
    the same way. A signal filed under an unknown key never fires, so an
    unknown key is an error now rather than a silence.
    """
    validator = Draft202012Validator(_schema())
    spec = copy.deepcopy(closed_world_spec)
    spec["device"]["identification"][key] = value
    assert list(validator.iter_errors(spec)), (
        f"schema accepted identification.{key}, which no consumer reads"
    )


@pytest.mark.parametrize(
    "key,value",
    [
        ("local_access", {"status": "native"}),
        ("features", [{"type": "image_upload"}]),
        ("protocol_handler", "hue"),
        ("payload_formats", {"state": {"description": "x"}}),
    ],
)
def test_top_level_blocks_cannot_hide_under_device(closed_world_spec, key, value):
    """These four are read at the top level and nowhere else.

    Seventeen specs wrote them one level down and no consumer ever saw them --
    five printers' image_upload capability among the casualties. Nesting them
    is a validation error now rather than a silent loss.
    """
    validator = Draft202012Validator(_schema())
    spec = copy.deepcopy(closed_world_spec)
    spec.pop(key, None)
    spec["device"][key] = value
    assert list(validator.iter_errors(spec)), (
        f"schema accepted {key} nested under device:"
    )


def test_protocol_details_accepts_anything_it_is_given(closed_world_spec):
    """The escape hatch has to actually escape, or specs route around it."""
    validator = Draft202012Validator(_schema())
    spec = copy.deepcopy(closed_world_spec)
    spec["protocol_details"] = {
        "hue_lan_protocol": {"nested": {"deeply": ["arbitrary", 1, True]}}
    }
    assert not list(validator.iter_errors(spec))


def test_bespoke_blocks_live_under_protocol_details(specs):
    """Catalogue side of the same rule, named so a failure explains itself."""
    declared = set(_schema()["properties"])
    stray = {
        device_id: sorted(set(spec) - declared)
        for device_id, spec in specs.items()
        if set(spec) - declared
    }
    assert not stray, (
        f"undeclared top-level keys (move under protocol_details): {stray}"
    )


@pytest.mark.parametrize("value", ["ble_gatt", "ble", "tcp-json", "upnp", "mdns"])
def test_retired_transport_spellings_are_rejected(closed_world_spec, value):
    """One wire, one spelling — the drift these values came from was silent.

    `mdns` is in the list because it is not a transport at all: it is how a
    device was found, and a spec that documents only discovery says so in
    `device.discovery` and leaves this field out.
    """
    validator = Draft202012Validator(_schema())
    spec = copy.deepcopy(closed_world_spec)
    spec["device"]["transport"] = value
    assert list(validator.iter_errors(spec)), (
        f"schema accepted the retired transport spelling {value!r}"
    )


def test_every_declared_transport_is_in_the_enum(specs):
    """Catalogue side, so a failure names the spec rather than the value."""
    allowed = set(
        _schema()["properties"]["device"]["properties"]["transport"]["enum"]
    )
    wrong = {
        device_id: spec["device"]["transport"]
        for device_id, spec in specs.items()
        if spec["device"].get("transport")
        and spec["device"]["transport"] not in allowed
    }
    assert not wrong, f"transports outside the enum: {wrong}"


# --------------------------------------------------------------------------
# Unit spelling.
#
# `unit` is prose to a validator and data to a consumer: `unit_values` maps a
# device's own unit setting onto these same strings, so two spellings of one
# quantity is a comparison that silently fails. The schema prescribes the bare
# symbol; these tests are what makes that prescription hold.
# --------------------------------------------------------------------------

RETIRED_UNITS = {
    "°C": "C",
    "°F": "F",
    "percent": "%",
    "%RH": "%",
    "minutes": "min",
    "seconds": "s",
    "° before TDC": "°",
    "° BTDC": "°",
}


def every_unit(spec):
    """Yield (path, value) for every `unit:` anywhere in a spec."""

    def walk(node, path):
        if isinstance(node, dict):
            for key, value in node.items():
                if key == "unit" and isinstance(value, str):
                    yield f"{path}.unit", value
                yield from walk(value, f"{path}.{key}")
        elif isinstance(node, list):
            for i, value in enumerate(node):
                yield from walk(value, f"{path}[{i}]")

    yield from walk(spec, "")


def test_units_use_the_canonical_spelling(specs):
    """One quantity, one spelling — including inside protocol_details."""
    wrong = [
        f"{device_id}{path} = {value!r} (use {RETIRED_UNITS[value]!r})"
        for device_id, spec in specs.items()
        for path, value in every_unit(spec)
        if value in RETIRED_UNITS
    ]
    assert not wrong, "retired unit spellings:\n  " + "\n  ".join(wrong)


def test_no_unit_is_empty(specs):
    """A dimensionless value omits the key; `unit: ""` reads as an oversight."""
    empty = [
        f"{device_id}{path}"
        for device_id, spec in specs.items()
        for path, value in every_unit(spec)
        if not value.strip()
    ]
    assert not empty, f"empty unit values (omit the key instead): {empty}"


def test_no_unit_names_two_quantities(specs):
    """`unit: "V, %"` cannot be read by anything; the prose has to carry it."""
    compound = [
        f"{device_id}{path} = {value!r}"
        for device_id, spec in specs.items()
        for path, value in every_unit(spec)
        if "," in value
    ]
    assert not compound, f"compound units (describe the pair in prose): {compound}"


@pytest.mark.parametrize("retired", ["sources", "source"])
def test_the_retired_provenance_spellings_are_rejected(closed_world_spec, retired):
    """Three keys meant provenance; only `evidence` does now."""
    validator = Draft202012Validator(_schema())
    spec = copy.deepcopy(closed_world_spec)
    spec[retired] = [{"type": "static_analysis"}]
    assert list(validator.iter_errors(spec)), (
        f"schema accepted the retired provenance key {retired!r}"
    )


def test_an_artifact_says_what_kind_of_artifact_it_is(closed_world_spec):
    """A digest with no `type` cannot be weighed against anything."""
    validator = Draft202012Validator(_schema())
    spec = copy.deepcopy(closed_world_spec)
    spec["evidence"] = {"artifacts": [{"sha256": "0" * 64}]}
    assert list(validator.iter_errors(spec)), (
        "schema accepted an evidence artifact with no type"
    )


def test_provenance_is_spelled_evidence_everywhere(specs):
    """Catalogue side, naming the spec rather than the key."""
    stray = {
        device_id: sorted({"sources", "source"} & set(spec))
        for device_id, spec in specs.items()
        if {"sources", "source"} & set(spec)
    }
    assert not stray, f"provenance outside `evidence`: {stray}"


# --------------------------------------------------------------------------
# Model vocabulary.
#
# Six keys once listed the products a spec covers. Two remain, and they answer
# a question with an answer: one product (`device.model`) or several
# (`device.variants`).
# --------------------------------------------------------------------------

RETIRED_MODEL_KEYS = [
    ("variants", [{"model": "X"}]),
    ("model_variants", [{"model": "X"}]),
    ("hardware_variants", [{"name": "X"}]),
    ("firmware_variants", {"variants": []}),
    ("device_families", [{"model": "X"}]),
]


@pytest.mark.parametrize("key,value", RETIRED_MODEL_KEYS)
def test_retired_top_level_model_keys_are_rejected(closed_world_spec, key, value):
    validator = Draft202012Validator(_schema())
    spec = copy.deepcopy(closed_world_spec)
    spec[key] = value
    assert list(validator.iter_errors(spec)), (
        f"schema accepted the retired top-level key {key!r}"
    )


def test_device_models_is_rejected(closed_world_spec):
    """A bare name list says less than `variants` and matches nothing."""
    validator = Draft202012Validator(_schema())
    spec = copy.deepcopy(closed_world_spec)
    spec["device"]["models"] = ["A", "B"]
    assert list(validator.iter_errors(spec)), "schema accepted device.models"


def test_a_spec_does_not_claim_both_a_model_and_variants(specs):
    """`model` means one product. With `variants` present it is a duplicate.

    Both divoom and gerbing had a `model` that simply repeated one of their
    own variants, which reads as a claim that that one is primary.
    """
    both = [
        device_id
        for device_id, spec in specs.items()
        if spec["device"].get("model") and spec["device"].get("variants")
    ]
    assert not both, f"specs carrying both device.model and device.variants: {both}"


def test_every_variant_names_a_model(specs):
    """`entities[].variants` refers to these strings, so they must exist."""
    bad = [
        f"{device_id}[{i}]"
        for device_id, spec in specs.items()
        for i, variant in enumerate(spec["device"].get("variants") or [])
        if not str(variant.get("model", "")).strip()
    ]
    assert not bad, f"variants with no model: {bad}"


def test_reference_specs_state_coverage_rather_than_a_model(specs):
    """A standard is not a product; what a reader needs is which part it covers."""
    wrong = [
        device_id
        for device_id, spec in specs.items()
        if is_reference(spec)
        and (spec["device"].get("model") or spec["device"].get("variants"))
    ]
    assert not wrong, f"reference specs claiming a model/variants: {wrong}"


# --------------------------------------------------------------------------
# DNS-SD service types.
#
# The schema pins the form on the two keys it can reach. This sweeps every
# service type anywhere in a spec -- including inside `evidence` and
# `protocol_details`, which are open objects -- because the bare forms that
# started the drift were all in transcriptions of a live probe, and a reader
# comparing a probe record against a discovery axis has to see the same string.
# --------------------------------------------------------------------------

SERVICE_TYPE_KEYS = {"mdns_service_type", "service_type"}
DNS_SD_TYPE = re.compile(r"^_[A-Za-z0-9_-]+\._(tcp|udp)\.local\.$")
# wemo and viera write UPnP service URNs into a key of the same name.
UPNP_URN = re.compile(r"^urn:")


def every_service_type(spec):
    def walk(node, path):
        if isinstance(node, dict):
            for key, value in node.items():
                if key in SERVICE_TYPE_KEYS:
                    for item in value if isinstance(value, list) else [value]:
                        if isinstance(item, str):
                            yield f"{path}.{key}", item
                yield from walk(value, f"{path}.{key}")
        elif isinstance(node, list):
            for i, value in enumerate(node):
                yield from walk(value, f"{path}[{i}]")

    yield from walk(spec, "")


def test_dns_sd_service_types_are_fully_qualified(specs):
    """`_hap._tcp` and `_hap._tcp.local.` are one service and two strings.

    String equality against the wrong one never fires, and a discovery axis
    that never fires is indistinguishable from a device that is not there.
    """
    wrong = [
        f"{device_id}{path} = {value!r}"
        for device_id, spec in specs.items()
        for path, value in every_service_type(spec)
        if value.startswith("_") and not DNS_SD_TYPE.match(value)
    ]
    assert not wrong, (
        "DNS-SD service types must end `._tcp.local.` / `._udp.local.`:\n  "
        + "\n  ".join(wrong)
    )


def test_a_discovery_axis_matches_the_identification_it_claims(specs):
    """A spec's mdns identification must be one of its own discovery types.

    Two places state the same fact and only one of them is what a matcher
    reads first; letting them disagree is how a spec stops meaning what it
    says without anything going red.
    """
    mismatched = {}
    for device_id, spec in specs.items():
        declared = spec["device"].get("identification", {}).get("mdns_service_type")
        if not declared:
            continue
        methods = spec["device"].get("discovery", {}).get("methods") or []
        offered = {
            m["mdns"]["service_type"]
            for m in methods
            if m.get("type") == "mdns" and "service_type" in (m.get("mdns") or {})
        }
        if offered and declared not in offered:
            mismatched[device_id] = (declared, sorted(offered))
    assert not mismatched, (
        f"identification.mdns_service_type not among the discovery methods: {mismatched}"
    )


def test_a_bare_service_type_is_rejected_by_the_schema(closed_world_spec):
    """The pattern, not just the sweep: it must hold for specs not written yet."""
    validator = Draft202012Validator(_schema())
    spec = copy.deepcopy(closed_world_spec)
    spec["device"]["identification"]["mdns_service_type"] = "_hue._tcp"
    assert list(validator.iter_errors(spec)), (
        "schema accepted a bare DNS-SD service type"
    )


def test_every_device_states_whether_it_was_tested(specs):
    """Absent reads as 'nobody looked', which is not what these two meant.

    smartdawn documented a live 2026-08-08 session against curtain hardware
    in its own prose and still indexed as untested; airthings documented two
    HCI captures and did the same. The block is the only place a consumer
    reads the verdict, so silence there erases the work.
    """
    missing = [
        device_id
        for device_id, spec in specs.items()
        if "testing" not in spec["device"] and not is_reference(spec)
    ]
    assert not missing, f"specs with no device.testing block: {missing}"


def test_reference_specs_do_not_claim_hardware_testing(specs):
    """There is no hardware to drive; the block would be meaningless."""
    claiming = [
        device_id
        for device_id, spec in specs.items()
        if is_reference(spec) and "testing" in spec["device"]
    ]
    assert not claiming, f"reference specs carrying device.testing: {claiming}"


def test_a_testing_claim_names_its_evidence(specs):
    """A status with no notes is a label a reviewer cannot check."""
    bare = [
        device_id
        for device_id, spec in specs.items()
        if (spec["device"].get("testing") or {}).get("status") == "verified"
        and not (spec["device"]["testing"].get("notes") or "").strip()
    ]
    assert not bare, f"verified without notes saying what was driven: {bare}"


def test_an_endpoint_hedged_in_prose_is_hedged_in_its_status(specs):
    """Prose saying "placeholder" is invisible to the client that would call it.

    An endpoint with no `status` is, by the schema's own rule, active and
    usable. Six specs described a `GET /` as a placeholder for a surface that
    is not HTTP at all and left the field off, which said the exact opposite of
    what the description said. An explicit status is required either way --
    `placeholder` when nothing there is a control, `unverified` when the
    endpoint may well exist and it is the method or payload that is a guess
    (frigidaire's case, and a different meaning of the same word).
    """
    unmarked = [
        f"{device_id} {endpoint.get('method')} {endpoint.get('path')}"
        for device_id, spec in specs.items()
        for endpoint in spec.get("http_endpoints") or []
        if "placeholder" in (endpoint.get("description") or "").lower()
        and not endpoint.get("status")
    ]
    assert not unmarked, (
        f"endpoints hedged in prose but not in `status`: {unmarked}"
    )


# --------------------------------------------------------------------------
# Discovery: absent, stated-absent, or answered.
# --------------------------------------------------------------------------


def test_a_discovery_block_answers_its_own_question(closed_world_spec):
    """`identity` and `static_ip_required` without `methods` says nothing.

    Two specs carried exactly that -- a discovery block describing how to
    IDENTIFY a device it never said how to FIND.
    """
    validator = Draft202012Validator(_schema())
    spec = copy.deepcopy(closed_world_spec)
    spec["device"]["discovery"] = {"static_ip_required": False}
    assert list(validator.iter_errors(spec)), (
        "schema accepted a discovery block with neither methods nor none"
    )


def test_discovery_cannot_be_both_absent_and_present(closed_world_spec):
    """`none` is the escape, not an annotation to hang beside real methods."""
    validator = Draft202012Validator(_schema())
    spec = copy.deepcopy(closed_world_spec)
    spec["device"]["discovery"]["none"] = "x" * 40
    assert list(validator.iter_errors(spec)), (
        "schema accepted discovery with both methods and none"
    )


def test_stated_absence_gives_a_reason(closed_world_spec):
    """Bare 'none' repeats what an omitted block already said."""
    validator = Draft202012Validator(_schema())
    spec = copy.deepcopy(closed_world_spec)
    spec["device"]["discovery"] = {"none": "no"}
    assert list(validator.iter_errors(spec)), (
        "schema accepted discovery.none with no real reason"
    )


@pytest.mark.parametrize("retired", ["protocol", "identification"])
def test_the_retired_top_level_lock_shapes_are_rejected(closed_world_spec, retired):
    """A top-level `protocol:` collided with `device.protocol`, an enum.

    `identification:` was worse: it looked like the matcher block and was not
    one, so kwikset and nuki carried their whole matching story in a key no
    consumer reads and had no `device.identification` at all.
    """
    validator = Draft202012Validator(_schema())
    spec = copy.deepcopy(closed_world_spec)
    spec[retired] = {"framing": "x"}
    assert list(validator.iter_errors(spec)), (
        f"schema accepted the retired top-level `{retired}:` block"
    )


def test_every_ble_spec_can_be_matched_by_something(specs):
    """A BLE spec with no matcher in `device.identification` is undiscoverable.

    Not a style rule: `device.identification` is the block a scanner reads, and
    a BLE spec that leaves it empty describes a device the app can never bind a
    scan result to, however complete the rest of the file is.
    """
    axes = ("local_name_prefix", "local_name_prefixes", "local_names",
            "service_uuids", "manufacturer_data", "mac_prefixes")
    unmatched = [
        device_id
        for device_id, spec in specs.items()
        if spec["device"].get("protocol") == "ble"
        # A reference spec documents a published profile other specs cite --
        # FTMS is service 0x1826, not a product -- so there is no scan result
        # to bind it to, the same reason references carry no `testing` block.
        # Worse than pointless: giving it the profile's own service UUID as an
        # axis would enter it in the matcher against every real FTMS treadmill.
        and not is_reference(spec)
        and not any(
            (spec["device"].get("identification") or {}).get(axis) for axis in axes
        )
        # A spec may argue that no signal distinguishes this device from
        # anything else -- fardriver does, and does it well. That argument
        # belongs in `discovery.none`, where a checker can see it, not in a
        # comment.
        and not (spec["device"].get("discovery") or {}).get("none")
    ]
    assert not unmatched, (
        "BLE specs with neither an identification axis nor a stated reason "
        f"there is none: {unmatched}"
    )


def test_gaps_md_states_the_real_spec_count(specs):
    """A hand-written count drifts, silently, and then it is just wrong.

    GAPS.md claimed 92/92 while the catalogue was validating 137. The number is
    the one thing in that file a machine can check, so it should be checked.
    """
    devices = len(SPEC_PATHS)
    examples = len(
        list((REPO_ROOT / "device-specs" / "examples").glob("*.yaml"))
    )
    total = devices + examples
    text = (REPO_ROOT / "GAPS.md").read_text(encoding="utf-8")
    expected = (
        f"## Validation: {total}/{total} passing "
        f"({devices} device specs + {examples} example)"
    )
    assert expected in text, (
        f"GAPS.md validation line is stale; it should read:\n  {expected}"
    )


# ── MQTT commands are renderable on their own ───────────────────────────────
# A consumer publishes to `path` with `body` or `arguments` as the payload and
# nothing else. Everything the topic and payload need must therefore be
# declared ON the command: prose one level up does not reach the renderer, and
# the failures it causes are silent — a publish to a topic still containing a
# literal `{client_id}` succeeds at the socket and does nothing at the device.


def _mqtt_commands(specs: dict[str, dict]):
    """Every `transport: mqtt` command in the catalogue, as (spec, name, cmd)."""
    for name, spec in specs.items():
        for command_name, command in (spec.get("commands") or {}).items():
            if command.get("transport") == "mqtt":
                yield name, command_name, command


def test_an_mqtt_command_names_the_topic_it_publishes_to(specs):
    for spec_name, command_name, command in _mqtt_commands(specs):
        assert command.get("path"), (
            f"{spec_name}: mqtt command {command_name!r} declares no `path` — "
            "the topic IS the address, and without one there is nothing to send"
        )


def test_every_mqtt_topic_placeholder_is_a_declared_parameter(specs):
    for spec_name, command_name, command in _mqtt_commands(specs):
        declared = set((command.get("parameters") or {}).keys())
        for placeholder in re.findall(r"\{([^{}]+)\}", command.get("path", "")):
            assert placeholder in declared, (
                f"{spec_name}: mqtt command {command_name!r} addresses "
                f"{{{placeholder}}} but does not declare it as a parameter, so "
                "a renderer has no value to fill it with and would publish the "
                "brace literally"
            )


def test_an_mqtt_command_declares_at_most_one_payload(specs):
    # `body` is a literal payload template, `arguments` builds a JSON object.
    # Both is two answers to one question; a renderer cannot merge them.
    for spec_name, command_name, command in _mqtt_commands(specs):
        assert not (command.get("body") and command.get("arguments")), (
            f"{spec_name}: mqtt command {command_name!r} declares both `body` "
            "and `arguments`; an MQTT message has one payload"
        )


# A renderer fills `{name}` where name is parameter-shaped and leaves every
# other brace alone — that is what lets a JSON payload be written as a `body`
# template. The guard below looks for the same shape, anywhere in the template
# rather than only as the whole of it: `body: "KEY_{foo}"` with no `foo`
# parameter would publish the brace literally, and a device ignores a key it
# has never heard of without saying so.
_PLACEHOLDER = re.compile(r"\{([A-Za-z0-9_]+)\}")


def test_every_mqtt_payload_placeholder_is_a_declared_parameter(specs):
    for spec_name, command_name, command in _mqtt_commands(specs):
        declared = set((command.get("parameters") or {}).keys())
        templates = [command.get("body") or ""]
        templates += [
            value
            for value in (command.get("arguments") or {}).values()
            if isinstance(value, str)
        ]
        for template in templates:
            for name in _PLACEHOLDER.findall(template):
                assert name in declared, (
                    f"{spec_name}: mqtt command {command_name!r} sends "
                    f"{{{name}}} but does not declare it as a parameter"
                )


def test_an_mqtt_examples_body_agrees_with_what_the_command_renders(specs):
    """`example_body` is what a consumer diffs against when a device says no.

    Checked only where the payload is fully determined — a command with no
    parameters to fill. Where placeholders exist the example is a worked case
    by design and cannot equal the template.
    """
    for spec_name, command_name, command in _mqtt_commands(specs):
        example = command.get("example_body")
        body = command.get("body")
        if example is None or body is None:
            continue
        if "{" in body:
            continue
        assert str(example) == str(body), (
            f"{spec_name}: mqtt command {command_name!r} would send {body!r} "
            f"but its example says {example!r}"
        )


# ── State reads and literal bodies resolve to something a consumer can send ──
# `state_command` is a NAME and the schema now says so; these are the two
# catalogue-wide checks that keep it one. sony-bravia and divoom-pixoo used to
# name JSON-RPC methods and vendor wire tokens here, which parsed, validated,
# and produced a state poll nothing could issue -- a card with buttons that
# work and a value that never arrives.


def _declared_request_names(spec: dict) -> set[str]:
    """Everything a `state_command` may resolve to.

    Top-level `commands` keys and `http_endpoints[].name` on the network
    side; a characteristic's `commands` keys on the BLE side, which is where
    a GATT command lives (tuya-bt-soil-tester's `dp_query`).
    """
    names = set(spec.get("commands") or {})
    names |= {e.get("name") for e in spec.get("http_endpoints") or []}
    for service in spec.get("services") or []:
        for characteristic in service.get("characteristics") or []:
            names |= set(characteristic.get("commands") or {})
    names.discard(None)
    return names


def test_every_state_command_resolves_to_a_declared_request(specs):
    """A `state_command` names a `commands` key, an `http_endpoints` name,
    or a characteristic command -- never a bare wire token."""
    unresolved = []
    for device_id, spec in specs.items():
        declared = _declared_request_names(spec)
        for entity in spec.get("entities") or []:
            name = entity.get("state_command")
            if name is None:
                continue
            if name not in declared:
                unresolved.append((device_id, entity.get("name"), name))
    assert not unresolved, (
        "state_command values that resolve to no `commands` key, "
        "`http_endpoints[].name` or characteristic command -- declare the "
        f"request (method, path, body) and point at its name: {unresolved}"
    )


def _literal_body_commands(specs: dict[str, dict]):
    """(spec, name, command) for every http/websocket command whose `body`
    carries no `{name}` placeholder and which publishes an `example_body`."""
    for spec_name, spec in specs.items():
        device_transport = spec["device"].get("transport")
        for command_name, command in (spec.get("commands") or {}).items():
            if not isinstance(command, dict):
                continue
            transport = command.get("transport") or device_transport
            if transport not in {"http", "https", "websocket"}:
                continue
            body = command.get("body")
            example = command.get("example_body")
            if body is None or example is None or _PLACEHOLDER.search(body):
                continue
            yield spec_name, command_name, body, example


def test_a_literal_body_renders_to_its_own_example(specs):
    """Where `body` has no blanks, it IS what goes out, so `example_body`
    must be the same document -- parsed as JSON where both parse, byte for
    byte otherwise. vizio-smartcast's KEYLIST commands are why this exists:
    flat `arguments` rendered to one shape while the example showed the
    nested one the TV wants, and only the TV noticed.
    """
    seen = 0
    for spec_name, command_name, body, example in _literal_body_commands(specs):
        seen += 1
        try:
            same = json.loads(body) == json.loads(str(example))
        except ValueError:
            same = str(body) == str(example)
        assert same, (
            f"{spec_name}: command {command_name!r} would send {body!r} but "
            f"its example_body says {example!r}"
        )
    assert seen, "no http/websocket command carries a literal body with an example"


def test_network_and_ble_auto_vocabularies_are_one():
    """The network parameter block copies the BLE `auto` enum rather than
    $ref-ing it; this is what keeps the copy honest. magic-home's
    `sum_checksum` validated for as long as the network side had no enum."""
    schema = _schema()
    ble = schema["properties"]["services"]["items"]["properties"][
        "characteristics"
    ]["items"]["properties"]["commands"]["additionalProperties"]["properties"][
        "parameters"
    ]["additionalProperties"]["properties"]["auto"]["enum"]
    network = schema["properties"]["commands"]["additionalProperties"][
        "properties"
    ]["parameters"]["additionalProperties"]["properties"]["auto"]["enum"]
    assert ble == network, "the two `auto` enums have drifted apart"


# ── The WebSocket access surface ────────────────────────────────────────────
# A consumer opens `websocket.connect`, is authorised by `websocket.pairing`,
# and turns each command into a frame with the channel the command names. Every
# cross-reference between those three has to hold, because a renderer resolving
# a name that is not there has nothing to fall back on.


def _websocket_specs(specs: dict[str, dict]):
    for name, spec in specs.items():
        if "websocket" in spec:
            yield name, spec, spec["websocket"]


def test_exactly_one_websocket_channel_is_the_default(specs):
    for spec_name, _, ws in _websocket_specs(specs):
        defaults = [c for c in ws["channels"] if c.get("default")]
        assert len(defaults) == 1, (
            f"{spec_name}: {len(defaults)} channels claim `default` — a command "
            "that names none has to have exactly one place to go"
        )


def test_every_command_channel_names_a_declared_channel(specs):
    for spec_name, spec, ws in _websocket_specs(specs):
        declared = {c["name"] for c in ws["channels"]}
        for command_name, command in (spec.get("commands") or {}).items():
            channel = command.get("channel")
            if channel is None:
                continue
            assert channel in declared, (
                f"{spec_name}: command {command_name!r} rides channel "
                f"{channel!r}, which `websocket.channels` does not declare "
                f"(has {sorted(declared)})"
            )


def test_a_runtime_channel_names_the_command_that_finds_it(specs):
    # A second socket the device hands out at runtime is only reachable if the
    # request that returns its address is itself a declared command.
    for spec_name, spec, ws in _websocket_specs(specs):
        commands = spec.get("commands") or {}
        for channel in ws["channels"]:
            obtained_by = channel.get("obtained_by")
            if obtained_by is None:
                continue
            assert obtained_by in commands, (
                f"{spec_name}: channel {channel['name']!r} is obtained by "
                f"{obtained_by!r}, which is not a declared command"
            )
            assert channel.get("address_path"), (
                f"{spec_name}: channel {channel['name']!r} says which command "
                "returns its address but not where in the reply to look"
            )


def _is_send_channel(channel):
    """Whether a client writes frames on this channel.

    `direction: receive` is a socket the DEVICE pushes on — the SoundTouch
    emits `<updates>` wrappers on one whose control surface is the port-8090
    HTTP API. A client subscribes and sends nothing, so the rules below about
    what a frame is built from have nothing to apply to.
    """
    return channel.get("direction", "send") == "send"


def test_a_channel_carries_the_frame_its_encoding_needs(specs):
    for spec_name, _, ws in _websocket_specs(specs):
        for channel in ws["channels"]:
            if not _is_send_channel(channel):
                assert not (channel.get("frame") or channel.get("frame_template")), (
                    f"{spec_name}: receive channel {channel['name']!r} declares a "
                    "frame, which nothing will ever send"
                )
                continue
            if channel["encoding"] == "json":
                assert channel.get("frame"), (
                    f"{spec_name}: json channel {channel['name']!r} declares no "
                    "`frame`, so there is nothing to build"
                )
            else:
                assert channel.get("frame_template"), (
                    f"{spec_name}: text channel {channel['name']!r} declares no "
                    "`frame_template`, so there is nothing to fill"
                )


def test_websocket_pairing_says_what_it_issues_and_where(specs):
    # A pairing flow that does not name its credential cannot be stored, and
    # one that does not say where the device puts it cannot be read back.
    for spec_name, _, ws in _websocket_specs(specs):
        pairing = ws.get("pairing")
        if pairing is None:
            continue
        assert pairing.get("credential_name"), (
            f"{spec_name}: websocket.pairing issues something but does not name "
            "it, so a client has no key to store it under"
        )
        assert pairing.get("issued_at"), (
            f"{spec_name}: websocket.pairing does not say where in the device's "
            "reply the issued secret appears"
        )
        if pairing["mode"] == "register_frame":
            assert pairing.get("register_frame"), (
                f"{spec_name}: pairing mode is register_frame but no frame is "
                "declared to send"
            )


def test_a_websocket_spec_declares_the_transport_its_commands_ride(specs):
    # The block describes a surface; `device.transport` is what makes the
    # commands route to it. A spec with one and not the other is half-migrated.
    #
    # Unless nothing rides it. A spec whose channels are ALL `receive` has
    # declared a socket the device pushes on, not one its commands travel over:
    # the SoundTouch emits state on 8080 and takes commands on the 8090 HTTP
    # API, and `device.transport: http` is the true answer for it. Requiring
    # `websocket` there would make the spec lie about where its commands go.
    for spec_name, spec, ws in _websocket_specs(specs):
        if not any(_is_send_channel(c) for c in ws["channels"]):
            continue
        transport = spec["device"].get("transport")
        assert transport == "websocket", (
            f"{spec_name}: declares a sendable `websocket` channel but "
            f"device.transport is {transport!r}"
        )


def _credential_consumers(spec):
    """name -> [(command, parameter, description)] for every `credential:` source."""
    found = {}
    for command_name, command in (spec.get("commands") or {}).items():
        if not isinstance(command, dict):
            continue
        for param_name, param in (command.get("parameters") or {}).items():
            if not isinstance(param, dict):
                continue
            source = param.get("source") or ""
            if not source.startswith("credential:"):
                continue
            name = source[len("credential:"):]
            found.setdefault(name, []).append(
                (command_name, param_name, param.get("description"))
            )
    return found


def _issued_credential_names(spec):
    """Every name a setup method, or one of its stages, declares it issues."""
    methods = ((spec.get("device") or {}).get("setup") or {}).get("methods") or []
    phases = []
    for method in methods:
        if isinstance(method, dict):
            phases.append(method)
            phases.extend(s for s in method.get("stages") or [] if isinstance(s, dict))
    return {name for phase in phases for name in (phase.get("issues_credentials") or {})}


def test_every_credential_can_be_obtained_or_asked_for(specs):
    """A `credential:` parameter says where its value comes from, one way or
    the other.

    Two routes, and a spec must offer one of them. Either a setup method
    declares it in `issues_credentials`, so a consumer can run the flow and
    read the value out of the reply — or the parameter carries a `description`
    saying where a person finds it, so a consumer can ask.

    Neither is a control surface that silently cannot be driven. The commands
    resolve, the buttons draw, and every press fails on a value the client has
    no way to obtain and no words to request. A generic consumer builds its
    prompt out of this description — that is what makes it generic, and what
    makes an absent one a prompt with a blank in it.

    Hisense was the case that prompted this: `mqtt_client_id` is the source of
    all thirty-nine of its commands, and what the id IS lived in
    protocol_details, three hundred lines from the parameter that needs it.
    """
    for device_id, spec in specs.items():
        issued = _issued_credential_names(spec)
        for name, consumers in _credential_consumers(spec).items():
            if name in issued:
                continue
            described = any(
                (description or "").strip() for _, _, description in consumers
            )
            assert described, (
                f"{device_id}: {len(consumers)} command(s) source "
                f"{name!r} from a stored credential, but no setup method "
                f"issues it and no parameter describes it. A client can "
                f"neither obtain it nor ask for it. Add a `description` to "
                f"the parameter saying where a person finds the value, or "
                f"declare the issuing method in `issues_credentials`."
            )


def test_issued_credentials_are_named_the_way_their_consumers_spell_them(specs):
    """`issues_credentials` keys and `credential:<name>` sources are one
    vocabulary.

    The schema says the coupling IS the key spelling — that is what lets a
    consumer store a pairing's output and fill a later request without a
    per-device table. A pairing that issues `user` for commands that source
    `username` stores the value under a name nothing looks up, and every send
    fails as though the pairing had never happened.

    An issued name with no consumer is fine and deliberate: Hue's `clientkey`
    is obtainable only at creation time and is stored because it can never be
    had again, even though no command in the catalogue uses it yet.
    """
    for device_id, spec in specs.items():
        consumed = set(_credential_consumers(spec))
        issued = _issued_credential_names(spec)
        if not consumed or not issued:
            continue
        # A spec whose consumers are ENTIRELY unissued names is not a
        # spelling error -- it is a device whose credentials come from
        # outside any flow it documents (a serial off a touchscreen). The
        # mismatch worth catching is a pairing that issues something close
        # to, but not the same as, what the commands ask for.
        if consumed & issued:
            continue
        raise AssertionError(
            f"{device_id}: setup issues {sorted(issued)} and commands source "
            f"{sorted(consumed)} — no name is shared, so nothing a pairing "
            "yields can fill a request. The key spelling is the coupling."
        )


# ---------------------------------------------------------------------------
# Clean-room: private LAN addresses are placeholders or product facts
# ---------------------------------------------------------------------------
#
# docs/CLEANROOM_RULES.md: an address the researcher's DHCP server happened to
# assign identifies the researcher's network, teaches nobody anything, and
# keeps arriving inside otherwise-good verification evidence. The convention
# is 192.168.1.50 (.51-.53 when one note needs several distinct hosts).
# Addresses fixed by the PRODUCT — a SoftAP gateway, a captive-portal
# endpoint, a camera's hardcoded address — are protocol facts and stay.
#
# The scrub happened once already and regressed; this is the gate that stops
# it regressing again. Every RFC1918 address under device-specs/, docs/ AND
# research-notes/ must be a placeholder, a known product-fixed address, or
# declared by the same YAML file in a fixed-address field (gateway_ip /
# ap_ip / setup_endpoint). research-notes/ is held to a STRICTER rule than
# the other two: the common home-gateway lookalikes are not vouched for by
# the table there (see RESEARCHER_GATEWAY_LOOKALIKES), because that tree is
# where a live session's paste lands first.

PLACEHOLDER_LAN_ADDRESSES = frozenset(
    {"192.168.1.50", "192.168.1.51", "192.168.1.52", "192.168.1.53"}
)

# Addresses that are the device's, not the researcher's — each BOUND to the
# file(s) that ESTABLISH it. Binding is the whole point: a factory-default
# address teaches nothing outside the product that fixes it, so vouching for it
# everywhere (the union this used to be) let a researcher's own 192.168.1.188
# pass in any file merely because some unrelated product ships that default.
#
# An owner token is either a spec/note *stem* — which matches
# device-specs/devices/<stem>.yaml AND any same-stem doc or note beside it, e.g.
# docs/devices/<stem>.md — or an explicit repo-relative path, used for a doc
# whose stem does not match its device's (docs/devices/frigidaire-ac.md documents
# frigidaire-window-ac) and for a shared doc no single spec owns
# (docs/CLEANROOM_RULES.md, docs/AUTODETECTION.md). A table address is vouched
# for ONLY in its owning files; the same address in any other file is a leak
# until it earns its own owner here or is declared in a gateway_ip / ap_ip /
# setup_endpoint field of the file itself. A device that declares its address in
# such a field needs no entry here at all — several below carry a stem only so
# the device's cross-stem docs are covered too.
PRODUCT_FIXED_LAN_ADDRESSES = {
    # Frigidaire v2.0 cleartext exception target (garadget's Particle/Photon
    # SoftAP shares the address but is vouched for by garadget.yaml's ap_ip).
    "192.168.0.1": frozenset({
        "frigidaire-portable-ac", "frigidaire-window-ac",
        "docs/devices/frigidaire-local-api-audit.md", "docs/devices/frigidaire-ac.md",
    }),
    # AR.Drone 1.0/2.0 AP; Govee SoftAP provisioning socket.
    "192.168.1.1": frozenset({
        "parrot-arsdk-drone", "govee-rgb-light", "govee-rgbic-light",
        "govee-home-apk-v7.5.30",
    }),
    # VEVOR VT256 thermal imager's fixed AP address.
    "192.168.1.10": frozenset({"vevor-vt256-thermal-imager"}),
    # Dericam/Wanscam-family static factory-default IP.
    "192.168.1.188": frozenset({"dericam"}),
    # Novatek dashcam AP default (INNOVV K-series web UI).
    "192.168.1.254": frozenset({"innovv-k7-capture-plan"}),
    # ESP-style SoftAP default (SP108E, LED Space, BanlanX, ESPHome fallback…).
    "192.168.4.1": frozenset({
        "banlanx-sp6xxe", "govee-rgbic-light", "led-shop-sp108e", "led-space",
        "autobaba-led-backpack", "flowtoys-props", "esphome-device",
        "govee-home-apk-v7.5.30", "docs/AUTODETECTION.md",
    }),
    # Frigidaire/Electrolux NIU setup endpoint.
    "192.168.6.1": frozenset({
        "frigidaire-portable-ac", "frigidaire-window-ac",
        "docs/devices/frigidaire-local-api-audit.md", "docs/devices/frigidaire-ac.md",
    }),
    # Valetudo provisioning AP; June oven's captive-DNS answer.
    "192.168.8.1": frozenset({"valetudo", "docs/devices/june-oven-lan-recon.md"}),
    # Aqara hub setup-AP HTTPS default (from the Aqara Home 4.2.1 app binary; the
    # address is the app's built-in default, the path is a placeholder).
    "192.168.5.1": frozenset({"aqara-hub"}),
    # Rachio Gen 2 / Rabbit Air setup AP gateway; Schlage BR400 bridge softAP.
    "192.168.10.1": frozenset({
        "rachio-controller", "rabbit-air-purifier", "schlage-wifi-local-surface",
    }),
    # Parrot Bebop/Anafi family AP.
    "192.168.42.1": frozenset({"parrot-arsdk-drone"}),
    # Dyson setup-AP MQTT broker (non-EC categories).
    "192.168.60.1": frozenset({"dyson-air-purifier"}),
    # OpenGarage device-AP web UI.
    "192.168.100.1": frozenset({"opengarage"}),
    # iRobot Create 3 over USB-C RNDIS Ethernet.
    "192.168.186.2": frozenset({"irobot-create3"}),
    # HF-LPB100 module SoftAP (Mi-Light bridge and kin).
    "10.10.100.254": frozenset({
        "limitlessled-milight-bridge", "govee-home-apk-v7.5.30",
        "docs/CLEANROOM_RULES.md",
    }),
    # Wemo setup AP.
    "10.22.22.1": frozenset({
        "wemo-devices", "docs/devices/wemo-setup.md", "docs/protocols/device-setup.md",
    }),
    # LIFX SoftAP gateway.
    "172.16.0.1": frozenset({"lifx-z"}),
    # Enphase Envoy AP-mode gateway.
    "172.30.1.1": frozenset({"enphase-envoy"}),
}

# Two of the product-fixed addresses are ALSO the commonest home-router
# gateways. In the curated trees the ambiguity resolves by review; in
# research-notes/ — where a live session's paste lands first — a bare
# 192.168.1.1 is overwhelmingly the researcher's own gateway, so there the
# table above does not vouch for them: scrub the address, or declare it in
# a FIXED_ADDRESS_FIELDS key if the product genuinely fixes it.
RESEARCHER_GATEWAY_LOOKALIKES = frozenset({"192.168.0.1", "192.168.1.1"})

# YAML keys whose value states an address fixed by the product. An address a
# spec declares under one of these is allowed anywhere in the same file, so a
# new SoftAP spec does not need to touch the table above.
FIXED_ADDRESS_FIELDS = frozenset({"gateway_ip", "ap_ip", "setup_endpoint"})

# The three RFC1918 blocks, as they appear embedded in prose, YAML and JSON.
# The lookbehind keeps this from matching inside a longer dotted run or a
# standard's section number (ISO 15765-2 §10.4.2.1 is not an address); the
# lookahead stops a partial match of a longer final octet.
RFC1918_ADDRESS_RE = re.compile(
    r"(?<![\w.§])"
    r"(?:10\.\d{1,3}\.\d{1,3}\.\d{1,3}"
    r"|172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}"
    r"|192\.168\.\d{1,3}\.\d{1,3})"
    r"(?!\d)"
)


def _rfc1918_scan_paths():
    """Every text file the gate reads: specs, the schema, the docs — and the
    research notes, which are where the addresses actually leak. The notes
    tree is where a hardware session's paste lands first (this repo's own
    address scrub happened there), so carving it out guarded every tree
    except the one with the regression history."""
    for tree in (
        REPO_ROOT / "device-specs",
        REPO_ROOT / "docs",
        REPO_ROOT / "research-notes",
    ):
        for path in sorted(tree.rglob("*")):
            if path.suffix not in {".yaml", ".yml", ".md", ".json"}:
                continue
            # Generated on main by CI from specs that already pass this test.
            if path.name == "index.json":
                continue
            yield path


def _declared_fixed_addresses(path: Path, parsed_specs=None) -> frozenset:
    """Addresses this YAML file declares in a fixed-address field."""
    if path.suffix not in {".yaml", ".yml"}:
        return frozenset()
    # The module fixture already parsed every device spec once; re-reading
    # the whole catalogue here doubled the run's YAML cost for the same
    # documents. Only files outside the fixture (research-note YAML and kin)
    # still parse fresh.
    doc = (
        parsed_specs.get(path.stem)
        if parsed_specs is not None and path in SPEC_PATHS
        else None
    )
    if doc is None:
        try:
            doc = yaml.safe_load(path.read_text(encoding="utf-8"))
        except yaml.YAMLError:
            return frozenset()  # validate_specs.py owns reporting parse errors

    found: set[str] = set()

    def walk(node) -> None:
        if isinstance(node, dict):
            for key, value in node.items():
                if key in FIXED_ADDRESS_FIELDS and isinstance(value, str):
                    found.update(RFC1918_ADDRESS_RE.findall(value))
                walk(value)
        elif isinstance(node, list):
            for item in node:
                walk(item)

    walk(doc)
    return frozenset(found)


def _table_owned_addresses(path: Path) -> frozenset:
    """Product-fixed table addresses whose owner set names THIS file.

    An owner token is a *stem* — matched against the file's own stem, so a spec
    and any same-stem doc/note both qualify, which is the `docs/devices/<stem>.md`
    sibling case — or an explicit repo-relative path, for a doc whose stem does
    not match its device's or a shared doc no single spec owns.
    """
    rel = path.relative_to(REPO_ROOT).as_posix()
    stem = path.stem
    return frozenset(
        address
        for address, owners in PRODUCT_FIXED_LAN_ADDRESSES.items()
        if stem in owners or rel in owners
    )


def _allowed_addresses_for(path: Path, parsed_specs=None) -> frozenset:
    """Every RFC1918 address a given file may carry: placeholders, the
    product-fixed addresses THIS file owns, and anything it declares in a
    gateway_ip / ap_ip / setup_endpoint field.

    research-notes/ is held stricter: the common home-gateway lookalikes are
    not vouched for by the table there (a live session's paste lands there
    first), only by a declaration — the file's own, or its .yaml sibling's for
    the .md half of a note pair.
    """
    declared = _declared_fixed_addresses(path, parsed_specs)
    allowed = (
        PLACEHOLDER_LAN_ADDRESSES
        | _table_owned_addresses(path)
        | declared
    )
    rel = path.relative_to(REPO_ROOT)
    if rel.parts[0] == "research-notes":
        # The table stops vouching for the gateway lookalikes here; a
        # declaration in the file itself still does. A note pair shares that
        # declaration — garadget.md's SoftAP address is vouched for by
        # garadget.yaml's ap_ip — so the prose half does not have to strip a
        # genuine product fact.
        allowed -= RESEARCHER_GATEWAY_LOOKALIKES - declared
        sibling = path.with_suffix(".yaml")
        if path.suffix == ".md" and sibling.exists():
            allowed |= _declared_fixed_addresses(sibling, parsed_specs)
    return allowed


def test_lan_addresses_are_placeholders_or_product_facts(specs):
    """No researcher-network address may reach a published file again.

    A product-fixed address is vouched for ONLY in the file(s) that establish
    it — see PRODUCT_FIXED_LAN_ADDRESSES. The same address elsewhere is a leak
    until it earns an owner or is declared in the file's own fixed-address field.
    """
    offenders = []
    for path in _rfc1918_scan_paths():
        allowed = _allowed_addresses_for(path, specs)
        rel = path.relative_to(REPO_ROOT)
        for lineno, line in enumerate(
            path.read_text(encoding="utf-8").splitlines(), start=1
        ):
            for match in RFC1918_ADDRESS_RE.finditer(line):
                address = match.group()
                if address in allowed:
                    continue
                rest = line[match.end():]
                # Subnet notation (192.168.1.0/24) describes a network, not
                # a host on the researcher's — the shape an implementer
                # needs. The `.0` requirement keeps `<real host>/24` from
                # slipping through as if it were a network, and the prefix
                # match reads one- and two-digit lengths whatever follows
                # them (`/8,` used to fail the old two-character check).
                if address.endswith(".0") and re.match(r"/\d{1,2}(?!\d)", rest):
                    continue
                # A `.255` is a broadcast only in its /24-or-wider context;
                # bare, it is as likely a host in a pasted /16. It passes
                # when its own line SAYS so — a CIDR alongside, or the word
                # broadcast — which every genuine use in the tree does.
                if address.endswith(".255") and (
                    "broadcast" in line.lower()
                    or re.search(r"/\d{1,2}(?!\d)", line)
                ):
                    continue
                offenders.append(f"{rel}:{lineno}: {address}")

    assert not offenders, (
        "researcher-network addresses in published files (see "
        "docs/CLEANROOM_RULES.md — scrub your own identifiers):\n  "
        + "\n  ".join(offenders)
        + "\nUse 192.168.1.50 (.51-.53 for distinct hosts). If the address "
        "is fixed by the product, declare it in a gateway_ip / ap_ip / "
        "setup_endpoint field, or add this file's stem (or path) to that "
        "address's owner set in PRODUCT_FIXED_LAN_ADDRESSES — the table "
        "vouches for an address only in the files that establish it."
    )


def test_a_product_fixed_address_is_bound_to_its_owning_file(specs):
    """The table vouches for an address only where the product establishes it.

    This is the whole of S-1: the blanket union this replaced put every table
    address into `allowed` for every file, so a researcher's own address passed
    in ANY file the moment it coincided with some product's factory default.
    Prove both directions on a real address — ACCEPTED in an owning file,
    REFUSED in one that does not establish it.
    """
    # esphome-device establishes the 192.168.4.1 fallback-hotspot address; the
    # Hue bridge is cabled and establishes no SoftAP address at all.
    owner = DEVICES_DIR / "esphome-device.yaml"
    non_owner = DEVICES_DIR / "hue-bridge.yaml"
    assert "192.168.4.1" in _allowed_addresses_for(owner, specs), (
        "the gate must ACCEPT a product-fixed address in its owning file"
    )
    assert "192.168.4.1" not in _allowed_addresses_for(non_owner, specs), (
        "the gate must REFUSE a product-fixed address in a file that does not "
        "establish it — otherwise the table is a repo-wide clean-room bypass"
    )
    # And a research-note-owned address stays bound: Dericam's static default
    # is vouched for in the Dericam note and nowhere else.
    dericam = REPO_ROOT / "research-notes" / "dericam.yaml"
    assert "192.168.1.188" in _allowed_addresses_for(dericam, specs)
    assert "192.168.1.188" not in _allowed_addresses_for(non_owner, specs)


def test_every_product_fixed_owner_names_a_real_file():
    """An owner token that matches no file vouches for nothing.

    A typo in an owner stem or path would silently reinstate exactly the
    repo-wide leak this binding exists to stop: the address would be vouched
    for in no file (so a genuine use fails) while the misspelled token sits
    there looking correct. Every token must resolve to a scanned file — by
    stem or by explicit path.
    """
    scanned = list(_rfc1918_scan_paths())
    stems = {path.stem for path in scanned}
    rels = {path.relative_to(REPO_ROOT).as_posix() for path in scanned}
    dangling = {
        address: sorted(
            owner
            for owner in owners
            if owner not in stems and owner not in rels
        )
        for address, owners in PRODUCT_FIXED_LAN_ADDRESSES.items()
    }
    dangling = {address: owners for address, owners in dangling.items() if owners}
    assert not dangling, (
        f"PRODUCT_FIXED_LAN_ADDRESSES owner tokens matching no scanned file "
        f"(a stem must name a spec/note, a path must exist): {dangling}"
    )


def test_command_auth_names_declared_schemes(specs):
    """`auth` on a command names entries of the root `auth_schemes`; a
    misspelt name is a command no client can authenticate."""
    for device_id, spec in specs.items():
        schemes = spec.get("auth_schemes") or {}
        used = set()
        for name, command in (spec.get("commands") or {}).items():
            for scheme in (command or {}).get("auth") or []:
                assert scheme in schemes, (
                    f"{device_id}: command {name!r} accepts auth scheme "
                    f"{scheme!r}, which auth_schemes does not declare"
                )
                used.add(scheme)
        unused = set(schemes) - used
        assert not unused, f"{device_id}: auth_schemes {sorted(unused)} are used by no command"


def test_auth_scheme_placeholders_resolve(specs):
    """A scheme's `{name}` placeholders are its stored credential or a
    parameter of every command that uses it -- nothing else fills them."""
    placeholder = re.compile(r"\{([A-Za-z_][A-Za-z0-9_]*)\}")
    for device_id, spec in specs.items():
        schemes = spec.get("auth_schemes") or {}
        for scheme_name, scheme in schemes.items():
            values = list((scheme.get("headers") or {}).values())
            values += [scheme.get("username") or "", scheme.get("password") or ""]
            names = {n for v in values for n in placeholder.findall(v)}
            for command_name, command in (spec.get("commands") or {}).items():
                if scheme_name not in ((command or {}).get("auth") or []):
                    continue
                params = set((command.get("parameters") or {}))
                missing = names - params - {scheme.get("credential")}
                assert not missing, (
                    f"{device_id}: auth scheme {scheme_name!r} used by "
                    f"{command_name!r} needs {sorted(missing)}, which is neither "
                    "the scheme's credential nor a parameter of the command"
                )


def test_auth_scheme_credentials_can_be_obtained(specs):
    """A scheme that needs a stored credential is useless unless setup says
    how to get one."""
    for device_id, spec in specs.items():
        issued = _issued_credential_names(spec)
        for scheme_name, scheme in (spec.get("auth_schemes") or {}).items():
            credential = scheme.get("credential")
            if credential:
                assert credential in issued, (
                    f"{device_id}: auth scheme {scheme_name!r} needs credential "
                    f"{credential!r}, which no setup method or stage issues"
                )


def _format_fields(spec):
    for service in spec.get("services") or []:
        for characteristic in (service or {}).get("characteristics") or []:
            for field in (characteristic or {}).get("format") or []:
                yield characteristic, field


def test_format_masks_fit_their_field(specs):
    for device_id, spec in specs.items():
        for characteristic, field in _format_fields(spec):
            mask = field.get("mask")
            if mask is None:
                continue
            assert mask < 1 << (8 * field["length"]), (
                f"{device_id}: {characteristic['uuid']} field {field['name']!r} "
                f"mask {mask:#x} is wider than its {field['length']}-byte field"
            )


def test_unit_scales_are_keyed_by_units_the_field_can_be_in(specs):
    """`unit_scales` is looked up by the unit `unit_values` resolved to; a key
    no unit_values entry produces is a scale nothing ever selects."""
    for device_id, spec in specs.items():
        for characteristic, field in _format_fields(spec):
            scales = field.get("unit_scales")
            if not scales:
                continue
            units = set((field.get("unit_values") or {}).values()) | {field.get("unit")}
            stray = set(scales) - units
            assert not stray, (
                f"{device_id}: {characteristic['uuid']} field {field['name']!r} "
                f"has unit_scales for {sorted(stray)}, which unit_values never yields"
            )


def _all_commands(spec):
    """name -> command, across the top-level block and every characteristic."""
    found = dict(spec.get("commands") or {})
    for service in spec.get("services") or []:
        for characteristic in (service or {}).get("characteristics") or []:
            found.update((characteristic or {}).get("commands") or {})
    return found


def _dfu_blocks(spec):
    for feature in spec.get("features") or []:
        if isinstance(feature, dict) and feature.get("dfu"):
            yield feature["dfu"]


def test_dfu_entry_command_exists_and_is_advanced(specs):
    """The command that reboots a device into its bootloader is one tap from
    leaving it unusable, so it is `advanced` -- and it must be a real
    command, or the declaration points nowhere."""
    for device_id, spec in specs.items():
        commands = _all_commands(spec)
        for dfu in _dfu_blocks(spec):
            enter = dfu.get("enter") or {}
            name = enter.get("command")
            if enter.get("how") == "command":
                assert name, f"{device_id}: dfu.enter.how is command but names none"
            if not name:
                continue
            assert name in commands, (
                f"{device_id}: dfu.enter.command {name!r} is not a declared command"
            )
            assert commands[name].get("advanced") is True, (
                f"{device_id}: {name!r} enters the bootloader but is not `advanced`"
            )


def test_dfu_services_are_declared_services(specs):
    """`dfu.services` points a GATT explorer at services to keep read-only;
    one the spec does not declare cannot be recognised on connect."""
    for device_id, spec in specs.items():
        declared = {
            (service or {}).get("uuid") for service in spec.get("services") or []
        }
        for dfu in _dfu_blocks(spec):
            for uuid in dfu.get("services") or []:
                assert uuid in declared, (
                    f"{device_id}: dfu.services lists {uuid}, which `services` "
                    "does not declare"
                )


def test_dfu_upload_endpoint_exists_and_is_advanced(specs):
    for device_id, spec in specs.items():
        endpoints = {
            (e or {}).get("name"): e for e in spec.get("http_endpoints") or []
        }
        for dfu in _dfu_blocks(spec):
            name = dfu.get("endpoint")
            if not name:
                continue
            assert name in endpoints, (
                f"{device_id}: dfu.endpoint {name!r} is not an http_endpoints name"
            )
            assert endpoints[name].get("advanced") is True, (
                f"{device_id}: http endpoint {name!r} takes a firmware image but "
                "is not `advanced`"
            )


def test_feature_variants_name_declared_models_and_do_not_overlap(specs):
    """`features[].variants` refers to `device.variants[].model`, like an
    entity's. Two entries of one type covering the same model leave a
    consumer to guess which one holds for it."""
    for device_id, spec in specs.items():
        models = {
            (v or {}).get("model") for v in spec["device"].get("variants") or []
        }
        by_type = {}
        for feature in spec.get("features") or []:
            if not isinstance(feature, dict):
                continue
            scoped = feature.get("variants")
            for model in scoped or []:
                assert model in models, (
                    f"{device_id}: feature {feature['type']!r} names variant "
                    f"{model!r}, which device.variants does not declare"
                )
            by_type.setdefault(feature["type"], []).append(
                frozenset(scoped) if scoped else None
            )
        for feature_type, scopes in by_type.items():
            if len(scopes) < 2:
                continue
            assert None not in scopes, (
                f"{device_id}: several {feature_type!r} features and one has no "
                "`variants`, so it overlaps every other"
            )
            seen = set()
            for scope in scopes:
                assert not (seen & scope), (
                    f"{device_id}: variants {sorted(seen & scope)} are covered by "
                    f"more than one {feature_type!r} feature"
                )
                seen |= scope
