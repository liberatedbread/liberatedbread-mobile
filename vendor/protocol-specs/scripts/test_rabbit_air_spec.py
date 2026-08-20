# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Proves the Rabbit Air spec can be driven from the spec alone.

`device-specs/devices/rabbit-air-purifier.yaml` declares the purifier's
control surface as network entities over `udp` commands whose `body` carries
the static envelope fields, and documents the minified-JSON envelope and the
AES-128-CBC cipher (random IV appended) the `rabbit_air_lan` protocol handler
uses. This module transcribes the consumer's side of that contract —
rendering a command body into the {id, cmd, ts, data} envelope, encrypting
and decrypting a datagram, and decoding a cmd-4 state reply — straight from
the YAML, and holds the spec to it. It is the sibling of
`test_kasa_spec.py` (tcp-json) for the raw-UDP JSON transport.

If the envelope the spec's example_exchange shows does not fall out of the
documented construction, or the crypto the spec documents cannot round-trip a
rendered command, the spec is underspecified and this fails.

Hermetic: no network, no hardware. Key and IV below are documentation values,
exactly as the spec's example_exchange declares its own to be.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest
import yaml
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

REPO_ROOT = Path(__file__).resolve().parent.parent
SPEC_PATH = REPO_ROOT / "device-specs" / "devices" / "rabbit-air-purifier.yaml"

# Documentation-only credentials. A real user key is a per-device secret the
# owner reads out of the vendor app; this one encrypts nothing real.
DOC_KEY = bytes(range(16))
DOC_IV = bytes(range(16, 32))


@pytest.fixture(scope="module")
def spec() -> dict:
    return yaml.safe_load(SPEC_PATH.read_text(encoding="utf-8"))


@pytest.fixture(scope="module")
def protocol(spec) -> dict:
    return spec["rabbit_air_protocol"]


@pytest.fixture(scope="module")
def commands(spec) -> dict:
    return spec["commands"]


@pytest.fixture(scope="module")
def entities(spec) -> list:
    return spec["entities"]


# ── Reference implementation, transcribed from the spec ──────────────────────


def render_envelope(body: str, request_id: int, ts: int) -> str:
    """Wrap a command body into the request envelope per client_rendering.

    The body carries the static fields (`cmd`, plus `data` when the command
    writes state); the renderer supplies the runtime `id` and `ts`. Field
    order is the one example_exchange shows — id, cmd, ts, data (data last,
    omitted when the body has none) — serialized as minified JSON.
    """
    static = json.loads(body)
    envelope = {"id": request_id, "cmd": static["cmd"], "ts": ts}
    if "data" in static:
        envelope["data"] = static["data"]
    return json.dumps(envelope, separators=(",", ":"))


def pkcs7_pad(plaintext: bytes) -> bytes:
    pad = 16 - len(plaintext) % 16
    return plaintext + bytes([pad]) * pad


def pkcs7_unpad(padded: bytes) -> bytes:
    pad = padded[-1]
    assert 1 <= pad <= 16, "PKCS7 padding length out of range"
    assert padded[-pad:] == bytes([pad]) * pad, "PKCS7 padding bytes corrupted"
    return padded[:-pad]


def encrypt_datagram(plaintext: bytes, key: bytes, iv: bytes) -> bytes:
    """AES-128-CBC with PKCS7, IV APPENDED — the spec's `encryption` block:
    the datagram is ciphertext || IV."""
    assert len(key) == 16 and len(iv) == 16
    encryptor = Cipher(algorithms.AES128(key), modes.CBC(iv)).encryptor()
    ciphertext = encryptor.update(pkcs7_pad(plaintext)) + encryptor.finalize()
    return ciphertext + iv


def decrypt_datagram(datagram: bytes, key: bytes) -> bytes:
    """IV = msg[-16:], ciphertext = msg[:-16] — the spec's own words."""
    iv, ciphertext = datagram[-16:], datagram[:-16]
    assert ciphertext and len(ciphertext) % 16 == 0
    decryptor = Cipher(algorithms.AES128(key), modes.CBC(iv)).decryptor()
    return pkcs7_unpad(decryptor.update(ciphertext) + decryptor.finalize())


def user_parameters(command: dict) -> list[str]:
    """Parameters the caller supplies: neither defaulted nor read back."""
    return [
        name
        for name, parameter in (command.get("parameters") or {}).items()
        if "default" not in parameter and "source" not in parameter
    ]


