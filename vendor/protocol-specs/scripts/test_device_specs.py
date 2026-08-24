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
        step_lists = [m.get("steps", []) for m in setup["methods"]]
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
        total = sum(len(m.get("steps", [])) for m in setup["methods"])
        assert total > 0, (
            f"{device_id}: setup.required is true but no method documents steps"
        )


def test_no_provisioning_methods_are_consistent_with_required(specs):
    """A device whose only method is 'nothing to do' must not claim required."""
    for device_id, setup in setups(specs):
        types = {m["type"] for m in setup["methods"]}
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
        types = {m["type"] for m in setup["methods"]}
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
            types = {m["type"] for m in setup["methods"]}
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
        for method in setup["methods"]:
            if method["type"] != "cloud_account":
                continue
            cloud = method.get("cloud", {})
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


def test_button_presses_name_a_declared_command(specs):
    """And the half a schema cannot check: the bound name resolves.

    `press: press_home` is only a control if `press_home` exists. The schema
    sees a string either way, so the binding is checked here, across every
    spec in the catalogue rather than one device's own test file.
    """
    for device_id, spec in specs.items():
        declared = set(spec.get("commands") or {})
        for characteristic in _characteristics(spec):
            declared |= set(characteristic.get("commands") or {})
        for entity in spec.get("entities") or []:
            if entity.get("platform") != "button":
                continue
            bound = (entity.get("commands") or {}).get("press")
            assert bound in declared, (
                f"{device_id}: button {entity.get('name')!r} presses "
                f"{bound!r}, which no command declares"
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
    """A real spec whose factory_reset is unestablished with a candidate."""
    return load(DEVICES_DIR / "govee-h6001-bulb.yaml")


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
