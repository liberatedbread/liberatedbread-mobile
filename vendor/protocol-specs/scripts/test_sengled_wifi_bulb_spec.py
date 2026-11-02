# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Proves the Sengled Wi-Fi bulb spec's provisioning cipher and command
bodies are what the document says they are.

`device-specs/devices/sengled-wifi-bulb.yaml` says the setup-AP credential
datagram is the base64 of RC4 over the UTF-8 JSON text, keyed with the 52
ASCII bytes of a fixed string that is NOT base64-decoded first, and it
publishes test vectors for that. This module transcribes RC4 with nothing
but the standard library and holds every vector in the spec to it -- the
same contract `test_wemo_spec.py` keeps for the Wemo crypto and
`test_am43_spec.py` for the AM43 checksum.

It also renders every UDP command body with in-range parameters and checks
the result is the `{"func", "param"}` envelope the spec describes, and that
the discovery probe is the state-read command's bytes.
"""

from __future__ import annotations

import base64
import json
import re
from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
SPEC_PATH = REPO_ROOT / "device-specs" / "devices" / "sengled-wifi-bulb.yaml"
PLACEHOLDER = re.compile(r"\{([A-Za-z0-9_]+)\}")


def rc4(key: bytes, data: bytes) -> bytes:
    """Textbook RC4: KSA over the key, PRGA with no bytes discarded."""
    state = list(range(256))
    j = 0
    for i in range(256):
        j = (j + state[i] + key[i % len(key)]) & 0xFF
        state[i], state[j] = state[j], state[i]
    out = bytearray()
    i = j = 0
    for byte in data:
        i = (i + 1) & 0xFF
        j = (j + state[i]) & 0xFF
        state[i], state[j] = state[j], state[i]
        out.append(byte ^ state[(state[i] + state[j]) & 0xFF])
    return bytes(out)


def encrypt(key: str, plaintext: str) -> str:
    """credential_encryption.algorithm_steps, transcribed."""
    return base64.b64encode(rc4(key.encode("utf-8"), plaintext.encode("utf-8"))).decode("ascii")


def decrypt(key: str, ciphertext_b64: str) -> str:
    return rc4(key.encode("utf-8"), base64.b64decode(ciphertext_b64)).decode("utf-8")


@pytest.fixture(scope="module")
def spec() -> dict:
    return yaml.safe_load(SPEC_PATH.read_text(encoding="utf-8"))


@pytest.fixture(scope="module")
def crypto(spec) -> dict:
    method = spec["device"]["setup"]["methods"][0]
    assert method["type"] == "softap_udp"
    return method["softap"]["credential_encryption"]


def test_key_is_used_as_ascii_not_decoded(crypto):
    key = crypto["test_vectors"]["input"]["key_ascii"]
    assert len(key) == 52
    # It happens to be valid base64 -- the trap the spec warns about.
    base64.b64decode(key)
    assert crypto["algorithm"] == "RC4"
    assert crypto["encoding"] == "base64"


def test_keystream_matches_the_spec(crypto):
    inputs = crypto["test_vectors"]["input"]
    key = inputs["key_ascii"].encode("utf-8")
    assert rc4(key, bytes(16)).hex() == inputs["keystream_first_16_bytes_hex"]


def test_every_vector_encrypts_as_published(crypto):
    key = crypto["test_vectors"]["input"]["key_ascii"]
    vectors = crypto["test_vectors"]["vectors"]
    assert len(vectors) >= 3
    for vector in vectors:
        assert encrypt(key, vector["plaintext"]) == vector["ciphertext_base64"], vector["plaintext"]


def test_every_vector_decrypts_back(crypto):
    key = crypto["test_vectors"]["input"]["key_ascii"]
    for vector in crypto["test_vectors"]["vectors"]:
        assert decrypt(key, vector["ciphertext_base64"]) == vector["plaintext"]


def test_the_long_vector_is_a_setparams_request(crypto):
    """The worked example is the real datagram shape, not a toy string."""
    longest = max(crypto["test_vectors"]["vectors"], key=lambda v: len(v["plaintext"]))
    message = json.loads(longest["plaintext"])
    assert message["name"] == "setParamsRequest"
    payload = message["payload"]
    for field in ("userID", "appServerDomain", "jbalancerDomain", "timeZone", "routerInfo"):
        assert field in payload, field
    assert set(payload["routerInfo"]) >= {"ssid", "password"}


def _sample_value(param: dict):
    if param.get("type") == "string":
        return "http://192.168.1.50:57542/x.bin"
    return param.get("min", 0)


def _udp_commands(spec):
    for name, command in spec["commands"].items():
        if command.get("transport") == "udp":
            yield name, command


def test_udp_bodies_render_to_the_func_param_envelope(spec):
    seen = 0
    for name, command in _udp_commands(spec):
        body = command["body"]
        params = command.get("parameters") or {}
        for placeholder in PLACEHOLDER.findall(body):
            assert placeholder in params, f"{name}: {{{placeholder}}} undeclared"
            body = body.replace("{" + placeholder + "}", str(_sample_value(params[placeholder])))
        message = json.loads(body)
        assert set(message) == {"func", "param"}, name
        assert isinstance(message["func"], str) and message["func"]
        assert isinstance(message["param"], dict), name
        seen += 1
    assert seen >= 8


def test_udp_parameter_ranges_are_the_documented_ones(spec):
    commands = spec["commands"]
    assert commands["set_brightness"]["parameters"]["level"]["max"] == 100
    assert commands["set_color_temperature"]["parameters"]["level"]["min"] == 1
    assert commands["set_color_temperature"]["parameters"]["level"]["max"] == 100
    for channel in ("red", "green", "blue"):
        assert commands["set_color"]["parameters"][channel]["max"] == 255


def test_discovery_probe_is_the_state_read(spec):
    method = spec["device"]["discovery"]["methods"][0]
    probe = bytes.fromhex(method["udp_broadcast"]["probe_hex"]).decode("utf-8")
    assert json.loads(probe) == json.loads(spec["commands"]["get_state"]["body"])
    assert method["udp_broadcast"]["port"] == spec["device"]["identification"]["default_port"] == 9080


def _mqtt_requests(node):
    """Every MQTT request the spec writes out, wherever it sits."""
    if isinstance(node, dict):
        if node.get("protocol") == "mqtt" and "message" in node:
            yield node
        for value in node.values():
            yield from _mqtt_requests(value)
    elif isinstance(node, list):
        for value in node:
            yield from _mqtt_requests(value)


def test_mqtt_messages_are_arrays_of_attribute_objects(spec):
    """The spec has no MQTT commands; its MQTT messages are written out in its
    reset steps. Each must follow the envelope the mqtt section describes."""
    seen = 0
    for request in _mqtt_requests(spec):
        assert re.fullmatch(r"wifielement/<MAC>/update", request["action"]), request["action"]
        body = request["message"].replace("<MAC>", "AA:BB:CC:DD:EE:FF").replace("<epoch ms>", "0")
        message = json.loads(body)
        assert isinstance(message, list) and message
        for item in message:
            assert set(item) == {"dn", "type", "value", "time"}
            assert isinstance(item["value"], str), "value must be a string"
        seen += 1
    assert seen >= 1
