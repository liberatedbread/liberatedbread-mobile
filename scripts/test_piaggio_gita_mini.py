"""Check the gitamini spec's documented command, chunk and ECDH framing."""

import hashlib
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
SPEC = yaml.safe_load(
    (ROOT / "device-specs" / "devices" / "piaggio-gita-mini.yaml").read_text(
        encoding="utf-8"
    )
)


def _secp256k1_add(left, right):
    if left is None:
        return right
    if right is None:
        return left
    prime = 2**256 - 2**32 - 977
    x1, y1 = left
    x2, y2 = right
    if x1 == x2 and (y1 != y2 or y1 == 0):
        return None
    if left == right:
        slope = (3 * x1 * x1) * pow(2 * y1, -1, prime)
    else:
        slope = (y2 - y1) * pow(x2 - x1, -1, prime)
    slope %= prime
    x3 = (slope * slope - x1 - x2) % prime
    return x3, (slope * (x1 - x3) - y1) % prime


def _secp256k1_multiply(scalar, point):
    result = None
    while scalar:
        if scalar & 1:
            result = _secp256k1_add(result, point)
        point = _secp256k1_add(point, point)
        scalar >>= 1
    assert result is not None
    return result


def _commands():
    return SPEC["services"][0]["characteristics"][1]["commands"]


def _no_data(opcode: int) -> list[int]:
    return [opcode, 0x7F, 0, 0, 0, 0, 0, 0, 0, 0]


def _chunk_layout():
    return SPEC["protocol_details"]["command_framing"]["chunk_layout"]


def _chunks(ciphertext: bytes) -> list[bytes]:
    layout = _chunk_layout()
    size = layout["ciphertext_bytes_per_chunk"]
    markers = layout["continuation_marker"]
    chunks = []
    for offset in range(0, len(ciphertext), size):
        part = ciphertext[offset : offset + size]
        last = offset + size >= len(ciphertext)
        chunks.append(part + bytes([markers["final" if last else "more"]]))
    return chunks


def test_no_data_command_frames():
    commands = _commands()
    expected = {
        "get_ap_list": 50,
        "get_ip_address": 53,
        "get_gita_version": 81,
        "get_gita_uptime": 86,
        "get_ota_status": 90,
        "lock_latch": 78,
        "unlock_latch": 79,
        "update_gita": 80,
        "download_new_software": 85,
    }
    for name, opcode in expected.items():
        assert commands[name]["value"] == _no_data(opcode)
        assert len(commands[name]["value"]) == 10


def test_wifi_join_payload_is_inside_encrypted_frame():
    command = _commands()["set_wifi_connection"]
    assert command["template"][:2] == [0x33, 0x7F]
    assert command["template"][2] == "{ssid_and_password}"
    assert command["advanced"] is True
    assert command["parameters"]["ssid_and_password"]["type"] == "string"


def test_chunk_layout_fits_mtu_and_matches_prose():
    layout = _chunk_layout()
    size = layout["ciphertext_bytes_per_chunk"]
    # One ATT write carries MTU - 3 bytes: the ciphertext piece plus its marker.
    assert size + 1 == layout["requested_mtu"] - 3
    assert layout["continuation_marker"] == {"more": 0, "final": 1}
    prose = SPEC["protocol_details"]["command_framing"]["chunking"]
    assert f"Request MTU {layout['requested_mtu']}." in prose
    assert f"{size}-byte pieces" in prose


def test_chunk_boundaries_and_final_markers():
    layout = _chunk_layout()
    size = layout["ciphertext_bytes_per_chunk"]
    markers = layout["continuation_marker"]
    ciphertext = bytes(range(200)) * 2
    chunks = _chunks(ciphertext)
    assert [len(chunk) for chunk in chunks] == [size + 1, size + 1, 400 - 2 * size + 1]
    assert [chunk[-1] for chunk in chunks] == [
        markers["more"],
        markers["more"],
        markers["final"],
    ]
    assert b"".join(chunk[:-1] for chunk in chunks) == ciphertext
    # A ciphertext that fills whole chunks still ends on a final marker.
    exact = _chunks(bytes(2 * size))
    assert [chunk[-1] for chunk in exact] == [markers["more"], markers["final"]]


