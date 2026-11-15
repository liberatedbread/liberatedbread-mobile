"""End-to-end test of the Wemo provisioning flow against a fake device.

Stands up an HTTP server that behaves like a Wemo in setup mode — it serves a
realistic ``setup.xml``, answers the WiFiSetup SOAP actions, and, critically,
*decrypts the passphrase it is sent* and refuses to report success unless it
comes back as the original plaintext.

That last part is what makes this more than a mock: it exercises the key
derivation, the OpenSSL invocation, the length suffix and the SOAP wire format
end to end. It cannot prove real firmware agrees with pywemo's documented
scheme, but it does prove this implementation of that scheme is self-consistent
and that the client drives the flow in the right order.

Requires the ``openssl`` binary (as the client itself does).
"""

from __future__ import annotations

import argparse
import base64
import http.server
import shutil
import subprocess
import sys
import threading
from pathlib import Path

import pytest

_scripts_dir = Path(__file__).resolve().parent
if str(_scripts_dir) not in sys.path:
    sys.path.insert(0, str(_scripts_dir))

import wemo_setup  # noqa: E402

pytestmark = pytest.mark.skipif(
    shutil.which("openssl") is None, reason="openssl binary not available"
)

MAC = "94103E36AF15"
SERIAL = "221517K0101769"
META_INFO = f"{MAC}|{SERIAL}|Wemo_WW|WeMo_US_2.00.11408|Wemo.Mini.4A2|Socket"
WIFI_PASSWORD = "correct horse battery staple"
TARGET_SSID = "HomeNet"

AP_LIST = (
    "3\n"
    f"{TARGET_SSID}|6|WPA2PSK|blah|WPA2PSK/AES,\n"
    "Neighbour|11|WPA2PSK|blah|WPA2PSK/AES,\n"
    "OpenGuest|1|OPEN|blah|OPEN/NONE,\n"
)

