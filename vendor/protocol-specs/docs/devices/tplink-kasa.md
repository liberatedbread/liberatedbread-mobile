# TP-Link Kasa Smart Plug

> **Status**: Local protocol documented from public reverse engineering; not replayed against hardware here
> **Protocol**: WiFi (JSON over TCP/UDP port 9999, XOR-autokey cipher)
> **Manufacturer**: TP-Link
> **Manufacturer Status**: Active (company alive; the local protocol is what's endangered)

## Overview

The Kasa-era TP-Link smart plugs — **HS100** (switching) and **HS110**
(switching + energy monitoring), plus the same-protocol **HS103/HS105** and
**KP105/KP115** — speak a plaintext local protocol on **TCP port 9999**: JSON
commands wrapped in a trivial XOR "autokey" cipher, with **no authentication**.
[softScheck](https://www.softscheck.com/en/blog/tp-link-reverse-engineering/)
reverse-engineered it in 2016, and
[python-kasa](https://github.com/python-kasa/python-kasa) — which backs Home
Assistant's `tplink` integration — has implemented it ever since.

Control is entirely LAN-local: block the plug from the internet at the router
and everything here still works.

!!! warning "The local protocol is being retired"
    TP-Link the company is alive, so this is `manufacturer_status: active`;
    what is endangered is the protocol. HS100 hardware v4 on firmware 1.1.0
    (~2020) **closed port 9999**, and newer hardware (EP25, KP125M, the whole
    Tapo line) moved to the encrypted KLAP/AES protocol with cloud-tied
    credentials — out of scope here. Keep a working unit offline from vendor
    firmware updates to preserve the API.

!!! danger "No authentication on a mains relay"
    The relay is mains-rated (13–16 A depending on region) and the protocol
    has no authentication of any kind, so anything on the LAN can toggle the
    load. Segment the device accordingly.

## The cipher (XOR autokey)

Every payload — control and discovery alike — is obfuscated with a running XOR:

- **Encrypt**: start `key = 0xAB`; for each plaintext byte `p`, emit
  `c = key XOR p`, then set `key = c`.
- **Decrypt**: start `key = 0xAB`; for each ciphertext byte `c`, emit
  `p = key XOR c`, then set `key = c`.

So after the first byte the key is the previous *ciphertext* byte. This is
obfuscation, not security — there is no secret. Reproducible test vectors
(hex) live in the machine-readable spec and are asserted by
`scripts/test_kasa_spec.py`:

| Plaintext | Ciphertext |
|---|---|
| `00 00 00` | `ab ab ab` |
| `01 02 03` | `aa a8 ab` |
| `{"system":{"get_sysinfo":null}}` | `d0f281f88bff9af7d5ef94b6d1b4c09fec95e68fe187e8caf09eeb87eb96eb` |

## Framing

| Transport | Framing |
|---|---|
| **TCP** (control) | 4-byte big-endian length prefix (encrypted-payload length, prefix excluded) + XOR-encrypted JSON. Replies use the same framing. |
| **UDP** (discovery) | A single datagram of the XOR-encrypted JSON, **no** length prefix. |

## Discovery

Broadcast the XOR-encoded `{"system":{"get_sysinfo":null}}` to
`255.255.255.255:9999`. Every Kasa-protocol device on the segment answers with
a unicast datagram carrying its full `get_sysinfo` — `alias`, `model`,
`deviceId`, `mac`, `rssi` and `relay_state`. `deviceId` is the stable identity;
`alias` is the user-facing name.

## Commands

| JSON | Meaning |
|---|---|
| `{"system":{"get_sysinfo":null}}` | Device info + current `relay_state` (0/1). The state poll and the discovery probe. |
| `{"system":{"set_relay_state":{"state":1}}}` | Turn the outlet **on**. |
| `{"system":{"set_relay_state":{"state":0}}}` | Turn the outlet **off**. |
| `{"emeter":{"get_realtime":null}}` | HS110 only — instantaneous voltage/current/power/total. The state poll for the energy sensors below. |
| `netif.set_stainfo` | Provisioning: join the plug to a Wi-Fi network. |

## Energy monitoring (HS110)

The HS110's meter is modelled as four sensor entities in the machine-readable
spec — **Voltage** (V), **Current** (A), **Power** (W) and **Total
Consumption** (kWh) — all polled with `emeter.get_realtime`. The reply nests
under `{"emeter":{"get_realtime":{...}}}`.

One hardware quirk matters: the field **names** vary. Current firmware reports
`voltage`/`current`/`power`/`total` as floats already in V/A/W/kWh; HS110
hardware v1 reports `voltage_mv`/`current_ma`/`power_mw`/`total_wh` in
milli-units instead. Normalize to SI units (divide by 1000) before displaying —
this is what python-kasa's `EmeterStatus` does, and both code paths exist in
the vendor app (see the spec's `evidence` block). The HS100 has no metering
hardware and answers the command with an error.

## Setup (adopting a reset plug)

A factory-fresh or reset plug hosts an **open AP** named `TP-LINK_Smart
Plug_XXXX` and speaks the same port-9999 protocol on it. Joining it to the home
Wi-Fi needs no cloud account: send `netif.set_stainfo` with the target SSID,
passphrase and key type over the local protocol (this is what `kasa wifi join`
does in python-kasa). The passphrase rides inside the same XOR obfuscation, so
it is effectively plaintext — the open setup AP is the only transport
protection. Not replayed against hardware here; full steps live in
`device.setup` in the machine-readable spec.

**Factory reset**: with the plug powered, press and hold its physical button
for about 5 seconds until the LED blinks rapidly. This clears Wi-Fi
credentials, the alias and any schedules, returning the plug to its setup-AP
state. A short press just toggles the relay.

## Power strips

Power strips (HS300 / KP303 / EP40) report a `children` array in `get_sysinfo`
and address each outlet by wrapping a command in
`{"context":{"child_ids":["<deviceId>0N"]}}`. That is a separate spec; this one
covers single-relay plugs only.

Machine-readable spec: `device-specs/devices/tplink-kasa-smart-plug.yaml`