def substitute(body: str, command: dict, values: dict[str, str]) -> str:
    """Fill the declared `{parameter}` placeholders in a body — the rule the
    app's JSON-body renderer (kasa.rs) already implements and the
    rabbit_air_lan handler mirrors: declared parameters only, never a brace
    scan, because JSON is made of braces."""
    out = body
    for name in (command.get("parameters") or {}):
        out = out.replace("{" + name + "}", values[name])
    return out


def sample_body(command: dict) -> str:
    """The body with every caller parameter filled by a documentation value
    (first enum entry, else the declared minimum). A parameterized body is a
    template, not JSON; this is the renderable form of it."""
    values = {}
    for name in user_parameters(command):
        parameter = command["parameters"][name]
        if "enum" in parameter:
            values[name] = str(parameter["enum"][0])
        else:
            values[name] = str(int(parameter.get("min", 0)))
    return substitute(command["body"], command, values)


# ── The commands block is renderable ─────────────────────────────────────────


def test_every_command_is_a_udp_message_with_a_static_body(commands):
    """The contract the rabbit_air_lan handler is keyed on: transport udp, and
    a body that parses as JSON carrying ONLY static envelope fields — an `id`
    or `ts` frozen into a body would replay one nonce and one stale timestamp
    forever, which is exactly what client_rendering forbids."""
    for name, command in commands.items():
        assert command["transport"] == "udp", f"{name}: not a udp command"
        static = json.loads(sample_body(command))
        assert isinstance(static["cmd"], int), f"{name}: body carries no cmd"
        assert set(static) <= {"cmd", "data"}, (
            f"{name}: body must carry only static fields, found {sorted(static)}"
        )


def test_command_bodies_cover_the_documented_command_ids(commands, protocol):
    """Every cmd the protocol block documents has a command that sends it, and
    every body's cmd is one the protocol block names."""
    documented = {entry["cmd"] for entry in protocol["commands"]}
    sent = {json.loads(sample_body(c))["cmd"] for c in commands.values()}
    assert documented == {4, 9, 255}
    assert sent == documented


def test_envelope_construction_reproduces_the_example_exchange(commands, protocol):
    """Body + runtime id/ts, in envelope field order, minified — must equal the
    plaintexts example_exchange publishes, byte for byte."""
    example = protocol["example_exchange"]
    assert (
        render_envelope(commands["time_sync"]["body"], 1234567, 1700000000)
        == example["time_sync_request_plaintext"]
    )
    assert (
        render_envelope(commands["get_state"]["body"], 1234568, 1700000123)
        == example["state_get_request_plaintext"]
    )
    assert (
        render_envelope(commands["turn_on"]["body"], 1234569, 1700000124)
        == example["state_set_power_on_plaintext"]
    )


# ── The crypto reproduces the documented construction ────────────────────────


def test_encryption_block_documents_the_algorithm_this_implements(protocol):
    """The implementation above is only honest if the spec actually says
    AES-128-CBC, PKCS7, 16-byte key, appended IV — pin those words."""
    encryption = protocol["encryption"]
    assert encryption["algorithm"] == "AES-128-CBC, PKCS7 padding"
    assert "16-byte user key" in encryption["key"]
    assert "APPENDED as the last 16 bytes" in encryption["iv"]
    assert protocol["transport"]["udp"]["port"] == 9009


def test_datagram_layout_is_ciphertext_then_iv(commands):
    """A rendered datagram's last 16 bytes are the IV it was encrypted under,
    and the ciphertext before them is a whole number of AES blocks."""
    for name, command in commands.items():
        envelope = render_envelope(sample_body(command), request_id=1, ts=1700000000)
        datagram = encrypt_datagram(envelope.encode(), DOC_KEY, DOC_IV)
        assert datagram[-16:] == DOC_IV, f"{name}: IV is not the appended tail"
        assert (len(datagram) - 16) % 16 == 0
        assert len(datagram) - 16 >= 16, f"{name}: no ciphertext at all"


