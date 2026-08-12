"""Proves the Hue Bridge spec can be implemented from the spec alone.

`device-specs/devices/hue-bridge.yaml` claims to be sufficient on its own for
the three things a hub client does — **pair** with the bridge, **enumerate**
the lights behind it, and **drive** one of them. This module is how that claim
is kept honest, the way `test_hue_spec.py`'s sibling `test_wemo_spec.py` keeps
the Wemo spec honest for SOAP.

Everything below is a **transcription of what the YAML says**, importing
nothing but the standard library. Each function cites the spec path it came
from. If a transcription cannot be written, or does not reproduce the spec's
own published examples, the spec is underspecified and this fails.

There is no supported client surface here. The mobile app's Rust core is the
real consumer; a second Python client from us would be a worse copy. The spec
is the contribution, and this file is its test — the transcriptions exist to
prove the document is complete, not to be used.

The spec exercises the P12 vocabulary (see
docs/contributing/spec-evolution.md#p12): `method` beside `path`, the
`credential:` and `instance:` parameter sources, and an `instances:` entity
stamped out per light. The tests here are therefore also the executable
statement of what those keys mean.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
SPEC_PATH = REPO_ROOT / "device-specs" / "devices" / "hue-bridge.yaml"

PLACEHOLDER = re.compile(r"^\{(.+)\}$")
PATH_PLACEHOLDER = re.compile(r"\{([^{}/]+)\}")


@pytest.fixture(scope="module")
def spec() -> dict:
    return yaml.safe_load(SPEC_PATH.read_text(encoding="utf-8"))


@pytest.fixture(scope="module")
def commands(spec) -> dict:
    return spec["commands"]


@pytest.fixture(scope="module")
def entities(spec) -> list:
    return spec["entities"]


@pytest.fixture(scope="module")
def endpoints(spec) -> dict:
    return {endpoint["name"]: endpoint for endpoint in spec["http_endpoints"]}


@pytest.fixture(scope="module")
def light_entity(entities) -> dict:
    lights = [e for e in entities if e.get("instances")]
    assert len(lights) == 1, "expected exactly one instanced entity (Hue Light)"
    return lights[0]


# ── Reference implementation, transcribed from the spec ──────────────────────
#
# The whole client-side procedure the `commands` block documents for
# `transport: http`: coerce each substituted value by its declared parameter
# type, fill `{name}` placeholders in the path and the arguments, and render
# the arguments as compact JSON in declared order (the canon
# commands.create_user.example_notes states). A placeholder with no value
# must FAIL the send — `source` parameters carry no default on purpose.


def coerce(parameter: dict, value: object) -> object:
    """A substituted value renders as the TYPE the parameter declares.

    commands.light_set_brightness.example_notes: bri is an integer, so it
    renders as a JSON number, never a quoted string.
    """
    declared = parameter.get("type", "string")
    if declared == "integer":
        return int(value)
    if declared == "number":
        return float(value)
    if declared == "boolean":
        return bool(value)
    return str(value)


def render_command(command: dict, values: dict | None = None) -> tuple[str, str, str | None]:
    """Render one http command to (method, path, body) from the spec alone."""
    supplied = dict(values or {})
    parameters = command.get("parameters") or {}
    for name, parameter in parameters.items():
        if name not in supplied and "default" in parameter:
            supplied[name] = parameter["default"]

    def resolve(name: str) -> object:
        # A `source` parameter with no value is a failed send, visibly —
        # the contract schema.json states for all three source schemes.
        if name not in supplied:
            raise KeyError(f"unfilled parameter {name!r}")
        return coerce(parameters.get(name, {}), supplied[name])

    path = PATH_PLACEHOLDER.sub(lambda m: str(resolve(m.group(1))), command["path"])

    body = None
    if command.get("arguments"):
        rendered = {}
        for name, template in command["arguments"].items():
            match = PLACEHOLDER.match(str(template)) if isinstance(template, str) else None
            rendered[name] = resolve(match.group(1)) if match else template
        body = json.dumps(rendered, separators=(",", ":"))
    return command["method"], path, body


def user_parameters(command: dict) -> list[str]:
    """Parameters the caller supplies: neither defaulted nor sourced."""
    return [
        name
        for name, parameter in (command.get("parameters") or {}).items()
        if "default" not in parameter and "source" not in parameter
    ]


def walk(obj: object, dotted: str) -> object:
    """Resolve a state_mapping / label_path dotted path inside a JSON object."""
    for part in dotted.split("."):
        obj = obj[part]
    return obj


def read_children(lights_reply: dict, entity: dict) -> dict[str, dict]:
    """Stamp the instanced entity out per child, per its `instances` block.

    The reply to state_command is an object keyed by instance id; each
    state_mapping path resolves INSIDE one child's object, and label_path
    names the child for the human.
    """
    instances = entity["instances"]
    children = {}
    for instance_id, child in lights_reply.items():
        reading = {
            role: walk(child, dotted)
            for role, dotted in entity["state_mapping"].items()
        }
        label = walk(child, instances["label_path"]) if instances.get("label_path") else instance_id
        children[instance_id] = {"label": label, **reading}
    return children


# ── Pairing ──────────────────────────────────────────────────────────────────


def test_create_user_renders_its_published_example(commands):
    """The pairing request, byte for byte, from the spec's own example."""
    method, path, body = render_command(
        commands["create_user"], {"devicetype": "opengreeniot#hub"}
    )
    assert method == "POST"
    assert path == "/api"
    assert body == commands["create_user"]["example_body"].strip()


