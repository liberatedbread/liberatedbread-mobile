"""Check the Kinsa thermometer spec's family naming and destructive commands."""

from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
SPEC_PATH = ROOT / "device-specs" / "devices" / "kinsa-thermometer.yaml"
SPEC = yaml.safe_load(SPEC_PATH.read_text(encoding="utf-8"))

FAMILIES = {
    "Ear-1": "2893b28b-c868-423a-9dc2-e9c2fcb4ebb5",
    "Ear-2": "00000000-0068-746c-6165-4861736e694b",
    "Forehead": "00000000-0069-746c-6165-4861736e694b",
    "Stick-1": "00000000-006a-746c-6165-4861736e694b",
    "Stick-2": "00000000-006b-746c-6165-4861736e694b",
}


def _service(uuid):
    return next(s for s in SPEC["services"] if s["uuid"] == uuid)


def test_families_are_named_by_role_and_service():
    variants = {
        v["model"]: v["identification"]["service_uuids"]
        for v in SPEC["device"]["variants"]
    }
    assert variants == {name: [uuid] for name, uuid in FAMILIES.items()}
    table = SPEC["protocol_details"]["family_table"]["families"]
    assert [row["family"] for row in table] == list(FAMILIES)
    for entity in SPEC["entities"]:
        assert set(entity["variants"]) <= set(FAMILIES)


def test_every_cache_clear_is_advanced():
    clears = []
    for service in SPEC["services"]:
        for char in service.get("characteristics", []):
            for name, command in (char.get("commands") or {}).items():
                if name == "clear_cache":
                    clears.append((service["uuid"], command))
    # The ASCII "CE" on the first-generation ear plus opcode 0x44 elsewhere.
    assert FAMILIES["Ear-1"] in [uuid for uuid, _ in clears]
    assert len(clears) >= 2
    for uuid, command in clears:
        assert command.get("advanced") is True, uuid
        assert command.get("advanced_reason"), uuid


def test_ascii_clear_cache_is_ce():
    request = _service(FAMILIES["Ear-1"])["characteristics"][0]
    assert request["commands"]["clear_cache"]["value"] == list(b"CE")