SETUP_XML_TEMPLATE = """<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <device>
    <deviceType>urn:Belkin:device:controllee:1</deviceType>
    <friendlyName>Wemo Mini</friendlyName>
    <manufacturer>Belkin International Inc.</manufacturer>
    <modelName>Socket</modelName>
    <modelNumber>1.0</modelNumber>
    <serialNumber>{serial}</serialNumber>
    <macAddress>{mac}</macAddress>
    <UDN>uuid:Socket-1_0-{serial}</UDN>
    <firmwareVersion>WeMo_US_2.00.11408</firmwareVersion>
    <rtos>{rtos}</rtos>
    <iot>{iot}</iot>
    <serviceList>
      <service>
        <serviceType>urn:Belkin:service:basicevent:1</serviceType>
        <serviceId>urn:Belkin:serviceId:basicevent1</serviceId>
        <controlURL>/upnp/control/basicevent1</controlURL>
        <eventSubURL>/upnp/event/basicevent1</eventSubURL>
        <SCPDURL>/eventservice.xml</SCPDURL>
      </service>
      <service>
        <serviceType>urn:Belkin:service:metainfo:1</serviceType>
        <serviceId>urn:Belkin:serviceId:metainfo1</serviceId>
        <controlURL>/upnp/control/metainfo1</controlURL>
        <eventSubURL>/upnp/event/metainfo1</eventSubURL>
        <SCPDURL>/metainfoservice.xml</SCPDURL>
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

SOAP_RESPONSE = (
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
    "<s:Body>"
    '<u:{action}Response xmlns:u="{service}">{values}</u:{action}Response>'
    "</s:Body></s:Envelope>"
)


def decrypt(blob: str, key_data: str, add_lengths: bool) -> str:
    """Decrypt what the client sent, the way real firmware would have to."""
    if add_lengths:
        # Trailing xxyy: encrypted length, plaintext length, two hex digits each.
        encoded, plain_len = blob[:-4], int(blob[-2:], 16)
        assert int(blob[-4:-2], 16) == len(encoded), "encrypted length mismatch"
    else:
        encoded, plain_len = blob, None

    proc = subprocess.run(
        [
            "openssl",
            "enc",
            "-d",
            "-aes-128-cbc",
            "-md",
            "md5",
            "-S",
            key_data[0:8].encode().hex(),
            "-iv",
            key_data[0:16].encode().hex(),
            "-pass",
            f"pass:{key_data}",
        ],
        input=base64.b64decode(encoded),
        capture_output=True,
        check=True,
    )
    plaintext = proc.stdout.decode()
    if plain_len is not None:
        assert len(plaintext) == plain_len, "plaintext length mismatch"
    return plaintext


class FakeWemo:
    """A Wemo device in setup mode, as far as the client can tell."""

    def __init__(
        self, rtos: str = "0", iot: str = "0", close_setup_supported: bool = True
    ) -> None:
        self.rtos = rtos
        self.iot = iot
        #: Some firmware has no CloseSetup action; when False it 500s, as a
        #: real device without the action would.
        self.close_setup_supported = close_setup_supported
        self.calls: list[str] = []
        self.received: dict[str, str] = {}
        self.decrypted_password: str | None = None
        #: 0 connecting, 3 handshaking, 1 connected — walked in that order.
        self._status_sequence: list[str] = []
        self.setup_closed = False
        self.setup_done_status_called = False

        server = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):  # noqa: ARG002 - silence test output
                pass

            def _send(self, payload: bytes, content_type: str = "text/xml") -> None:
                self.send_response(200)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def do_GET(self):  # noqa: N802 - BaseHTTPRequestHandler API
                if self.path != "/setup.xml":
                    self.send_error(404)
                    return
                self._send(
                    SETUP_XML_TEMPLATE.format(
                        mac=MAC, serial=SERIAL, rtos=server.rtos, iot=server.iot
                    ).encode()
                )

            def do_POST(self):  # noqa: N802 - BaseHTTPRequestHandler API
                length = int(self.headers.get("Content-Length", 0))
                body = self.rfile.read(length).decode()
                soap_action = self.headers.get("SOAPACTION", "").strip('"')
                service, _, action = soap_action.partition("#")
                server.calls.append(action)

                values = server.handle(action, body)
                if values is None:
                    self.send_error(500)
                    return
                rendered = "".join(f"<{k}>{v}</{k}>" for k, v in values.items())
                self._send(
                    SOAP_RESPONSE.format(
                        action=action, service=service, values=rendered
                    ).encode()
                )

        self._httpd = http.server.HTTPServer(("127.0.0.1", 0), Handler)
        self.port = self._httpd.server_port
        self._thread = threading.Thread(target=self._httpd.serve_forever, daemon=True)

    def handle(self, action: str, body: str) -> dict[str, str] | None:
        if action == "GetMetaInfo":
            return {"MetaInfo": META_INFO}
        if action == "GetApList":
            return {"ApList": AP_LIST}
        if action == "ConnectHomeNetwork":
            for field in ("ssid", "auth", "password", "encrypt", "channel"):
                start = body.find(f"<{field}>")
                end = body.find(f"</{field}>")
                if start >= 0:
                    self.received[field] = body[start + len(field) + 2 : end]
            if self.received.get("encrypt") == "NONE":
                # Open network: no passphrase is sent, nothing to decrypt.
                self.decrypted_password = ""
                self._status_sequence = ["0", "3", "1"]
                return {"PairingStatus": "Connecting"}

            method, add_lengths = (
                (2, False) if self.rtos == "1" and self.iot != "1" else (1, True)
            )
            meta = wemo_setup.MetaInfo.parse(META_INFO)
            key_data = wemo_setup.build_key_data(meta, method)
            self.decrypted_password = decrypt(
                self.received["password"], key_data, add_lengths
            )
            # Only start walking towards success if the credentials decode.
            if self.decrypted_password == WIFI_PASSWORD:
                self._status_sequence = ["0", "3", "1"]
            return {"PairingStatus": "Connecting"}
        if action == "GetNetworkStatus":
            if not self._status_sequence:
                return {"NetworkStatus": "0"}
            value = self._status_sequence[0]
            if len(self._status_sequence) > 1:
                self._status_sequence.pop(0)
            return {"NetworkStatus": value}
        if action == "CloseSetup":
            if not self.close_setup_supported:
                return None  # 500, as a device without the action would
            self.setup_closed = True
            return {"status": "success"}
        if action == "SetSetupDoneStatus":
            self.setup_done_status_called = True
            return {"status": "success"}
        return None

    def __enter__(self) -> FakeWemo:
        self._thread.start()
        return self

    def __exit__(self, *exc) -> None:
        self._httpd.shutdown()
        self._httpd.server_close()


def connect_args(port: int, **overrides) -> argparse.Namespace:
    defaults = dict(
        device="127.0.0.1",
        port=port,
        execute=True,
        timeout=5,
        ssid=TARGET_SSID,
        encrypt_method=None,
        add_lengths=None,
        attempts=1,
        timeout_connect=5.0,
        status_delay=0.01,
    )
    defaults.update(overrides)
    return argparse.Namespace(**defaults)


def test_connect_drives_the_full_flow(monkeypatch, capsys):
    """The happy path: the device decrypts our passphrase and reports success."""
    monkeypatch.setenv("WEMO_WIFI_PASSWORD", WIFI_PASSWORD)

    with FakeWemo() as device:
        assert wemo_setup.cmd_connect(connect_args(device.port)) == 0

        # The device got the credentials it expected, and they decrypt.
        assert device.decrypted_password == WIFI_PASSWORD
        assert device.received["ssid"] == TARGET_SSID
        # Auth mode, cipher and channel are taken from the device's own scan,
        # not from anything the user typed.
        assert device.received["auth"] == "WPA2PSK"
        assert device.received["encrypt"] == "AES"
        assert device.received["channel"] == "6"

        # Order matters: scan, then key material, then credentials, then close.
        assert device.calls[0] == "GetApList"
        assert device.calls.index("GetMetaInfo") < device.calls.index(
            "ConnectHomeNetwork"
        )
        # ConnectHomeNetwork is deliberately sent twice.
        assert device.calls.count("ConnectHomeNetwork") == 2
        assert device.setup_closed
        assert device.setup_done_status_called

    out = capsys.readouterr().out
    assert WIFI_PASSWORD not in out
    assert f"Connected to {TARGET_SSID}" in out


def test_connect_succeeds_when_close_setup_is_absent(monkeypatch, capsys):
    """A device that joined but has no CloseSetup action is still a success.

    Regression: CloseSetup 500ing (or being absent) must not turn a completed
    join into a reported failure. pywemo tolerates it; so must we.
    """
    monkeypatch.setenv("WEMO_WIFI_PASSWORD", WIFI_PASSWORD)

    with FakeWemo(close_setup_supported=False) as device:
        assert wemo_setup.cmd_connect(connect_args(device.port)) == 0
        assert device.decrypted_password == WIFI_PASSWORD
        assert not device.setup_closed  # the action 500'd

    out = capsys.readouterr().out
    assert f"Connected to {TARGET_SSID}" in out
    assert "CloseSetup: not available" in out


def test_explicit_encrypt_method_uses_that_methods_length_default(monkeypatch):
    """`--encrypt-method 1` alone must still append the lengths, as method 1 does.

    Regression: an explicit method with no --add-lengths previously fell to
    False, so the device rejected a method-1 blob and the method looked broken.
    The FakeWemo expects method 1 with lengths, so a wrong default fails here.
    """
    monkeypatch.setenv("WEMO_WIFI_PASSWORD", WIFI_PASSWORD)

    with FakeWemo() as device:  # default firmware -> method 1, add_lengths True
        assert (
            wemo_setup.cmd_connect(connect_args(device.port, encrypt_method=1)) == 0
        )
        assert device.decrypted_password == WIFI_PASSWORD


def test_connect_uses_method_2_for_rtos_firmware(monkeypatch):
    """A device advertising rtos=1 gets the method-2 key and no length suffix."""
    monkeypatch.setenv("WEMO_WIFI_PASSWORD", WIFI_PASSWORD)

    with FakeWemo(rtos="1") as device:
        assert wemo_setup.cmd_connect(connect_args(device.port)) == 0
        assert device.decrypted_password == WIFI_PASSWORD
        # Method 2 omits the four trailing hex digits, so the whole field is
        # valid base64 with nothing to strip.
        assert base64.b64decode(device.received["password"], validate=True)


def test_connect_reports_unknown_ssid(monkeypatch):
    monkeypatch.setenv("WEMO_WIFI_PASSWORD", WIFI_PASSWORD)
    with FakeWemo() as device:
        with pytest.raises(wemo_setup.SetupError, match="cannot see a network"):
            wemo_setup.cmd_connect(connect_args(device.port, ssid="NoSuchNetwork"))


def test_connect_rejects_short_password(monkeypatch):
    monkeypatch.setenv("WEMO_WIFI_PASSWORD", "short")
    with FakeWemo() as device:
        with pytest.raises(wemo_setup.SetupError, match="at least 8"):
            wemo_setup.cmd_connect(connect_args(device.port))


def test_open_network_sends_no_passphrase(monkeypatch):
    """An open network gets auth=OPEN and an empty password field."""
    monkeypatch.setenv("WEMO_WIFI_PASSWORD", WIFI_PASSWORD)
    with FakeWemo() as device:
        assert wemo_setup.cmd_connect(
            connect_args(device.port, ssid="OpenGuest")
        ) == 0
        assert device.received["auth"] == "OPEN"
        assert device.received["encrypt"] == "NONE"
        assert device.received["password"] == ""
        # No key material is needed, so the device is never asked for it.
        assert "GetMetaInfo" not in device.calls


def test_info_reports_the_encryption_variant(capsys):
    with FakeWemo(rtos="1") as device:
        args = argparse.Namespace(
            device="127.0.0.1", port=device.port, execute=True, timeout=5
        )
        assert wemo_setup.cmd_info(args) == 0

    out = capsys.readouterr().out
    assert "method=2" in out
    assert "add_lengths=False" in out
    assert "Wemo.Mini.4A2" in out  # setup AP SSID from MetaInfo
    assert SERIAL in out


def test_reset_sends_the_wifi_code(capsys):
    with FakeWemo() as device:
        args = argparse.Namespace(
            device="127.0.0.1",
            port=device.port,
            execute=True,
            timeout=5,
            wifi=True,
            data=False,
            factory=False,
        )
        # The fake returns None for ReSetup, so the client reports a failure —
        # what matters here is the Reset code that went out on the wire.
        with pytest.raises(wemo_setup.SetupError):
            wemo_setup.cmd_reset(args)
        assert device.calls == ["ReSetup"]

    out = capsys.readouterr().out
    assert "Reset=5" in out
