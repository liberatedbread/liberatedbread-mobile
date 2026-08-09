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
    "softap_soap",
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

    `applicable: unknown` is the third answer, for a device that probably has a
    reset that nobody has established yet. It is deliberately uncomfortable —
    low confidence, no procedures — because the alternative is a plausible
    guess that reads exactly like a verified one.
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

        if reset.get("applicable") == "unknown":
            assert not reset.get("procedures"), (
                f"{device_id}: factory_reset is marked unknown but still lists "
                "procedures — say which one you established instead"
            )
            assert reset.get("confidence") == "low", (
                f"{device_id}: an unestablished factory reset is low confidence"
            )
            continue

        assert reset.get("confidence") in CONFIDENCE_VALUES, (
            f"{device_id}: factory_reset needs a confidence level"
        )
        procedures = reset.get("procedures", [])
        assert procedures, f"{device_id}: factory_reset needs at least one procedure"
        for procedure in procedures:
            assert procedure.get("name"), f"{device_id}: a reset procedure has no name"
            assert procedure.get("steps"), (
                f"{device_id}: reset procedure {procedure.get('name')!r} has no steps"
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
