"""Tests for the Wemo tooling: discovery parsing, control, and setup.

Prerequisites: run from the repo root. Uses only the standard library plus
pytest; the setup-encryption tests additionally need the ``openssl`` binary and
are skipped when it is unavailable.
"""

from __future__ import annotations

import base64
import hashlib
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

# Make scripts/ importable
_scripts_dir = Path(__file__).resolve().parent
if str(_scripts_dir) not in sys.path:
    sys.path.insert(0, str(_scripts_dir))

import wemo_control  # noqa: E402
import wemo_discover  # noqa: E402
import wemo_setup  # noqa: E402

SETUP_XML = b"""<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <device>
    <deviceType>urn:Belkin:device:controllee:1</deviceType>
    <friendlyName>Kitchen Plug</friendlyName>
    <manufacturer>Belkin International Inc.</manufacturer>
    <modelName>Socket</modelName>
    <modelNumber>1.0</modelNumber>
    <serialNumber>221517K0101769</serialNumber>
    <macAddress>94103E36AF15</macAddress>
    <UDN>uuid:Socket-1_0-221517K0101769</UDN>
    <serviceList>
      <service>
        <serviceType>urn:Belkin:service:basicevent:1</serviceType>
        <serviceId>urn:Belkin:serviceId:basicevent1</serviceId>
        <controlURL>/upnp/control/basicevent1</controlURL>
        <eventSubURL>/upnp/event/basicevent1</eventSubURL>
        <SCPDURL>/eventservice.xml</SCPDURL>
      </service>
      <service>
        <serviceType>urn:Belkin:service:WiFiSetup:1</serviceType>
        <serviceId>urn:Belkin:serviceId:WiFiSetup1</serviceId>
        <controlURL>/upnp/control/WiFiSetup1</controlURL>
        <eventSubURL>/upnp/event/WiFiSetup1</eventSubURL>
        <SCPDURL>/setupservice.xml</SCPDURL>
      </service>
    </serviceList>
  </device>
</root>
"""

SOAP_RESPONSE = b"""<?xml version="1.0"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
  <s:Body>
    <u:GetMetaInfoResponse xmlns:u="urn:Belkin:service:metainfo:1">
      <MetaInfo>221517K0101769|94103E36AF15|Wemo Mini</MetaInfo>
    </u:GetMetaInfoResponse>
  </s:Body>
</s:Envelope>
"""


# ── Discovery ────────────────────────────────────────────────────────────────


def test_parse_setup_xml_extracts_identity_and_services():
    device = wemo_discover.parse_setup_xml(SETUP_XML)
    assert device is not None
    assert device.device_type == "urn:Belkin:device:controllee:1"
    assert device.friendly_name == "Kitchen Plug"
    assert device.udn == "uuid:Socket-1_0-221517K0101769"
    assert device.serial_number == "221517K0101769"
    assert device.mac_address == "94103E36AF15"

    # Both services must survive parsing, with their control URLs intact —
    # the WiFiSetup controlURL is what the setup tool resolves at runtime.
    by_type = {s.service_type: s for s in device.services}
    assert set(by_type) == {
        "urn:Belkin:service:basicevent:1",
        "urn:Belkin:service:WiFiSetup:1",
    }
    assert by_type["urn:Belkin:service:WiFiSetup:1"].control_url == (
        "/upnp/control/WiFiSetup1"
    )
    assert by_type["urn:Belkin:service:basicevent:1"].event_sub_url == (
        "/upnp/event/basicevent1"
    )


def test_parse_setup_xml_without_namespace():
    """Some firmware serves the description without the UPnP namespace."""
    device = wemo_discover.parse_setup_xml(
        SETUP_XML.replace(b' xmlns="urn:schemas-upnp-org:device-1-0"', b"")
    )
    assert device is not None
    assert device.friendly_name == "Kitchen Plug"
    assert len(device.services) == 2


def test_parse_setup_xml_rejects_garbage():
    assert wemo_discover.parse_setup_xml(b"not xml at all") is None


def test_parse_ip_port():
    assert wemo_discover.parse_ip_port("http://192.168.1.42:49153/setup.xml") == (
        "192.168.1.42",
        49153,
    )
    assert wemo_discover.parse_ip_port("http://192.168.1.42/setup.xml") == (
        "192.168.1.42",
        80,
    )


