#!/usr/bin/env python3
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Provision a Belkin Wemo device onto a WiFi network without the vendor app.

Drives the WiFiSetup SOAP service a Wemo device exposes while it is in setup
mode, so a factory-reset device can be joined to a network — and an already
provisioned one can be moved to a different network — entirely locally. The
Belkin cloud is not involved at any point.

Run this while joined to the device's own setup access point (an open network
named ``Wemo.*``); the device answers on 10.22.22.1. The exception is
``reset``, which is sent to a device still on your LAN.

Every subcommand is a DRY RUN by default and prints the SOAP it would send.
Pass --execute to actually talk to the device.

Usage:
    python scripts/wemo_setup.py info --execute
    python scripts/wemo_setup.py list-aps --execute
    python scripts/wemo_setup.py connect --ssid HomeNet --execute
    python scripts/wemo_setup.py status --execute
    python scripts/wemo_setup.py reset --wifi --device 192.168.1.42 --execute

The WiFi passphrase is read from the WEMO_WIFI_PASSWORD environment variable
or prompted for without echo. It is never printed and never logged.

Environment:
    Python 3 stdlib only, plus the `openssl` command-line tool for the
    AES-128-CBC passphrase encryption the device requires (Python's stdlib has
    no AES implementation).

Protocol source: this implements the flow in pywemo's
``pywemo/ouimeaux_device/__init__.py`` (Apache 2.0), which is the maintained
reference and has been exercised against real hardware across several device
generations. Its encryption derivation in turn credits Vadim Kantorov's
``wemosetup``. The encryption reproduces the spec's published test vectors —
see ``scripts/test_wemo_spec.py`` and ``scripts/test_wemo.py``. If this script
fails against your device, pywemo itself is the better-tested fallback.

VERIFICATION SCAFFOLDING — NOT A SUPPORTED CLIENT.

This exists to check `device-specs/devices/wemo-devices.yaml` against real
hardware, because every `methods[].verified` in that spec is still false. Once
the spec is confirmed it should be deleted; see issue #16.