def test_every_command_round_trips_through_the_cipher(commands):
    """decrypt(encrypt(render(x))) == render(x) — the full send path, from the
    YAML body to the datagram and back."""
    for command in commands.values():
        envelope = render_envelope(sample_body(command), request_id=2, ts=1700000100)
        datagram = encrypt_datagram(envelope.encode(), DOC_KEY, DOC_IV)
        assert decrypt_datagram(datagram, DOC_KEY).decode() == envelope


def test_pkcs7_adds_a_full_block_on_block_aligned_plaintext():
    """A 32-byte plaintext pads to 48 bytes of ciphertext — the padding rule a
    decryptor depends on when the message happens to be block-aligned."""
    padded = pkcs7_pad(b"x" * 32)
    assert len(padded) == 48 and padded[-16:] == b"\x10" * 16
    assert pkcs7_unpad(padded) == b"x" * 32


# ── Parameterized commands substitute cleanly ────────────────────────────────


def test_set_mode_and_set_speed_take_exactly_one_caller_value(commands):
    """A select/number control fills exactly one blank; two blanks would not
    know which one the user's value belongs in."""
    assert user_parameters(commands["set_mode"]) == ["mode"]
    assert user_parameters(commands["set_speed"]) == ["speed"]
    for name in ("get_state", "time_sync", "get_info", "turn_on", "turn_off"):
        assert not user_parameters(commands[name]), (
            f"{name} must be sendable with no caller-supplied parameters"
        )


def test_parameterized_examples_render_from_the_declared_parameters(commands):
    """Substituting a value into the body must produce the example_body the
    spec publishes — and valid JSON, since a body that is not JSON could never
    be sent."""
    cases = {
        "set_mode": {"mode": "2"},
        "set_speed": {"speed": "3"},
    }
    for name, values in cases.items():
        command = commands[name]
        rendered = substitute(command["body"], command, values)
        assert rendered == command["example_body"]
        assert json.loads(rendered)


def test_set_speed_bounds_match_the_entity_range(commands, entities):
    """The command's parameter bounds and the number entity's min/max must
    agree, or the slider would offer values the command disclaims."""
    speed = commands["set_speed"]["parameters"]["speed"]
    number = next(e for e in entities if e["platform"] == "number")
    assert (number["min"], number["max"], number["step"]) == (1, 5, 1)
    assert (speed["min"], speed["max"]) == (number["min"], number["max"])


# ── Entities bind real commands and decode the state reply ───────────────────


def test_every_entity_reads_through_get_state(entities, commands):
    """state_command must name a declared command — a binding that resolves
    nowhere is a dead control drawn on screen."""
    for entity in entities:
        assert entity["state_command"] == "get_state"
        assert entity["state_command"] in commands
        for role, command_name in (entity.get("commands") or {}).items():
            assert command_name in commands, (
                f"{entity['name']}: {role} binds {command_name!r}, undeclared"
            )


def test_every_state_field_is_one_get_state_returns(entities, commands):
    """The field an entity reads must be one get_state says it returns —
    otherwise the poll and the decode disagree about what comes back. Paths
    are relative to the reply's data object (value "power" = data.power)."""
    returned = {r["name"] for r in commands["get_state"]["returns"]}
    for entity in entities:
        field = entity["state_mapping"]["value"]
        assert "." not in field, f"{entity['name']}: paths root at the data object"
        assert field in returned, f"{entity['name']}: {field} not in get_state returns"


def test_state_reply_decodes_through_the_state_mappings(entities, commands):
    """A fabricated cmd-4 reply's data object decodes to each entity's reading
    through its own state_mapping: booleans read directly (no on_when — the
    wire speaks boolean), the mode select through its options table."""
    data = {"power": True, "mode": 1, "speed": 3, "quality": 2,
            "ionizer": False, "lock": False, "filter_life": 2400, "rssi": -57}
    returned = {r["name"] for r in commands["get_state"]["returns"]}
    assert set(data) <= returned
    by_name = {e["name"]: e for e in entities}
    assert data[by_name["Power"]["state_mapping"]["value"]] is True
    mode = by_name["Mode"]["state_mapping"]
    assert mode["options"][data[mode["value"]]] == "Pollen"
    speed = by_name["Fan Speed"]["state_mapping"]
    assert by_name["Fan Speed"]["min"] <= data[speed["value"]] <= by_name["Fan Speed"]["max"]
    quality = by_name["Air Quality"]["state_mapping"]
    assert data[quality["value"]] in quality["options"]