def test_is_wemo_filters_other_upnp_responders():
    """ssdp:all makes every UPnP device on the LAN answer; only Wemo counts."""
    wemo = wemo_discover.WemoDevice(
        location_url="",
        ip="192.168.1.42",
        port=49153,
        manufacturer="Belkin International Inc.",
    )
    printer = wemo_discover.WemoDevice(
        location_url="",
        ip="192.168.1.9",
        port=80,
        manufacturer="Brother",
        device_type="urn:schemas-upnp-org:device:Printer:1",
        raw_ssdp_response="HTTP/1.1 200 OK\r\nSERVER: Linux/3.0 UPnP/1.0\r\n",
    )
    assert wemo_discover.is_wemo(wemo)
    assert not wemo_discover.is_wemo(printer)


# ── Control ──────────────────────────────────────────────────────────────────


def test_parse_insight_params_field_alignment():
    """wifipower sits between timeperiod and currentpower_mw.

    Regression test: an earlier field list omitted wifipower, which shifted
    every power reading one column to the left.
    """
    raw = "8|1700000000|100|200|300|1209600|8000|18500|1200|9900|8000"
    parsed = wemo_control.parse_insight_params(raw)

    assert parsed["state"] == "8"
    assert parsed["timeperiod"] == "1209600"
    assert parsed["wifipower"] == "8000"
    assert parsed["currentpower_mw"] == "18500"
    assert parsed["powerthreshold"] == "8000"


def test_parse_insight_params_keeps_extra_fields():
    raw = "|".join(["0"] * len(wemo_control.INSIGHT_PARAM_FIELDS) + ["42"])
    parsed = wemo_control.parse_insight_params(raw)
    assert parsed[f"field_{len(wemo_control.INSIGHT_PARAM_FIELDS)}"] == "42"


def test_parse_soap_values_returns_every_named_child():
    values = wemo_control.parse_soap_values(SOAP_RESPONSE)
    assert values == {"MetaInfo": "221517K0101769|94103E36AF15|Wemo Mini"}


def test_parse_soap_values_on_garbage():
    assert wemo_control.parse_soap_values(b"<not-soap/>") == {}


def test_soap_body_matches_the_reference_wire_format():
    """The namespace goes on the action element, arguments are unqualified.

    ElementTree hoists namespace declarations to the root, which is equivalent
    XML but not what Wemo firmware normally receives; these devices run crude
    parsers, so the wire format is pinned to what pywemo and ouimeaux send.
    """
    body = wemo_control.build_soap_body(
        wemo_control.SERVICE_WIFI,
        "ConnectHomeNetwork",
        {"ssid": "HomeNet", "channel": "6"},
    ).decode("utf-8")

    assert '<u:ConnectHomeNetwork xmlns:u="urn:Belkin:service:WiFiSetup:1">' in body
    assert "<ssid>HomeNet</ssid>" in body
    assert "<channel>6</channel>" in body
    assert "u:ssid" not in body
    assert body.startswith('<?xml version="1.0" encoding="utf-8"?>')


def test_soap_body_escapes_argument_values():
    """An SSID containing & must not produce a malformed document."""
    body = wemo_control.build_soap_body(
        wemo_control.SERVICE_WIFI, "ConnectHomeNetwork", {"ssid": "Ben & Jerry"}
    )
    assert b"<ssid>Ben &amp; Jerry</ssid>" in body
    # Must still parse.
    import xml.etree.ElementTree as ET

    ET.fromstring(body)


# ── Setup ────────────────────────────────────────────────────────────────────

META_INFO = "94103E36AF15|221517K0101769|Wemo_WW|WeMo_US_2.00.11408|Wemo.Mini.4A2|Socket"


def test_meta_info_field_order():
    """Field 0 is the MAC and field 1 the serial — not the other way round.

    Getting this backwards silently produces a valid-looking but undecryptable
    passphrase, so it is worth pinning.
    """
    meta = wemo_setup.MetaInfo.parse(META_INFO)
    assert meta.mac == "94103E36AF15"
    assert meta.serial_number == "221517K0101769"
    assert meta.firmware_version == "WeMo_US_2.00.11408"
    assert meta.access_point_ssid == "Wemo.Mini.4A2"


