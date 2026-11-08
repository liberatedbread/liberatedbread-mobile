"""Validate the optional category hierarchy and discovery metadata."""

from pathlib import Path

import yaml

from build_index import Spec, build_manifest
from generate_index import build_entry

ROOT = Path(__file__).resolve().parents[1]
ALLOWED_HIERARCHIES = {
    "display": {"led_matrix", "screen", "other"},
    "light": {"led", "bulb", "strip", "lamp", "other"},
    "measurement": {"distance", "temperature", "environmental", "health", "other"},
}
HEALTH_SUBTYPES = {
    "pulse_oximetry",
    "blood_pressure",
    "thermometry",
    "sleep",
    "body_composition",
    "medication_management",
    "metabolic",
    "other",
}
CATEGORY_DOMAINS = {
    "display": "display",
    "light": "light",
    "sensor": "measurement",
    "health": "measurement",
    "scale": "measurement",
}


def specs():
    return {
        path.stem: yaml.safe_load(path.read_text(encoding="utf-8"))
        for path in (ROOT / "device-specs" / "devices").glob("*.yaml")
    }


def test_category_hierarchies_use_the_controlled_vocabulary():
    for stem, spec in specs().items():
        device = spec["device"]
        path = device.get("category_hierarchy")
        if path is None:
            continue
        assert 2 <= len(path) <= 3, f"{stem}: {path}"
        domain, kind = path[:2]
        assert domain in ALLOWED_HIERARCHIES, f"{stem}: unknown domain {domain}"
        assert kind in ALLOWED_HIERARCHIES[domain], f"{stem}: {path}"
        assert device.get("category") in CATEGORY_DOMAINS, (
            f"{stem}: hierarchy has no legacy category mapping"
        )
        assert CATEGORY_DOMAINS[device["category"]] == domain, (
            f"{stem}: category {device['category']} does not match {path}"
        )
        if domain == "measurement" and kind == "health":
            assert len(path) == 3, f"{stem}: health measurement needs a subtype"
            assert path[2] in HEALTH_SUBTYPES, f"{stem}: {path}"
        else:
            assert len(path) == 2, f"{stem}: unexpected subtype {path}"


def test_representative_device_paths():
    devices = specs()
    expected = {
        "jlx-laser-distance-meter": ["measurement", "distance"],
        "beurer-po60-pulse-oximeter": ["measurement", "health", "pulse_oximetry"],
        "beurer-series800-blood-pressure": ["measurement", "health", "blood_pressure"],
        "leds2rave4-lunchbox-led": ["display", "led_matrix"],
        "autobaba-led-backpack": ["display", "led_matrix"],
        "elk-bledom-led-strip": ["light", "led"],
    }
    for stem, path in expected.items():
        assert devices[stem]["device"]["category_hierarchy"] == path


def test_leds2rave4_commercial_and_app_names_are_findable():
    device = specs()["leds2rave4-lunchbox-led"]["device"]
    assert "LEDs2RAVE4" in device["aliases"]
    parties = {party["name"]: party for party in device["distributors"]}
    assert parties["LEDs 2 RAVE 4"]["role"] == "brand"
    assert parties["Lunchbox Packs"]["role"] == "retailer"
    apps = {app["name"]: app for app in device["companion_apps"]}
    assert apps["LED CHORD"]["package"] == "com.spled.pzse"
    assert apps["SPOTLED"]["package"] == "com.led.spotled"
    assert apps["iLEDColor"]["package"] == "com.led.iledcolor"


def test_beurer_apps_and_metadata_reach_the_index():
    devices = specs()
    po60 = devices["beurer-po60-pulse-oximeter"]
    bm92 = devices["beurer-series800-blood-pressure"]
    for spec in (po60, bm92):
        assert any(
            app["package"] == "com.beurer.healthmanager"
            for app in spec["device"]["companion_apps"]
        )
        entry = build_entry(ROOT / "device-specs/devices/example.yaml", spec, "2020-12")
        assert entry["category_hierarchy"] == spec["device"]["category_hierarchy"]
        assert entry["companion_apps"] == spec["device"]["companion_apps"]
    assert po60["device"]["testing"]["status"] == "untested"
    assert po60["device"]["testing"]["detail"] == "capture-verified"
    assert po60["device"]["pairing"]["pin"]["source"] == "device_screen"

    manifest = build_manifest([
        Spec(
            raw=po60,
            json_text="{}\n",
            checksum="sha256:test",
            id="beurer-po60-pulse-oximeter",
            path=Path("device-specs/devices/beurer-po60-pulse-oximeter.yaml"),
        )
    ], {}, "2026-11-07T00:00:00Z")
    entry = manifest["devices"][0]
    assert entry["category_hierarchy"] == ["measurement", "health", "pulse_oximetry"]
    assert entry["companion_apps"][0]["name"] == "beurer HealthManager Pro"
