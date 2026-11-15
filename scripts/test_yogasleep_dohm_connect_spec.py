# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Proves the Dohm Connect spec's frames follow its own grammar.

`device-specs/devices/yogasleep-dohm-connect.yaml` says every command is
ASCII shaped `LETTER[,ID[,VALUE...]]$`, with a lowercase letter for a query
and an uppercase letter for a set, and that replies are `OK$`, `Failed NN$`,
an echo, or a typed report without the ID. This module transcribes that
grammar with the standard library and holds every command template, every
worked example and every reply format to it. It renders each template from
the example's parameters and checks the result byte for byte.

The frames upstream (martinemde/dohm-ble, docs/protocol.md) publishes are
pinned here too, with the ID swapped for the spec's invented one. That way
a spec that drifts from the wire fails here rather than against a machine.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
SPEC_PATH = REPO_ROOT / "device-specs" / "devices" / "yogasleep-dohm-connect.yaml"
SERVICE_UUID = "00005600-d102-11e1-9b23-00025b005aa5"
CHAR_UUID = "00005601-d102-11e1-9b23-00025b005aa5"
DEVICE_ID = "00532A"

# docs/protocol.md command table, transcribed with the invented ID in place of
# the one upstream prints, so this file carries no real unit's address.
UPSTREAM_FRAMES = {
    "get_device_id": "i$",
    "get_power": "m,00532A$",
    "power_on": "M,00532A,1$",
    "power_off": "M,00532A,0$",
    "get_speed": "s,00532A$",
    "set_speed": "S,00532A,3$",
    "get_name": "n,00532A$",
    "set_clock": "T,00532A,2133,2$",
    "get_schedule": "p,00532A,1$",
    "set_schedule_start": "P,00532A,1,1,2030$",
    "set_schedule_stop": "P,00532A,2,1,0730$",
    "set_schedule_days_speed": "P,00532A,3,1,7F,02$",
}

COMMAND_RE = re.compile(r"^(?P<letter>[A-Za-z])(?:,(?P<rest>[^,$]+(?:,[^,$]+)*))?\$$")
EXPERIMENTAL = {"get_clock_experimental", "set_device_id_experimental"}
QUERY_LETTERS = set("imnpst")
SET_LETTERS = set("MSNTPI")


def render(command: dict, params: dict) -> bytes:
    """Fill a template the way the schema says: ints are bytes, "{x}" is a parameter."""
    if "value" in command:
        return bytes(command["value"])
    out = bytearray()
    for item in command["template"]:
        if isinstance(item, int):
            out.append(item)
            continue
        name = item.strip("{}")
        spec = command["parameters"][name]
        value = params[name]
        if spec["type"] == "string":
            assert isinstance(value, str)
            assert "," not in value and "$" not in value, "no escaping exists"
            out += value.encode("ascii")
        elif spec["type"] == "uint8":
            assert spec["min"] <= value <= spec["max"], (name, value)
            out.append(value)
        else:
            raise AssertionError(f"unexpected parameter type {spec['type']}")
    return bytes(out)


def parse_command(frame: str) -> tuple[str, list[str]]:
    match = COMMAND_RE.fullmatch(frame)
    assert match, f"{frame!r} is not LETTER[,ID[,VALUE...]]$"
    rest = match.group("rest")
    return match.group("letter"), rest.split(",") if rest else []