For actually using a Wemo device, use pywemo (https://github.com/pywemo/pywemo).
It is maintained and tested against far more hardware than this is, and it is
what our documentation points people at. The spec is this project's
contribution; `scripts/test_wemo_spec.py` is what proves the spec stands on its
own without any client.
"""

from __future__ import annotations

import argparse
import base64
import getpass
import os
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from typing import Optional
from urllib.error import URLError

# Sibling modules: sys.path[0] is scripts/ when run as `python scripts/...`.
from wemo_control import (  # noqa: E402
    SERVICE_BASICEVENT,
    SERVICE_METAINFO,
    SERVICE_WIFI,
    build_soap_body,
    parse_soap_values,
    post_soap,
    soapaction_header,
)
from wemo_discover import WemoDevice, device_at  # noqa: E402

# ── Constants ────────────────────────────────────────────────────────────────

#: Address a Wemo device answers on while hosting its own setup AP.
SETUP_AP_HOST = "10.22.22.1"

#: Fallback control paths, used only when setup.xml cannot be read. The
#: spelling varies across firmware generations; setup.xml is authoritative.
FALLBACK_CONTROL_PATHS = {
    SERVICE_WIFI: "/upnp/control/WiFiSetup1",
    SERVICE_METAINFO: "/upnp/control/metainfo1",
    SERVICE_BASICEVENT: "/upnp/control/basicevent1",
}

#: GetNetworkStatus values, per pywemo.
NETWORK_STATUS = {
    "0": "connecting",
    "1": "connected",
    "2": "rejected: password shorter than 8 characters",
    "3": "handshaking (usually becomes 1 shortly)",
}
STATUS_CONNECTED = "1"
STATUS_SHORT_PASSWORD = "2"
STATUS_HANDSHAKING = "3"
#: Statuses that end the polling loop — no point retrying either one.
TERMINAL_STATUSES = {STATUS_CONNECTED, STATUS_SHORT_PASSWORD}

#: Cipher names the device accepts in ConnectHomeNetwork's `encrypt` argument.
SUPPORTED_ENCRYPTIONS = {"NONE", "AES", "TKIPAES"}

#: Wemo firmware rejects passphrases shorter than this (reported as status 2).
MIN_PASSWORD_LENGTH = 8

#: Constants baked into the two later key-derivation variants.
METHOD2_KEY_SUFFIX = "b3{8t;80dIN{ra83eC1s?M70?683@2Yf"
METHOD3_KEY_EXTRA = "b2Ujb3Rtb24mY3ZEbmlhaXBBZGFiT25v"

#: Placeholder shown instead of the encrypted passphrase in dry-run output.
PASSWORD_PLACEHOLDER = "[encrypted-passphrase-not-shown]"

#: ReSetup Reset codes, per pywemo. Names match the Wemo app's wording.
RESET_CODES = {
    "data": (1, "Clear Personalized Info — name, icon and rules"),
    "factory": (2, "Factory Restore — everything, including WiFi"),
    "wifi": (5, "Change Wi-Fi — WiFi credentials only"),
}


class SetupError(RuntimeError):
    """A provisioning step failed in a way the user needs to act on."""


@dataclass(frozen=True)
class MetaInfo:
    """Parsed metainfo#GetMetaInfo output.

    The pipe-delimited MetaInfo string is six fields; the first two supply the
    key material for passphrase encryption. Field order per pywemo's
    ``util.MetaInfo``.
    """

    mac: str
    serial_number: str
    device_sku: str
    firmware_version: str
    access_point_ssid: str
    model_name: str

    @classmethod
    def parse(cls, value: str) -> MetaInfo:
        fields = value.split("|")
        if len(fields) < 6:
            raise SetupError(
                f"MetaInfo has {len(fields)} field(s), expected at least 6: "
                f"{value!r}"
            )
        return cls(*fields[:6])


@dataclass(frozen=True)
class AccessPoint:
    """One entry from the device's WiFi scan."""

    ssid: str
    channel: str
    auth_mode: str
    encryption: str
    raw: str

    @property
    def supported(self) -> bool:
        return self.encryption in SUPPORTED_ENCRYPTIONS


# ── Passphrase encryption ────────────────────────────────────────────────────


def build_key_data(meta: MetaInfo, method: int) -> str:
    """Build the key material for one of the three encryption variants.

    Which variant a device wants depends on its firmware; see
    :func:`detect_encryption_method`.
    """
    mac, serial = meta.mac, meta.serial_number

    if method == 1:
        key_data = mac[:6] + serial + mac[6:12]
    elif method == 2:
        key_data = mac[:6] + serial + mac[6:12] + METHOD2_KEY_SUFFIX
    elif method == 3:
        key_data = (
            mac[:3] + mac[9:12] + serial + METHOD3_KEY_EXTRA + mac[6:9] + mac[3:6]
        )
    else:
        raise SetupError(f"encryption method {method} must be 1, 2 or 3")

    if len(key_data) < 16:
        raise SetupError(
            f"derived key material is {len(key_data)} characters; 16 are "
            "needed for the initialization vector. The device's MetaInfo may "
            "not be in the expected form."
        )
    return key_data


def detect_encryption_method(device: WemoDevice) -> tuple[int, bool]:
    """Pick the encryption variant and length-suffix behaviour for a device.

    Derived from the non-standard elements Belkin adds to setup.xml. pywemo
    notes that the Wemo APK's own logic (binaryOption -> 3, new_algo -> 2)
    matches hardware less often than keying off rtos/iot, so this follows
    pywemo. Returns ``(method, add_lengths)``.
    """
    extras = {k.lower(): v for k, v in device.config_extras.items()}
    is_rtos = extras.get("rtos", "0") == "1"
    is_iot = extras.get("iot", "0") == "1"

    method = 2 if (is_rtos and not is_iot) else 1
    # Methods 1 and 3 append the password lengths; method 2 does not.
    return method, method in (1, 3)


def encrypt_wifi_password(
    password: str, key_data: str, add_lengths: bool
) -> str:
    """Encrypt a WiFi passphrase the way a Wemo device expects it.

    AES-128-CBC. The key is ``MD5(key_data + salt)[:16]`` with the salt and IV
    taken from the head of *key_data* — which is exactly what OpenSSL's legacy
    ``EVP_BytesToKey`` derivation produces for AES-128 when the IV is supplied
    explicitly. Output is base64, optionally followed by two hex length bytes.

    This is obfuscation, not a security boundary: every input is derived from
    metadata the device serves unauthenticated. See docs/devices/wemo-setup.md.
    """
    openssl = shutil.which("openssl")
    if openssl is None:
        raise SetupError(
            "the `openssl` command-line tool is required for passphrase "
            "encryption but was not found on PATH"
        )

    salt = key_data[0:8].encode("utf-8")
    iv = key_data[0:16].encode("utf-8")

    proc = subprocess.run(
        [
            openssl,
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
        check=False,
    )
    if proc.returncode != 0:
        # stderr may echo key material derived from the passphrase; withhold it.
        raise SetupError(f"openssl exited {proc.returncode} during encryption")

    # OpenSSL 1.x writes a "Salted__" + 8-byte-salt header even when the salt
    # was supplied with -S; OpenSSL 3.x omits it. Strip it when present rather
    # than slicing 16 bytes unconditionally, which corrupts output on 3.x.
    ciphertext = proc.stdout
    if ciphertext.startswith(b"Salted__"):
        ciphertext = ciphertext[16:]
    if not ciphertext:
        raise SetupError("openssl produced no ciphertext")

    encoded = base64.b64encode(ciphertext).decode("ascii")

    if not add_lengths:
        return encoded

    if len(encoded) > 255 or len(password) > 255:
        raise SetupError(
            "Wemo encodes the passphrase lengths as two hex digits each, so "
            f"both must be 255 or shorter (got {len(password)} plaintext, "
            f"{len(encoded)} encrypted)"
        )
    # Four trailing digits: encrypted length, then plaintext length, each as
    # exactly two zero-padded hex digits.
    return f"{encoded}{len(encoded):02x}{len(password):02x}"


def read_password(prompt: str = "Home network passphrase: ") -> str:
    """Read the WiFi passphrase from the environment or an unechoed prompt."""
    return os.environ.get("WEMO_WIFI_PASSWORD") or getpass.getpass(prompt)


# ── SOAP plumbing ────────────────────────────────────────────────────────────


class Client:
    """Talks to one Wemo device, resolving control URLs from its setup.xml."""

    def __init__(
        self,
        host: str,
        execute: bool,
        timeout: int = 20,
        port: Optional[int] = None,
        verbose: bool = True,
    ) -> None:
        self.host = host
        self.execute = execute
        self.timeout = timeout
        self.verbose = verbose
        self.device: Optional[WemoDevice] = None
        self.port = port

        if execute:
            self.device = device_at(host, port)
            if self.device is None:
                raise SetupError(
                    f"no Wemo device answered at {host} on any known port. "
                    "In setup mode, check you are joined to the device's "
                    "Wemo.* access point; on the LAN, find it with "
                    "`python scripts/wemo_discover.py`."
                )
            self.port = self.device.port

    @property
    def address(self) -> str:
        return f"{self.host}:{self.port or 49153}"

    def control_path(self, service_type: str) -> str:
        """Resolve a service's control URL, preferring the device's own."""
        if self.device is not None:
            service = self.device.service_by_type(service_type)
            if service is not None and service.control_url:
                return service.control_url
        return FALLBACK_CONTROL_PATHS[service_type]

    def call(
        self,
        service_type: str,
        action: str,
        arguments: Optional[dict[str, str]] = None,
        redact: Optional[dict[str, str]] = None,
        timeout: Optional[int] = None,
    ) -> dict[str, str]:
        """Print, and when executing, send one SOAP action.

        *redact* maps argument names to the placeholder printed in their
        place, so a passphrase blob never reaches the terminal or a log.
        """
        control_path = self.control_path(service_type)
        body = build_soap_body(service_type, action, arguments)

        if self.verbose:
            printable = dict(arguments or {})
            for name, placeholder in (redact or {}).items():
                if name in printable:
                    printable[name] = placeholder
            display = build_soap_body(service_type, action, printable)

            print(f"── SOAP ACTION: {action} ──")
            print(f"URL:        http://{self.address}{control_path}")
            print(f"SOAPACTION: {soapaction_header(service_type, action)}")
            print()
            print(display.decode("utf-8"))

        if not self.execute:
            if self.verbose:
                print("[DRY RUN — not sent. Use --execute to send.]")
            return {}

        try:
            response = post_soap(
                device_addr=self.address,
                body=body,
                service_type=service_type,
                action=action,
                control_path=control_path,
                timeout=timeout or self.timeout,
            )
        except URLError as exc:
            raise SetupError(f"{action} failed: {exc}") from exc

        values = parse_soap_values(response)
        if not values:
            raise SetupError(
                f"{action} returned no values; raw response:\n"
                f"{response.decode('utf-8', errors='replace')}"
            )
        return values

    def meta_info(self) -> MetaInfo:
        values = self.call(SERVICE_METAINFO, "GetMetaInfo")
        raw = values.get("MetaInfo", "")
        if not raw:
            raise SetupError("GetMetaInfo returned no MetaInfo value")
        return MetaInfo.parse(raw)

    def access_points(self) -> tuple[list[AccessPoint], str]:
        """Return the device's WiFi scan results and the raw ApList string."""
        values = self.call(SERVICE_WIFI, "GetApList", timeout=max(self.timeout, 20))
        return parse_ap_list(values.get("ApList", "")), values.get("ApList", "")

    def network_status(self) -> str:
        return self.call(SERVICE_WIFI, "GetNetworkStatus").get("NetworkStatus", "")


def parse_ap_list(ap_list: str) -> list[AccessPoint]:
    """Parse the ApList string returned by WiFiSetup#GetApList.

    Each entry is one line, pipe-delimited, with the SSID first, the channel
    second, and the authorization mode and cipher joined by a slash in the
    last column::

        HomeNet|6|...|WPA2PSK/AES,

    The first line is a header/count and is skipped, matching pywemo.
    """
    access_points = []
    for line in ap_list.split("\n")[1:]:
        line = line.strip().rstrip(",")
        if not line or "|" not in line:
            continue
        columns = line.split("|")
        if len(columns) < 3:
            continue
        auth_string = columns[-1].strip()
        auth_mode, _, encryption = auth_string.partition("/")
        access_points.append(
            AccessPoint(
                ssid=columns[0].strip(),
                channel=columns[1].strip(),
                auth_mode=auth_mode.strip(),
                encryption=encryption.strip(),
                raw=line,
            )
        )
    return access_points


# ── Commands ─────────────────────────────────────────────────────────────────


def cmd_info(args: argparse.Namespace) -> int:
    """Show the device description, setup services and encryption variant."""
    if not args.execute:
        print(f"Would probe http://{args.device}:<49151-49159>/setup.xml")
        print("[DRY RUN — not sent. Use --execute to send.]")
        return 0

    client = Client(
        args.device, execute=True, timeout=args.timeout, port=args.port, verbose=False
    )
    device = client.device
    assert device is not None  # Client raises if it cannot reach the device

    print(f"Address:      {device.ip}:{device.port}")
    print(f"Name:         {device.friendly_name}")
    print(f"Device type:  {device.device_type}")
    print(f"Model:        {device.model_name} {device.model_number}".rstrip())
    print(f"Serial:       {device.serial_number}")
    print(f"MAC:          {device.mac_address}")
    print(f"UDN:          {device.udn}")

    if device.config_extras:
        print()
        print("Firmware extras (these select the setup encryption variant):")
        for key, value in sorted(device.config_extras.items()):
            print(f"  {key:<20} {value}")

    print()
    print("Services:")
    for service in device.services:
        print(f"  {service.service_type:<45} {service.control_url}")

    has_wifi_setup = device.service_by_type(SERVICE_WIFI) is not None
    method, add_lengths = detect_encryption_method(device)
    print()
    print(f"Encryption variant: method={method}, add_lengths={add_lengths}")
    if not has_wifi_setup:
        print()
        print(
            "warning: this device is not advertising the WiFiSetup service, so "
            "it is probably already provisioned. Use `reset --wifi` on the LAN, "
            "or factory reset it by hand.",
            file=sys.stderr,
        )
        return 1

    meta = client.meta_info()
    print()
    print(f"Firmware:     {meta.firmware_version}")
    print(f"Device SKU:   {meta.device_sku}")
    print(f"Setup AP:     {meta.access_point_ssid}")
    return 0


def cmd_list_aps(args: argparse.Namespace) -> int:
    """Ask the device to scan and print the networks it can see."""
    client = Client(args.device, execute=args.execute, timeout=args.timeout, port=args.port)
    access_points, raw = client.access_points()
    if not args.execute:
        return 0

    print("── Raw ApList ──")
    print(raw)
    print()
    print(f"{'SSID':<32} {'Ch':<4} {'Auth':<12} {'Cipher':<10} Usable")
    for ap in access_points:
        usable = "yes" if ap.supported else f"no ({ap.encryption or 'unknown'})"
        print(
            f"{ap.ssid[:31]:<32} {ap.channel:<4} {ap.auth_mode[:11]:<12} "
            f"{ap.encryption[:9]:<10} {usable}"
        )
    print()
    print(
        "The device's own strings are used verbatim when connecting, so pick a "
        "network from this list rather than typing one in."
    )
    return 0


def cmd_connect(args: argparse.Namespace) -> int:
    """Hand the device the home network credentials and poll the result."""
    client = Client(args.device, execute=args.execute, timeout=args.timeout, port=args.port)

    if not args.execute:
        print(
            "Would call GetApList to locate the network, GetMetaInfo for the\n"
            "encryption key material, then ConnectHomeNetwork (twice) and poll\n"
            "GetNetworkStatus.\n"
        )
        client.call(
            SERVICE_WIFI,
            "ConnectHomeNetwork",
            {
                "ssid": args.ssid,
                "auth": "<from ApList>",
                "password": PASSWORD_PLACEHOLDER,
                "encrypt": "<from ApList>",
                "channel": "<from ApList>",
            },
        )
        return 0

    # 1. Find the target network in the device's own scan results.
    access_points, _ = client.access_points()
    selected = next((ap for ap in access_points if ap.ssid == args.ssid), None)
    if selected is None:
        seen = ", ".join(sorted({ap.ssid for ap in access_points if ap.ssid}))
        raise SetupError(
            f"the device cannot see a network called {args.ssid!r}. It found: "
            f"{seen or '(nothing)'}. Wemo radios are 2.4 GHz only — a 5 GHz "
            "network will never appear here."
        )
    if selected.auth_mode == "Unknown" or not selected.supported:
        raise SetupError(
            f"the device reports {args.ssid!r} as {selected.auth_mode}/"
            f"{selected.encryption}, which it cannot join. Supported ciphers "
            f"are {', '.join(sorted(SUPPORTED_ENCRYPTIONS))} — WPA3 in "
            "particular is not supported."
        )

    print(
        f"Selected: {selected.ssid} channel {selected.channel} "
        f"{selected.auth_mode}/{selected.encryption}"
    )
    print()

    # 2. Encrypt the passphrase, unless the network is open.
    if selected.encryption == "NONE":
        print("Open network — no passphrase will be sent.")
        auth_mode, encrypted = "OPEN", ""
    else:
        password = read_password()
        if len(password) < MIN_PASSWORD_LENGTH:
            raise SetupError(
                f"Wemo requires a passphrase of at least {MIN_PASSWORD_LENGTH} "
                "characters and will reject anything shorter"
            )
        meta = client.meta_info()
        if args.encrypt_method is not None:
            method = args.encrypt_method
            # An explicit method with no --add-lengths uses that method's
            # natural default (1 and 3 append the lengths, 2 does not) rather
            # than silently falling to False, which would produce a blob the
            # device rejects and make the method look broken.
            add_lengths = method in (1, 3)
        else:
            device = client.device
            assert device is not None
            method, add_lengths = detect_encryption_method(device)
        if args.add_lengths is not None:
            add_lengths = args.add_lengths
        print(f"Encryption: method={method}, add_lengths={add_lengths}")
        encrypted = encrypt_wifi_password(
            password, build_key_data(meta, method), add_lengths
        )
        auth_mode = selected.auth_mode

    arguments = {
        "ssid": selected.ssid,
        "auth": auth_mode,
        "password": encrypted,
        "encrypt": selected.encryption,
        "channel": selected.channel,
    }

    # 3. Send the credentials. Sending twice measurably improves the success
    #    rate; the reason is not understood, but pywemo does the same.
    status = ""
    for attempt in range(1, args.attempts + 1):
        print(f"\nSending connection request (attempt {attempt}/{args.attempts})...")
        for send in range(2):
            result = client.call(
                SERVICE_WIFI,
                "ConnectHomeNetwork",
                arguments,
                redact={"password": PASSWORD_PLACEHOLDER},
            )
            print(f"  PairingStatus: {result.get('PairingStatus', result)}")
            if send == 0:
                time.sleep(0.1)

        # 4. Poll for the outcome.
        deadline = time.monotonic() + args.timeout_connect
        time.sleep(0.5)
        status = client.network_status()
        print(f"  NetworkStatus: {status} ({NETWORK_STATUS.get(status, 'unknown')})")
        while time.monotonic() < deadline and status not in TERMINAL_STATUSES:
            time.sleep(args.status_delay)
            status = client.network_status()
            print(
                f"  NetworkStatus: {status} "
                f"({NETWORK_STATUS.get(status, 'unknown')})"
            )
        if status in TERMINAL_STATUSES:
            break

    # Status 3 usually precedes success; give it a few more seconds.
    if status == STATUS_HANDSHAKING:
        print("\nStill handshaking — waiting a little longer...")
        for _ in range(3):
            time.sleep(args.status_delay)
            status = client.network_status()
            print(
                f"  NetworkStatus: {status} "
                f"({NETWORK_STATUS.get(status, 'unknown')})"
            )
            if status in TERMINAL_STATUSES:
                break

    if status == STATUS_SHORT_PASSWORD:
        raise SetupError(
            "the device rejected the passphrase as too short (it requires at "
            f"least {MIN_PASSWORD_LENGTH} characters)"
        )

    # 5. Close setup regardless, so a device that did connect is released.
    #    CloseSetup is absent on some firmware; a device that already joined is
    #    provisioned whether or not it answers this, so tolerate it failing the
    #    way pywemo does rather than reporting a successful join as a failure.
    print()
    try:
        close_status = client.call(SERVICE_WIFI, "CloseSetup").get("status", "")
    except SetupError:
        close_status = ""
        print("CloseSetup: not available on this device")
    else:
        print(f"CloseSetup: {close_status}")

    if status != STATUS_CONNECTED:
        raise SetupError(
            f"the device did not report a connected state (last status: "
            f"{status or 'none'} — {NETWORK_STATUS.get(status, 'unknown')}). "
            "See the troubleshooting table in docs/devices/wemo-setup.md; "
            "retrying the exact same steps often works."
        )

    try:
        client.call(SERVICE_BASICEVENT, "SetSetupDoneStatus")
    except SetupError:
        # Not present on every device or firmware; setup still succeeded.
        print("(SetSetupDoneStatus not available on this device)")

    print()
    print(f"Connected to {selected.ssid}.")
    if close_status != "success":
        print(
            f"CloseSetup returned {close_status!r} rather than 'success' — "
            "verify the device joined before assuming it is done."
        )
    print("Rejoin your own network, then rediscover the device:")
    print("  python scripts/wemo_discover.py --timeout 5")
    return 0


def cmd_status(args: argparse.Namespace) -> int:
    """Report the device's current join status."""
    client = Client(args.device, execute=args.execute, timeout=args.timeout, port=args.port)
    status = client.network_status()
    if not args.execute:
        return 0
    print(f"NetworkStatus: {status} ({NETWORK_STATUS.get(status, 'unknown')})")
    return 0 if status == STATUS_CONNECTED else 1


def cmd_close(args: argparse.Namespace) -> int:
    """Close setup mode so the device joins the configured network."""
    client = Client(args.device, execute=args.execute, timeout=args.timeout, port=args.port)
    result = client.call(SERVICE_WIFI, "CloseSetup")
    if args.execute:
        print(f"CloseSetup: {result.get('status', result)}")
    return 0


def cmd_reset(args: argparse.Namespace) -> int:
    """Reset a device over the network via basicevent#ReSetup."""
    if args.factory:
        scope = "factory"
    elif args.data:
        scope = "data"
    else:
        scope = "wifi"
    code, description = RESET_CODES[scope]

    print(f"Reset scope: {scope} (Reset={code}) — {description}")
    if scope in ("wifi", "factory"):
        print(
            "This clears the stored WiFi credentials immediately. If the\n"
            "reprovisioning that follows fails, the device will be sitting in\n"
            "setup mode, not back on the current network. Have the new SSID\n"
            "and passphrase to hand before running this with --execute.\n"
        )

    client = Client(args.device, execute=args.execute, timeout=args.timeout, port=args.port)
    result = client.call(SERVICE_BASICEVENT, "ReSetup", {"Reset": str(code)})
    if not args.execute:
        return 0

    status = result.get("Reset", "").strip().lower()
    print(f"Reset: {status or result}")
    if status not in ("success", "reset_remote"):
        print(
            f"warning: unexpected reset result {status!r}; the reset may still "
            "have worked. Check whether the device reappears in setup mode.",
            file=sys.stderr,
        )
    if scope in ("wifi", "factory"):
        print()
        print(
            "The device should drop off the LAN and start advertising its "
            "Wemo.* setup AP within about 90 seconds."
        )
    return 0


# ── CLI ──────────────────────────────────────────────────────────────────────


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Provision a Belkin Wemo device onto WiFi via its local WiFiSetup "
            "SOAP service. Dry-run by default."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Typical session, joined to the device's open Wemo.* setup AP:

  %(prog)s info --execute
  %(prog)s list-aps --execute
  %(prog)s connect --ssid HomeNet --execute

Moving a device that is still on your LAN to a different network:

  %(prog)s reset --wifi --device 192.168.1.42 --execute

If a connect attempt fails, the encryption variant may be misdetected. There
are six combinations; try them in this order:

  --encrypt-method 1 --add-lengths        (default for most devices)
  --encrypt-method 2 --no-add-lengths
  --encrypt-method 3 --add-lengths
  --encrypt-method 1 --no-add-lengths
  --encrypt-method 2 --add-lengths
  --encrypt-method 3 --no-add-lengths
        """,
    )
    parser.add_argument(
        "--device",
        default=SETUP_AP_HOST,
        help=(
            "Device host, with an optional :port. Default "
            f"{SETUP_AP_HOST} (the setup AP address); the port is probed "
            "across 49151-49159."
        ),
    )
    parser.add_argument(
        "--execute",
        action="store_true",
        help="Actually contact the device (default: dry-run only).",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=20,
        help="Per-request HTTP timeout in seconds (default: 20).",
    )

    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("info", help="Show the device description and setup services.")
    sub.add_parser("list-aps", help="Ask the device which networks it can see.")

    connect = sub.add_parser("connect", help="Send the home network credentials.")
    connect.add_argument(
        "--ssid",
        required=True,
        help="Target network SSID, as reported by list-aps.",
    )
    connect.add_argument(
        "--encrypt-method",
        type=int,
        choices=[1, 2, 3],
        help="Override the detected passphrase encryption variant.",
    )
    lengths = connect.add_mutually_exclusive_group()
    lengths.add_argument(
        "--add-lengths",
        dest="add_lengths",
        action="store_true",
        default=None,
        help="Force appending the passphrase lengths to the encrypted blob.",
    )
    lengths.add_argument(
        "--no-add-lengths",
        dest="add_lengths",
        action="store_false",
        help="Force omitting the passphrase length suffix.",
    )
    connect.add_argument(
        "--attempts",
        type=int,
        default=2,
        help="Connection attempts before giving up (default: 2).",
    )
    connect.add_argument(
        "--timeout-connect",
        type=float,
        default=25.0,
        help="Seconds to poll for a result per attempt (default: 25).",
    )
    connect.add_argument(
        "--status-delay",
        type=float,
        default=1.0,
        help="Seconds between status polls (default: 1.0).",
    )

    sub.add_parser("status", help="Report the current NetworkStatus.")
    sub.add_parser("close", help="Close setup mode and release the device.")

    reset = sub.add_parser(
        "reset", help="Reset a device over the network (basicevent#ReSetup)."
    )
    scope = reset.add_mutually_exclusive_group()
    scope.add_argument(
        "--wifi",
        action="store_true",
        help="Clear WiFi credentials only, the app's 'Change Wi-Fi' (default).",
    )
    scope.add_argument(
        "--data",
        action="store_true",
        help="Clear name, icon and rules — the app's 'Clear Personalized Info'.",
    )
    scope.add_argument(
        "--factory",
        action="store_true",
        help="Clear everything, the app's 'Factory Restore'.",
    )

    return parser


COMMANDS = {
    "info": cmd_info,
    "list-aps": cmd_list_aps,
    "connect": cmd_connect,
    "status": cmd_status,
    "close": cmd_close,
    "reset": cmd_reset,
}


def main() -> int:
    args = build_parser().parse_args()

    # Accept host or host:port in --device.
    if ":" in args.device:
        host, _, port = args.device.rpartition(":")
        args.device = host
        args.port = int(port)
    else:
        args.port = None

    try:
        return COMMANDS[args.command](args)
    except SetupError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print("\nInterrupted.", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
