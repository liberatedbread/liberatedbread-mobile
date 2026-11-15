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
    strip = commands["set_strip_color_temperature"]["parameters"]["mireds"]
    assert (strip["min"], strip["max"], strip["unit"]) == (153, 285, "mired")
    # Both white-point controls take native mireds; the body must carry the
    # number unconverted, not a Kelvin value.
    for name, mireds in (("set_color_temperature", 221), ("set_strip_color_temperature", 200)):
        body = render(commands[name], mireds=mireds)
        assert body == {"lights": [{"temperature": mireds}]}, name


def test_cct_state_mapping_reads_its_documented_shape(spec):
    entity = next(e for e in spec["entities"] if e.get("variants") == ["CCT"])
    reply = {"numberOfLights": 1, "lights": [{"on": 1, "brightness": 43, "temperature": 221}]}
    mapping = entity["state_mapping"]
    assert lookup(reply, mapping["is_on"]) == 1
    assert lookup(reply, mapping["brightness"]) == 43
    assert lookup(reply, mapping["color_temperature"]) == 221
    assert entity["commands"]["set_color_temperature"] == "set_color_temperature"


def test_hsv_and_scene_controls_cannot_be_confused(spec):
    hsv = next(e for e in spec["entities"] if e["name"] == "Light Strip")
    scene = next(e for e in spec["entities"] if e["name"] == "Light Strip Scene")
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


# Example replies, one dict per device: command name -> JSON reply (None for
# a 404). Shapes follow python-elgato's test fixtures and the spec's own
# endpoint descriptions; identifiers are invented.
KEY_LIGHT_SETTINGS = {
    "powerOnBehavior": 1,
    "powerOnBrightness": 20,
    "powerOnTemperature": 213,
    "switchOnDurationMs": 100,
    "switchOffDurationMs": 300,
    "colorChangeDurationMs": 100,
}
STRIP_SETTINGS = {
    "powerOnBehavior": 2,
    "powerOnHue": 40.0,
    "powerOnSaturation": 15.0,
    "powerOnBrightness": 40,
    "powerOnTemperature": 0,
    "switchOnDurationMs": 150,
    "switchOffDurationMs": 400,
    "colorChangeDurationMs": 150,
}
STRIP_INFO = {"productName": "Elgato Light Strip", "hardwareBoardType": 70, "serialNumber": "<serial>"}
KEY_LIGHT_INFO = {"productName": "Elgato Key Light", "hardwareBoardType": 53, "serialNumber": "<serial>"}

DEVICES = {
    "cct_key_light": (
        {
            "get_lights": {"numberOfLights": 1, "lights": [{"on": 1, "brightness": 21, "temperature": 297}]},
            "get_light_settings": KEY_LIGHT_SETTINGS,
            "get_accessory_info": KEY_LIGHT_INFO,
            "get_battery_info": None,
        },
        {"CCT"},
    ),
    "strip_colour_mode": (
        {
            "get_lights": {"numberOfLights": 1, "lights": [{"on": 1, "hue": 358.0, "saturation": 6.0, "brightness": 50}]},
            "get_light_settings": STRIP_SETTINGS,
            "get_accessory_info": STRIP_INFO,
            "get_battery_info": None,
        },
        {"Strip"},
    ),
    "strip_white_mode": (
        {
            # Same shape as the Key Light's reply: the case the old lights-only
            # probe misread as a white-only light with a 143-344 range.
            "get_lights": {"numberOfLights": 1, "lights": [{"on": 1, "brightness": 21, "temperature": 200}]},
            "get_light_settings": STRIP_SETTINGS,
            "get_accessory_info": STRIP_INFO,
            "get_battery_info": None,
        },
        {"Strip"},
    ),
    "strip_running_scene": (
        {
            "get_lights": {
                "numberOfLights": 1,
                "lights": [{"on": 1, "brightness": 60.5, "id": "scene-id", "name": "Scene", "scene": [], "numberOfSceneElements": 0}],
            },
            "get_light_settings": STRIP_SETTINGS,
            "get_accessory_info": {**STRIP_INFO, "productName": "Elgato Light Strip Pro"},
            "get_battery_info": None,
        },
        {"Strip"},
    ),
    "key_light_mini_on_battery": (
        {
            "get_lights": {"numberOfLights": 1, "lights": [{"on": 1, "brightness": 20, "temperature": 230}]},
            "get_light_settings": {**KEY_LIGHT_SETTINGS, "battery": {"bypass": 0}},
            "get_accessory_info": {**KEY_LIGHT_INFO, "productName": "Elgato Key Light Mini"},
            "get_battery_info": {"powerSource": 2, "level": 11.4, "status": 0},
        },
        {"CCT", "Battery"},
    ),
}


def has_path(document: object, path: str) -> bool:
    try:
        lookup(document, path)
    except (KeyError, IndexError, TypeError):
        return False
    return True


def probe_matches(probe: dict, replies: dict) -> bool:
    """Apply a state_probe as the schema defines it: all conditions AND."""
    reply = replies[probe["command"]]
    if reply is None:
        return False
    if not all(has_path(reply, path) for path in probe.get("keys_present", [])):
        return False
    if any(has_path(reply, path) for path in probe.get("keys_absent", [])):
        return False
    for path, needle in probe.get("value_contains", {}).items():
        if not has_path(reply, path) or needle not in str(lookup(reply, path)):
            return False
    return True


@pytest.mark.parametrize("device", sorted(DEVICES))
def test_variant_probes_pick_exactly_the_intended_variants(spec, device):
    replies, expected = DEVICES[device]
    matched = {
        variant["model"]
        for variant in spec["device"]["variants"]
        if probe_matches(variant["identification"]["state_probe"], replies)
    }
    assert matched == expected


def test_strip_in_white_mode_binds_the_strip_range(spec):
    strip = next(e for e in spec["entities"] if e["name"] == "Light Strip")
    assert strip["variants"] == ["Strip"]
    command = spec["commands"][strip["commands"]["set_color_temperature"]]
    assert command["parameters"]["mireds"]["max"] == 285
    reply = DEVICES["strip_white_mode"][0]["get_lights"]
    assert lookup(reply, strip["state_mapping"]["color_temperature"]) == 200


def test_firmware_source_names_the_public_host(spec):
    image = spec["features"][0]["dfu"]["image"]
    assert image["source"] == "public_url"
    assert "https://gc-updates.elgato.com/" in image["notes"]


def test_obfuscated_provisioning_is_not_called_encrypted(spec):
    credentials = spec["device"]["setup"]["credentials"]
    assert credentials["wifi_passphrase_protection"] == "plaintext"


def test_strip_white_brightness_keeps_the_white_point(spec: dict) -> None:
    """A brightness write in white mode must carry the temperature, or the strip turns colour."""
    commands = spec["commands"]
    cmd = commands["set_strip_white_brightness"]
    rendered = render(cmd, brightness=50, mireds=200)
    assert rendered == json.loads(cmd["example_body"])
    assert set(rendered["lights"][0]) == {"brightness", "temperature"}
    strip = commands["set_strip_color_temperature"]["parameters"]["mireds"]
    assert cmd["parameters"]["mireds"]["min"] == strip["min"]
    assert cmd["parameters"]["mireds"]["max"] == strip["max"]
