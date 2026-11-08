"""Regression tests for advertised-name/service identity collisions."""

import re
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
FFF0 = "0000fff0-0000-1000-8000-00805f9b34fb"


def load(path):
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def specs():
    return {
        path.stem: load(path)
        for path in (ROOT / "device-specs" / "devices").glob("*.yaml")
    }


def test_fff0_is_not_an_identity_signal():
    offenders = []
    paths = list((ROOT / "device-specs" / "devices").glob("*.yaml"))
    paths += list((ROOT / "device-specs" / "examples").glob("*.yaml"))
    for path in paths:
        device = load(path)["device"]
        if FFF0 in (device.get("identification", {}).get("service_uuids") or []):
            offenders.append(f"{path.stem}: identification")
        for method in device.get("discovery", {}).get("methods") or []:
            if method.get("type") != "ble_scan":
                continue
            if FFF0 in (method.get("ble", {}).get("service_uuids") or []):
                offenders.append(f"{path.stem}: discovery.methods")
    assert not offenders, (
        "FFF0 is shared by unrelated protocols and must not activate a spec. "
        "Keep it in services and use name/GATT/manufacturer evidence instead: "
        + ", ".join(offenders)
    )


def matches(spec, advertised_name, advertised_services):
    device = spec["device"]
    identity = device.get("identification") or {}
    prefixes = list(identity.get("local_name_prefixes") or [])
    if identity.get("local_name_prefix"):
        prefixes.append(identity["local_name_prefix"])
    if any(advertised_name.lower().startswith(p.lower()) for p in prefixes):
        return True
    if any(
        advertised_name.casefold() == value.casefold()
        for value in identity.get("local_names") or []
    ):
        return True
    for method in device.get("discovery", {}).get("methods") or []:
        if method.get("type") != "ble_scan":
            continue
        ble = method.get("ble") or {}
        matcher = ble.get("local_name") or {}
        kind = matcher.get("match", "prefix")
        values = matcher.get("values") or ([matcher["value"]] if matcher.get("value") else [])
        for value in values:
            if kind == "prefix" and advertised_name.lower().startswith(value.lower()):
                return True
            if kind == "exact" and advertised_name.casefold() == value.casefold():
                return True
            if kind == "contains" and value.casefold() in advertised_name.casefold():
                return True
            if kind == "regex" and re.search(value, advertised_name):
                return True
        if set(ble.get("service_uuids") or []) & set(advertised_services):
            return True
    return bool(set(identity.get("service_uuids") or []) & set(advertised_services))


def test_loy_advertisement_selects_only_loypro():
    matched = [
        stem
        for stem, spec in specs().items()
        if matches(spec, "LOY5265115155", [FFF0])
    ]
    assert matched == ["loypro-led-display"]


def test_loypro_keeps_fff0_as_gatt_not_identity():
    spec = specs()["loypro-led-display"]
    assert spec["device"]["integration"] == "identify_only"
    assert spec["services"][0]["uuid"] == FFF0
    assert spec["device"]["testing"]["status"] == "untested"