def parse_reply(text: str):
    assert text.endswith("$"), text
    body = text[:-1]
    if body == "OK":
        return ("ack",)
    if body.startswith("Failed "):
        code = body[len("Failed "):]
        assert re.fullmatch(r"[0-9]{2}", code), text
        return ("failed", code)
    letter, _, rest = body.partition(",")
    if letter == "I":
        assert re.fullmatch(r"[^,$]+", rest)
        return ("id", rest)
    if letter == "M":
        assert rest in ("0", "1"), text
        return ("power", rest == "1")
    if letter == "S":
        assert re.fullmatch(r"[0-9]{2}", rest), text
        speed = int(rest)
        assert 1 <= speed <= 10
        return ("speed", speed)
    if letter == "N":
        return ("name", rest)
    if letter == "P":
        slot, start, stop, days, speed = rest.split(",")
        assert 1 <= int(slot) <= 3
        for hhmm in (start, stop):
            assert re.fullmatch(r"[0-9]{4}", hhmm)
            assert int(hhmm[:2]) < 24 and int(hhmm[2:]) < 60
        assert re.fullmatch(r"[0-9A-F]{2}", days) and int(days, 16) <= 0x7F
        assert re.fullmatch(r"[0-9]{2}", speed) and 0 <= int(speed) <= 10
        return ("schedule", int(slot), start, stop, int(days, 16), int(speed))
    raise AssertionError(f"unknown reply {text!r}")


@pytest.fixture(scope="module")
def spec() -> dict:
    return yaml.safe_load(SPEC_PATH.read_text())


@pytest.fixture(scope="module")
def commands(spec) -> dict:
    (service,) = spec["services"]
    (char,) = service["characteristics"]
    return char["commands"]


@pytest.fixture(scope="module")
def examples(spec) -> dict:
    return spec["protocol_details"]["examples"]


def test_one_service_one_write_notify_characteristic(spec):
    (service,) = spec["services"]
    assert service["uuid"] == SERVICE_UUID
    (char,) = service["characteristics"]
    assert char["uuid"] == CHAR_UUID
    assert set(char["properties"]) == {"write", "notify"}
    assert "read" not in char["properties"]


def test_every_uuid_in_the_spec_is_lowercase():
    text = SPEC_PATH.read_text()
    uuids = re.findall(r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}", text)
    assert uuids
    assert all(u == u.lower() for u in uuids)


def test_every_command_has_an_example(commands, examples):
    covered = {entry.get("command", name) for name, entry in examples.items()}
    assert covered == set(commands)
    for name in examples:
        assert examples[name].get("command", name) in commands


def test_templates_render_the_examples(commands, examples):
    for name, entry in examples.items():
        command = commands[entry.get("command", name)]
        assert render(command, entry["params"]) == entry["frame"].encode("ascii"), name


def test_every_example_frame_follows_the_grammar(commands, examples):
    for name, entry in examples.items():
        command_name = entry.get("command", name)
        letter, fields = parse_command(entry["frame"])
        if command_name == "get_device_id":
            assert (letter, fields) == ("i", [])
            continue
        assert fields[0] == DEVICE_ID, f"{name}: ID must be the invented one"
        if command_name.startswith("get_"):
            assert letter in QUERY_LETTERS and letter.islower(), name
        else:
            assert letter in SET_LETTERS and letter.isupper(), name
            assert len(fields) >= 2, f"{name}: a set carries a value"


def test_example_replies_parse(examples):
    for entry in examples.values():
        if "reply" in entry:
            parse_reply(entry["reply"])
    assert parse_reply(examples["get_device_id"]["reply"]) == ("id", DEVICE_ID)
    assert parse_reply(examples["set_speed_out_of_range"]["reply"]) == ("failed", "03")
    assert parse_reply(examples["get_schedule"]["reply"]) == ("schedule", 1, "2030", "0730", 0x7F, 2)


def test_payload_format_examples_parse(spec):
    formats = spec["payload_formats"]
    for name, fmt in formats.items():
        if name == "Echo":
            continue
        parse_reply(fmt["example"])
    assert parse_reply(formats["PowerReport"]["example"]) == ("power", True)
    assert parse_reply(formats["SpeedReport"]["example"]) == ("speed", 2)


def test_upstream_frames_match_with_the_id_swapped(commands, examples):
    by_command = {}
    for name, entry in examples.items():
        by_command.setdefault(entry.get("command", name), []).append(entry["frame"])
    for command_name, frame in UPSTREAM_FRAMES.items():
        assert frame in by_command[command_name], command_name


