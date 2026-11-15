# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Proves the Philips encrypted-CoAP spec's envelope reproduces its own vectors.

`device-specs/devices/philips-air-coap.yaml` states, in
`protocol_details.envelope`, how the AES-128-CBC key and IV come out of the
session counter and the shared string published by py-air-control and
aioairctrl, how the SHA-256 trailer is computed, and how counter, ciphertext
and digest are laid out. This module transcribes those rules -- AES from
`cryptography` (a dev dependency), everything else from the standard library
-- imports none of our code and none of the upstream projects', and asserts
that the transcription rebuilds every envelope the spec carries from its
invented counter and plaintext, and decrypts every one back.

It also renders each control command's body template and checks it against
its example and against the control wrapper the clients send, so a template
that drifts from the wire fails here rather than at a purifier.
"""

from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path

import pytest
import yaml
from cryptography.hazmat.primitives import padding
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

REPO_ROOT = Path(__file__).resolve().parent.parent
SPEC_PATH = REPO_ROOT / "device-specs" / "devices" / "philips-air-coap.yaml"
DOC_PATH = REPO_ROOT / "docs" / "devices" / "philips-air-coap.md"
PLACEHOLDER = re.compile(r"\{([A-Za-z0-9_]+)\}")
WRAPPER = {"CommandType": "app", "DeviceId": "", "EnduserId": ""}
HEX8 = re.compile(r"^[0-9A-F]{8}$")


@pytest.fixture(scope="module")
def spec() -> dict:
    return yaml.safe_load(SPEC_PATH.read_text(encoding="utf-8"))


@pytest.fixture(scope="module")
def envelope(spec) -> dict:
    return spec["protocol_details"]["envelope"]


@pytest.fixture(scope="module")
def commands(spec) -> dict:
    return spec["commands"]


# --- transcription of protocol_details.envelope ----------------------------

def key_and_iv(secret: str, counter: str) -> tuple[bytes, bytes]:
    digest = hashlib.md5((secret + counter).encode("ascii")).hexdigest().upper()
    return digest[:16].encode("ascii"), digest[16:].encode("ascii")


def seal(secret: str, counter: str, plaintext: str) -> str:
    key, iv = key_and_iv(secret, counter)
    padder = padding.PKCS7(128).padder()
    padded = padder.update(plaintext.encode("utf-8")) + padder.finalize()
    encryptor = Cipher(algorithms.AES(key), modes.CBC(iv)).encryptor()
    ciphertext = (encryptor.update(padded) + encryptor.finalize()).hex().upper()
    trailer = hashlib.sha256((counter + ciphertext).encode("ascii")).hexdigest().upper()
    return counter + ciphertext + trailer


def unseal(secret: str, envelope_text: str) -> str:
    counter, ciphertext, trailer = envelope_text[:8], envelope_text[8:-64], envelope_text[-64:]
    expected = hashlib.sha256((counter + ciphertext).encode("ascii")).hexdigest().upper()
    if trailer != expected:
        raise ValueError("digest mismatch")
    key, iv = key_and_iv(secret, counter)
    decryptor = Cipher(algorithms.AES(key), modes.CBC(iv)).decryptor()
    padded = decryptor.update(bytes.fromhex(ciphertext)) + decryptor.finalize()
    unpadder = padding.PKCS7(128).unpadder()
    return (unpadder.update(padded) + unpadder.finalize()).decode("utf-8")


def next_counter(counter: str) -> str:
    """aioairctrl 0.3.1: +1, 32-bit wrap, 8 uppercase hex digits."""
    return f"{(int(counter, 16) + 1) % 0x100000000:08X}"


# --- the vectors ------------------------------------------------------------

def test_the_shared_secret_is_the_published_constant(envelope):
    assert envelope["shared_secret"] == "JiangPan"


def test_there_are_vectors_in_both_directions(envelope):
    names = [v["name"] for v in envelope["test_vectors"]]
    assert len(names) >= 3
    assert any("status" in n for n in names)
    assert any("power on" in n for n in names)


@pytest.mark.parametrize("index", range(3))
def test_each_envelope_rebuilds_from_its_counter_and_plaintext(envelope, index):
    vector = envelope["test_vectors"][index]
    assert HEX8.match(vector["counter"])
    rebuilt = seal(envelope["shared_secret"], vector["counter"], vector["plaintext"])
    assert rebuilt == vector["envelope"], vector["name"]


@pytest.mark.parametrize("index", range(3))
def test_each_envelope_decrypts_back(envelope, index):
    vector = envelope["test_vectors"][index]
    plaintext = unseal(envelope["shared_secret"], vector["envelope"])
    assert plaintext == vector["plaintext"]
    json.loads(plaintext)


def test_stated_keys_and_ivs_match_the_derivation(envelope):
    checked = 0
    for vector in envelope["test_vectors"]:
        if "key_ascii" not in vector:
            continue
        key, iv = key_and_iv(envelope["shared_secret"], vector["counter"])
        assert key.decode() == vector["key_ascii"]
        assert iv.decode() == vector["iv_ascii"]
        assert len(key) == len(iv) == 16  # AES-128, raw hex characters as bytes
        checked += 1
    assert checked >= 2


def test_layout_is_counter_ciphertext_digest(envelope):
    for vector in envelope["test_vectors"]:
        text = vector["envelope"]
        assert text.startswith(vector["counter"])
        assert re.fullmatch(r"[0-9A-F]+", text)
        assert (len(text) - 8 - 64) % 32 == 0 and len(text) > 8 + 64


def test_a_tampered_envelope_is_rejected(envelope):
    text = envelope["test_vectors"][0]["envelope"]
    flipped = text[:10] + ("0" if text[10] != "0" else "1") + text[11:]
    with pytest.raises(ValueError):
        unseal(envelope["shared_secret"], flipped)


def test_the_digest_is_unkeyed(envelope):
    """The trailer is SHA-256 of counter+ciphertext hex, nothing else: anyone
    can recompute it, which is why the spec calls it corruption detection."""
    vector = envelope["test_vectors"][0]
    text = vector["envelope"]
    body = text[:-64]
    assert hashlib.sha256(body.encode()).hexdigest().upper() == text[-64:]


def test_counter_increments_before_each_envelope(spec, envelope):
    vectors = {v["counter"]: v for v in envelope["test_vectors"]}
    # The power-on vector follows a sync answered 6D2C0F41, the compact one
    # FFFFFFFE; the sync example reply is the first.
    assert spec["payload_formats"]["SyncReply"]["example"] == "6D2C0F41"
    assert next_counter("6D2C0F41") in vectors
    assert next_counter("FFFFFFFE") in vectors
    assert next_counter("FFFFFFFF") == "00000000"
    assert "6D2C0F41" in envelope["test_vectors"][0]["name"]


def test_the_status_vector_is_the_documented_status_example(spec, envelope):
    status = next(v for v in envelope["test_vectors"] if "status" in v["name"])
    assert status["plaintext"] == spec["payload_formats"]["StatusDocument"]["example"]
    reported = json.loads(status["plaintext"])["state"]["reported"]
    assert "modelid" in reported  # classic key set


# --- command templates ------------------------------------------------------

def render(template: str, values: dict, parameters: dict) -> str:
    def fill(match: re.Match) -> str:
        name = match.group(1)
        value = values[name]
        if parameters[name]["type"] == "string":
            return str(value)
        return json.dumps(value)

    return PLACEHOLDER.sub(fill, template)


def control_commands(commands: dict):
    return {n: c for n, c in commands.items() if c.get("path") == "/sys/dev/control"}


def test_every_command_is_a_coap_request_on_the_three_resources(commands):
    paths = {"/sys/dev/sync", "/sys/dev/status", "/sys/dev/control"}
    for name, command in commands.items():
        assert command["transport"] == "coap", name
        assert command["path"] in paths, name
        assert command["method"] == ("GET" if command["path"] == "/sys/dev/status" else "POST"), name
        declared = set(command.get("parameters") or {})
        used = set(PLACEHOLDER.findall(command.get("body", "")))
        assert used == declared, f"{name}: uses {sorted(used)}, declares {sorted(declared)}"


def test_control_bodies_carry_the_clients_wrapper(commands):
    for name, command in control_commands(commands).items():
        parameters = command.get("parameters") or {}
        values = {
            p: (v["enum"][0] if "enum" in v else (v.get("min", 1)))
            for p, v in parameters.items()
        }
        document = json.loads(render(command["body"], values, parameters))
        desired = document["state"]["desired"]
        assert list(document) == ["state"] and list(document["state"]) == ["desired"], name
        assert {k: desired[k] for k in WRAPPER} == WRAPPER, name
        assert len(desired) > len(WRAPPER), name


def _sentinel(parameter: dict, name: str):
    if parameter["type"] == "string":
        return f"__{name}__"
    return 987654000 + sum(name.encode())  # distinct per parameter name


def test_examples_render_from_their_templates(commands):
    """Read each parameter's value back out of the example and re-render."""
    seen = 0
    for name, command in commands.items():
        parameters = command.get("parameters") or {}
        if not parameters or "example_body" not in command:
            continue
        example = command["example_body"]
        if command["path"] != "/sys/dev/control":
            assert render(command["body"], {p: example for p in parameters}, parameters) == example
            seen += 1
            continue
        probe = {p: _sentinel(v, p) for p, v in parameters.items()}
        rendered = json.loads(render(command["body"], probe, parameters))["state"]["desired"]
        actual = json.loads(example)["state"]["desired"]
        values = {}
        for p, spec_p in parameters.items():
            key = next(k for k, v in rendered.items() if v == probe[p])
            values[p] = actual[key]
            if "enum" in spec_p:
                assert values[p] in spec_p["enum"], name
            if "min" in spec_p:
                assert spec_p["min"] <= values[p] <= spec_p["max"], name
        assert render(command["body"], values, parameters) == example, name
        seen += 1
    assert seen >= 10


