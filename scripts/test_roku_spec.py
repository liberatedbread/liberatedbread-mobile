# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Proves the Roku spec's control surface can be driven from the spec alone.

`device-specs/devices/roku-ecp.yaml` declares a remote as `button` entities
over HTTP commands. This module transcribes the consumer's side of that
contract — resolve a role to a command, render the command to a request —
and holds the spec to it, the same way its sibling `test_wemo_spec.py` holds
the Wemo SOAP surface honest.

Everything here reads the YAML and the standard library, nothing else. If a
button cannot be rendered into the exact request the official ECP document
publishes, the spec is underspecified and this fails.
"""

from __future__ import annotations

from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
SPEC_PATH = REPO_ROOT / "device-specs" / "devices" / "roku-ecp.yaml"

# The keypress vocabulary from the official ECP documentation (see
# device.openness.upstream_docs), spelled as the wire wants each key. The
# standard keys every device accepts, then the TV-class keys. This list is the
# test's own transcription of the doc, so a spec that drifts from the wire
# spelling fails here rather than on a television.
STANDARD_KEYS = {
    "Home",
    "Rev",
    "Fwd",
    "Play",
    "Select",
    "Left",
    "Right",
    "Down",
    "Up",
    "Back",
    "InstantReplay",
    "Info",
    "Backspace",
    "Search",
    "Enter",
    "FindRemote",
}
TV_KEYS = {
    "VolumeUp",
    "VolumeDown",
    "VolumeMute",
    "PowerOn",
    "PowerOff",
    "ChannelUp",
    "ChannelDown",
    "InputTuner",
    "InputHDMI1",
    "InputHDMI2",
    "InputHDMI3",
    "InputHDMI4",
    "InputAV1",
}

# What the official Roku app's remote exposes as buttons, as keys. The
# app-parity claim the entities block makes is exactly this set: everything on
# the app's remote surface that is a single ECP keypress. Backspace/Enter/Lit_
# are the app's keyboard, not buttons, and voice is not ECP at all.
APP_REMOTE_KEYS = (STANDARD_KEYS | TV_KEYS) - {"Backspace", "Enter"}


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


# ── Reference implementation, transcribed from the spec ──────────────────────


def render_request(command: dict, values: dict | None = None) -> tuple[str, str]:
    """(method, path) for a command, per ecp_common.request_format.

    The transcription is nearly nothing, which is the point the spec makes:
    the whole request is the method and the path (placeholders substituted
    from the caller's values), with an empty body.
    """
    assert command.get("transport") == "http"
    path = command["path"]
    for name, value in (values or {}).items():
        path = path.replace("{" + name + "}", str(value))
    return command["method"], path


def user_parameters(command: dict) -> list[str]:
    """Parameters the caller supplies: neither defaulted nor read back."""
    return [
        name
        for name, parameter in (command.get("parameters") or {}).items()
        if "default" not in parameter and "source" not in parameter
    ]


def read_source(document: str, source: dict) -> list[tuple[str | None, str]]:
    """(value, label) pairs per the options_source/state_source contract.

    Transcribed from the schema's own words: every element whose local name
    equals `item`, anywhere in the document; the attribute named by `value`
    is the raw value; the element's trimmed text is the label. The value is
    None when the attribute is absent — the home-screen case a state reader
    must treat as "no option is current".
    """
    import xml.etree.ElementTree as ET

    root = ET.fromstring(document)
    out = []
    for element in root.iter():
        if element.tag.rpartition("}")[2] != source["item"]:
            continue
        out.append((element.get(source["value"]), (element.text or "").strip()))
    return out


# ── Control: entities resolve, commands render ───────────────────────────────


def test_every_entity_binding_resolves(entities, commands):
    """A role map names a command; a name that resolves nowhere is a dead
    control drawn on screen."""
    for entity in entities:
        for role, command_name in (entity.get("commands") or {}).items():
            assert command_name in commands, (
                f"{entity['name']}: {role} binds {command_name!r}, which "
                "`commands` does not declare"
            )


def test_buttons_bind_exactly_the_press_role(entities):
    """A button is momentary: one role, `press`, and no state binding.

    The schema excuses `button` from naming a state source because a keypress
    has none; this holds the entities to the other half of that bargain — no
    state keys smuggled in, and no second role a consumer would have to
    invent semantics for.
    """
    buttons = [e for e in entities if e["platform"] == "button"]
    assert buttons, "the remote is the point of this spec"
    for entity in buttons:
        assert list(entity.get("commands") or {}) == ["press"], (
            f"{entity['name']}: a button binds exactly the `press` role"
        )
        stateful = {"state_topic", "state_endpoint", "state_command", "state_mapping"}
        assert not stateful & set(entity), f"{entity['name']}: a button has no state to read"


def test_press_commands_are_sendable_from_nothing(entities, commands):
    """`press` is a fixed role: the command must have no caller-supplied
    blanks, because a button has nothing to fill one with."""
    for entity in entities:
        for role, command_name in (entity.get("commands") or {}).items():
            if role != "press":
                continue
            blanks = user_parameters(commands[command_name])
            assert not blanks, (
                f"{entity['name']}: press binds {command_name}, which still needs {blanks}"
            )


def test_commands_render_the_documented_requests(commands):
    """Every press command renders to POST /keypress/<key> with a key the
    official vocabulary spells exactly that way; the one non-keypress
    command is the launcher, checked by its own test."""
    for name, command in commands.items():
        if user_parameters(command):
            continue
        method, path = render_request(command)
        assert method == "POST", f"{name}: keypresses are POSTs"
        prefix, _, key = path.rpartition("/")
        assert prefix == "/keypress", f"{name}: {path} is not a keypress"
        assert key in STANDARD_KEYS | TV_KEYS, f"{name}: {key!r} is not a documented ECP key"


def test_every_command_names_a_documented_action(commands, endpoints):
    """A command is an invocation of a catalogued endpoint; `action` is the
    join, and it must land on an endpoint that still exists."""
    for name, command in commands.items():
        action = command.get("action")
        assert action in endpoints, f"{name}: action {action!r} names no `http_endpoints` entry"
        assert endpoints[action].get("status") != "sunset", (
            f"{name}: {action} is sunset; a control must not be built on it"
        )
        assert command.get("verification"), f"{name}: does not say how well it is known"


def test_the_remote_covers_the_official_apps_buttons(entities, commands):
    """The app-parity claim, executable: every key the official app's remote
    surface sends is a button here, and nothing else is."""
    exposed = {
        render_request(commands[entity["commands"]["press"]])[1].rpartition("/")[2]
        for entity in entities
        if entity["platform"] == "button"
    }
    missing = APP_REMOTE_KEYS - exposed
    assert not missing, f"remote keys the app has and this spec does not: {sorted(missing)}"
    extra = exposed - APP_REMOTE_KEYS
    assert not extra, f"buttons for keys the app's remote does not send: {sorted(extra)}"


def test_button_names_are_unique(entities):
    """Two controls with one name are indistinguishable on screen and in a
    consumer's send-in-flight bookkeeping, which keys on the name."""
    names = [e["name"] for e in entities]
    assert len(names) == len(set(names))


def test_sunset_endpoints_stay_out_of_the_vocabulary(spec):
    """The search-browse sunset is recorded as data, so a consumer can filter
    on it instead of parsing SUNSET out of prose."""
    sunset = [
        endpoint["name"]
        for endpoint in spec["http_endpoints"]
        if endpoint.get("status") == "sunset"
    ]
    assert "Search Browse" in sunset


# ── The channel launcher ─────────────────────────────────────────────────────


@pytest.fixture(scope="module")
def channel(entities) -> dict:
    picks = [e for e in entities if e["name"] == "Channel"]
    assert picks, "the spec declares the Channel select"
    return picks[0]


def test_the_launcher_select_is_whole(channel, commands, endpoints):
    """Dynamic options, a state source, and a launch command that takes
    exactly the one value an option carries."""
    command = commands[channel["commands"]["select_option"]]
    blanks = user_parameters(command)
    assert blanks == ["app_id"], "a single control supplies one value"
    method, path = render_request(command, {"app_id": "12"})
    assert (method, path) == ("POST", "/launch/12")

    # Both sources name real, living GET endpoints — a source pointing at a
    # sunset or write endpoint would be a list that can never load.
    for key in ("options_source", "state_source"):
        source = channel[key]
        endpoint = endpoints[source["command"]]
        assert endpoint["method"] == "GET", f"{key}: options are read, not sent"
        assert endpoint.get("status") != "sunset", f"{key}: names a dead endpoint"


def test_the_sources_read_the_published_examples(channel, endpoints):
    """The contract, run against the spec's own example documents: the
    Installed Apps example yields launchable options, the Active App example
    yields a current value that matches one of them."""
    options = read_source(
        endpoints["Installed Apps"]["response_body"]["example"],
        channel["options_source"],
    )
    assert ("12", "Netflix") in options
    assert all(value is not None for value, _ in options), (
        "every documented app carries a launchable id"
    )

    current = read_source(
        endpoints["Active App"]["response_body"]["example"],
        channel["state_source"],
    )
    assert current, "the example names a foreground app"
    assert current[0][0] in {value for value, _ in options}, (
        "the current channel is one of the installed ones"
    )


def test_the_gate_lists_name_real_endpoints_and_do_not_overlap(spec, endpoints):
    """The "Control by mobile apps" gate, as data a consumer can filter on.

    It does not split along command/query lines — keypresses and three
    queries are gated while launching and the app queries stay open — so a
    client that treats "command" as a proxy for "gated" both suppresses a
    working launcher and mishandles a 403 from a query. These lists are the
    machine-readable form of that, and this holds them to naming real,
    non-overlapping endpoints.
    """
    gating = spec["ecp_common"]["response_format"]["gating"]
    gated, open_ = set(gating["gated"]), set(gating["open"])

    assert gated <= set(endpoints), f"gated names no such endpoint: {gated - set(endpoints)}"
    assert open_ <= set(endpoints), f"open names no such endpoint: {open_ - set(endpoints)}"
    assert not gated & open_, "an endpoint cannot be both gated and open"

    # The claim the launcher depends on, stated once and asserted here: the
    # endpoints it uses are all on the open side.
    for name in ("Installed Apps", "Active App", "Launch App"):
        assert name in open_, f"the channel launcher needs {name} to be open"

    # Every live endpoint is classified. A new one landing unclassified is
    # exactly how this block would rot back into prose.
    live = {
        endpoint["name"]
        for endpoint in spec["http_endpoints"]
        if endpoint.get("status") != "sunset"
    }
    assert live == gated | open_, f"unclassified endpoints: {live - (gated | open_)}"


def test_the_home_screen_reads_as_no_current_channel(channel):
    """The documented edge: on the home screen the app element has no id.

    The schema says a missing value attribute is 'no option is current';
    this holds the transcription to it, because the tempting bug is to
    treat the attribute as required and throw on the one screen every Roku
    spends most of its life on."""
    home = "<active-app><app>Roku</app></active-app>"
    current = read_source(home, channel["state_source"])
    assert current == [(None, "Roku")]
