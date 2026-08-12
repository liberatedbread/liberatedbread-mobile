"""Pins the Wemo verification scaffolding to the spec it is meant to verify.

`wemo_discover.py`, `wemo_control.py` and `wemo_setup.py` exist to check
`device-specs/devices/wemo-devices.yaml` against real hardware while its
`verified` flags are still false (issue #16). That only works if the two agree:
a script that has quietly drifted from the spec tests the script, not the
document, and a green hardware run would prove nothing about what we published.

So every constant the scripts hold that the spec also states is asserted equal
here, and the two things that go on the wire — the M-SEARCH datagram and the
SOAP request body — are diffed against the spec's own published examples.

These tests are scaffolding too. They skip cleanly when the scripts are gone,
and should be deleted along with them.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
SPEC_PATH = REPO_ROOT / "device-specs" / "devices" / "wemo-devices.yaml"

_scripts_dir = Path(__file__).resolve().parent
if str(_scripts_dir) not in sys.path:
    sys.path.insert(0, str(_scripts_dir))

wemo_discover = pytest.importorskip(
    "wemo_discover", reason="Wemo scaffolding has been removed"
)
wemo_control = pytest.importorskip(
    "wemo_control", reason="Wemo scaffolding has been removed"
)
wemo_setup = pytest.importorskip(
    "wemo_setup", reason="Wemo scaffolding has been removed"
)


@pytest.fixture(scope="module")
def spec() -> dict:
    return yaml.safe_load(SPEC_PATH.read_text(encoding="utf-8"))


@pytest.fixture(scope="module")
def ssdp(spec) -> dict:
    methods = [m for m in spec["device"]["discovery"]["methods"] if m["type"] == "ssdp"]
    return methods[0]["ssdp"]


@pytest.fixture(scope="module")
def setup(spec) -> dict:
    return spec["device"]["setup"]


@pytest.fixture(scope="module")
def softap_method(setup) -> dict:
    return [m for m in setup["methods"] if m["type"] == "softap_soap"][0]


def test_discovery_constants_match_the_spec(ssdp):
    """Multicast target, ports and timings are stated in both places."""
    assert wemo_discover.SSDP_MULTICAST == ssdp["multicast_group"]
    assert wemo_discover.SSDP_PORT == ssdp["multicast_port"]
    assert wemo_discover.SSDP_MX == ssdp["request"]["mx"]
    assert wemo_discover.PROBE_PORTS == ssdp["port_fallback"]
    assert wemo_discover.HTTP_TIMEOUT == ssdp["timing"]["http_fetch_timeout_seconds"]

    # The script probes a subset — it need not send every documented target,
    # but it must not invent one the spec does not list.
    assert set(wemo_discover.SEARCH_TARGETS) <= set(ssdp["search_targets"])


def test_msearch_datagram_matches_the_published_example(ssdp):
    """The bytes the script sends must be the bytes the spec publishes.

    This is the one that matters most for a hardware run: if the script sends
    something the spec does not describe and the device answers, the spec is
    still unverified.
    """
    packet = wemo_discover.build_msearch_packet(
        "urn:Belkin:service:basicevent:1", mx=ssdp["request"]["mx"]
    )
    example = ssdp["request"]["example"].rstrip("\n").split("\n")
    expected = ("\r\n".join(example) + "\r\n\r\n").encode("utf-8")
    assert packet == expected


def test_soap_body_matches_the_published_example(spec):
    """Likewise for control: same wire format, byte for byte."""
    built = wemo_control.build_soap_body(
        wemo_control.SERVICE_WIFI,
        "ConnectHomeNetwork",
        {
            "ssid": "HomeNet",
            "auth": "WPA2PSK",
            "password": "mKUXMHrq3r71VIBnALtgaQH/iTpWEZSSMVizvzMXrVM=2c1c",
            "encrypt": "AES",
            "channel": "6",
        },
    ).decode("utf-8")
    published = spec["soap_common"]["request_format"]["example"]["body"]
    assert built.strip() == published.strip()


def test_insight_param_fields_match_the_published_payload_format(spec):
    """Field order is the whole risk here; both places must say the same order."""
    documented = [f["name"] for f in spec["payload_formats"]["InsightParams"]["fields"]]
    assert wemo_control.INSIGHT_PARAM_FIELDS == documented


def test_setup_constants_match_the_spec(setup, softap_method):
    """Addresses, limits and status codes used when provisioning."""
    softap = softap_method["softap"]
    encryption = softap["credential_encryption"]

    assert wemo_setup.SETUP_AP_HOST == softap["gateway_ip"]
    assert (
        wemo_setup.MIN_PASSWORD_LENGTH
        == encryption["password_constraints"]["min_length"]
    )

    ap_list = softap_method["payload_formats"]["ApList"]
    assert wemo_setup.SUPPORTED_ENCRYPTIONS == set(ap_list["supported_ciphers"])

    poll = next(
        step
        for method in setup["methods"]
        for step in method.get("steps", [])
        if step.get("request", {}).get("action") == "GetNetworkStatus"
    )
    assert set(wemo_setup.NETWORK_STATUS) == set(poll["status_codes"])


def test_encryption_constants_match_the_spec(softap_method):
    """The magic strings in the key derivations."""
    variants = {
        v["method"]: v
        for v in softap_method["softap"]["credential_encryption"]["variants"]
    }
    assert wemo_setup.METHOD2_KEY_SUFFIX in variants[2]["keydata"]
    assert wemo_setup.METHOD3_KEY_EXTRA in variants[3]["keydata"]

    # add_lengths defaults must agree, or a hardware run tests the wrong pairing.
    for method, variant in variants.items():
        _, add_lengths = wemo_setup.detect_encryption_method(
            wemo_discover.WemoDevice(
                location_url="",
                ip="10.22.22.1",
                port=49153,
                config_extras={"rtos": "1"} if method == 2 else {},
            )
        )
        if method in (1, 2):  # method 3 is never auto-selected
            assert add_lengths == variant["add_lengths"], (
                f"method {method}: script picks add_lengths={add_lengths}, "
                f"spec says {variant['add_lengths']}"
            )


def test_reset_codes_match_the_spec(setup):
    """ReSetup scopes: the script's codes must be the documented ones."""
    argument = next(
        argument
        for step in setup["rejoin"]["steps"]
        for argument in step.get("request", {}).get("arguments", [])
        if argument["name"] == "Reset"
    )
    for scope, (code, _label) in wemo_setup.RESET_CODES.items():
        assert str(code) in argument["description"], (
            f"{scope} uses Reset={code}, which the spec does not document"
        )


def test_scaffolding_is_marked_as_such():
    """Each script must say what it is, so nobody mistakes it for a client."""
    for name in ("wemo_discover", "wemo_control", "wemo_setup"):
        module = sys.modules[name]
        doc = (module.__doc__ or "").upper()
        assert "VERIFICATION SCAFFOLDING" in doc, f"{name}: no scaffolding banner"
        assert "#16" in (module.__doc__ or ""), f"{name}: banner cites no tracking issue"