def test_vector_plaintexts_are_rendered_command_bodies(commands, envelope):
    power_on = envelope["test_vectors"][0]["plaintext"]
    assert commands["power_on"]["body"] == power_on
    compact = envelope["test_vectors"][1]["plaintext"]
    assert render(commands["compact_set_mode"]["body"], {"mode": 18}, commands["compact_set_mode"]["parameters"]) == compact


def test_compact_key_writes_use_json_integers(commands):
    for name, command in control_commands(commands).items():
        if not name.startswith("compact_"):
            continue
        parameters = command.get("parameters") or {}
        assert all(p["type"] == "integer" for p in parameters.values()), name
        values = {p: v.get("enum", [v.get("min", 0)])[0] for p, v in parameters.items()}
        desired = json.loads(render(command["body"], values, parameters))["state"]["desired"]
        for key, value in desired.items():
            if key.startswith("D03"):
                assert isinstance(value, int) and not isinstance(value, bool), (name, key)


def test_key_sets_match_the_clients(commands):
    def desired(name, **values):
        command = commands[name]
        return json.loads(render(command["body"], values, command.get("parameters") or {}))["state"]["desired"]

    assert desired("power_on")["pwr"] == "1" and desired("power_off")["pwr"] == "0"
    assert desired("child_lock_on")["cl"] is True
    assert desired("dashed_power_on")["D03-02"] == "ON"
    assert desired("compact_power_on")["D03102"] == 1
    assert desired("compact_child_lock_on")["D03103"] == 1
    assert desired("set_fan_speed", speed="t") == {**WRAPPER, "mode": "M", "om": "t"}
    # Silent needs mode S, not M (the integration's AC2729 table).
    assert "s" not in commands["set_fan_speed"]["parameters"]["speed"]["enum"]
    assert desired("set_silent") == {**WRAPPER, "mode": "S", "om": "s"}
    # AC0950 medium: D0310C 19 with companion D0310D 2.
    assert desired("compact_set_mode_pair", mode=19, companion=2) == {
        **WRAPPER, "D03102": 1, "D0310C": 19, "D0310D": 2
    }


