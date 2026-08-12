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
    """Per payload_formats.<name>.delimiter and .fields."""
    parts = value.split(payload_format["delimiter"])
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
    # The split rule has to be executable, not merely stated: a consumer that
    # cannot find the state in the long form reports a live plug as off.
    assert binary_state.get("delimiter"), "the long form's separator is not declared"
    assert binary_state.get("fields"), "no field says where the state sits"
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


# ── The control surface, transcribed from `commands` and `entities` ──────────
#
# The claim these hold to account: the two devices we have hardware for — the
# smart plugs and the Crock-Pot — can be *driven* from this file, not merely
# found and provisioned. A consumer reads `entities` for what to draw and
# where each control reads its state, `commands` for what to send, and
# `http_endpoints` for the actions both of those name. Nothing below imports
# our own code, and nothing consults pywemo: if a binding here resolves to
# nothing, the spec has published a control that reaches nothing.


@pytest.fixture(scope="module")
def commands(spec) -> dict:
    return spec["commands"]


@pytest.fixture(scope="module")
def entities(spec) -> list:
    return spec["entities"]


@pytest.fixture(scope="module")
def endpoints(spec) -> dict:
    return {endpoint["name"]: endpoint for endpoint in spec["http_endpoints"]}


PLACEHOLDER = re.compile(r"^\{(.+)\}$")


def render_command(spec: dict, command: dict, values: dict | None = None) -> str:
    """Per the `commands` block, rendered through soap_common.request_format.

    The whole client-side procedure the block documents: default what the
    caller did not supply, substitute `{name}` arguments from `parameters`,
    and hand the result to the shared SOAP template.
    """
    supplied = dict(values or {})
    for name, parameter in (command.get("parameters") or {}).items():
        if name not in supplied and "default" in parameter:
            supplied[name] = parameter["default"]

    arguments = {}
    for name, template in command["arguments"].items():
        match = PLACEHOLDER.match(str(template))
        arguments[name] = str(supplied[match.group(1)]) if match else str(template)
    return build_soap_body(spec, command["service"], command["action"], arguments)


def user_parameters(command: dict) -> list[str]:
    """Parameters the caller supplies: neither defaulted nor read back.

    A `source` parameter is not the caller's — the client fetches it from the
    device as part of the send — but it is also not a blank that disqualifies
    the command, which is why it is excluded here rather than counted.
    """
    return [
        name
        for name, parameter in (command.get("parameters") or {}).items()
        if "default" not in parameter and "source" not in parameter
    ]


def entity_state(returned: dict, entity: dict, payload_formats: dict) -> object:
    """Read one entity's state out of what its state command returned.

    Transcribes the rule the `entities` block states: `state_mapping.value`
    names a value the call RETURNS, `payload_formats` says how to parse that
    value when it is not a bare number, and `on_when: nonzero` is what decides
    on/off.
    """
    mapping = entity["state_mapping"]
    raw = returned[mapping["value"]]

    # A returned value may pack several fields into one string, and only the
    # spec knows: the delimiter and the field index are declared, so this
    # follows data rather than reading the prose rule beside them.
    payload_format = payload_formats.get(mapping["value"])
    if payload_format and payload_format.get("delimiter"):
        index = min(field["index"] for field in payload_format["fields"])
        raw = raw.split(payload_format["delimiter"])[index]

    if mapping.get("on_when") == "nonzero":
        return int(raw) != 0
    if "options" in mapping:
        return mapping["options"].get(int(raw), "unknown")
    return int(raw)


def test_every_entity_binding_resolves(spec, entities, commands, endpoints):
    """A name that resolves to nothing is a control the user cannot use.

    Each entity names an action to read its state and, per role, a command to
    send. Both namespaces are in this file; neither is searched by luck.
    """
    variant_names = {variant["name"] for variant in spec["device"]["variants"]}
    for entity in entities:
        label = entity["name"]

        assert entity["state_command"] in endpoints, (
            f"{label}: state_command {entity['state_command']!r} names no "
            "http_endpoints entry"
        )
        assert entity["state_endpoint"] == endpoints[entity["state_command"]]["path"], (
            f"{label}: state_endpoint disagrees with the endpoint it names"
        )

        for role, command_name in (entity.get("commands") or {}).items():
            assert command_name in commands, (
                f"{label}: role {role!r} binds {command_name!r}, which the "
                "`commands` block does not declare"
            )

        for variant in entity.get("variants") or []:
            assert variant in variant_names, (
                f"{label}: scoped to variant {variant!r}, which "
                "device.variants does not list"
            )


