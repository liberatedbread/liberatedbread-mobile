# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Proves the TP-Link Kasa spec can be driven from the spec alone.

`device-specs/devices/tplink-kasa-smart-plug.yaml` declares an outlet as a
`switch` entity over `tcp-json` commands, and documents the XOR-autokey cipher
and TCP/UDP framing the transport uses. This module transcribes the consumer's
side of that contract — the cipher, the framing, rendering a command's `body`,
and decoding a get_sysinfo reply — straight from the YAML and the standard
library, and holds the spec to it. It is the sibling of `test_wemo_spec.py`
(SOAP) and `test_roku_spec.py` (HTTP) for the raw-socket JSON transport.

If the cipher the spec documents does not reproduce the vectors the spec
publishes, or a control cannot be rendered into the bytes the discovery
datagram shows, the spec is underspecified and this fails.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
SPEC_PATH = REPO_ROOT / "device-specs" / "devices" / "tplink-kasa-smart-plug.yaml"


@pytest.fixture(scope="module")
def spec() -> dict:
    return yaml.safe_load(SPEC_PATH.read_text(encoding="utf-8"))


@pytest.fixture(scope="module")
def protocol(spec) -> dict:
    return spec["tplink_smarthome_protocol"]


@pytest.fixture(scope="module")
def commands(spec) -> dict:
    return spec["commands"]


@pytest.fixture(scope="module")
def entities(spec) -> list:
    return spec["entities"]


@pytest.fixture(scope="module")
def variants(spec) -> list:
    return spec["device"]["variants"]


@pytest.fixture(scope="module")
def sensors(entities) -> list:
    return [e for e in entities if e["platform"] == "sensor"]


# ── Reference implementation, transcribed from the spec ──────────────────────


def encrypt(plaintext: bytes, initial_key: int) -> bytes:
    """XOR autokey per tplink_smarthome_protocol.cipher.

    key starts at initial_key; each output byte becomes the next key. The
    whole cipher, in four lines — which is the point the spec makes about it.
    """
    key = initial_key
    out = bytearray()
    for byte in plaintext:
        key ^= byte
        out.append(key)
    return bytes(out)


def decrypt(ciphertext: bytes, initial_key: int) -> bytes:
    key = initial_key
    out = bytearray()
    for byte in ciphertext:
        out.append(key ^ byte)
        key = byte
    return bytes(out)


def tcp_frame(plaintext: bytes, initial_key: int) -> bytes:
    """4-byte big-endian length prefix + encrypted payload (the TCP framing)."""
    body = encrypt(plaintext, initial_key)
    return len(body).to_bytes(4, "big") + body


def user_parameters(command: dict) -> list[str]:
    """Parameters the caller supplies: neither defaulted nor read back."""
    return [
        name
        for name, parameter in (command.get("parameters") or {}).items()
        if "default" not in parameter and "source" not in parameter
    ]


def read_relay_state(get_sysinfo_reply: dict, mapping: dict) -> bool:
    """Decode a switch's on/off from a get_sysinfo reply per state_mapping.

    `state_mapping.value` names the field; `on_when: nonzero` means any nonzero
    reading is on. Transcribed from the schema's state_mapping contract, the
    same rule the SOAP/Wemo path applies to BinaryState.
    """
    sysinfo = get_sysinfo_reply["system"]["get_sysinfo"]
    raw = sysinfo[mapping["value"]]
    assert mapping["on_when"] == "nonzero"
    return float(raw) != 0.0


def read_dotted_path(reply: dict, path: str):
    """Resolve a state_mapping `value` dotted path against a decoded reply.

    The sensor entities' paths are dotted from the reply ROOT
    ("emeter.get_realtime.power"), resolved the way the schema's state_mapping
    description spells it for nested JSON — the counterpart of how the switch's
    bare `relay_state` is lifted out of the sysinfo object.
    """
    node = reply
    for key in path.split("."):
        node = node[key]
    return node


class Missing:
    """Sentinel: the path is not present in this reply."""


def try_dotted_path(reply: dict, path: str):
    """`read_dotted_path`, but absence is an answer rather than a KeyError."""
    node = reply
    for key in path.split("."):
        if not isinstance(node, dict) or key not in node:
            return Missing
        node = node[key]
    return node