def test_meta_info_rejects_short_string():
    with pytest.raises(wemo_setup.SetupError):
        wemo_setup.MetaInfo.parse("94103E36AF15|221517K0101769")


def test_build_key_data_variants():
    """The three key layouts, as implemented by pywemo."""
    meta = wemo_setup.MetaInfo.parse(META_INFO)
    mac, serial = meta.mac, meta.serial_number

    assert wemo_setup.build_key_data(meta, 1) == mac[:6] + serial + mac[6:12]
    assert wemo_setup.build_key_data(meta, 2) == (
        mac[:6] + serial + mac[6:12] + wemo_setup.METHOD2_KEY_SUFFIX
    )
    assert wemo_setup.build_key_data(meta, 3) == (
        mac[:3]
        + mac[9:12]
        + serial
        + wemo_setup.METHOD3_KEY_EXTRA
        + mac[6:9]
        + mac[3:6]
    )


def test_build_key_data_rejects_unknown_method():
    meta = wemo_setup.MetaInfo.parse(META_INFO)
    with pytest.raises(wemo_setup.SetupError):
        wemo_setup.build_key_data(meta, 4)


def test_detect_encryption_method():
    """rtos without iot selects method 2, which omits the length suffix."""

    def device(**extras):
        return wemo_discover.WemoDevice(
            location_url="", ip="10.22.22.1", port=49153, config_extras=extras
        )

    assert wemo_setup.detect_encryption_method(device()) == (1, True)
    assert wemo_setup.detect_encryption_method(device(rtos="1")) == (2, False)
    assert wemo_setup.detect_encryption_method(device(rtos="1", iot="1")) == (1, True)
    assert wemo_setup.detect_encryption_method(device(iot="1")) == (1, True)


def test_parse_ap_list_skips_header_and_splits_auth():
    """SSID is column 0, channel column 1, and AUTH/CIPHER is the LAST column."""
    ap_list = (
        "3\n"
        "HomeNet|6|WPA2PSK|blah|WPA2PSK/AES,\n"
        "OpenGuest|11|OPEN|blah|OPEN/NONE,\n"
        "NewFangled|1|SAE|blah|Unknown,\n"
    )
    aps = wemo_setup.parse_ap_list(ap_list)

    assert [ap.ssid for ap in aps] == ["HomeNet", "OpenGuest", "NewFangled"]

    home = aps[0]
    assert (home.channel, home.auth_mode, home.encryption) == ("6", "WPA2PSK", "AES")
    assert home.supported

    assert aps[1].encryption == "NONE" and aps[1].supported
    # WPA3 and anything else the device cannot express comes back as Unknown.
    assert aps[2].auth_mode == "Unknown" and not aps[2].supported


def test_parse_ap_list_ignores_junk_lines():
    assert wemo_setup.parse_ap_list("") == []
    assert wemo_setup.parse_ap_list("1\n\n   \ngarbage-no-pipe\n") == []


requires_openssl = pytest.mark.skipif(
    shutil.which("openssl") is None, reason="openssl binary not available"
)


@requires_openssl
def test_encrypt_wifi_password_round_trips():
    """The blob decrypts back to the passphrase with the documented parameters.

    This pins the derivation (salt/IV/key material) and the header handling:
    OpenSSL 1.x emits a "Salted__" prefix even when -S is given, OpenSSL 3.x
    does not, and slicing 16 bytes unconditionally corrupts the output on 3.x.
    """
    meta = wemo_setup.MetaInfo.parse(META_INFO)
    key_data = wemo_setup.build_key_data(meta, 1)
    password = "correct horse battery"

    encoded = wemo_setup.encrypt_wifi_password(password, key_data, add_lengths=False)

    proc = subprocess.run(
        [
            shutil.which("openssl"),
            "enc",
            "-d",
            "-aes-128-cbc",
            "-md",
            "md5",
            "-S",
            key_data[0:8].encode("utf-8").hex(),
            "-iv",
            key_data[0:16].encode("utf-8").hex(),
            "-pass",
            f"pass:{key_data}",
        ],
        input=base64.b64decode(encoded),
        capture_output=True,
        check=False,
    )
    assert proc.returncode == 0, proc.stderr.decode("utf-8", errors="replace")
    assert proc.stdout.decode("utf-8") == password