def test_every_command_names_a_documented_action(spec, commands, endpoints):
    """`commands` invokes; `http_endpoints` documents. They must agree."""
    for name, command in commands.items():
        assert command["transport"] == "soap"
        action = command["action"]
        assert action in endpoints, f"{name}: action {action!r} is not documented"
        assert endpoints[action].get("service") == command["service"], (
            f"{name}: the endpoint for {action} does not declare the service "
            "this command sends it to (or declares a different one)"
        )
        assert command.get("verification"), f"{name}: does not say how well it is known"


def test_state_commands_have_a_machine_readable_service(spec, entities, endpoints):
    """A state read needs a SOAPACTION header, and prose cannot supply one.

    Every endpoint an entity reads its state from must declare `service` as
    data — and it must agree with the URN the description states, because two
    spellings of one fact are only safe while something checks them.
    """
    for entity in entities:
        endpoint = endpoints[entity["state_command"]]
        service = endpoint.get("service")
        assert service, (
            f"{entity['name']}: state endpoint {entity['state_command']} "
            "declares no service, so a client cannot build the SOAPACTION "
            "header for the state read"
        )
        assert service in endpoint["description"], (
            f"{entity['name']}: the declared service and the description "
            "disagree about which service this action belongs to"
        )


def test_command_arguments_only_reference_declared_parameters(commands):
    """A `{placeholder}` with no parameter behind it cannot be substituted."""
    for name, command in commands.items():
        declared = set(command.get("parameters") or {})
        referenced = {
            match.group(1)
            for value in command["arguments"].values()
            for match in [PLACEHOLDER.match(str(value))]
            if match
        }
        assert not referenced - declared, (
            f"{name}: references {sorted(referenced - declared)} with no such "
            "parameter declared"
        )
        assert not declared - referenced, (
            f"{name}: declares {sorted(declared - referenced)}, which no "
            "argument uses — a parameter nothing substitutes reaches nothing"
        )


def test_role_commands_are_sendable(entities, commands):
    """A control can only send a command whose every blank it can fill.

    The rule a consumer applies before drawing anything: each parameter is
    either the value this control owns or one the spec defaults. Two blanks
    and one value means the control cannot send it — which is why the
    Crock-Pot's writes carry a `source` and a default for the setting they are
    not changing.
    """
    fixed_roles = {"turn_on", "turn_off", "press"}
    for entity in entities:
        for role, command_name in (entity.get("commands") or {}).items():
            command = commands[command_name]
            blanks = user_parameters(command)
            if role in fixed_roles:
                assert not blanks, (
                    f"{entity['name']}: {role} binds {command_name}, which "
                    f"still needs {blanks} — a toggle has nothing to fill them "
                    "with"
                )
            else:
                assert len(blanks) == 1, (
                    f"{entity['name']}: {role} binds {command_name}, which "
                    f"needs {blanks}; a single control supplies one value"
                )

            # Every parameter the control does not supply is either protocol
            # filler (default) or a read-back (source) — and never both. A
            # parameter carrying both would let a renderer substitute the
            # constant when the read-back fails, which on this device is a
            # cleared timer with nothing on screen saying so.
            for name, parameter in (command.get("parameters") or {}).items():
                if name in blanks:
                    continue
                assert ("default" in parameter) != ("source" in parameter), (
                    f"{command_name}: parameter {name!r} must carry exactly "
                    "one of `default` (a genuine constant) or `source` (a "
                    "mandatory read-back)"
                )


