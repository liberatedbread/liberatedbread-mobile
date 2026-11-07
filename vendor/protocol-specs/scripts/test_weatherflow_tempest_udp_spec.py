#!/usr/bin/env python3
"""Independent WeatherFlow UDP layout checks using YAML and stdlib."""

import json
from pathlib import Path

import pytest
import yaml

SPEC = yaml.safe_load(
    (Path(__file__).parents[1] / "device-specs/devices/weatherflow-tempest-udp.yaml").read_text()
)


def decode_observation(message):
    kind = message["type"]
    layout = SPEC["payload_formats"][kind]["fields"]
    observations = message["obs"]
    if not isinstance(observations, list) or len(observations) != 1:
        raise ValueError("expected one observation")
    values = observations[0]
    if len(values) != len(layout):
        raise ValueError("observation length disagrees with its layout")
    return {
        field["name"]: values[field["index"]]
        for field in layout
    }


def test_tempest_complete_layout_and_previous_minute_rain():
    values = [
        1735689600, 1.0, 2.0, 3.0, 180, 3, 1001.2, 20.5, 50.0,
        12000, 3.2, 400, 0.5, 1, None, 2, 2.7, 1,
    ]
    decoded = decode_observation({"type": "obs_st", "obs": [values]})
    assert len(decoded) == 18
    assert decoded["air_temperature"] == 20.5
    assert decoded["rain_previous_minute"] == 0.5
    assert decoded["rain_previous_minute"] * 60 == pytest.approx(30.0)
    assert decoded["lightning_average_distance"] is None
    rain = SPEC["payload_formats"]["obs_st"]["fields"][12]
    assert rain["index"] == 12
    assert "not cumulative daily rain" in rain["description"]


def test_short_observation_is_rejected():
    with pytest.raises(ValueError):
        decode_observation({"type": "obs_st", "obs": [[1, 2, 3]]})


def test_legacy_layouts_are_not_tempest_offsets():
    air = [1735689600, 1001.2, 20.5, 50.0, 2, 10, 2.7, 1]
    sky = [1735689600, 12000, 3.2, 0.5, 1.0, 2.0, 3.0, 180, 2.7, 1, 400, 8.0, 1, 3]
    decoded_air = decode_observation({"type": "obs_air", "obs": [air]})
    decoded_sky = decode_observation({"type": "obs_sky", "obs": [sky]})
    assert decoded_air["air_temperature"] == 20.5
    assert decoded_sky["rain_previous_minute"] == 0.5
    assert decoded_sky["rain_local_day_accumulation"] == 8.0
    assert decoded_sky["wind_sample_interval"] == 3


def test_lightning_distance_and_energy_boundaries():
    fields = SPEC["payload_formats"]["evt_strike"]["fields"]
    event = json.loads('{"evt":[1735689600,63,16842755]}')
    epoch, distance, energy = event["evt"]
    assert [field["index"] for field in fields] == [0, 1, 2]
    assert epoch == 1735689600
    assert distance == 63
    assert (energy & ~(1 << 24)) == 65539
    assert "unit" not in fields[2]


def test_sensor_and_radio_status_bits_are_declared():
    statuses = SPEC["protocol_details"]["device_status_bits"]
    assert statuses[0x0001] == "lightning failed"
    assert statuses[0x10000] == "power booster shore power"
    assert SPEC["protocol_details"]["hub_status"]["radio_status"][7] == "BLE connected"
