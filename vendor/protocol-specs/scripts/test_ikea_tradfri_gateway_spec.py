# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Holds the TRÅDFRI gateway spec's CoAP commands to the published payloads.

`device-specs/devices/ikea-tradfri-gateway.yaml` declares every control as a
CoAP request whose `body` is a JSON template. This module renders each
template with nothing but the standard library, checks that it parses, that
it agrees with the command's own `example_body`, and that the key numbers it
uses mean what the community clients say they mean. The payload shapes in
PUBLISHED are the ones the glenndehaan/ikea-tradfri-coap-docs walk-through
and pytradfri send (the blind stop is node-tradfri-client's `0`; pytradfri
writes `true`), so a spec that drifts from the wire fails here rather
than at a lamp.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
SPEC_PATH = REPO_ROOT / "device-specs" / "devices" / "ikea-tradfri-gateway.yaml"
PLACEHOLDER = re.compile(r"\{([A-Za-z0-9_]+)\}")

# Resource and key numbers as pytradfri's const.py and node-tradfri-client
# name them. The spec must use these and only these for the roles below.
ROOTS = {"devices": "15001", "groups": "15004", "moods": "15005", "gateway": "15011"}
KIND_LIGHT, KIND_OUTLET, KIND_BLIND = "3311", "3312", "15015"
ON_OFF, DIMMER, MIREDS = "5850", "5851", "5711"
COLOR_HEX, COLOR_X, COLOR_Y = "5706", "5709", "5710"
TRANSITION, BLIND_POSITION, BLIND_TRIGGER = "5712", "5536", "5523"
SCENE, IDENTITY, COMMISSIONING = "9039", "9090", "9061"

# command -> (rendering arguments, the document a published client sends)
PUBLISHED = {
    "request_psk": ({"identity": "pytradfri"}, {IDENTITY: "pytradfri"}),
    "light_set_brightness": ({"brightness": 127}, {KIND_LIGHT: [{DIMMER: 127}]}),
    "light_turn_on": ({}, {KIND_LIGHT: [{ON_OFF: 1}]}),
    "light_set_color_temperature": ({"mireds": 250}, {KIND_LIGHT: [{MIREDS: 250}]}),
    "light_set_color_xy": (
        {"x": 65535, "y": 65535},
        {KIND_LIGHT: [{COLOR_X: 65535, COLOR_Y: 65535}]},
    ),
    "light_set_color_hex": ({"hex": "efd275"}, {KIND_LIGHT: [{COLOR_HEX: "efd275"}]}),
    "light_set_brightness_transition": (
        {"brightness": 254, "transition": 10},
        {KIND_LIGHT: [{DIMMER: 254, TRANSITION: 10}]},
    ),
    "outlet_turn_on": ({}, {KIND_OUTLET: [{ON_OFF: 1}]}),
    "blind_set_position": ({"position": 0}, {KIND_BLIND: [{BLIND_POSITION: 0}]}),
    "blind_stop": ({}, {KIND_BLIND: [{BLIND_TRIGGER: 0}]}),
    "group_turn_on": ({}, {ON_OFF: 1}),
    "group_activate_scene": ({"scene_id": 196621}, {ON_OFF: 1, SCENE: 196621}),
    "set_commissioning_mode": ({"seconds": 60}, {COMMISSIONING: 60}),
}

PATHS = {
    "request_psk": ("POST", "/15011/9063"),
    "get_gateway_info": ("GET", "/15011/15012"),
    "list_devices": ("GET", "/15001"),
    "get_device": ("GET", "/15001/{id}"),
    "list_groups": ("GET", "/15004"),
    "get_group": ("GET", "/15004/{id}"),
    "list_scenes": ("GET", "/15005/{group_id}"),
    "reboot_gateway": ("POST", "/15011/9030"),
    "factory_reset": ("POST", "/15011/9031"),
}


def render(template: str, values: dict, parameters: dict) -> str:
    """Substitute placeholders the way the schema describes: by declared type."""

    def fill(match: re.Match) -> str:
        name = match.group(1)
        value = values[name]
        if parameters[name]["type"] == "string":
            return str(value)  # the template already supplies the quotes
        return json.dumps(value)

    return PLACEHOLDER.sub(fill, template)


@pytest.fixture(scope="module")
def spec() -> dict:
    return yaml.safe_load(SPEC_PATH.read_text(encoding="utf-8"))


@pytest.fixture(scope="module")
def commands(spec) -> dict:
    return spec["commands"]


def test_every_command_is_an_addressable_coap_request(commands):
    for name, command in commands.items():
        assert command.get("transport") == "coap", name
        assert command.get("method") in {"GET", "PUT", "POST"}, name
        path = command.get("path", "")
        assert path.startswith("/"), name
        declared = set(command.get("parameters") or {})
        used = set(PLACEHOLDER.findall(path)) | set(
            PLACEHOLDER.findall(command.get("body", ""))
        )
        assert used == declared, f"{name}: uses {sorted(used)}, declares {sorted(declared)}"


@pytest.mark.parametrize("name", sorted(PATHS))
def test_resource_paths_match_the_clients(commands, name):
    method, path = PATHS[name]
    assert (commands[name]["method"], commands[name]["path"]) == (method, path)


@pytest.mark.parametrize("name", sorted(PUBLISHED))
def test_bodies_render_to_the_published_payloads(commands, name):
    values, expected = PUBLISHED[name]
    command = commands[name]
    rendered = render(command["body"], values, command.get("parameters") or {})
    assert json.loads(rendered) == expected


def _shape(document):
    """Keys and nesting with the leaf values thrown away."""
    if isinstance(document, dict):
        return {k: _shape(v) for k, v in document.items()}
    if isinstance(document, list):
        return [_shape(v) for v in document]
    return None