def test_pairing_envelopes_parse_under_the_documented_rules(spec, endpoints):
    """Both pre- and post-press replies are published and machine-readable.

    payload_formats.V1Envelope carries the pre-press (error 101) envelope;
    the Create User endpoint's response example carries the post-press
    success. A pairing client polls until the first becomes the second.
    """
    envelope = json.loads(spec["payload_formats"]["V1Envelope"]["example"])
    assert envelope[0]["error"]["type"] == 101, (
        "V1Envelope's example must be the keep-polling signal itself"
    )

    success = json.loads(endpoints["Create User"]["response_body"]["example"])
    credentials = success[0]["success"]
    assert len(credentials["username"]) >= 20, "username example is not credential-shaped"
    assert re.fullmatch(r"[0-9A-F]{32}", credentials["clientkey"]), (
        "clientkey is documented as 32 hex chars (16-byte DTLS PSK)"
    )


def test_create_user_asks_for_the_clientkey_unconditionally(commands):
    """generateclientkey is only honoured at creation time, so it is a literal.

    A username created without it can never get a clientkey later; the spec
    encodes that by making it a decided argument, not a caller option.
    """
    assert commands["create_user"]["arguments"]["generateclientkey"] is True


# ── Driving a light ──────────────────────────────────────────────────────────


def test_light_commands_render_their_published_examples(commands):
    """Each light write reproduces its example_body, and its path shape."""
    values = {"username": "testuser", "id": "1", "bri": 200}
    for name in ("light_turn_on", "light_turn_off", "light_set_brightness"):
        method, path, body = render_command(commands[name], values)
        assert method == "PUT", name
        assert path == "/api/testuser/lights/1/state", name
        assert body == commands[name]["example_body"].strip(), name


def test_brightness_renders_as_a_number_not_a_string(commands):
    """The typed-coercion rule, checked against the failure it prevents."""
    _, _, body = render_command(
        commands["light_set_brightness"], {"username": "u", "id": "1", "bri": 200}
    )
    assert json.loads(body)["bri"] == 200
    assert '"200"' not in body, "bri must be a JSON number; a quoted bri is rejected"


def test_unpaired_send_fails_visibly(commands):
    """A missing credential: source must fail the send, not improvise.

    The schema's contract for every source scheme: no default, and a
    renderer holding no value fails visibly. An unpaired client erroring
    here is correct behaviour.
    """
    with pytest.raises(KeyError):
        render_command(commands["light_turn_on"], {"id": "1"})
    with pytest.raises(KeyError):
        render_command(commands["light_turn_on"], {"username": "u"})


def test_brightness_bounds_are_the_devices_own(commands):
    """1–254, not 0–255 — the ends of the obvious range are both wrong."""
    bri = commands["light_set_brightness"]["parameters"]["bri"]
    assert (bri["min"], bri["max"]) == (1, 254)


def test_set_brightness_carries_on_true(commands):
    """A bare bri to an off light answers error 201; the spec sends both."""
    arguments = commands["light_set_brightness"]["arguments"]
    assert arguments["on"] is True, (
        "light_set_brightness must carry \"on\": true beside bri"
    )


# ── The instanced entity ─────────────────────────────────────────────────────


def test_children_recover_from_the_lights_example(light_entity, endpoints):
    """Enumeration, labels and per-child state from one documented reply.

    This is the whole `instances:` contract executed: the Lights example is
    an object keyed by id, and walking it with the entity's own
    state_mapping and label_path yields every child's reading with no
    per-device code.
    """
    reply = json.loads(endpoints[light_entity["state_command"]]["response_body"]["example"])
    children = read_children(reply, light_entity)

    assert sorted(children) == ["1", "2"]
    assert children["1"] == {"label": "Kitchen counter", "is_on": True, "brightness": 254}
    assert children["2"] == {"label": "Hallway", "is_on": False, "brightness": 77}


