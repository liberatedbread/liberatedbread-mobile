"""Schema contract tests for the shared number-semantics vocabulary.

`$defs/number_semantics` in device-specs/schema.json says what a numeric wire
value MEANS — `unit`, `scale`, `value_offset`, the C-vs-F machinery
(`unit_source`/`unit_reference`/`unit_values`) and `values` code tables — and
is composed into BLE command `parameters`, BLE `format` fields, `bus` message
fields and `payload_formats` fields. The schema is deliberately permissive, so
these tests pin the two things that must NOT drift silently:

- the vocabulary validates everywhere it is meant to be usable, and
- the guardrails actually fire: a bogus `unit_source` is rejected, and
  `unit_source: device_setting` without a `unit_reference` is rejected —
  "the unit depends on a setting" is useless without saying where the
  setting lives.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from jsonschema import Draft202012Validator

REPO_ROOT = Path(__file__).resolve().parent.parent
SCHEMA_PATH = REPO_ROOT / "device-specs" / "schema.json"

SERVICE_UUID = "0000fff0-0000-1000-8000-00805f9b34fb"
CHAR_UUID = "0000fff1-0000-1000-8000-00805f9b34fb"


@pytest.fixture(scope="module")
def validator() -> Draft202012Validator:
    schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
    Draft202012Validator.check_schema(schema)
    return Draft202012Validator(schema)


def ble_spec(characteristic: dict) -> dict:
    """Minimal valid BLE spec wrapping one characteristic."""
    return {
        "device": {
            "name": "Test Device",
            "manufacturer": "Test",
            "manufacturer_status": "abandoned",
            "protocol": "ble",
        },
        "services": [
            {
                "uuid": SERVICE_UUID,
                "name": "Test Service",
                "characteristics": [characteristic],
            }
        ],
    }


def format_field_spec(**field_extras) -> dict:
    field = {"offset": 0, "length": 2, "name": "temp_raw", "type": "uint16", **field_extras}
    return ble_spec(
        {
            "uuid": CHAR_UUID,
            "name": "Temperature",
            "properties": ["read"],
            "format": [field],
        }
    )


def parameter_spec(**param_extras) -> dict:
    param = {"type": "uint8", "min": 0, "max": 255, **param_extras}
    return ble_spec(
        {
            "uuid": CHAR_UUID,
            "name": "Target",
            "properties": ["write"],
            "commands": {
                "set_target": {
                    "description": "Set target",
                    "template": ["{value}"],
                    "parameters": {"value": param},
                }
            },
        }
    )


def errors(validator: Draft202012Validator, doc: dict) -> list[str]:
    return [f"{e.json_path}: {e.message}" for e in validator.iter_errors(doc)]


def test_format_field_accepts_full_number_semantics(validator):
    """A format field can say unit, linear transform, and enumerated values."""
    doc = format_field_spec(
        unit="C",
        scale=0.5,
        value_offset=85,
        values={0: "off", 1: "on"},
        notes="App rounds the decoded value up to the nearest 5 for display.",
    )
    assert errors(validator, doc) == []


def test_parameter_accepts_description_and_semantics(validator):
    """Command parameters — the encode direction — carry the same vocabulary."""
    doc = parameter_spec(
        description="Target temperature",
        unit="F",
        scale=0.5,
        value_offset=85,
    )
    assert errors(validator, doc) == []


def test_device_setting_unit_requires_a_reference(validator):
    """'The unit follows a device setting' must say where the setting lives."""
    doc = format_field_spec(unit_source="device_setting")
    assert errors(validator, doc), "device_setting with no unit_reference should fail"

    doc = format_field_spec(
        unit_source="device_setting",
        unit_reference=f"{CHAR_UUID}.temp_unit",
        unit_values={0: "C", 1: "F"},
    )
    assert errors(validator, doc) == []


def test_device_setting_guardrail_fires_for_parameters_too(validator):
    doc = parameter_spec(unit_source="device_setting")
    assert errors(validator, doc), "parameters share the unit_reference guardrail"


def test_fixed_unit_source_needs_no_reference(validator):
    doc = format_field_spec(unit="C", unit_source="fixed")
    assert errors(validator, doc) == []


def test_unknown_unit_source_is_rejected(validator):
    doc = format_field_spec(unit_source="whatever_the_app_says")
    assert errors(validator, doc), "unit_source outside fixed/device_setting should fail"


def test_number_entity_min_max_step(validator):
    doc = ble_spec(
        {"uuid": CHAR_UUID, "name": "Target", "properties": ["read", "write"],
         "format": [{"offset": 0, "length": 2, "name": "target_raw", "type": "uint16"}]}
    )
    doc["entities"] = [
        {
            "platform": "number",
            "name": "Target Temperature",
            "unit": "C",
            "min": 49,
            "max": 63,
            "step": 0.5,
            "state_characteristic": CHAR_UUID,
        }
    ]
    assert errors(validator, doc) == []

    doc["entities"][0]["step"] = 0
    assert errors(validator, doc), "a zero step is a broken control, not a granularity"


def test_bus_field_gains_value_offset(validator):
    """The bus block now shares the vocabulary instead of a private unit/scale."""
    doc = {
        "device": {
            "name": "Test Bus Device",
            "manufacturer": "Test",
            "manufacturer_status": "active",
            "protocol": "uart",
        },
        "bus": {
            "link": {"type": "uart", "baud": 9600},
            "style": "stream",
            "messages": [
                {
                    "name": "status",
                    "verification": "reported",
                    "fields": [
                        {
                            "offset": 1,
                            "name": "motor_temp",
                            "type": "uint8",
                            "unit": "C",
                            "scale": 1,
                            "value_offset": -40,
                        }
                    ],
                }
            ],
        },
    }
    assert errors(validator, doc) == []


def test_payload_format_field_carries_units(validator):
    doc = ble_spec(
        {"uuid": CHAR_UUID, "name": "Status", "properties": ["read"],
         "format": [{"offset": 0, "length": 1, "name": "state", "type": "uint8"}]}
    )
    doc["payload_formats"] = {
        "InsightParams": {
            "description": "Pipe-delimited state string.",
            "fields": [
                {"index": 7, "name": "currentpower", "unit": "mW"},
                {"index": 2, "name": "lastchange", "unit": "seconds"},
            ],
        }
    }
    assert errors(validator, doc) == []