def test_model_ids_and_gatt_map():
    device = SPEC["device"]
    assert device["identification"]["manufacturer_data"]["company_id"] == 2107
    assert device["identification"]["service_uuids"] == [
        "00009999-0000-1000-8000-00805f9b34fb"
    ]
    variants = {variant["model"]: variant for variant in device["variants"]}
    assert "model 2" in variants["gitamini"]["identification"]["manufacturer_data"][
        "description"
    ]
    assert "model 3" in variants["gita pro"]["identification"]["manufacturer_data"][
        "description"
    ]

    service = SPEC["services"][0]
    assert service["uuid"] == "87654321-1234-5678-1234-56789abcdef0"
    assert len(service["characteristics"]) == 11
    assert service["characteristics"][1]["role"] == "command"


def test_unknown_payload_opcodes_are_not_made_executable():
    commands = _commands()
    assert "connect_hidden_wifi" not in commands
    assert "connect_wifi" not in commands
    assert "activate_gita" not in commands
    assert "disable_ssh" not in commands


def test_session_initialization_orders_dependencies_before_auth():
    feedback = "87654321-1234-5678-1234-56789abcdef9"
    session_auth = "87654321-1234-5678-1234-56789abcdef1"
    session_key_exchange = "87654321-1234-5678-1234-56789abcdefb"
    initialization = SPEC["initialization"]
    positions = {
        item["characteristic"]: index for index, item in enumerate(initialization)
    }
    for auth in (session_auth, session_key_exchange):
        assert positions[feedback] < positions[auth]
    assert positions[session_key_exchange] < positions[session_auth]

    for method in SPEC["device"]["setup"]["methods"]:
        actions = [step["action"] for step in method["steps"]]
        subscribed = next(
            index for index, action in enumerate(actions) if "Subscribe" in action
        )
        for index, action in enumerate(actions):
            if index <= subscribed:
                continue
            if any(
                f"command {opcode}" in action
                for opcode in (8, 9, 60, 61, 62, 63, 68)
            ):
                assert subscribed < index, action


def test_saved_session_wire_exchange_and_success_gate():
    auth = SPEC["protocol_details"]["session_authentication"]
    existing = auth["verify_existing"]
    assert existing["request"]["plaintext"] == "[0x3f][0x7f][user_id_utf8][n1_ascii]"
    assert "ECDH" in existing["request"]["encryption"]
    assert existing["success_response"]["type"] == 109
    assert existing["success_response"]["inner_plaintext"] == (
        "[n1_ascii][.][n2_ascii]"
    )
    assert "saved cloud-issued credential" in existing["authenticate"]["encryption"]
    assert existing["authenticate"]["plaintext"] == "[0x09][0x7f][n2_ascii]"
    assert existing["failure_and_completion"]["expired_type"] == 110
    assert existing["failure_and_completion"]["invalid_type"] == 111
    assert existing["failure_and_completion"]["timeout_seconds"] == 8
    assert "no dedicated success reply" in existing["failure_and_completion"][
        "notes"
    ]
    assert "version read" in existing["failure_and_completion"]["notes"]

    fresh = auth["request_fresh"]
    assert fresh["request"]["opcode"] == 62
    assert fresh["request"]["plaintext"] == "[0x3e][0x7f][user_id_utf8][n1_ascii]"
    assert fresh["robot_reply"]["plaintext"] == (
        "[key_part][.][n2_ascii][.][payload]"
    )


def test_ecdh_public_key_and_unpadded_secret_vector():
    vector = SPEC["protocol_details"]["ecdh"]["test_vector"]
    generator = (
        int("79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798", 16),
        int("483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8", 16),
    )
    points = {}
    for party in ("phone", "robot"):
        scalar = int(vector[f"{party}_private_scalar_hex"], 16)
        point = _secp256k1_multiply(scalar, generator)
        public_key = (
            b"\x04" + point[0].to_bytes(32, "big") + point[1].to_bytes(32, "big")
        )
        assert len(public_key) == 65
        assert public_key.hex() == vector[f"{party}_public_key_hex"]
        points[party] = point

    phone_scalar = int(vector["phone_private_scalar_hex"], 16)
    shared_point = _secp256k1_multiply(phone_scalar, points["robot"])
    shared_x_padded = shared_point[0].to_bytes(32, "big")
    assert shared_x_padded.hex() == vector["shared_x_padded_hex"]

    secret_hex_text = format(shared_point[0], "x")
    assert len(secret_hex_text) == 63
    assert secret_hex_text == vector["shared_secret_hex_text"]
    digest = hashlib.sha256(secret_hex_text.encode("ascii")).hexdigest()
    assert digest == vector["sha256_hex"]
    assert digest != hashlib.sha256(shared_x_padded).hexdigest()
    assert digest[:32] == vector["aes_key_hex"]
    assert digest[32:] == vector["iv_hex"]
