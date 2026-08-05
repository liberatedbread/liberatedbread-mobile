"""Proves the Wemo spec can be implemented from the spec alone.

`device-specs/devices/wemo-devices.yaml` claims to be sufficient on its own for
all three things a client does — **discover** a device, **control** it, and
**provision** it. This module is how that claim is kept honest.

Everything below is a **transcription of what the YAML says**, importing
nothing but the standard library. Each function cites the spec path it came
from. If a transcription cannot be written, or does not reproduce the spec's
own published examples and test vectors, the spec is underspecified and this
fails.

There is no supported client surface here. Discovery, control and provisioning
are all things existing libraries (pywemo) already do, tested against far more
hardware than we have; a second implementation from us would be a worse copy.
The spec is the contribution, and this file is its test — the transcriptions
here exist to prove the document is complete, not to be used.

The `wemo_*.py` scripts alongside this one are verification scaffolding, not
that client surface: they exist to check the spec against hardware while its
`verified` flags are still false, and are tracked for deletion in issue #16.
This module deliberately does not import them, so it keeps testing the document
whatever happens to them.

Requires the ``openssl`` binary, which the spec names as an equivalent
implementation of its encryption.
"""

from __future__ import annotations

import base64
import hashlib
import re
import shutil
import subprocess
import xml.etree.ElementTree as ET
from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
SPEC_PATH = REPO_ROOT / "device-specs" / "devices" / "wemo-devices.yaml"

requires_openssl = pytest.mark.skipif(
    shutil.which("openssl") is None, reason="openssl binary not available"
)


@pytest.fixture(scope="module")
def spec() -> dict:
    return yaml.safe_load(SPEC_PATH.read_text(encoding="utf-8"))


@pytest.fixture(scope="module")
def setup(spec) -> dict:
    return spec["device"]["setup"]


@pytest.fixture(scope="module")
def method(setup) -> dict:
    methods = [m for m in setup["methods"] if m["type"] == "softap_soap"]
    assert methods, "spec must document the softap_soap onboarding method"
    return methods[0]


@pytest.fixture(scope="module")
def encryption(method) -> dict:
    return method["softap"]["credential_encryption"]


@pytest.fixture(scope="module")
def ssdp(spec) -> dict:
    methods = [m for m in spec["device"]["discovery"]["methods"] if m["type"] == "ssdp"]
    assert methods, "spec must document SSDP discovery"
    return methods[0]["ssdp"]


# ── Reference implementation, transcribed from the spec ──────────────────────
#
# Nothing here imports our own code. Every step cites the spec field it comes
# from, so a failure points at the sentence that needs fixing.


def parse_meta_info(value: str) -> dict[str, str]:
    """Per setup.methods[].payload_formats.MetaInfo."""
    fields = value.split("|")
    return {
        "mac": fields[0],
        "serial_number": fields[1],
        "device_sku": fields[2],
        "firmware_version": fields[3],
        "access_point_ssid": fields[4],
        "model_name": fields[5],
    }


def parse_ap_list(ap_list: str) -> list[dict[str, str]]:
    """Per setup.methods[].payload_formats.ApList.parse_rules, in order."""
    access_points = []
    for line in ap_list.split("\n")[1:]:  # rule 1: skip the header line
        line = line.strip().rstrip(",")  # rule 2: strip whitespace and comma
        if "|" not in line:  # rule 3: ignore partial lines
            continue
        columns = line.split("|")  # rule 4: column 0 SSID, column 1 channel
        auth_mode, _, cipher = columns[-1].strip().partition("/")  # rule 5: LAST column
        access_points.append(
            {
                "ssid": columns[0].strip(),
                "channel": columns[1].strip(),
                "auth": auth_mode.strip(),
                "encrypt": cipher.strip(),
            }
        )
    return access_points


def build_key_data(mac: str, serial: str, variant: dict) -> str:
    """Per setup...credential_encryption.variants[].keydata.

    The layouts are published as expressions over `mac` and `serial`; this is
    the transcription a reader would write.
    """
    method = variant["method"]
    if method == 1:
        return mac[0:6] + serial + mac[6:12]
    if method == 2:
        suffix = variant["keydata"].split("+")[-1].strip().strip("'\"")
        return mac[0:6] + serial + mac[6:12] + suffix
    if method == 3:
        # The published expression interleaves the MAC around a constant.
        extra = next(
            part.strip().strip("'\"")
            for part in variant["keydata"].split("+")
            if "b2Ujb3" in part
        )
        return mac[0:3] + mac[9:12] + serial + extra + mac[6:9] + mac[3:6]
    raise AssertionError(f"undocumented variant {method}")


