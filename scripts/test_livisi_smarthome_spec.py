# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Checks that the LIVISI SmartHome spec can be implemented from the YAML alone.

The code below transcribes only what `device-specs/devices/livisi-smarthome.yaml`
says, using nothing but the standard library and PyYAML. It covers the token
login's client credentials, how every action body renders from its declared
parameters, the per-generation status shapes the sensors read, and the event
frame a WebSocket client parses. Nothing here talks to a controller.
"""

from __future__ import annotations

import base64
import json
import re
from pathlib import Path

import pytest
import yaml

SPEC_PATH = (
    Path(__file__).resolve().parent.parent
    / "device-specs" / "devices" / "livisi-smarthome.yaml"
)
PLACEHOLDER = re.compile(r"\{([A-Za-z_][A-Za-z0-9_]*)\}")

# The values each command's `example_notes` says its example was rendered with.
EXAMPLE_VALUES = {
    "get_token": {"password": "Example-Pass1!"},
    "switch_on": {"capability_id": "0123456789abcdef0123456789abcdef"},
    "switch_off": {"capability_id": "0123456789abcdef0123456789abcdef"},
    "set_dim_level": {"capability_id": "0123456789abcdef0123456789abcdef", "dim_level": 60},
    "set_shutter_level": {"capability_id": "0123456789abcdef0123456789abcdef", "shutter_level": 40},
    "shutter_up": {"capability_id": "0123456789abcdef0123456789abcdef"},
    "shutter_down": {"capability_id": "0123456789abcdef0123456789abcdef"},
    "shutter_stop": {"capability_id": "0123456789abcdef0123456789abcdef"},
    "set_thermostat_point_temperature": {
        "capability_id": "0123456789abcdef0123456789abcdef", "point_temperature": 21.5},
    "set_room_setpoint": {
        "capability_id": "0123456789abcdef0123456789abcdef", "setpoint_temperature": 20},
    "set_room_setpoint_classic": {
        "capability_id": "0123456789abcdef0123456789abcdef", "point_temperature": 20},
    "set_operation_mode": {
        "capability_id": "0123456789abcdef0123456789abcdef", "operation_mode": "Auto"},
    "set_variable": {"capability_id": "0123456789abcdef0123456789abcdef", "value": True},
    "restart_controller": {"device_id": "fedcba9876543210fedcba9876543210"},
}


@pytest.fixture(scope="module")
def spec() -> dict:
    return yaml.safe_load(SPEC_PATH.read_text(encoding="utf-8"))


def render(template: str, parameters: dict, values: dict) -> str:
    """Substitute by declared type: strings JSON-escaped (the template supplies
    the quotes), numbers and booleans as JSON literals."""

    def one(match: re.Match) -> str:
        name = match.group(1)
        value = values[name]
        declared = parameters[name]["type"]
        if declared == "string":
            return json.dumps(value)[1:-1]
        if declared == "boolean":
            return "true" if value else "false"
        return json.dumps(value)

    return PLACEHOLDER.sub(one, template)


def test_client_basic_is_the_published_constant(spec):
    scheme = spec["auth_schemes"]["client_basic"]
    token = base64.b64encode(
        f"{scheme['username']}:{scheme['password']}".encode()
    ).decode()
    assert token == "Y2xpZW50SWQ6Y2xpZW50UGFzcw=="
    assert token in scheme["description"]


def test_every_body_renders_to_its_example(spec):
    rendered = 0
    for name, command in spec["commands"].items():
        body = command.get("body")
        if body is None:
            continue
        values = EXAMPLE_VALUES[name]
        out = render(body, command.get("parameters") or {}, values)
        assert json.loads(out) == json.loads(command["example_body"]), name
        rendered += 1
    assert rendered == len(EXAMPLE_VALUES)


def test_every_placeholder_is_declared(spec):
    issued = set()
    for method in spec["device"]["setup"]["methods"]:
        issued |= set(method.get("issues_credentials") or {})
    for name, command in spec["commands"].items():
        params = set(command.get("parameters") or {})
        texts = [command.get("path", ""), command.get("body", "")]
        texts += list((command.get("headers") or {}).values())
        for text in texts:
            for placeholder in PLACEHOLDER.findall(text):
                assert placeholder in params, (name, placeholder)
        for param in (command.get("parameters") or {}).values():
            source = param.get("source", "")
            if source.startswith("credential:"):
                assert source.split(":", 1)[1] in issued
    ws_path = spec["websocket"]["connect"]["path"]
    assert set(PLACEHOLDER.findall(ws_path)) == {"access_token"} <= issued


def test_a_password_with_json_metacharacters_still_renders(spec):
    command = spec["commands"]["get_token"]
    tricky = 'Pa"ss\\word-12!'
    out = json.loads(render(command["body"], command["parameters"], {"password": tricky}))
    assert out == {"username": "admin", "password": tricky, "grant_type": "password"}


def test_the_token_comes_from_the_login_reply(spec):
    setup = spec["device"]["setup"]["methods"][0]
    issued = setup["issues_credentials"]["access_token"]
    assert issued["command"] == "get_token"
    token_endpoint = next(e for e in spec["http_endpoints"] if e["path"] == "/auth/token")
    reply = json.loads(token_endpoint["response_body"]["example"])
    token = reply[issued["reply_path"]]
    payload = token.split(".")[1]
    payload += "=" * (-len(payload) % 4)
    assert "exp" in json.loads(base64.urlsafe_b64decode(payload))
    assert spec["auth_schemes"]["bearer"]["headers"]["Authorization"] == "Bearer {access_token}"


def test_event_ports_follow_the_generation(spec):
    connect = spec["websocket"]["connect"]
    assert (connect["port"], connect["fallback"]["port"]) == (9090, 8080)
    assert spec["device"]["identification"]["default_port"] == 8080
    probes = {
        v["model"]: v["identification"]["state_probe"]["value_contains"]["controllerType"]
        for v in spec["device"]["variants"]
    }
    assert probes == {"SHC 1 (Classic)": "Classic", "SHC 2": "Avatar"}


def resolve(document, path: str):
    for part in path.split("."):
        if not isinstance(document, dict) or part not in document:
            return None
        document = document[part]
    return document


def test_status_sensors_read_both_generations(spec):
    shc1 = json.loads(next(e for e in spec["http_endpoints"] if e["path"] == "/status")
                      ["response_body"]["example"])
    shc2 = json.loads(spec["payload_formats"]["StatusReply"]["example"])
    assert shc1["controllerType"] == "Classic" and shc2["controllerType"] == "Avatar"
    for entity in spec["entities"]:
        mapping = entity["state_mapping"]
        for reply in (shc1, shc2):
            value = resolve(reply, mapping["value"])
            if value is None and "value_fallback" in mapping:
                value = resolve(reply, mapping["value_fallback"]["path"])
            assert value is not None, (entity["name"], reply)


def test_payload_examples_parse_and_carry_their_fields(spec):
    formats = spec["payload_formats"]
    for fmt in formats.values():
        json.loads(fmt["example"])
    for name in ("ErrorReply", "ActionReply", "ActionRequest", "Event"):
        example = json.loads(formats[name]["example"])
        required = {f["name"] for f in formats[name]["fields"]} - {"messages", "data"}
        assert required <= set(example), name
    for name in ("DeviceList", "CapabilityList", "MessageList"):
        example = json.loads(formats[name]["example"])
        assert isinstance(example, list) and example, name
        names = {f["name"] for f in formats[name]["fields"]}
        present = set().union(*(set(item) for item in example))
        assert names <= present, (name, names - present)


def test_error_codes_drive_token_refresh(spec):
    codes = {int(k) for k in spec["payload_formats"]["ErrorReply"]["values"]}
    assert {2003, 2007, 2009} <= codes
    example = json.loads(spec["payload_formats"]["ErrorReply"]["example"])
    assert example["errorcode"] == 2007


def test_an_event_maps_onto_a_known_capability_property(spec):
    formats = spec["payload_formats"]
    event = json.loads(formats["Event"]["example"])
    assert event["type"] == "StateChanged"
    capability_id = event["source"].removeprefix("/capability/")
    capabilities = json.loads(formats["CapabilityList"]["example"])
    assert capability_id in {c["id"] for c in capabilities}
    known = {f["name"] for f in formats["CapabilityState"]["fields"]}
    assert set(event["properties"]) <= known
    switch_on = json.loads(spec["commands"]["switch_on"]["example_body"])
    assert switch_on["target"] == event["source"]
    assert set(switch_on["params"]) <= known