@requires_openssl
def test_encrypt_wifi_password_length_suffix_is_zero_padded():
    """Wemo expects exactly four hex digits: xxyy, both zero-padded.

    Regression test: emitting a single digit for a length below 16 produces a
    blob the device silently rejects.
    """
    meta = wemo_setup.MetaInfo.parse(META_INFO)
    key_data = wemo_setup.build_key_data(meta, 1)
    password = "8charact"  # length 8 -> "08", not "8"

    bare = wemo_setup.encrypt_wifi_password(password, key_data, add_lengths=False)
    suffixed = wemo_setup.encrypt_wifi_password(password, key_data, add_lengths=True)

    assert suffixed == f"{bare}{len(bare):02x}08"
    assert len(suffixed) == len(bare) + 4


@requires_openssl
def test_encrypt_wifi_password_is_deterministic():
    """Same passphrase and key material must produce the same blob.

    The device derives its key from fixed metadata, so a random salt or IV
    would make the credential undecryptable on the device side.
    """
    meta = wemo_setup.MetaInfo.parse(META_INFO)
    key_data = wemo_setup.build_key_data(meta, 1)
    first = wemo_setup.encrypt_wifi_password("hunter2!", key_data, True)
    second = wemo_setup.encrypt_wifi_password("hunter2!", key_data, True)
    assert first == second


@requires_openssl
def test_encrypt_wifi_password_rejects_overlong_password():
    meta = wemo_setup.MetaInfo.parse(META_INFO)
    key_data = wemo_setup.build_key_data(meta, 1)
    with pytest.raises(wemo_setup.SetupError):
        wemo_setup.encrypt_wifi_password("x" * 256, key_data, add_lengths=True)


def test_dry_run_never_prints_the_passphrase(capsys):
    """Redacted arguments must not reach stdout, even in dry-run output."""
    client = wemo_setup.Client("10.22.22.1", execute=False)
    client.call(
        wemo_control.SERVICE_WIFI,
        "ConnectHomeNetwork",
        arguments={"ssid": "HomeNet", "password": "s3cr3t-passphrase"},
        redact={"password": wemo_setup.PASSWORD_PLACEHOLDER},
    )
    out = capsys.readouterr().out
    assert "s3cr3t-passphrase" not in out
    assert wemo_setup.PASSWORD_PLACEHOLDER in out
    assert "HomeNet" in out
    assert "DRY RUN" in out


def test_reset_codes_match_the_app_wording():
    assert wemo_setup.RESET_CODES["data"][0] == 1
    assert wemo_setup.RESET_CODES["factory"][0] == 2
    assert wemo_setup.RESET_CODES["wifi"][0] == 5


# ── Spec conformance ─────────────────────────────────────────────────────────
#
# The point of these tests is that device-specs/devices/wemo-devices.yaml is
# meant to be implementable on its own, without reading this code. That only
# stays true if the two cannot drift, so the spec's own values are the
# expectations here.

import yaml  # noqa: E402

_REPO_ROOT = Path(__file__).resolve().parent.parent
_SPEC_PATH = _REPO_ROOT / "device-specs" / "devices" / "wemo-devices.yaml"


@pytest.fixture(scope="module")
def spec_setup():
    spec = yaml.safe_load(_SPEC_PATH.read_text(encoding="utf-8"))
    return spec["device"]["setup"]


@pytest.fixture(scope="module")
def spec_method(spec_setup):
    methods = [m for m in spec_setup["methods"] if m["type"] == "softap_soap"]
    assert methods, "spec must document the softap_soap onboarding method"
    return methods[0]


@pytest.fixture(scope="module")
def spec_softap(spec_method):
    return spec_method["softap"]