def encrypt(password: str, key_data: str, add_lengths: bool) -> str:
    """Per setup...credential_encryption.algorithm_steps, via openssl_equivalent."""
    salt = key_data[0:8].encode("utf-8")  # step 2: UTF-8, not hex-decoded
    iv = key_data[0:16].encode("utf-8")  # step 3

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
        input=password.encode("utf-8"),  # steps 5-6: pkcs7 pad, AES-128-CBC
        capture_output=True,
        check=True,
    )
    ciphertext = proc.stdout
    if ciphertext.startswith(b"Salted__"):  # documented OpenSSL 1.x vs 3.x quirk
        ciphertext = ciphertext[16:]

    encoded = base64.b64encode(ciphertext).decode("ascii")  # step 7
    if not add_lengths:
        return encoded
    # Step 8: two zero-padded hex digits each, encrypted then plaintext.
    return f"{encoded}{len(encoded):02x}{len(password):02x}"


# ── The spec must publish what the transcription needs ───────────────────────


def test_spec_publishes_an_implementable_encryption_block(encryption):
    """The fields a reader needs before they can write any code at all."""
    assert encryption["algorithm"], "no cipher named"
    assert encryption.get("padding"), "padding scheme not stated"
    assert encryption.get("algorithm_steps"), "no step-by-step procedure"
    assert encryption.get("variants"), "key derivations not published"
    assert encryption.get("openssl_equivalent", {}).get("command")
    assert encryption.get("test_vectors"), "nothing to verify an implementation against"

    constraints = encryption.get("password_constraints", {})
    assert constraints.get("min_length"), "passphrase length limits not stated"

    # Each variant must say when it applies, or a reader cannot choose one.
    for variant in encryption["variants"]:
        assert variant.get("selector"), f"variant {variant['method']} has no selector"
        assert "add_lengths" in variant
        assert variant.get("keydata")


def test_spec_publishes_the_wire_format(spec):
    """A reader must not have to know UPnP conventions we already learned."""
    request = spec["soap_common"]["request_format"]
    assert "u:{action}" in request["template"]
    assert "{arguments}" in request["template"]
    assert request["http"]["method"] == "POST"
    assert "SOAPACTION" in request["http"]["headers"]
    # The trap that cost us a bug: arguments are not namespace-qualified.
    assert "UNQUALIFIED" in request["argument_qualification"].upper()
    # And the one that bites on an SSID containing an ampersand.
    assert request.get("escaping"), "XML escaping of argument values not stated"
    assert spec["soap_common"]["response_format"]["parse_rule"]


def test_spec_publishes_payload_formats(method):
    """Non-self-describing payloads need parse rules and a literal example."""
    formats = method["payload_formats"]
    assert {"MetaInfo", "ApList"} <= set(formats)

    metainfo = formats["MetaInfo"]
    assert metainfo["example"]
    assert [f["name"] for f in metainfo["fields"]][:2] == ["mac", "serial_number"]

    ap_list = formats["ApList"]
    assert ap_list["example"]
    assert ap_list["parse_rules"], "no parse rules for a delimited payload"
    assert ap_list["supported_ciphers"]


def test_spec_publishes_the_call_sequence(method):
    """Steps must name the actions, in order, with their arguments."""
    actions = [
        step["request"]["action"]
        for step in method["steps"]
        if "request" in step and "action" in step["request"]
    ]
    for required in (
        "GetMetaInfo",
        "GetApList",
        "ConnectHomeNetwork",
        "GetNetworkStatus",
        "CloseSetup",
    ):
        assert required in actions, f"{required} missing from the documented flow"
    assert actions.index("GetApList") < actions.index("ConnectHomeNetwork")
    assert actions.index("ConnectHomeNetwork") < actions.index("GetNetworkStatus")

    connect = next(
        step
        for step in method["steps"]
        if step.get("request", {}).get("action") == "ConnectHomeNetwork"
    )
    argument_names = {a["name"] for a in connect["request"]["arguments"]}
    assert argument_names == {"ssid", "auth", "password", "encrypt", "channel"}