def test_every_id_parameter_comes_from_the_stored_credential(commands):
    for name, command in commands.items():
        params = command.get("parameters") or {}
        if name == "get_device_id":
            assert "value" in command and not params
            continue
        assert params["device_id"]["source"] == "credential:device_id", name
        assert params["device_id"]["description"].strip()
        # The ID always sits right after the letter and its comma.
        assert command["template"][1:3] == [0x2C, "{device_id}"], name


def test_template_references_are_declared(commands):
    for name, command in commands.items():
        if "template" not in command:
            continue
        refs = {i.strip("{}") for i in command["template"] if isinstance(i, str)}
        assert refs == set(command["parameters"]), name
        for item in command["template"]:
            if isinstance(item, int):
                assert 0x20 <= item <= 0x7E, f"{name}: non-printable literal {item:#x}"
        assert command["template"][-1] == 0x24, f"{name}: must end with $"


def test_ascii_digit_parameters_label_every_value(commands):
    weekday = commands["set_clock"]["parameters"]["weekday"]
    assert (weekday["min"], weekday["max"]) == (ord("1"), ord("7"))
    assert len(weekday["labels"]) == 7 and weekday["labels"][0] == "Monday"
    slot = commands["get_schedule"]["parameters"]["slot"]
    assert (slot["min"], slot["max"]) == (ord("1"), ord("3"))
    assert len(slot["labels"]) == 3


def test_schedule_writes_put_the_selector_before_the_slot(commands):
    for selector, name in enumerate(
        ("set_schedule_start", "set_schedule_stop", "set_schedule_days_speed"), start=1
    ):
        template = commands[name]["template"]
        assert template[:5] == [0x50, 0x2C, "{device_id}", 0x2C, ord(str(selector))]
        assert template[5:7] == [0x2C, "{slot}"]


def test_experimental_commands_are_marked_unproven(commands):
    for name in EXPERIMENTAL:
        assert commands[name]["verification"] == "hypothesis"
        assert "observed" not in commands[name]
    assert commands["set_device_id_experimental"]["advanced"] is True
    for name in set(commands) - EXPERIMENTAL:
        assert commands[name]["verification"] == "reported", name


def test_power_switch_binds_the_on_off_commands(spec):
    (switch,) = [e for e in spec["entities"] if e["platform"] == "switch"]
    assert switch["commands"] == {"turn_on": "power_on", "turn_off": "power_off"}
    assert switch["state_characteristic"] == CHAR_UUID


def test_no_lan_address_and_no_full_mac_other_than_the_documentation_range():
    text = SPEC_PATH.read_text()
    # Version strings such as 1.0.7.0 look like IPv4; only private ranges leak.
    private = r"\b(?:10|192\.168|172\.(?:1[6-9]|2\d|3[01]))(?:\.\d{1,3}){2,3}\b"
    assert not re.search(private, text)
    macs = re.findall(r"\b[0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){5}\b", text)
    assert all(m.lower().startswith("00:00:5e:00:53:") for m in macs), macs


def test_device_id_is_the_documentation_mac_suffix():
    mac = "00:00:5e:00:53:2a"
    assert mac.replace(":", "")[-6:].upper() == DEVICE_ID


def test_spec_status(spec):
    device = spec["device"]
    assert device["testing"]["status"] == "untested"
    assert device["manufacturer_status"] == "active"
    assert device["setup"]["factory_reset"]["applicable"] == "unknown"
    assert device["pairing"]["bonding"] == "required"


def test_initialization_subscribes_then_asks_for_the_device_id(spec):
    steps = spec["initialization"]
    uuid = "00005601-d102-11e1-9b23-00025b005aa5"
    assert steps[0] == {**steps[0], "characteristic": uuid, "subscribe": True}
    assert steps[1]["characteristic"] == uuid
    assert bytes(steps[1]["write"]) == b"i$"
