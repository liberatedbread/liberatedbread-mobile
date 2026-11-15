# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Holds the JuiceBox spec's frames to its own stated hash rule.

`device-specs/devices/enel-x-juicebox.yaml` says every status line and every
CMD reply ends in three base-35 characters computed from the ASCII payload
before '!': a 16-bit hash `h = (h ^ ((h << 5) + (h >> 2) + ord(c))) & 0xFFFF`
per character, reduced modulo 35^3 and written least-significant digit first
with the alphabet 0-9, A-N, Z (for digit 24, in place of O), P-Y. This module
transcribes that rule with nothing but the standard library and checks the
spec's own example lines, the two command bodies rendered from the spec's
worked examples, and a handful of CMD frames that juicepassproxy publishes
verbatim from captures of the real Enel X servers (CMD frames carry no unit
ID, so they identify no one). Three of those published frames hash above
35^3, which is what pins the three-character truncation as the protocol's
behaviour rather than a shortcut.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
SPEC_PATH = REPO_ROOT / "device-specs" / "devices" / "enel-x-juicebox.yaml"

ALPHABET = "0123456789ABCDEFGHIJKLMNZPQRSTUVWXY"  # digit 24 is Z; O never appears

# CMD frames as the real servers sent them, published in
# JuiceRescue/juicepassproxy test_message.py (Apache-2.0).
PUBLISHED_CMD = [
    "CMD41325A0040M040C006S638!5N5$",
    "CMD62210A20M18C006S006!31Y$",
    "CMD62228A20M15C008S048!IR4$",
    "CMD31353A0000M010C244S741!2B3$",  # hash 46937 >= 35^3
    "CMD41301A29M40C242S075!TJ5$",  # hash 49694 >= 35^3
    "CMD41302A40M40C006S082!KQL$",
]


def hash16(payload: str) -> int:
    h = 0
    for c in payload:
        h ^= (h << 5) + (h >> 2) + ord(c)
        h &= 0xFFFF
    return h


def base35_3(n: int) -> str:
    n %= 35**3
    out = ""
    for _ in range(3):
        n, digit = divmod(n, 35)
        out += ALPHABET[digit]
    return out


def crc(payload: str) -> str:
    return base35_3(hash16(payload))


def split_line(line: str) -> tuple[str, str]:
    """(payload, crc) of a hashed line; the terminator is ':' or '$'."""
    m = re.fullmatch(r"(?P<payload>[^!]*)!(?P<crc>[0-9A-Z]{3})[:$]", line)
    assert m, f"not a hashed JuiceNet line: {line!r}"
    return m.group("payload"), m.group("crc")


@pytest.fixture(scope="module")
def spec() -> dict:
    return yaml.safe_load(SPEC_PATH.read_text(encoding="utf-8"))


def test_alphabet_matches_the_spec_prose(spec):
    prose = spec["protocol_details"]["crc"]["algorithm"]
    assert "Z for digit 24" in prose
    assert "O" not in ALPHABET and ALPHABET[24] == "Z" and len(ALPHABET) == 35


def test_published_server_frames_hash_as_stated():
    truncated = 0
    for line in PUBLISHED_CMD:
        payload, want = split_line(line)
        assert line.endswith("$")
        assert crc(payload) == want, line
        truncated += hash16(payload) >= 35**3
    assert truncated >= 2, "the vectors must include hashes that need truncating"


def test_worked_example_in_the_spec(spec):
    example = spec["protocol_details"]["crc"]["worked_example"]
    assert "CMD31830A0016M040C006S001!RAS$" in example
    assert hash16("CMD31830A0016M040C006S001") == 34677
    assert "34677" in example
    assert crc("CMD31830A0016M040C006S001") == "RAS"


def test_payload_format_examples_carry_valid_hashes(spec):
    formats = spec["payload_formats"]
    for name in ("StatusMessage", "CommandMessage"):
        payload, want = split_line(formats[name]["example"])
        assert crc(payload) == want, name
    status = formats["StatusMessage"]["example"]
    assert status.endswith(":") and formats["CommandMessage"]["example"].endswith("$")
    # The unit ID is the invented one, 28 digits, and the version tag follows.
    assert re.match(r"^0910000000000000000000004242:v09u,", status)


def test_debug_example_has_no_hash(spec):
    example = spec["payload_formats"]["DebugMessage"]["example"]
    assert "!" not in example
    assert re.match(r"^[0-9]{28}:DBG,(NFO|WRN|ERR):", example)


def render(body: str, params: dict[str, str]) -> str:
    out = body
    for key, value in params.items():
        out = out.replace("{" + key + "}", value)
    assert "{" not in out, f"unfilled placeholder in {out!r}"
    return out


def test_command_bodies_render_to_their_examples(spec):
    commands = spec["commands"]

    online = commands["set_online_current"]
    payload = render(
        online["body"].split("!")[0],
        {"weekday": "3", "hhmm": "1830", "online_amps": "0016",
         "offline_amps": "040", "counter": "001"},
    )
    assert f"{payload}!{crc(payload)}$" == online["example_body"]

    offline = commands["set_offline_current"]
    payload = render(
        offline["body"].split("!")[0],
        {"weekday": "3", "hhmm": "1830", "online_amps": "0032",
         "offline_amps": "032", "counter": "003"},
    )
    assert f"{payload}!{crc(payload)}$" == offline["example_body"]


def test_command_templates_name_only_declared_parameters(spec):
    for name, command in spec["commands"].items():
        placeholders = set(re.findall(r"\{([a-z_]+)\}", command["body"]))
        assert placeholders <= set(command["parameters"]), name
        assert command["body"].startswith("CMD") and command["body"].endswith("!{crc}$"), name


def test_status_example_decodes_as_documented(spec):
    status = spec["payload_formats"]["StatusMessage"]
    payload, _ = split_line(status["example"])
    unit_id, rest = payload.split(":", 1)
    tokens = rest.split(status["delimiter"])
    assert tokens[0] == "v09u"
    fields = {t[0]: t[1:] for t in tokens[1:]}
    scale = {f["name"]: f.get("scale", 1) for f in status["fields"]}
    assert round(int(fields["V"]) * scale["V"], 1) == 240.0
    assert round(int(fields["A"]) * scale["A"], 1) == 16.1
    assert round(int(fields["f"]) * scale["f"], 2) == 59.90
    assert round(int(fields["p"]) * scale["p"], 3) == 0.996
    assert int(fields["S"]) == 2 and "2" in spec["payload_formats"]["StatusCode"]["values"]
    assert int(fields["e"]) == -1  # signed field
    assert int(fields["M"]) == 24 and int(fields["C"]) == 40 and int(fields["m"]) == 40