# ── The transcription must reproduce the published vectors ───────────────────


@requires_openssl
def test_transcribed_algorithm_reproduces_the_published_vectors(encryption):
    """The load-bearing test.

    If an implementation written only from the spec's prose reproduces the
    spec's own vectors, the prose is sufficient. If it does not, the spec is
    wrong or incomplete — no matter what our other code does.
    """
    vectors = encryption["test_vectors"]
    meta = parse_meta_info(vectors["input"]["meta_info"])
    password = vectors["input"]["passphrase"]

    assert meta["mac"] == vectors["input"]["mac"]
    assert meta["serial_number"] == vectors["input"]["serial"]
    assert len(password) == vectors["input"]["passphrase_length"]

    variants = {v["method"]: v for v in encryption["variants"]}
    assert len(vectors["vectors"]) == len(variants), "every variant needs a vector"

    for vector in vectors["vectors"]:
        variant = variants[vector["method"]]
        label = f"method {vector['method']}"

        key_data = build_key_data(meta["mac"], meta["serial_number"], variant)
        assert key_data == vector["keydata"], f"{label}: keydata"
        assert key_data[0:8] == vector["salt"], f"{label}: salt"
        assert key_data[0:16] == vector["iv"], f"{label}: iv"

        # Step 4, independently of openssl: one MD5 round, truncated to 16.
        derived = hashlib.md5(  # noqa: S324 - the scheme Wemo uses
            key_data.encode("utf-8") + key_data[0:8].encode("utf-8")
        ).digest()[:16]
        assert derived.hex() == vector["aes_key_hex"], f"{label}: aes key"

        assert encrypt(password, key_data, False) == vector["base64_ciphertext"], (
            f"{label}: ciphertext"
        )
        assert encrypt(password, key_data, vector["add_lengths"]) == (
            vector["password_argument"]
        ), f"{label}: password argument"

        # The vector's add_lengths must agree with its variant's.
        assert vector["add_lengths"] == variant["add_lengths"], f"{label}: add_lengths"


@requires_openssl
def test_length_suffix_is_zero_padded(encryption):
    """A length below 16 must contribute two digits, not one.

    Regression guard for the documented trap: emitting a single hex digit
    yields a blob the device rejects with no explanation.
    """
    vectors = encryption["test_vectors"]
    meta = parse_meta_info(vectors["input"]["meta_info"])
    variant = next(v for v in encryption["variants"] if v["method"] == 1)
    key_data = build_key_data(meta["mac"], meta["serial_number"], variant)

    password = "8charact"  # length 8 -> "08"
    bare = encrypt(password, key_data, False)
    assert encrypt(password, key_data, True) == f"{bare}{len(bare):02x}08"


# ── The spec's own examples must be self-consistent ──────────────────────────


def test_documented_metainfo_example_matches_documented_field_order(method):
    """The example is what a reader parses first; it must match the field list."""
    metainfo = method["payload_formats"]["MetaInfo"]
    parsed = parse_meta_info(metainfo["example"])
    for field in metainfo["fields"]:
        assert parsed[field["name"]] == metainfo["example"].split("|")[field["index"]]


def test_documented_ap_list_example_parses_under_documented_rules(method):
    """A stale example is worse than none — it is what an implementer tests on."""
    ap_format = method["payload_formats"]["ApList"]
    access_points = parse_ap_list(ap_format["example"])

    assert access_points, "the documented example parses to nothing"
    assert [ap["ssid"] for ap in access_points] == [
        "HomeNet",
        "OpenGuest",
        "NewFangled",
    ]
    assert access_points[0]["channel"] == "6"
    assert (access_points[0]["auth"], access_points[0]["encrypt"]) == ("WPA2PSK", "AES")

    # The example must exercise the documented unsupported marker.
    marker = ap_format["unsupported_marker"]["value"]
    unsupported = [ap for ap in access_points if ap["auth"] == marker]
    assert unsupported, f"example never shows the {marker!r} case"
    assert unsupported[0]["encrypt"] not in ap_format["supported_ciphers"]

    # And an open network, since that path skips encryption entirely.
    assert any(ap["encrypt"] == "NONE" for ap in access_points)