def read_entity_value(reply: dict, mapping: dict):
    """Read a role's value per state_mapping, honouring `value_fallback`.

    The schema's contract: try the role's primary path; only when that key is
    absent from the reply, resolve the fallback's `path` and multiply by its
    `scale`. This is the whole reason HS110 hardware v1 — which names the
    emeter fields differently rather than merely scaling them — is readable
    from the same entity as current firmware.
    """
    value = try_dotted_path(reply, mapping["value"])
    if value is not Missing:
        return value
    fallback = mapping.get("value_fallback")
    if fallback is None:
        return Missing
    raw = try_dotted_path(reply, fallback["path"])
    if raw is Missing:
        return Missing
    return raw * fallback.get("scale", 1)


# ── The cipher reproduces the published vectors ──────────────────────────────


def test_cipher_reproduces_every_published_vector(protocol):
    """The vectors in the spec must fall out of the documented algorithm."""
    cipher = protocol["cipher"]
    initial_key = cipher["initial_key"]
    assert initial_key == 0xAB
    cases = cipher["test_vectors"]["cases"]
    assert cases, "the cipher must publish at least one vector"
    for case in cases:
        if "plaintext_hex" in case:
            plaintext = bytes.fromhex(case["plaintext_hex"])
        else:
            plaintext = case["plaintext_utf8"].encode()
        assert encrypt(plaintext, initial_key).hex() == case["cipher_hex"], (
            f"cipher vector mismatch for {case}"
        )


def test_cipher_round_trips(protocol):
    """decrypt(encrypt(x)) == x — the property a reply reader depends on."""
    initial_key = protocol["cipher"]["initial_key"]
    for sample in (b"", b"\x00", b'{"system":{"get_sysinfo":null}}', bytes(range(256))):
        assert decrypt(encrypt(sample, initial_key), initial_key) == sample


# ── Discovery and command rendering ──────────────────────────────────────────


def test_discovery_datagram_matches_its_documented_bytes(protocol):
    """The UDP discovery datagram the spec shows is exactly the encrypted
    get_sysinfo — no length prefix, per the udp framing rule."""
    initial_key = protocol["cipher"]["initial_key"]
    discovery = protocol["discovery"]
    payload = discovery["request_json"].encode()
    assert encrypt(payload, initial_key).hex() == discovery["request_datagram_hex"]


def test_discovery_probe_is_the_get_sysinfo_command(protocol, commands):
    """Discovery and the state poll are the same request — the spec says so in
    prose, and this holds the two byte strings to being identical."""
    assert protocol["discovery"]["request_json"] == commands["get_sysinfo"]["body"]


def test_relay_commands_render_the_documented_json(commands):
    """Each control command's body is the documented set_relay_state JSON, and
    it parses as JSON (a body that is not valid JSON could never be sent)."""
    expected = {
        "relay_on": 1,
        "relay_off": 0,
    }
    for name, state in expected.items():
        command = commands[name]
        assert command["transport"] == "tcp-json"
        body = command["body"]
        assert json.loads(body) == {"system": {"set_relay_state": {"state": state}}}
        # example_body is what a consumer diffs against; it must match the body.
        assert command["example_body"] == body


def test_control_commands_take_no_caller_input(commands):
    """turn_on/turn_off are fixed roles: a switch has no value to fill a blank
    with, so the command must render from nothing."""
    for name in ("relay_on", "relay_off", "get_sysinfo", "get_emeter"):
        assert not user_parameters(commands[name]), (
            f"{name} must be sendable with no caller-supplied parameters"
        )


def test_commands_frame_onto_the_wire(protocol, commands):
    """A rendered command survives encrypt + TCP framing and decrypts back to
    the same JSON — the full send path, end to end, from the YAML."""
    initial_key = protocol["cipher"]["initial_key"]
    for name in ("relay_on", "relay_off", "get_sysinfo"):
        body = commands[name]["body"].encode()
        framed = tcp_frame(body, initial_key)
        length = int.from_bytes(framed[:4], "big")
        assert length == len(framed) - 4, "the length prefix counts the payload"
        assert decrypt(framed[4:], initial_key) == body


