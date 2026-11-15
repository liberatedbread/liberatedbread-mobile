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
        if matches(spec, "LOY0000000000", [FFF0])
    ]
    assert matched == ["loypro-led-display"]


def test_loypro_keeps_fff0_as_gatt_not_identity():
    spec = specs()["loypro-led-display"]
    assert spec["device"]["integration"] == "supported"
    assert spec["services"][0]["uuid"] == FFF0
    assert spec["device"]["testing"]["status"] == "verified"
    assert spec["device"]["testing"]["detail"] == "minimally-verified"

    observed = spec["protocol_details"]["read_only_identification"]["observed_reply"]
    assert (observed["width"], observed["height"]) == (48, 16)
    assert observed["width_height_endian"] == "little"
    assert "car_linkage" in observed["capabilities"]
    assert "brake" in observed["capabilities"]
    assert "accelerometer" not in observed["note"].lower()


def test_coolledx_matches_only_the_exact_basic_generation():
    spec = specs()["coolledx-led-sign"]
    identity = spec["device"]["identification"]
    assert identity["local_names"] == ["CoolLEDX"]
    assert "local_name_prefix" not in identity
    assert matches(spec, "CoolLEDX", [FFF0])
    for name in ("CoolLEDM", "CoolLEDU", "CoolLEDMX", "CoolLEDUX", "CoolLEDX2"):
        assert not matches(spec, name, [FFF0]), name


def test_treadmills_do_not_claim_generic_ftms():
    ftms = "00001826-0000-1000-8000-00805f9b34fb"
    urevo = specs()["urevo-walking-pad"]
    assert urevo["device"]["identification"]["local_name_prefixes"] == [
        "URTM",
        "SYWP",
    ]
    assert "service_uuids" not in urevo["device"]["identification"]
    assert matches(urevo, "URTM012", [ftms])
    assert matches(urevo, "SYWP006", [])
    assert not matches(urevo, "Generic treadmill", [ftms])

    kingsmith = specs()["kingsmith-walkingpad"]
    assert ftms not in kingsmith["device"]["identification"]["service_uuids"]
    assert not matches(kingsmith, "Generic treadmill", [ftms])
    for name in (
        "KS-MC21-abc",
        "KS-SMC21C-abc",
        "ZP-ZEALR1-abc",
        "KS-HD-Z1D",
        "KS-AP-RF3",
        "KS-AP-RP3",
        "KS-AP-ZP3",
    ):
        assert matches(kingsmith, name, [ftms]), name
    assert not matches(kingsmith, "KS-AP-unknown", [ftms])


def test_magic_display_requires_its_manufacturer_product_prefix():
    spec = specs()["magic-display"]
    identity = spec["device"]["identification"]
    assert "service_uuids" not in identity
    assert identity["manufacturer_data"]["company_id"] == 21076
    matcher = spec["device"]["discovery"]["methods"][0]["ble"]
    assert "service_uuids" not in matcher
    assert matcher["manufacturer_data"]["pattern"] == "0027"
    assert not matches(spec, "", ["0000fee9-0000-1000-8000-00805f9b34fb"])


def test_obd_hm10_uart_is_post_connect_routing_not_identity():
    spec = specs()["obd2-bluetooth-adapter"]
    ffe0 = "0000ffe0-0000-1000-8000-00805f9b34fb"
    assert spec["device"]["identification"]["service_uuids"] == [
        "000018f0-0000-1000-8000-00805f9b34fb"
    ]
    ble = spec["device"]["discovery"]["methods"][0]["ble"]
    assert ffe0 not in ble["service_uuids"]
    assert not matches(spec, "HM-10", [ffe0])
    assert matches(spec, "OBDII", [ffe0])


def test_thermopro_uses_the_scan_configs_exact_names():
    spec = specs()["thermopro-tempspike-bbq"]
    identity = spec["device"]["identification"]
    assert "local_name_prefixes" not in identity
    for name in ("Thermopro", "TP960R", "TP971S", "I61W", "TP980R", "P925"):
        assert name in identity["local_names"]
        assert matches(spec, name, [])
    for name in ("TP999", "TP25-extra", "TempPro", "iBBQ"):
        assert not matches(spec, name, []), name


def test_no_spec_claims_a_device_by_a_shared_signal_alone():
    """Generic FTMS, a bare Apple company ID and a three-letter word are not identity.

    Each of these reached main in a new spec: a rower that listed 0x1826 as a
    scan axis (and so claimed every treadmill and bike in range), and a
    battery monitor whose scan matcher was company ID 0x004c with no payload
    pattern (every iBeacon and Apple device).
    """
    ftms = "00001826-0000-1000-8000-00805f9b34fb"
    claimed = sorted(
        stem for stem, spec in specs().items() if matches(spec, "Generic treadmill", [ftms])
    )
    assert claimed == [], f"specs identifying a device from generic FTMS alone: {claimed}"

    bare_apple = []
    for stem, spec in specs().items():
        discovery = spec["device"].get("discovery") or {}
        for method in discovery.get("methods") or []:
            block = (method.get("ble") or {}).get("manufacturer_data") or {}
            if block.get("company_id") == 76 and not block.get("pattern"):
                bare_apple.append(stem)
    assert bare_apple == [], (
        f"scan matchers on Apple's company ID with no payload pattern: {bare_apple}"
    )