def test_status_codes_are_documented_where_they_are_used(method):
    """Every status a client can see must be explained at the polling step."""
    poll = next(
        step
        for step in method["steps"]
        if step.get("request", {}).get("action") == "GetNetworkStatus"
    )
    codes = poll["status_codes"]
    assert set(codes) == {"0", "1", "2", "3"}
    # The two terminal outcomes must be identifiable from the text alone.
    assert "connected" in codes["1"].lower()
    assert "8 characters" in codes["2"]


def test_timing_constants_are_published(method):
    """Values that look arbitrary and are not."""
    timing = method["timing"]
    assert timing["connect_send_count"] == 2, "the duplicate send must be documented"
    assert timing.get("connect_send_gap_ms")
    assert timing.get("status_poll_timeout_seconds")
    assert timing.get("status_poll_minimum_seconds")


def test_troubleshooting_covers_the_known_failure_modes(method):
    """The failures that actually happen, and how to tell them apart."""
    text = " ".join(
        entry["symptom"] + " " + " ".join(entry.get("causes", []))
        for entry in method["troubleshooting"]
    ).lower()
    for topic in ("5 ghz", "wpa3", "encryption variant", "8 characters"):
        assert topic in text, f"troubleshooting does not mention {topic}"


def test_reset_scopes_are_documented(setup):
    """ReSetup takes a scope argument; all three codes must be published."""
    arguments = [
        argument
        for step in setup["rejoin"]["steps"]
        for argument in step.get("request", {}).get("arguments", [])
        if argument["name"] == "Reset"
    ]
    assert arguments, "the Reset argument is not documented"
    description = arguments[0]["description"]
    for code in ("1", "2", "5"):
        assert code in description, f"reset code {code} not documented"


# ── Discovery, transcribed from device.discovery ─────────────────────────────
#
# These reconstruct what a discovery client does, using only what the spec
# publishes. Together they are the evidence that discovery does not need a
# reference implementation shipped alongside the document.


def build_msearch(ssdp: dict, search_target: str) -> bytes:
    """Per device.discovery.methods[].ssdp.request."""
    request = ssdp["request"]
    body = request["template"].format(
        multicast_group=ssdp["multicast_group"],
        multicast_port=ssdp["multicast_port"],
        mx=request["mx"],
        search_target=search_target,
    )
    # "Lines are CRLF-terminated and the request ends with a blank line."
    assert request["line_ending"] == "CRLF"
    return "\r\n".join(body.rstrip("\n").split("\n")).encode("utf-8") + b"\r\n\r\n"


def parse_ssdp_response(raw: str, ssdp: dict) -> dict[str, str]:
    """Per device.discovery.methods[].ssdp.response."""
    assert ssdp["response"]["header_matching"] == "case-insensitive"
    found = {}
    for header in ssdp["response"]["headers_used"]:
        match = re.search(rf"(?im)^{header}:\s*(.+)$", raw)
        if match:
            found[header] = match.group(1).strip()
    return found


def parse_description(xml_text: str) -> dict:
    """Per device.discovery...response_mapping.location.parse.parse_rules."""
    standard = {
        "deviceType",
        "friendlyName",
        "manufacturer",
        "manufacturerURL",
        "modelDescription",
        "modelName",
        "modelNumber",
        "modelURL",
        "serialNumber",
        "UDN",
        "UPC",
        "macAddress",
        "iconList",
        "serviceList",
        "deviceList",
        "presentationURL",
    }

    def local(tag: str) -> str:
        return tag.split("}")[-1] if "}" in tag else tag

    root = ET.fromstring(xml_text)
    # "Some firmware serves it with no namespace at all, so match on local
    # element names rather than requiring the namespace."
    device = next(el for el in root.iter() if local(el.tag) == "device")

    fields, extras, services = {}, {}, []
    for child in device:
        name = local(child.tag)
        text = (child.text or "").strip()
        if name == "serviceList":
            for service in child:
                services.append(
                    {
                        local(item.tag): (item.text or "").strip()
                        for item in service
                    }
                )
        elif name in standard:
            fields[name] = text
        elif text:
            extras[name] = text  # vendor extensions, per the parse rules
    return {"fields": fields, "config_extras": extras, "services": services}


def is_match(candidate: dict, match: dict) -> bool:
    """Per device.discovery.methods[].ssdp.match.rule."""
    haystack = " ".join(candidate.values()).lower()
    # The rule names the two tokens to look for; take them from the spec text
    # rather than hardcoding, so a change to the rule fails this instead.
    tokens = [t for t in ("belkin", "wemo") if t in match["rule"].lower()]
    assert tokens, "the match rule names no token to search for"
    return any(token in haystack for token in tokens)