def test_get_emeter_frames_to_exact_bytes(protocol, commands):
    """The get_emeter body renders as the documented emeter.get_realtime JSON,
    and cipher + TCP framing produce one exact byte string — pinned as a
    regression anchor the way the discovery datagram is pinned in the spec."""
    command = commands["get_emeter"]
    assert command["transport"] == "tcp-json"
    body = command["body"]
    assert command["example_body"] == body
    assert json.loads(body) == {"emeter": {"get_realtime": None}}
    initial_key = protocol["cipher"]["initial_key"]
    framed = tcp_frame(body.encode(), initial_key)
    assert framed.hex() == (
        "00000020"
        "d0f297fa9feb8efcdee49fbddabfcb94e683e28efa93fe9bb983ed98f498e598"
    )


# ── The switch entity resolves and decodes ───────────────────────────────────


def test_the_switch_binds_real_commands(entities, commands):
    """The outlet's role map names commands that exist — a binding that
    resolves nowhere is a dead control drawn on screen."""
    switches = [e for e in entities if e["platform"] == "switch"]
    assert switches, "the outlet is the point of this spec"
    for entity in switches:
        for role, command_name in entity["commands"].items():
            assert role in ("turn_on", "turn_off")
            assert command_name in commands, (
                f"{entity['name']}: {role} binds {command_name!r}, undeclared"
            )
        assert entity["state_command"] in commands, (
            f"{entity['name']}: state_command names no command"
        )


def test_the_switch_reads_relay_state_from_a_sysinfo_reply(entities):
    """A get_sysinfo reply decodes to on/off through the entity's state_mapping,
    for both relay states — the poll a consumer runs after every write."""
    switch = next(e for e in entities if e["platform"] == "switch")
    mapping = switch["state_mapping"]
    on_reply = {"system": {"get_sysinfo": {"relay_state": 1, "alias": "Desk Lamp"}}}
    off_reply = {"system": {"get_sysinfo": {"relay_state": 0, "alias": "Desk Lamp"}}}
    assert read_relay_state(on_reply, mapping) is True
    assert read_relay_state(off_reply, mapping) is False


def test_the_state_field_is_one_the_command_returns(entities, commands):
    """The field the switch reads must be one get_sysinfo says it returns —
    otherwise the poll and the decode disagree about what comes back."""
    switch = next(e for e in entities if e["platform"] == "switch")
    returned = {r["name"] for r in commands["get_sysinfo"]["returns"]}
    assert switch["state_mapping"]["value"] in returned


# ── The emeter sensors resolve and decode ────────────────────────────────────


EXPECTED_READINGS = {
    "Voltage": 121.043,
    "Current": 0.362,
    "Power": 43.81,
    "Total Consumption": 12.345,
}

# Current firmware: plain float fields, already in the entities' units.
MODERN_EMETER_REPLY = {
    "emeter": {
        "get_realtime": {
            "voltage": 121.043,
            "current": 0.362,
            "power": 43.81,
            "total": 12.345,
            "err_code": 0,
        }
    }
}

# HS110 hardware v1: the same four readings under DIFFERENT NAMES, in
# milli-units. Not a scaled copy of the reply above — the modern keys are
# absent entirely, which is exactly why prose telling a consumer to "divide by
# 1000" is not enough and the fallback paths have to be in the spec.
LEGACY_EMETER_REPLY = {
    "emeter": {
        "get_realtime": {
            "voltage_mv": 121043,
            "current_ma": 362,
            "power_mw": 43810,
            "total_wh": 12345,
            "err_code": 0,
        }
    }
}


def test_the_emeter_sensors_bind_get_emeter(sensors, commands):
    """Each sensor's state_command is the get_emeter command — and every path
    it reads, primary and fallback alike, must end in a field get_emeter says
    it returns, the same poll/decode agreement the switch is held to."""
    assert len(sensors) == 4, "Voltage/Current/Power/Total Consumption"
    returned = {r["name"] for r in commands["get_emeter"]["returns"]}
    for sensor in sensors:
        assert sensor["state_command"] == "get_emeter"
        mapping = sensor["state_mapping"]
        paths = [mapping["value"]]
        if "value_fallback" in mapping:
            paths.append(mapping["value_fallback"]["path"])
        for path in paths:
            assert path.split(".")[-1] in returned, (
                f"{sensor['name']}: {path!r} ends in a field get_emeter does not return"
            )