def test_commands_render_the_published_example_bodies(spec, commands):
    """The load-bearing control test: data in, the documented bytes out."""
    assert render_command(spec, commands["plug_turn_on"]).strip() == (
        commands["plug_turn_on"]["example_body"].strip()
    )

    # Low for four hours: the mode the control chose, the cook time it read
    # back from the device and is handing straight to the write.
    built = render_command(spec, commands["set_cook_mode"], {"mode": 51, "time": 240})
    assert built.strip() == commands["set_cook_mode"]["example_body"].strip()
    assert "<mode>51</mode>" in built and "<time>240</time>" in built
    ET.fromstring(built)

    # Off is the one Crock-Pot write with nothing to read back first.
    off = render_command(spec, commands["crockpot_turn_off"])
    assert "<mode>0</mode>" in off and "<time>0</time>" in off


def test_crockpot_read_backs_are_mandatory_not_defaulted(commands):
    """The trap the `source` key exists for, and the fix review forced.

    SetCrockpotState carries mode and time together, so a client changing one
    must send the other back unchanged. The first published version paired
    each `source` with `default: 0` as a fallback — which is a renderer
    quietly clearing the timer (or stopping a running cooker) whenever the
    read-back fails. A `source` parameter now carries NO default: rendering
    without the value must fail, visibly.
    """
    for name in ("set_cook_mode", "set_cook_time", "crockpot_turn_on"):
        read_backs = {
            parameter["source"]
            for parameter in commands[name]["parameters"].values()
            if "source" in parameter
        }
        expected = "state:GetCrockpotState." + ("time" if name != "set_cook_time" else "mode")
        assert read_backs == {expected}, f"{name}: the value it must read back is not named"
        for parameter in commands[name]["parameters"].values():
            if "source" in parameter:
                assert "default" not in parameter, (
                    f"{name}: a read-back parameter with a default is a "
                    "silent wrong write waiting for a failed read"
                )
                assert parameter.get("required") is not True, (
                    f"{name}: `required` means the CALLER supplies it; a "
                    "read-back is the client's job"
                )


def test_rendering_without_a_read_back_value_fails(spec, commands):
    """The rule the missing defaults create, exercised.

    A picker that could not fetch the cook time must get an error, not a
    request with an invented timer in it.
    """
    with pytest.raises(KeyError):
        render_command(spec, commands["set_cook_mode"], {"mode": 51})
    with pytest.raises(KeyError):
        render_command(spec, commands["crockpot_turn_on"])
    # Off has no read-back, so it renders from nothing at all.
    render_command(spec, commands["crockpot_turn_off"])


def test_documented_crockpot_response_drives_every_crockpot_entity(
    spec, entities, endpoints
):
    """One published response must yield every control's state.

    This is the whole claim in one assertion: a consumer holding this file and
    a device answers "what do I show?" without reading anything else.
    """
    returned = parse_soap_response(endpoints["GetCrockpotState"]["response_body"]["example"])
    assert set(returned) == {"mode", "time", "cookedTime"}

    documented = {
        field["name"] for field in endpoints["GetCrockpotState"]["response_body"]["fields"]
    }
    assert set(returned) == documented, "the example and the field list disagree"

    states = {
        entity["name"]: entity_state(returned, entity, spec["payload_formats"])
        for entity in entities
        if entity["state_command"] == "GetCrockpotState"
    }
    assert states == {
        "Slow Cooker": True,  # mode 51 is not off
        "Cook Mode": "low",
        "Cook Time": 240,
        "Cooked Time": 15,
    }


def test_documented_binary_state_response_reads_as_on(spec, entities, endpoints):
    """The plug's own example, through the documented split rule.

    The published response is the long pipe-delimited form with a leading 8,
    which is the case that goes wrong quietly: parsed whole it is not a
    number, and read as a plain state 8 is not 1.
    """
    returned = parse_soap_response(endpoints["GetBinaryState"]["response_body"]["example"])
    plug = next(entity for entity in entities if entity["name"] == "Plug")
    assert entity_state(returned, plug, spec["payload_formats"]) is True

    # And the spec must say what 8 means, since that is why it is True.
    assert "8" in spec["payload_formats"]["BinaryState"]["values"]


