"""Conventions for `device.pairing` that the schema cannot express.

docs/protocols/pairing.md is the reference. These are its rules applied to
the catalogue. Each one is written as a small predicate so it can be checked
twice: against every spec in tree, and against hand-built specs that it must
accept or reject. Without the second check, a rule whose predicate quietly
stopped matching anything would keep passing while guarding nothing.

The block's basic shape lives in test_device_specs.py: every device carries
one, `required` and `confidence` agree, PIN values are product-wide only,
and unverified procedures cite a basis.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
DEVICES_DIR = REPO_ROOT / "device-specs" / "devices"
DOCS_DIR = REPO_ROOT / "docs" / "devices"
SCHEMA = json.loads((REPO_ROOT / "device-specs" / "schema.json").read_text(encoding="utf-8"))

BLUETOOTH_PROTOCOLS = {"ble", "ble_gatt", "bluetooth_classic"}
# Radios whose "pairing" is admission to a network the controller owns.
MESH_PROTOCOLS = {"zigbee", "zwave", "thread"} & set(
    SCHEMA["properties"]["device"]["properties"]["protocol"]["enum"]
)
# Modes that are properties of a Bluetooth link. A device reached over IP or
# a wired bus has no link layer that could carry them.
LINK_LAYER_MODES = {
    "just_works",
    "passkey_entry",
    "numeric_comparison",
    "out_of_band",
    "legacy_pin",
}


def _load_specs() -> dict[str, dict]:
    return {
        path.stem: yaml.safe_load(path.read_text(encoding="utf-8"))
        for path in sorted(DEVICES_DIR.glob("*.yaml"))
    }


@pytest.fixture(scope="module")
def specs() -> dict[str, dict]:
    loaded = _load_specs()
    assert loaded, "no device specs found"
    return loaded


def pairings(specs: dict[str, dict]):
    for device_id, spec in specs.items():
        pairing = spec["device"].get("pairing")
        if pairing is not None:
            yield device_id, spec, pairing


# ---------------------------------------------------------------------------
# The rules, as predicates returning a problem string or None.
# ---------------------------------------------------------------------------


def missing_standing_answers(pairing: dict) -> str | None:
    """The four-line minimum: security_mode, bonding and enter_pairing_mode.

    docs/protocols/pairing.md's "Say no out loud" block is required plus
    these three. Each answers a question an implementer otherwise has to
    find out on hardware: does the link authenticate, does it remember, and
    must someone press something. `unknown` is an answer; absence is not.
    """
    missing = [key for key in ("security_mode", "bonding") if key not in pairing]
    if "required" not in (pairing.get("enter_pairing_mode") or {}):
        missing.append("enter_pairing_mode.required")
    return f"does not state {', '.join(missing)}" if missing else None


def lacks_prose(pairing: dict) -> str | None:
    """A block beyond "nothing pairs" tells its story in words.

    The bare BLE "connect and go" block is complete as it is. Anything else
    is a story a reader needs in prose: a credential, a button, a key from
    the cloud, or an unknown. It covers where the credential comes from,
    what the user must do, and what the vendor cloud's death does to it.
    The prose may sit on the block itself or on the part it explains.
    """
    if pairing.get("required") is False and pairing.get("security_mode") == "none":
        return None
    if pairing.get("notes"):
        return None
    for key in ("pin", "enter_pairing_mode", "unpair"):
        if (pairing.get(key) or {}).get("notes"):
            return None
    if (pairing.get("exclusivity") or {}).get("recovery"):
        return None
    return "goes beyond 'nothing pairs' but carries no prose explaining it"


def overclaims_confidence(spec: dict, pairing: dict) -> str | None:
    """`confidence: high` means the pairing story was seen on real hardware.

    The schema defines high as "a client connected and controlled the device
    (or was refused until it bonded) against real hardware". A spec whose
    `device.testing` says nobody has touched a unit cannot claim that. The
    one exception is an over-the-air capture of real traffic, which does
    show the pairing happen or not happen. That is `capture-verified`. A
    working open implementation is `medium`, however good it is.
    """
    if pairing.get("confidence") != "high":
        return None
    testing = spec["device"].get("testing") or {}
    if testing.get("status") == "verified" or testing.get("detail") == "capture-verified":
        return None
    return (
        "claims high pairing confidence, but device.testing records no hardware "
        f"run or capture (status {testing.get('status')!r})"
    )


def exclusivity_without_recovery(pairing: dict) -> str | None:
    """A device that admits one client says what to do about the other one.

    `single_connection` and `single_bond` both present as a timeout, and the
    boolean alone tells the user nothing to do. `recovery` is the half a
    consumer puts on screen.
    """
    exclusivity = pairing.get("exclusivity") or {}
    flagged = [k for k in ("single_connection", "single_bond") if exclusivity.get(k) is True]
    if flagged and not exclusivity.get("recovery"):
        return f"sets {' and '.join(flagged)} but gives no recovery"
    return None


def unpair_points_nowhere(spec: dict, pairing: dict) -> str | None:
    """ "Only a factory reset clears it" needs a factory reset to point at.

    `unpair.requires_factory_reset: true` sends the reader to
    `setup.factory_reset`. If that block is missing, or says there is no
    reset, the instruction is a dead end.
    """
    if (pairing.get("unpair") or {}).get("requires_factory_reset") is not True:
        return None
    reset = (spec["device"].get("setup") or {}).get("factory_reset")
    if not reset:
        return "unpairing requires a factory reset, but setup.factory_reset is missing"
    if reset.get("applicable") is False:
        return "unpairing requires a factory reset, but setup.factory_reset says there is none"
    return None


def wrong_layer_for_protocol(spec: dict, pairing: dict) -> str | None:
    """The security mode has to be one the transport can carry.

    Just Works, passkeys and legacy PINs are Bluetooth link-layer procedures.
    A TV's on-screen PIN is `app_layer` with `pin.source: device_screen`, not
    `passkey_entry`. Zigbee and Z-Wave pair by joining a network
    (`network_join`), and only those radios do.
    """
    protocol = spec["device"].get("protocol")
    mode = pairing.get("security_mode")
    if mode in LINK_LAYER_MODES and protocol not in BLUETOOTH_PROTOCOLS:
        return f"security_mode {mode!r} is a Bluetooth link-layer mode on a {protocol!r} device"
    if protocol in MESH_PROTOCOLS and mode not in {"network_join", "unknown"}:
        return f"a {protocol!r} device pairs by network_join, not {mode!r}"
    if mode == "network_join" and protocol not in MESH_PROTOCOLS:
        return f"network_join on a {protocol!r} device, which joins no mesh"
    return None


def pin_length_disagrees(pairing: dict) -> str | None:
    """A published default PIN and its stated length agree."""
    pin = pairing.get("pin") or {}
    value, length = pin.get("value"), pin.get("length")
    if value is not None and length is not None and len(value) != length:
        return f"pin.value has {len(value)} characters but pin.length says {length}"
    return None


SPEC_RULES = (overclaims_confidence, unpair_points_nowhere, wrong_layer_for_protocol)
BLOCK_RULES = (
    missing_standing_answers,
    lacks_prose,
    exclusivity_without_recovery,
    pin_length_disagrees,
)


def problems(spec: dict, pairing: dict) -> list[str]:
    found = [rule(spec, pairing) for rule in SPEC_RULES]
    found += [rule(pairing) for rule in BLOCK_RULES]
    return [problem for problem in found if problem]


# ---------------------------------------------------------------------------
# The catalogue.
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "rule",
    SPEC_RULES + BLOCK_RULES,
    ids=lambda rule: rule.__name__,
)
def test_catalogue_follows_the_pairing_conventions(specs, rule):
    failures = []
    for device_id, spec, pairing in pairings(specs):
        problem = rule(spec, pairing) if rule in SPEC_RULES else rule(pairing)
        if problem:
            failures.append(f"{device_id}: {problem}")
    assert not failures, "\n".join(failures)


PAGE_ROW = re.compile(r"^\| Pairing required \| (?P<answer>Yes|No|Unknown)\b", re.MULTILINE)


def test_device_pages_agree_with_their_spec_on_whether_pairing_is_required(specs):
    """The guide page and the YAML must give the same yes/no/unknown.

    Two pages in this tree said "No" over a spec that said yes, or the
    reverse, before the pairing sweep. The page is what a person reads and
    the YAML is what the app reads, so a disagreement means one of them is
    wrong in front of someone. Only the leading word is compared: pages
    rightly qualify it ("No for the read-only event stream").
    """
    expected = {True: "Yes", False: "No", "unknown": "Unknown"}
    failures, compared = [], 0
    for page in sorted(DOCS_DIR.glob("*.md")):
        spec = specs.get(page.stem)
        match = PAGE_ROW.search(page.read_text(encoding="utf-8"))
        if spec is None or match is None:
            continue
        pairing = spec["device"].get("pairing")
        if pairing is None:
            continue
        compared += 1
        want = expected[pairing["required"]]
        if match["answer"] != want:
            failures.append(f"{page.name}: page says {match['answer']}, spec says {want}")
    assert compared >= 20, f"only {compared} pages compared; has the table row format changed?"
    assert not failures, "\n".join(failures)


# ---------------------------------------------------------------------------
# The rules themselves, on specs built to pass or fail them.
# ---------------------------------------------------------------------------


def _spec(protocol: str = "wifi", testing: dict | None = None, setup: dict | None = None):
    device: dict = {"protocol": protocol}
    if testing is not None:
        device["testing"] = testing
    if setup is not None:
        device["setup"] = setup
    return {"device": device}


OPEN_API = {
    "required": False,
    "confidence": "medium",
    "security_mode": "none",
    "bonding": "none",
    "enter_pairing_mode": {"required": False},
}

ON_SCREEN_PIN = {
    "required": True,
    "confidence": "medium",
    "security_mode": "app_layer",
    "bonding": "none",
    "pin": {"source": "device_screen", "length": 4, "notes": "Shown on the TV."},
    "enter_pairing_mode": {"required": False},
}


def test_the_minimal_open_answer_passes_every_rule():
    assert problems(_spec(), OPEN_API) == []


def test_a_documented_on_screen_pin_passes_every_rule():
    assert problems(_spec(), ON_SCREEN_PIN) == []


@pytest.mark.parametrize("key", ["security_mode", "bonding", "enter_pairing_mode"])
def test_each_standing_answer_is_required(key):
    block = {k: v for k, v in OPEN_API.items() if k != key}
    assert missing_standing_answers(block)


def test_enter_pairing_mode_must_say_required():
    assert missing_standing_answers({**OPEN_API, "enter_pairing_mode": {"notes": "Press it."}})


def test_a_credential_without_prose_is_rejected_and_any_prose_satisfies_it():
    bare = {**ON_SCREEN_PIN, "pin": {"source": "device_screen", "length": 4}}
    assert lacks_prose(bare)
    assert not lacks_prose({**bare, "notes": "The TV shows a PIN."})
    assert not lacks_prose({**bare, "exclusivity": {"recovery": "Close the app."}})
    assert not lacks_prose({**bare, "unpair": {"notes": "Settings > Devices."}})


def test_unknown_needs_prose_too():
    assert lacks_prose({**OPEN_API, "required": "unknown", "confidence": "low"})


@pytest.mark.parametrize(
    "testing, ok",
    [
        ({"status": "untested"}, False),
        (None, False),
        ({"status": "untested", "detail": "capture-verified"}, True),
        ({"status": "verified", "detail": "minimally-verified"}, True),
    ],
)
def test_high_confidence_needs_hardware_or_a_capture(testing, ok):
    pairing = {**OPEN_API, "confidence": "high"}
    assert (overclaims_confidence(_spec(testing=testing), pairing) is None) is ok


def test_medium_confidence_needs_nothing_from_testing():
    assert overclaims_confidence(_spec(testing={"status": "untested"}), OPEN_API) is None


@pytest.mark.parametrize("flag", ["single_connection", "single_bond"])
def test_an_exclusive_device_must_say_how_to_recover(flag):
    assert exclusivity_without_recovery({"exclusivity": {flag: True}})
    assert not exclusivity_without_recovery(
        {"exclusivity": {flag: True, "recovery": "Close the vendor app."}}
    )


def test_unknown_exclusivity_needs_no_recovery():
    assert not exclusivity_without_recovery({"exclusivity": {"single_connection": "unknown"}})


@pytest.mark.parametrize(
    "setup, ok",
    [
        (None, False),
        ({"required": False}, False),
        ({"factory_reset": {"applicable": False}}, False),
        ({"factory_reset": {"applicable": "unknown"}}, True),
        ({"factory_reset": {"applicable": True}}, True),
    ],
)
def test_unpair_by_reset_needs_a_reset_to_point_at(setup, ok):
    pairing = {**ON_SCREEN_PIN, "unpair": {"supported": False, "requires_factory_reset": True}}
    assert (unpair_points_nowhere(_spec(setup=setup), pairing) is None) is ok


@pytest.mark.parametrize(
    "protocol, mode, ok",
    [
        ("ble", "just_works", True),
        ("bluetooth_classic", "legacy_pin", True),
        ("wifi", "passkey_entry", False),
        ("lan", "just_works", False),
        ("obd2", "legacy_pin", False),
        ("wifi", "app_layer", True),
        ("zigbee", "network_join", True),
        ("zwave", "network_join", True),
        ("zigbee", "app_layer", False),
        ("wifi", "network_join", False),
        ("ble", "network_join", False),
    ],
)
def test_security_mode_matches_the_transport(protocol, mode, ok):
    pairing = {**OPEN_API, "security_mode": mode}
    assert (wrong_layer_for_protocol(_spec(protocol=protocol), pairing) is None) is ok


def test_a_default_pin_and_its_length_agree():
    assert pin_length_disagrees({"pin": {"source": "fixed_default", "value": "1234", "length": 6}})
    assert not pin_length_disagrees(
        {"pin": {"source": "fixed_default", "value": "123456", "length": 6}}
    )
    assert not pin_length_disagrees({"pin": {"source": "device_screen", "length": 4}})


def test_the_page_row_pattern_reads_qualified_answers():
    sample = (
        "| Pairing required | No for the read-only event stream |\n"
        "| Pairing required | Yes / No / Unknown |\n"
    )
    assert [m["answer"] for m in PAGE_ROW.finditer(sample)] == ["No", "Yes"]
    assert PAGE_ROW.search("| Pairing required | Nope |") is None