def test_every_body_agrees_with_its_example(commands):
    seen = 0
    for name, command in commands.items():
        body = command.get("body")
        if body is None:
            continue
        assert command["method"] in {"PUT", "POST"}, f"{name}: a GET carries no body"
        parameters = command.get("parameters") or {}
        dummy = {p: ("x" if v["type"] == "string" else 1) for p, v in parameters.items()}
        rendered = json.loads(render(body, dummy, parameters))
        if not PLACEHOLDER.search(body):
            continue
        example = json.loads(command["example_body"])
        assert _shape(example) == _shape(rendered), name
        seen += 1
    assert seen >= 8


def test_device_writes_wrap_state_in_a_one_element_kind_array(commands):
    for name, command in commands.items():
        if command["method"] != "PUT" or not command["path"].startswith("/15001/"):
            continue
        values = {
            p: ("f1e0b5" if spec_p["type"] == "string" else 1)
            for p, spec_p in (command.get("parameters") or {}).items()
        }
        document = json.loads(render(command["body"], values, command.get("parameters") or {}))
        assert len(document) == 1, name
        (kind, array), = document.items()
        assert kind in {KIND_LIGHT, KIND_OUTLET, KIND_BLIND}, name
        assert isinstance(array, list) and len(array) == 1, name


def test_group_writes_are_flat(commands):
    for name, command in commands.items():
        if command["method"] == "PUT" and command["path"].startswith("/15004/"):
            parameters = command.get("parameters") or {}
            document = json.loads(
                render(command["body"], {p: 1 for p in parameters}, parameters)
            )
            assert not {KIND_LIGHT, KIND_OUTLET, KIND_BLIND} & set(document), name


def test_ranges_match_the_clients(commands):
    def bounds(command, parameter):
        p = commands[command]["parameters"][parameter]
        return p["min"], p["max"]

    assert bounds("light_set_brightness", "brightness") == (0, 254)
    assert bounds("light_set_color_temperature", "mireds") == (250, 454)
    assert bounds("light_set_color_xy", "x") == (0, 65535)
    assert bounds("blind_set_position", "position") == (0, 100)


def test_entities_read_the_same_keys_the_commands_write(spec):
    by_name = {e["name"]: e for e in spec["entities"]}
    light = by_name["TRÅDFRI Light"]["state_mapping"]
    assert light == {"is_on": f"{KIND_LIGHT}[0].{ON_OFF}", "brightness": f"{KIND_LIGHT}[0].{DIMMER}"}
    assert by_name["TRÅDFRI Control Outlet"]["state_mapping"]["is_on"] == f"{KIND_OUTLET}[0].{ON_OFF}"
    assert by_name["TRÅDFRI Blind"]["state_mapping"]["value"] == f"{KIND_BLIND}[0].{BLIND_POSITION}"


def test_published_examples_parse(spec):
    for fmt in spec["payload_formats"].values():
        if "example" in fmt:
            json.loads(fmt["example"])


def test_no_real_secret_or_address_in_the_spec():
    text = SPEC_PATH.read_text(encoding="utf-8")
    assert "<psk>" in text and "<security-code>" in text
    assert not re.search(r"\b(?:\d{1,3}\.){3}\d{1,3}\b", text)


def test_blind_position_encodes_percent_open_as_percent_closed(commands):
    """A percent-open UI value must reach the wire as percent closed."""
    command = commands["blind_set_position"]
    parameter = command["parameters"]["position"]
    scale, offset = parameter["scale"], parameter["value_offset"]

    def encode(percent_open: float) -> int:
        return round((percent_open - offset) / scale)

    assert encode(75) == 25
    assert encode(100) == parameter["min"]  # fully open
    assert encode(0) == parameter["max"]  # fully closed
    rendered = render(command["body"], {"position": encode(75)}, command["parameters"])
    assert rendered == command["example_body"]


def test_the_cover_reads_percent_closed_but_sets_percent_open(spec, commands):
    """The two directions differ, and only the notes can say so: the state is
    the raw wire value while the set command's parameter already inverts. A
    client that inverts both ways sends 75 % open as 75 % closed."""
    cover = next(e for e in spec["entities"] if e["platform"] == "cover")
    assert "scale" not in cover and "value_offset" not in cover
    assert cover["commands"]["set_cover_position"] == "blind_set_position"
    parameter = commands["blind_set_position"]["parameters"]["position"]
    assert (parameter["scale"], parameter["value_offset"]) == (-1, 100)
    notes = " ".join(cover["notes"].split())
    assert "RAW percent closed" in notes and "must not invert it a second time" in notes


def test_discovery_narrows_the_generic_coap_service_type(spec):
    """`_coap._udp` is every CoAP device on the link; the schema requires a
    TXT condition on a shared service type, in both places it lives."""
    ident = spec["device"]["identification"]
    method = next(m for m in spec["device"]["discovery"]["methods"] if m["type"] == "mdns")
    assert ident["mdns_service_type"] == method["mdns"]["service_type"] == "_coap._udp.local."
    wanted = [{"key": "version", "match": "present"}]
    assert ident["mdns_txt_match"] == wanted
    assert [{k: c[k] for k in ("key", "match")} for c in method["mdns"]["txt_match"]] == wanted


def test_the_enrolment_identity_is_a_stored_credential(spec, commands):
    stage = next(
        stage
        for method in spec["device"]["setup"]["methods"]
        for stage in method.get("stages") or []
        if "issues_credentials" in stage
    )
    assert {"identity", "psk"} <= set(stage["issues_credentials"])
    assert commands["request_psk"]["parameters"]["identity"]["source"] == "credential:identity"