def test_select_options_agree_with_the_payload_format(spec, entities):
    """The mode table is stated twice on purpose; it must not drift.

    `payload_formats.CrockpotMode` is where a parser reads it, the select's
    `options` is where a consumer that reads entities alone finds its labels.
    Two spellings of one fact are fine only while something checks them.
    """
    select = next(entity for entity in entities if entity["platform"] == "select")
    published = spec["payload_formats"]["CrockpotMode"]["values"]
    assert {str(code): label for code, label in select["state_mapping"]["options"].items()} == (
        published
    )


def test_the_crockpot_switch_does_not_read_binary_state(spec, entities):
    """The documented trap, held to.

    Every other Wemo switch reads BinaryState. The Crock-Pot answers 0 there
    whatever it is doing, so binding the obvious thing gives a cooker that
    always reads off — and nothing about the response says so.
    """
    cooker = next(entity for entity in entities if entity["name"] == "Slow Cooker")
    assert cooker["state_command"] == "GetCrockpotState"
    assert cooker["state_mapping"]["value"] == "mode"

    variant = next(
        v for v in spec["device"]["variants"] if v["model"].startswith("SCCPWM600")
    )
    warning = " ".join(variant["characteristics"]).lower()
    assert "binarystate is not this device's state" in warning, (
        "the variant must warn about the surface that lies, not just avoid it"
    )


# ── Scheduling, transcribed from the `scheduling` block ──────────────────────


@pytest.fixture(scope="module")
def scheduling(spec) -> dict:
    return spec["scheduling"]


def test_scheduling_says_whether_it_survives_the_client_going_away(scheduling):
    """The one fact a feature gets designed around.

    "Turn it on at five" means two different things depending on this field: a
    schedule the device keeps, or a timer that dies when the phone sleeps. A
    block that documents a mechanism without answering it has documented the
    less useful half.
    """
    assert scheduling["supported"] is True
    assert scheduling["mechanism"] == "on_device_rules"
    assert scheduling["runs_without_a_client"] is True
    # A stored schedule is only as right as the clock under it, and these
    # devices lost their time source when the cloud went away.
    assert "timesync" in scheduling["device_clock_dependency"].lower()


def test_scheduling_publishes_the_whole_round_trip(scheduling):
    """Fetch, edit, store — and the store call's three arguments.

    The database moves whole in both directions, so a client that knows only
    how to fetch has no way to write and a client that knows only how to store
    deletes everything.
    """
    actions = [
        step["request"]["action"]
        for step in scheduling["transfer"]["steps"]
        if "request" in step
    ]
    assert actions[0] == "FetchRules"
    assert actions[-1] == "StoreRules"

    store = scheduling["transfer"]["steps"][-1]["request"]
    argument_names = {a["name"] for a in store["arguments"]}
    assert argument_names == {"ruleDbVersion", "processDb", "ruleDbBody"}

    # The escaping that looks like a bug and is not: the argument's text
    # literally contains an escaped CDATA wrapper.
    body = next(a for a in store["arguments"] if a["name"] == "ruleDbBody")
    assert "&lt;![CDATA[" in body["description"]

    # And the rule that keeps a client from wiping rules made in an app the
    # user can no longer reinstall.
    edit = next(step for step in scheduling["transfer"]["steps"] if "request" not in step)
    assert "FETCH, MODIFY, STORE" in edit["expect"]


def test_scheduling_states_what_it_cannot_do(scheduling):
    """The limits, and the unknowns, in the spec rather than in a bug report.

    A rule's action is a number meaning on, off or toggle. Nothing in the
    table carries a cooking mode — so "start it on Low at five" is not
    expressible, however much a column list suggests otherwise. Anyone
    designing that feature should learn it here.
    """
    limits = " ".join(scheduling["limitations"]).lower()
    assert "toggle" in limits, "the action vocabulary is not stated"
    assert "not part of this" in limits, "the cook timer is not distinguished from a schedule"

    assert scheduling["open_questions"], "no unknowns listed, which is never true"
    unknowns = " ".join(scheduling["open_questions"]).lower()
    assert "dayid" in unknowns, "the column a wrong guess fires on the wrong day is not flagged"

    # Every worked row must say where it came from, since the two sources are
    # a maintained implementation and a nine-year-old capture.
    for example in scheduling["storage"]["examples"]:
        assert example["source"]
        assert example["verification"] == "reported"