@requires_openssl
def test_spec_test_vectors_are_reproducible(spec_softap):
    """Every published test vector must be reproducible by this code.

    Someone implementing from the YAML alone checks their crypto against these
    vectors. If this test fails, either the code regressed or the spec is
    publishing values nobody can reproduce — both are release blockers.
    """
    vectors = spec_softap["credential_encryption"]["test_vectors"]
    meta = wemo_setup.MetaInfo.parse(vectors["input"]["meta_info"])

    assert meta.mac == vectors["input"]["mac"]
    assert meta.serial_number == vectors["input"]["serial"]
    password = vectors["input"]["passphrase"]
    assert len(password) == vectors["input"]["passphrase_length"]

    assert len(vectors["vectors"]) == 3, "all three variants must be published"

    for vector in vectors["vectors"]:
        method = vector["method"]
        key_data = wemo_setup.build_key_data(meta, method)

        assert key_data == vector["keydata"], f"method {method} keydata"
        assert key_data[0:8] == vector["salt"], f"method {method} salt"
        assert key_data[0:16] == vector["iv"], f"method {method} iv"

        # The published AES key pins the derivation itself: one MD5 round over
        # keydata + salt, truncated to 16 bytes.
        derived = hashlib.md5(  # noqa: S324 - the scheme Wemo uses
            key_data.encode("utf-8") + key_data[0:8].encode("utf-8")
        ).digest()[:16]
        assert derived.hex() == vector["aes_key_hex"], f"method {method} key"

        bare = wemo_setup.encrypt_wifi_password(password, key_data, False)
        assert bare == vector["base64_ciphertext"], f"method {method} ciphertext"

        blob = wemo_setup.encrypt_wifi_password(
            password, key_data, vector["add_lengths"]
        )
        assert blob == vector["password_argument"], f"method {method} password arg"


def test_spec_variant_selectors_match_detection(spec_softap):
    """The add_lengths values in the spec must match what the code chooses."""
    variants = {
        v["method"]: v for v in spec_softap["credential_encryption"]["variants"]
    }
    assert set(variants) == {1, 2, 3}
    assert variants[1]["add_lengths"] is True
    assert variants[2]["add_lengths"] is False
    assert variants[3]["add_lengths"] is True

    def device(**extras):
        return wemo_discover.WemoDevice(
            location_url="", ip="10.22.22.1", port=49153, config_extras=extras
        )

    # The documented selector: rtos=1 and not iot=1 -> method 2, else method 1.
    method, add_lengths = wemo_setup.detect_encryption_method(device(rtos="1"))
    assert (method, add_lengths) == (2, variants[2]["add_lengths"])
    method, add_lengths = wemo_setup.detect_encryption_method(device())
    assert (method, add_lengths) == (1, variants[1]["add_lengths"])


def test_spec_key_constants_appear_in_the_published_formulas(spec_softap):
    """The magic strings in the code must be the ones the spec publishes."""
    variants = {
        v["method"]: v for v in spec_softap["credential_encryption"]["variants"]
    }
    assert wemo_setup.METHOD2_KEY_SUFFIX in variants[2]["keydata"]
    assert wemo_setup.METHOD3_KEY_EXTRA in variants[3]["keydata"]


def test_spec_status_codes_match_implementation(spec_softap, spec_setup):
    """Documented NetworkStatus codes and the code's table must agree."""
    steps = [
        step
        for method in spec_setup["methods"]
        for step in method.get("steps", [])
        if step.get("request", {}).get("action") == "GetNetworkStatus"
    ]
    assert steps, "spec must document GetNetworkStatus"
    assert set(steps[0]["status_codes"]) == set(wemo_setup.NETWORK_STATUS)


def test_spec_constraints_match_implementation(spec_method, spec_softap):
    """Password bounds, ciphers and port list are declared once, in the spec."""
    encryption = spec_softap["credential_encryption"]
    assert (
        encryption["password_constraints"]["min_length"]
        == wemo_setup.MIN_PASSWORD_LENGTH
    )

    ap_format = spec_method["payload_formats"]["ApList"]
    assert set(ap_format["supported_ciphers"]) == wemo_setup.SUPPORTED_ENCRYPTIONS
    assert spec_softap["port_probe_list"] == wemo_discover.PROBE_PORTS
    assert spec_softap["gateway_ip"] == wemo_setup.SETUP_AP_HOST

    timing = spec_method["timing"]
    assert timing["connect_send_count"] == 2
    assert timing["status_poll_minimum_seconds"] <= 20


def test_spec_metainfo_field_order_matches_implementation(spec_method):
    """The documented MetaInfo field order must match the parser."""
    metainfo = spec_method["payload_formats"]["MetaInfo"]
    documented = [f["name"] for f in metainfo["fields"]]
    parsed = wemo_setup.MetaInfo.parse(metainfo["example"])
    assert documented == [
        "mac",
        "serial_number",
        "device_sku",
        "firmware_version",
        "access_point_ssid",
        "model_name",
    ]
    # The documented example must parse into the documented field names.
    for index, name in enumerate(documented):
        assert getattr(parsed, name) == metainfo["example"].split("|")[index]