def test_every_entity_binding_resolves(light_entity, commands, endpoints):
    """A name that resolves to nothing is a control the user cannot use."""
    assert light_entity["state_command"] in endpoints, (
        "state_command names no http_endpoints entry"
    )
    for role, command_name in light_entity["commands"].items():
        assert command_name in commands, (
            f"role {role!r} binds {command_name!r}, which the `commands` "
            "block does not declare"
        )


def test_role_commands_are_sendable(light_entity, commands):
    """Fixed roles need no caller value; set_brightness owns exactly one."""
    for role, command_name in light_entity["commands"].items():
        blanks = user_parameters(commands[command_name])
        if role in ("turn_on", "turn_off"):
            assert not blanks, f"{role} binds {command_name}, which still needs {blanks}"
        else:
            assert len(blanks) == 1, (
                f"{role} binds {command_name}; a single-value control can fill "
                f"exactly one blank, not {blanks}"
            )


def test_instance_key_is_the_coupling_it_claims_to_be(light_entity, commands):
    """instances.keyed_by must be the `instance:` source the commands name.

    schema.json calls the shared name the coupling; this is the check that
    keeps the two spellings from drifting apart.
    """
    keyed_by = light_entity["instances"]["keyed_by"]
    for command_name in light_entity["commands"].values():
        sources = {
            parameter.get("source")
            for parameter in (commands[command_name].get("parameters") or {}).values()
        }
        assert f"instance:{keyed_by}" in sources, (
            f"{command_name} does not substitute the id the entity enumerates by"
        )


# ── Cross-block agreement ────────────────────────────────────────────────────


def test_every_command_is_executable_and_weighted(commands):
    """transport http needs method + path; every command states verification."""
    for name, command in commands.items():
        assert command["transport"] == "http", name
        assert command.get("method") in {"GET", "POST", "PUT", "DELETE", "PATCH"}, (
            f"{name}: an http command without a method is not sendable"
        )
        assert command.get("path"), f"{name}: an http command without a path is not sendable"
        assert command.get("verification"), f"{name}: does not say how well it is known"


def test_command_placeholders_and_parameters_agree(commands):
    """Every placeholder has a parameter; every parameter reaches the wire.

    Unlike SOAP, an http command's placeholders live in the path as well as
    the arguments — username and id never appear in a body at all.
    """
    for name, command in commands.items():
        declared = set(command.get("parameters") or {})
        referenced = set(PATH_PLACEHOLDER.findall(command["path"]))
        for value in (command.get("arguments") or {}).values():
            if isinstance(value, str):
                match = PLACEHOLDER.match(value)
                if match:
                    referenced.add(match.group(1))
        assert referenced == declared, (
            f"{name}: placeholders {sorted(referenced)} vs parameters "
            f"{sorted(declared)} — a blank nothing fills, or a parameter "
            "nothing substitutes"
        )


def test_command_paths_match_the_endpoints_that_document_them(commands, endpoints):
    """`commands` invokes; `http_endpoints` documents. They must agree."""
    documented = {(e["method"], e["path"]) for e in endpoints.values()}
    for name, command in commands.items():
        assert (command["method"], command["path"]) in documented, (
            f"{name}: {command['method']} {command['path']} is not documented "
            "as an endpoint"
        )


def test_bridgeid_is_the_mac_in_eui64_clothing(endpoints):
    """The identity rule a client leans on, checked against the config example.

    bridgeid is the MAC with FFFE spliced into the middle — the fact that
    lets a scanner match an mDNS TXT bridgeid to an ARP-table MAC, and the
    value the HTTPS certificate's CN must equal (lowercased).
    """
    config = json.loads(endpoints["Bridge Config"]["response_body"]["example"])
    mac_hex = config["mac"].replace(":", "").upper()
    assert config["bridgeid"] == mac_hex[:6] + "FFFE" + mac_hex[6:]
    assert re.fullmatch(r"[0-9A-F]{16}", config["bridgeid"])


def test_write_acknowledgement_is_not_mistakable_for_state(endpoints, light_entity):
    """The Set Light State reply is per-attribute acks, so read-back is real.

    If the ack ever looked like a light object, a client could be excused
    for treating it as state; this pins the shape that forbids that.
    """
    ack = json.loads(endpoints["Set Light State"]["response_body"]["example"])
    assert isinstance(ack, list)
    assert all("success" in element for element in ack)
    for element in ack:
        for role_path in light_entity["state_mapping"].values():
            assert role_path not in element["success"], (
                "the ack must not resemble a child object"
            )
