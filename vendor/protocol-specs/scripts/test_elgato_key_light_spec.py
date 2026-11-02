# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Checks the Elgato classic-HTTP spec against its own worked examples.

The JSON path reader is a small independent transcription of the spec's
`state_mapping` notation. It proves that the documented CCT, HSV, scene and
battery replies select the entities and values the spec says they do.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
SPEC_PATH = REPO_ROOT / "device-specs" / "devices" / "elgato-key-light.yaml"
PLACEHOLDER = re.compile(r"\{([A-Za-z0-9_]+)\}")


@pytest.fixture(scope="module")
def spec() -> dict:
    return yaml.safe_load(SPEC_PATH.read_text(encoding="utf-8"))


def render(command: dict, **values: object) -> dict:
    body = command["body"]
    for name in PLACEHOLDER.findall(body):
        body = body.replace("{" + name + "}", str(values[name]))
    return json.loads(body)


def lookup(document: object, path: str) -> object:
    """Resolve dotted keys and numeric brackets as state_mapping describes."""
    current = document
    for part in path.split("."):
        match = re.fullmatch(r"([^\[]+)(?:\[(\d+)\])?", part)
        assert match, path
        key, index = match.groups()
        current = current[key]
        if index is not None:
            current = current[int(index)]
    return current


def test_discovery_requires_elgato_and_excludes_mutual_tls(spec):
    conditions = spec["device"]["identification"]["mdns_txt_match"]
    by_key = {condition["key"]: condition for condition in conditions}
    assert by_key["mf"]["value"] == "Elgato"
    assert by_key["tls"]["match"] == "absent"
    assert "value" not in by_key["tls"]
    assert spec["device"]["identification"]["default_port"] == 9123


def test_cct_commands_render_the_published_examples(spec):
    commands = spec["commands"]
    assert render(commands["turn_on"]) == json.loads(commands["turn_on"]["example_body"])
    assert render(commands["turn_off"]) == json.loads(commands["turn_off"]["example_body"])
    assert render(commands["set_brightness"], brightness=50) == json.loads(
        commands["set_brightness"]["example_body"]
    )
    assert render(commands["set_color_temperature"], mireds=221) == json.loads(
        commands["set_color_temperature"]["example_body"]
    )
    assert render(commands["set_hsv"], hue=200, saturation=100) == json.loads(
        commands["set_hsv"]["example_body"]
    )


def test_control_units_and_ranges_are_native(spec):
    commands = spec["commands"]
    brightness = commands["set_brightness"]["parameters"]["brightness"]
    assert (brightness["min"], brightness["max"], brightness["unit"]) == (3, 100, "%")
    temperature = commands["set_color_temperature"]["parameters"]["mireds"]
    assert (temperature["min"], temperature["max"], temperature["unit"]) == (143, 344, "mired")
    assert "kelvin" not in temperature["description"].lower() or "mired" in temperature["description"].lower()


def test_cct_state_mapping_reads_its_documented_shape(spec):
    entity = next(e for e in spec["entities"] if e.get("variants") == ["CCT"])
    reply = {"numberOfLights": 1, "lights": [{"on": 1, "brightness": 43, "temperature": 221}]}
    mapping = entity["state_mapping"]
    assert lookup(reply, mapping["is_on"]) == 1
    assert lookup(reply, mapping["brightness"]) == 43
    assert lookup(reply, mapping["color_temperature"]) == 221
    assert entity["commands"]["set_color_temperature"] == "set_color_temperature"


def test_hsv_and_scene_controls_cannot_be_confused(spec):
    hsv = next(e for e in spec["entities"] if e.get("variants") == ["HSV"])
    scene = next(e for e in spec["entities"] if e.get("variants") == ["Scene"])
    hsv_reply = {"lights": [{"on": 1, "hue": 200.0, "saturation": 100.0, "brightness": 50}]}
    assert lookup(hsv_reply, hsv["state_mapping"]["hue"]) == 200.0
    assert lookup(hsv_reply, hsv["state_mapping"]["saturation"]) == 100.0
    assert "set_color" not in hsv["commands"]
    assert "commands" not in scene, "a bare write would destroy the running scene"


def test_battery_probe_and_reading_are_scoped_to_the_mini(spec):
    entity = next(e for e in spec["entities"] if e["name"] == "Battery")
    assert entity["variants"] == ["Battery"]
    assert entity["state_command"] == "get_battery_info"
    assert entity["unit"] == "%"
    reply = {"powerSource": 1, "level": 96.05, "status": 2, "currentBatteryVoltage": 4007}
    assert lookup(reply, entity["state_mapping"]["value"]) == 96.05


def test_variant_probes_resolve_to_real_read_commands(spec):
    commands = spec["commands"]
    for variant in spec["device"]["variants"]:
        probe = variant["identification"]["state_probe"]
        command = commands[probe["command"]]
        assert command["method"] == "GET"
        assert command["transport"] == "http"


def test_firmware_upload_is_advanced_and_signed(spec):
    dfu = spec["features"][0]["dfu"]
    assert dfu["image"]["signing"] == "signed"
    assert dfu["image"]["algorithm"] == "ed25519"
    endpoint = next(e for e in spec["http_endpoints"] if e["name"] == dfu["endpoint"])
    assert endpoint["advanced"] is True
    assert endpoint["advanced_reason"]