def test_spec_ap_list_example_parses_as_documented(spec_method):
    """The example ApList in the spec must parse under the documented rules.

    This is the check that the worked example is actually worked — a stale
    example is worse than none, since it is what an implementer tests against.
    """
    ap_format = spec_method["payload_formats"]["ApList"]
    access_points = wemo_setup.parse_ap_list(ap_format["example"])

    assert [ap.ssid for ap in access_points] == [
        "HomeNet",
        "OpenGuest",
        "NewFangled",
    ]
    assert (access_points[0].auth_mode, access_points[0].encryption) == (
        "WPA2PSK",
        "AES",
    )
    assert access_points[0].channel == "6"
    # The documented unsupported marker must actually be treated as unsupported.
    assert access_points[2].auth_mode == ap_format["unsupported_marker"]["value"]
    assert not access_points[2].supported


def test_spec_reset_codes_match_implementation(spec_setup):
    """ReSetup scope codes are documented in the rejoin steps."""
    arguments = [
        argument
        for step in spec_setup["rejoin"]["steps"]
        for argument in step.get("request", {}).get("arguments", [])
        if argument["name"] == "Reset"
    ]
    assert arguments, "spec must document the Reset argument"
    description = arguments[0]["description"]
    for scope, (code, _label) in wemo_setup.RESET_CODES.items():
        assert str(code) in description, f"{scope} code {code} not documented"


@requires_openssl
def test_spec_is_implementable_without_our_code(spec_softap):
    """Follow the spec's algorithm_steps literally and hit the published vectors.

    Deliberately does not call wemo_setup's encryption. This is a transcription
    of what the YAML instructs, using nothing but hashlib, base64 and the
    openssl CLI — the position someone implementing from the spec alone is in.
    If this passes, the written algorithm is sufficient to reproduce the
    vectors; if it fails, the prose is wrong or incomplete no matter what our
    own code does.
    """
    vectors = spec_softap["credential_encryption"]["test_vectors"]
    meta_fields = vectors["input"]["meta_info"].split("|")
    mac, serial = meta_fields[0], meta_fields[1]
    password = vectors["input"]["passphrase"]

    # Step 1: keydata layouts, transcribed from credential_encryption.variants.
    layouts = {
        1: mac[0:6] + serial + mac[6:12],
        2: mac[0:6] + serial + mac[6:12] + "b3{8t;80dIN{ra83eC1s?M70?683@2Yf",
        3: (
            mac[0:3]
            + mac[9:12]
            + serial
            + "b2Ujb3Rtb24mY3ZEbmlhaXBBZGFiT25v"
            + mac[6:9]
            + mac[3:6]
        ),
    }

    for vector in vectors["vectors"]:
        key_data = layouts[vector["method"]]
        assert key_data == vector["keydata"]

        # Steps 2-3: salt and IV are the head of keydata as UTF-8 bytes.
        salt = key_data[0:8].encode("utf-8")
        iv = key_data[0:16].encode("utf-8")

        # Step 4: one MD5 round over keydata + salt, truncated to 16 bytes.
        aes_key = hashlib.md5(  # noqa: S324 - the scheme Wemo uses
            key_data.encode("utf-8") + salt
        ).digest()[:16]
        assert aes_key.hex() == vector["aes_key_hex"]

        # Steps 5-7 via the documented openssl_equivalent command.
        proc = subprocess.run(
            [
                shutil.which("openssl"),
                "enc",
                "-aes-128-cbc",
                "-md",
                "md5",
                "-S",
                salt.hex(),
                "-iv",
                iv.hex(),
                "-pass",
                f"pass:{key_data}",
            ],
            input=password.encode("utf-8"),
            capture_output=True,
            check=True,
        )
        ciphertext = proc.stdout
        if ciphertext.startswith(b"Salted__"):  # the documented header quirk
            ciphertext = ciphertext[16:]
        encoded = base64.b64encode(ciphertext).decode("ascii")
        assert encoded == vector["base64_ciphertext"]

        # Step 8: two zero-padded hex digits each, encrypted then plaintext.
        expected = encoded
        if vector["add_lengths"]:
            expected += f"{len(encoded):02x}{len(password):02x}"
        assert expected == vector["password_argument"]