def test_spec_publishes_the_ssdp_request(ssdp):
    """A client cannot guess CRLF, the quoted MAN value or the trailing blank."""
    request = ssdp["request"]
    assert request["line_ending"] == "CRLF"
    assert request.get("mx"), "MX is not published"
    assert request.get("example"), "no literal datagram to diff against"

    built = build_msearch(ssdp, "urn:Belkin:service:basicevent:1")
    expected = (
        "\r\n".join(request["example"].rstrip("\n").split("\n")).encode("utf-8")
        + b"\r\n\r\n"
    )
    assert built == expected, "the template does not reproduce the published example"

    text = built.decode()
    assert text.startswith("M-SEARCH * HTTP/1.1\r\n")
    assert 'MAN: "ssdp:discover"' in text  # quotes are part of the value
    assert text.endswith("\r\n\r\n")  # blank line terminates the request
    # The listen window must be at least MX, or replies are missed.
    assert ssdp["timing"]["response_wait_seconds"] >= request["mx"]


def test_documented_ssdp_response_parses(ssdp):
    """The published reply must yield the headers the spec says to use."""
    headers = parse_ssdp_response(ssdp["response"]["example"], ssdp)
    assert set(headers) == set(ssdp["response"]["headers_used"])
    assert headers["LOCATION"].endswith("/setup.xml")
    assert headers["USN"].startswith("uuid:")
    # Deduplication key must be one of the headers a client actually reads.
    assert ssdp["response"]["dedupe_by"] in headers


def test_documented_description_parses(spec, ssdp):
    """setup.xml must yield identity, services and the vendor extensions."""
    parse = ssdp["response_mapping"]["location"]["parse"]
    assert parse.get("parse_rules"), "no rules for parsing the description"
    parsed = parse_description(parse["example"])

    # Identity keys named in device.discovery.identity must be obtainable.
    assert parsed["fields"]["UDN"].startswith("uuid:")
    assert parsed["fields"]["serialNumber"]
    assert parsed["fields"]["macAddress"]
    assert parsed["fields"]["friendlyName"]
    assert parsed["fields"]["deviceType"].startswith("urn:Belkin:device:")

    # Control URLs come from the description, never hardcoded.
    assert parsed["services"], "no services parsed"
    service = parsed["services"][0]
    assert service["serviceType"].startswith("urn:Belkin:service:")
    assert service["controlURL"].startswith("/upnp/control/")

    # Vendor extensions must survive — rtos/iot select the setup encryption.
    assert "firmwareVersion" in parsed["config_extras"]
    assert {"rtos", "iot"} <= set(parsed["config_extras"])


def test_description_parses_without_the_upnp_namespace(ssdp):
    """The spec promises namespace-optional parsing; hold it to that."""
    example = ssdp["response_mapping"]["location"]["parse"]["example"]
    stripped = example.replace(' xmlns="urn:schemas-upnp-org:device-1-0"', "")
    parsed = parse_description(stripped)
    assert parsed["fields"]["friendlyName"] == "Kitchen Plug"
    assert parsed["services"]


def test_match_rule_separates_wemo_from_other_upnp_responders(ssdp):
    """ssdp:all is a search target, so everything on the LAN answers."""
    assert "ssdp:all" in ssdp["search_targets"], "match rule would be unnecessary"
    match = ssdp["match"]
    assert match.get("rule"), "no rule for identifying this device's responses"

    wemo = {"manufacturer": match["manufacturer_exact"]}
    printer = {
        "manufacturer": "Brother",
        "deviceType": "urn:schemas-upnp-org:device:Printer:1",
    }
    assert is_match(wemo, match)
    assert not is_match(printer, match)


def test_port_instability_is_documented(ssdp):
    """Ports move; the spec must say so and publish the probe order."""
    assert ssdp["port_fallback"], "no port fallback list"
    assert ssdp.get("port_fallback_notes")
    assert ssdp["timing"].get("port_probe_timeout_seconds")


# ── Control, transcribed from soap_common and payload_formats ────────────────