def test_an_emeter_reply_decodes_through_the_sensor_mappings(sensors):
    """A get_emeter reply (current firmware's plain float fields, in SI units)
    resolves through every sensor's dotted state_mapping path — the poll a
    consumer runs to fill the four meter tiles."""
    for sensor in sensors:
        value = read_dotted_path(MODERN_EMETER_REPLY, sensor["state_mapping"]["value"])
        assert value == pytest.approx(EXPECTED_READINGS[sensor["name"]])


def test_a_legacy_milliunit_reply_decodes_to_the_same_readings(sensors):
    """HS110 hardware v1's reply — different field NAMES, milli-units — decodes
    through the same entities to the same values, via value_fallback.

    The primary path finds nothing in this reply, so a consumer with no
    fallback support renders no reading at all; that is the failure the
    fallback exists to remove, and this pins that it is removed.
    """
    for sensor in sensors:
        mapping = sensor["state_mapping"]
        assert try_dotted_path(LEGACY_EMETER_REPLY, mapping["value"]) is Missing, (
            f"{sensor['name']}: the legacy reply must not carry the modern key — "
            "if it did, the fallback would be untested here"
        )
        value = read_entity_value(LEGACY_EMETER_REPLY, mapping)
        assert value == pytest.approx(EXPECTED_READINGS[sensor["name"]])


def test_both_reply_shapes_decode_through_one_reader(sensors):
    """One `read_entity_value` reads both hardware generations, in the order
    the schema states: primary first, fallback only when the primary is
    absent. A consumer needs one code path, not a per-model branch."""
    for reply in (MODERN_EMETER_REPLY, LEGACY_EMETER_REPLY):
        for sensor in sensors:
            value = read_entity_value(reply, sensor["state_mapping"])
            assert value == pytest.approx(EXPECTED_READINGS[sensor["name"]])


# ── Variant scoping: the emeter surface is not on every covered model ────────


def test_variants_are_identifiable_from_a_sysinfo_reply(variants, commands):
    """Every variant declares a model_prefix, and get_sysinfo declares the
    `model` field a consumer matches it against — a variant table nothing in
    the protocol can be matched to is decoration."""
    assert variants, "the spec covers more than one model; they must be listed"
    returned = {r["name"] for r in commands["get_sysinfo"]["returns"]}
    assert "model" in returned and "feature" in returned
    for variant in variants:
        prefix = variant["identification"]["model_prefix"]
        assert variant["model"].startswith(prefix)
        # A region suffix must not defeat the match — this is a prefix test.
        assert f"{prefix}(US)".startswith(prefix)


def test_the_emeter_sensors_are_scoped_to_metering_models(sensors, variants):
    """The four meter sensors name the models that actually have the meter,
    and those names resolve to declared variants.

    Unscoped, a consumer draws four permanently-unavailable tiles on an
    HS100 — get_emeter on a plug with no metering hardware answers an error,
    not a reading.
    """
    declared = {v["model"] for v in variants}
    metering = {"HS110", "KP115"}
    assert metering <= declared
    for sensor in sensors:
        scope = sensor.get("variants")
        assert scope, f"{sensor['name']}: an emeter sensor must name its models"
        assert set(scope) == metering, (
            f"{sensor['name']}: scoped to {scope}, expected the metering models"
        )


def test_every_entity_variant_names_a_declared_variant(entities, variants):
    """No entity may scope itself to a model the device block never declares —
    a typo there silently hides the entity on every real device."""
    declared = {v["model"] for v in variants}
    for entity in entities:
        for model in entity.get("variants", []):
            assert model in declared, (
                f"{entity['name']}: variants names {model!r}, not in device.variants"
            )


def test_the_switch_is_not_variant_scoped(entities):
    """The relay is on every covered model, so the switch must NOT carry a
    variants list — scoping it would hide the one control every plug has."""
    switch = next(e for e in entities if e["platform"] == "switch")
    assert "variants" not in switch
