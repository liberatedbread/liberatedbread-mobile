"""Independent Eye-Fi credential and digest transcriptions using the stdlib."""

import hashlib
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
NOTE = yaml.safe_load(
    (ROOT / "research-notes" / "eye-fi-cards.yaml").read_text(encoding="utf-8")
)
SPEC = yaml.safe_load(
    (ROOT / "device-specs" / "devices" / "eye-fi-cards.yaml").read_text(
        encoding="utf-8"
    )
)


def credential(*hex_parts: str) -> str:
    joined = "".join(hex_parts)
    assert len(joined) % 2 == 0
    return hashlib.md5(bytes.fromhex(joined)).hexdigest()


def internet_checksum(block: bytes) -> int:
    assert len(block) % 2 == 0
    total = sum(
        int.from_bytes(block[offset : offset + 2], "big")
        for offset in range(0, len(block), 2)
    )
    while total > 0xFFFF:
        total = (total & 0xFFFF) + (total >> 16)
    return ~total & 0xFFFF


def integrity_digest(tar_bytes: bytes, upload_key: bytes) -> str:
    complete_length = len(tar_bytes) - len(tar_bytes) % 512
    checksums = b"".join(
        internet_checksum(tar_bytes[offset : offset + 512]).to_bytes(2, "big")
        for offset in range(0, complete_length, 512)
    )
    return hashlib.md5(checksums + upload_key).hexdigest()


def assert_vectors(vectors):
    mac = vectors["mac"]
    key = vectors["x2_upload_key"]
    zero = vectors["mobi_zero_key"]

    assert credential(mac, vectors["cnonce"], key) == vectors[
        "x2_start_session_credential"
    ]
    assert credential(mac, key, vectors["snonce"]) == vectors[
        "x2_photo_status_credential"
    ]
    assert credential(mac, vectors["cnonce"], zero) == vectors[
        "mobi_start_session_credential"
    ]
    assert credential(mac, zero, vectors["snonce"]) == vectors[
        "mobi_photo_status_credential"
    ]


def test_eye_fi_credentials_match_synthetic_vectors():
    assert_vectors(NOTE["credentials"]["test_vectors"])


def test_device_spec_carries_the_same_implementable_vectors():
    assert_vectors(SPEC["protocol_details"]["credentials"]["test_vectors"])


def test_eye_fi_vectors_use_documentation_identity_and_16_byte_keys():
    vectors = NOTE["credentials"]["test_vectors"]
    assert vectors["mac"] == "00005e005301"
    assert len(bytes.fromhex(vectors["x2_upload_key"])) == 16
    assert len(bytes.fromhex(vectors["mobi_zero_key"])) == 16
    assert set(vectors["mobi_zero_key"]) == {"0"}


def test_receiver_direction_and_safe_local_profile_are_explicit():
    receiver = SPEC["protocol_details"]["receiver"]
    assert receiver["direction"] == "card_initiates_upload_to_host"
    assert receiver["listen_port"] == 59278
    assert SPEC["device"]["integration"] == "identify_only"
    assert SPEC["device"]["setup"]["methods"][-1]["role"] == "historical"
    assert SPEC["protocol_details"]["archive_policy"]["validate_before_extract"]


def test_upload_photo_declares_action_ordered_parts_and_digest_format():
    sequence = SPEC["protocol_details"]["receiver"]["sequence"]
    upload = next(item for item in sequence if item["operation"] == "UploadPhoto")
    assert upload["soap_action"] == '"urn:UploadPhoto"'
    assert upload["verification"] == "reported"
    assert upload["multipart_fields"] == [
        "SOAPENVELOPE",
        "FILENAME",
        "INTEGRITYDIGEST",
    ]
    assert upload["multipart_order"] == "required_in_listed_order"
    assert upload["integrity_digest_format"] == "32 lowercase hexadecimal characters"


def test_integrity_digest_matches_synthetic_big_endian_vector():
    details = SPEC["protocol_details"]["resume"]["integrity_digest"]
    vector = details["test_vectors"]["synthetic_512_byte_tar_block"]
    tar_bytes = bytes.fromhex(vector["tar_bytes_hex"])
    upload_key = bytes.fromhex(vector["upload_key"])

    assert details["verification"] == "reported"
    assert details["word_byte_order"] == "big-endian"
    assert details["checksum_byte_order"] == "big-endian"
    assert len(tar_bytes) == 512
    assert len(upload_key) == 16
    assert internet_checksum(tar_bytes).to_bytes(2, "big").hex() == vector[
        "expected_block_checksum_hex"
    ]

    digest = integrity_digest(tar_bytes, upload_key)
    assert digest == vector["expected_integrity_digest"]
    assert len(digest) == 32
    assert set(digest) <= set("0123456789abcdef")
    assert integrity_digest(tar_bytes + b"trailing partial block", upload_key) == digest