def build_soap_body(spec: dict, service_type: str, action: str, arguments: dict) -> str:
    """Per soap_common.request_format."""
    request = spec["soap_common"]["request_format"]
    rendered = "\n".join(
        f"<{name}>{value}</{name}>" for name, value in arguments.items()
    )
    return request["template"].format(
        action=action, serviceType=service_type, arguments=rendered
    )


def parse_soap_response(xml_text: str) -> dict[str, str]:
    """Per soap_common.response_format.parse_rule."""
    envelope = ET.fromstring(xml_text)
    body = list(envelope)[0]
    response = list(body)[0]
    return {
        (item.tag.split("}")[-1] if "}" in item.tag else item.tag): (item.text or "")
        for item in response
    }


def parse_delimited(value: str, payload_format: dict) -> dict[str, str]:
    """Per payload_formats.<name>.fields, for pipe-delimited payloads."""
    parts = value.split("|")
    parsed = {
        field["name"]: parts[field["index"]]
        for field in payload_format["fields"]
        if field["index"] < len(parts)
    }
    # "Firmware may append fields beyond those documented here. Keep any extras."
    documented = len(payload_format["fields"])
    for index in range(documented, len(parts)):
        parsed[f"field_{index}"] = parts[index]
    return parsed


def test_soap_request_template_reproduces_the_published_example(spec):
    """Build a request from the template; it must match the spec's own example."""
    request = spec["soap_common"]["request_format"]
    built = build_soap_body(
        spec,
        "urn:Belkin:service:WiFiSetup:1",
        "ConnectHomeNetwork",
        {
            "ssid": "HomeNet",
            "auth": "WPA2PSK",
            "password": "mKUXMHrq3r71VIBnALtgaQH/iTpWEZSSMVizvzMXrVM=2c1c",
            "encrypt": "AES",
            "channel": "6",
        },
    )
    assert built.strip() == request["example"]["body"].strip()

    # And the trap the wire format exists to prevent.
    assert "<ssid>HomeNet</ssid>" in built
    assert "u:ssid" not in built
    ET.fromstring(built)  # must be well-formed


def test_documented_soap_response_parses(spec):
    """The published response must yield its named values under the parse rule."""
    values = parse_soap_response(spec["soap_common"]["response_format"]["example"])
    assert values == {"NetworkStatus": "1"}


def test_control_payload_formats_are_published(spec):
    """The values a control client reads back are not self-describing."""
    formats = spec["payload_formats"]
    assert {"BinaryState", "InsightParams", "MetaInfo"} <= set(formats)

    binary_state = formats["BinaryState"]
    assert binary_state["values"], "on/off values not enumerated"
    # The one that surprises people: 8 means on-but-standby, not a third state.
    assert "8" in binary_state["values"]
    assert binary_state.get("parse_rules"), "pipe-delimited extras not warned about"


def test_documented_insight_params_example_parses(spec):
    """Field alignment is the whole point of documenting this payload."""
    insight = spec["payload_formats"]["InsightParams"]
    parsed = parse_delimited(insight["example"], insight)

    names = [field["name"] for field in insight["fields"]]
    assert names.index("wifipower") == 6, (
        "wifipower must sit between timeperiod and currentpower_mw — omitting it "
        "shifts every power reading one column left"
    )
    assert parsed["state"] == "8"
    assert parsed["wifipower"] == "8000"
    assert parsed["currentpower_mw"] == "18500"
    assert parsed["powerthreshold"] == "8000"


def test_insight_params_keeps_undocumented_trailing_fields(spec):
    """The spec says firmware may append fields; a parser must not drop them."""
    insight = spec["payload_formats"]["InsightParams"]
    extended = insight["example"] + "|42"
    parsed = parse_delimited(extended, insight)
    assert parsed[f"field_{len(insight['fields'])}"] == "42"


def test_control_actions_are_documented_with_their_service(spec):
    """Every action a client sends needs its service URN and control URL."""
    endpoints = {e["name"]: e for e in spec["http_endpoints"]}
    for action in ("GetBinaryState", "SetBinaryState", "GetInsightParams", "GetMetaInfo"):
        assert action in endpoints, f"{action} is not documented"
        assert endpoints[action]["path"].startswith("/upnp/control/")
        # The SOAPACTION header value must be derivable from the description.
        assert "urn:Belkin:service:" in endpoints[action]["description"]

    set_state = endpoints["SetBinaryState"]
    fields = {f["name"] for f in set_state["request_body"]["fields"]}
    assert "BinaryState" in fields