def test_compact_mode_entity_is_read_only(spec):
    (mode,) = [e for e in spec["entities"] if e["name"] == "Mode" and e["variants"] == ["compact-keys"]]
    assert mode["platform"] == "sensor" and not mode.get("commands")


def test_entities_are_bound_to_one_key_set_each(spec, commands):
    variants = {v["model"] for v in spec["device"]["variants"]}
    assert variants == {"classic-keys", "dashed-keys", "compact-keys"}
    prefix = {"classic-keys": "", "dashed-keys": "dashed_", "compact-keys": "compact_"}
    for entity in spec["entities"]:
        (variant,) = entity["variants"]
        assert variant in variants
        assert entity["state_mapping"]["value" if "value" in entity["state_mapping"] else "is_on"].startswith("state.reported.")
        for bound in (entity.get("commands") or {}).values():
            assert bound in commands
            if prefix[variant]:
                assert bound.startswith(prefix[variant]), (entity["name"], bound)
            else:
                assert not bound.startswith(("dashed_", "compact_")), (entity["name"], bound)


def test_variant_probes_name_the_model_id_keys(spec):
    probes = {
        v["model"]: v["identification"]["state_probe"]["keys_present"]
        for v in spec["device"]["variants"]
    }
    assert probes == {
        "classic-keys": ["state.reported.modelid"],
        "dashed-keys": ["state.reported.D01-05"],
        "compact-keys": ["state.reported.D01S05"],
    }


def test_no_real_identifier_in_spec_or_doc():
    for path in (SPEC_PATH, DOC_PATH):
        text = path.read_text(encoding="utf-8")
        for address in re.findall(r"\b(?:\d{1,3}\.){3}\d{1,3}\b", text):
            assert address.startswith("192.168.1.5") and len(address) == 12, (path.name, address)
        # Device ids in examples are the obviously-invented counting pattern.
        for device_id in re.findall(r"\b[0-9a-f]{32}\b", text):
            assert device_id == "0123456789abcdef0123456789abcdef", (path.name, device_id)
