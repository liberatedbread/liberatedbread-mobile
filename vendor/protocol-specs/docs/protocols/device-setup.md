# Initial Device Setup (Provisioning)

Most of this documentation assumes a device is already on the network and
answering. Getting it there is a separate protocol problem, and usually a
harder one: onboarding is where the vendor app is most load-bearing, where the
only real secrets change hands, and where an abandoned cloud service turns a
working device into a paperweight.

A device you can control but cannot *re-onboard* is only half rescued. When the
router is replaced, the SSID changes, or the hardware is sold on, an
undocumented setup flow is exactly as fatal as an undocumented control protocol.

!!! note "Three different things called 'setup'"
    This project keeps them apart deliberately, and so does
    `device-specs/schema.json`:

    - **`device.setup`** — one-time provisioning: giving a factory-fresh device
      network credentials and an owner. Covered on this page.
    - **`device.discovery`** — finding an already-provisioned device. See
      [WiFi Discovery](../devices/wifi-discovery.md).
    - **`initialization`** — the per-connection handshake run *every* time a
      client connects (BLE key exchange, auth challenge). Not setup.

## Onboarding models

Every device documented here falls into one of these. The `type` values match
the `device.setup.methods[].type` enum in the schema, so a consumer can branch
on them directly.

| Type | What happens | Recoverable without the vendor? |
|---|---|---|
| `none` / `ble_direct` | Nothing to provision. Power on, scan, connect. | Yes — trivially |
| `softap_http` | Device hosts a temporary AP; credentials go over a local HTTP API | Yes, if the API is documented |
| `softap_soap` | Same, but the setup API is UPnP/SOAP (Wemo) | Yes — see [Wemo setup](../devices/wemo-setup.md) |
| `ble_provisioning` | Credentials pushed over GATT from a phone or hub | Yes, if the GATT protocol is documented |
| `wps` / `smartconfig` | Credentials delivered at the WiFi layer (button, or broadcast-encoded) | Partly — brittle and often removed |
| `wired` | Ethernet only; no wireless credentials exist | Yes — plug it in |
| `device_ui` | Configured on the device's own screen and buttons | Yes — no protocol needed |
| `button_pairing` | Physical button authorizes a client and issues it a credential | Yes |
| `hub_pairing` | Device joins a bridge (ZigBee/Z-Wave), not WiFi | Depends on the bridge |
| `cloud_account` | Onboarding exists only inside the vendor cloud | **No** — the failure case |

The ranking that matters for this project: anything that ends in
`cloud_account` with no local alternative is a device that dies with its
vendor, no matter how good the control protocol is. Document those loudly, and
capture the onboarding exchange **while the service still exists** — it is the
one capture you cannot go back for.

## WiFi devices: the SoftAP pattern

The dominant model. The device, unprovisioned, becomes an access point; the
phone joins it, hands over the home network credentials, and tells the device
to switch over.

```text
[1] Device has no credentials  ──▶ hosts AP  "Wemo.Mini.4A2" / "DYSON-…" / "Envoy_…"
[2] Client joins that AP        ──▶ gets an address on the device's own subnet
[3] Client reads device identity ─▶ serial / MAC / capability list
[4] Client asks device to scan  ──▶ list of visible SSIDs, auth modes, channels
[5] Client sends credentials    ──▶ SSID + passphrase (+ auth mode + channel)
[6] Client polls join status    ──▶ success / bad passphrase / not found
[7] Client closes setup         ──▶ device drops its AP, joins the home network
[8] Client rejoins home network ──▶ rediscovers the device by SSDP/mDNS
```

Things that reliably bite when reimplementing this:

- **The client loses its own network in step 2.** Phones aggressively fall back
  to cellular when the setup AP has no internet; a desktop client needs its
  route pinned to the setup subnet. Budget for the client being briefly unable
  to reach anything else.
- **The device's scan list is authoritative, not yours.** Send back the SSID,
  auth mode and channel exactly as the device reported them in step 4. Devices
  routinely reject a network they can see if the auth string does not match
  their own vocabulary (`WPA2PSK` vs `WPA2-PSK`).
- **2.4 GHz only.** Nearly every device here has a 2.4 GHz-only radio. A
  band-steering router advertising one SSID on both bands is the single most
  common onboarding failure, and it presents as a wrong-passphrase error.
- **Hidden SSIDs and non-ASCII SSIDs** are a common gap — the device may have
  no way to be told about a network it cannot see.
- **Step 6 is not optional.** Without a status poll you cannot distinguish a
  bad passphrase from a slow DHCP lease, and the device is about to become
  unreachable either way.
- **Step 8 needs a stable identity.** The device comes back on a different
  subnet with a new address. Match on serial, MAC, or UDN — never on IP. See
  the identity rules in [WiFi Discovery](../devices/wifi-discovery.md).

### Credential handling

The user's WiFi passphrase crosses this boundary in the clear more often than
not. Record it honestly in the spec's `setup.credentials` block:

| `wifi_passphrase_protection` | Meaning |
|---|---|
| `plaintext` | Sent as-is; anyone in radio range during setup can read it |
| `device_encrypted` | Obfuscated with a key derived from device metadata (Wemo) |
| `tls` | Real transport security |
| `not_applicable` | Wired, or no credential is transferred |

`device_encrypted` deserves scepticism. When the key is derived from data the
device hands out unauthenticated — a serial number, a MAC — it stops an
opportunistic listener and nothing else. Document it as obfuscation, implement
it exactly (the device will reject anything else), and do not describe it as a
security control.

A replacement client should also:

- Never log the passphrase, including in a dry-run/debug mode.
- Treat the setup AP as hostile: it is open, and anything nearby can join it.
- Prefer provisioning in a quiet RF environment, and re-provision from scratch
  if the passphrase may have been captured.

## BLE devices

BLE splits into two completely different situations, and conflating them is a
common documentation error.

### Most BLE devices need no setup at all

An LED strip, a badge, a mug, a thermometer: these advertise the moment they
have power and accept a connection from any central in range. There is no
account, no credential exchange, no pairing PIN. In the schema that is
`required: false` with a single `ble_direct` method — worth stating explicitly
rather than leaving blank, because "no setup" is a feature and a selling point
for a replacement app.

The real friction is not provisioning but **connection ownership**:

- Most of these devices accept exactly one central at a time. A phone still
  running the vendor app in the background holds the link, and every other
  client sees an unexplained connection failure. Close it, force-stop it, or
  power-cycle the device.
- Android and iOS cache bonds. A device removed from your app can still be
  auto-reconnected by the OS. "Forget this device" in the OS Bluetooth settings
  is part of the reset procedure, even though nothing on the device changed.
- Some devices gate *writes* behind a claim written by the first client that
  set it up (see the Ember Mug's DSK/UDSK). Reads work, writes silently fail,
  and it looks like a protocol bug rather than an authorization one.

### BLE as the provisioning channel for a WiFi device

The other pattern, and the best one for long-term recoverability: the device
has both radios, and BLE is used purely to hand over WiFi credentials. Vector
and the Chef iQ Sense both work this way.

This is worth calling out as a design the project should prefer, because BLE
stays reachable no matter what the WiFi state is. A device that can be
re-provisioned over BLE is never stranded by a router change; a WiFi-only
device whose old network no longer exists can only be recovered with a physical
factory reset.

Typical shape:

```text
1. Device advertises a setup name       ("Vector-A1B2", "CQ60")
2. Client connects, runs a handshake    (Curve25519 + PIN on Vector; none on CQ60)
3. Client requests a scan               (RtsWifiScanRequest / read scanned-network char)
4. Client writes credentials            (RtsWifiConnectRequest / write set-network char)
5. Client reads back the result         (connect response / notify on network-info char)
6. Client stores whatever was issued    (certificate, GUID, bearer token)
```

Note where the confidentiality comes from in each case. Vector encrypts the
whole BLE session with keys established under a screen-displayed PIN, so a
plaintext passphrase field inside it is fine. The Chef iQ writes the passphrase
to an unbonded characteristic, so it is exposed to a sniffer that catches the
connection event — the same field layout, a completely different risk.

## Factory reset

Reset procedures are protocol documentation. They are the entry point to every
flow above, and they are what a user actually needs when a device is bound to a
network or an account they no longer control.

For each device, record:

- **The trigger** — which button, held for how long, in what power state.
  Hold-while-powering-on is the most common pattern for plug-style hardware and
  cannot be discovered by pressing the button on a running device.
- **The confirmation** — the LED pattern or screen that says it took. Always
  prefer this to the stopwatch; documented hold times vary by generation and
  are frequently wrong.
- **The blast radius** — what is actually cleared. Clearing WiFi credentials is
  cheap. Clearing a bridge's ZigBee network or a hub's Z-Wave keys orphans
  every device paired to it, which is a much bigger decision and should be
  flagged before a user is told to hold a button for ten seconds.
- **What survives** — serial, MAC, UDN and BLE address are hardware identity
  and persist. That is what makes a reset device recognisable as the *same*
  device afterwards, which matters for anything that stores per-device state.

## Rebinding to a new network

The everyday case: the device works, but the router is being replaced. Three
possibilities, in descending order of how pleasant they are:

1. **In-place credential update.** The device accepts new credentials while
   still reachable — over BLE (Vector, Chef iQ), or on its own web UI (Envoy),
   or from its own screen (Roku). Nothing is lost.
2. **Remote re-entry into setup mode.** The device can be pushed back into
   provisioning mode over the network it is currently on — Wemo's
   `basicevent#ReSetup` is the example. This must be done *before* the old
   network disappears; afterwards the device is unreachable and this path is
   gone.
3. **Physical factory reset.** Always available, always the most disruptive,
   and the only option for a device whose old network is already gone.

The practical advice worth putting in front of users: **re-provision before you
retire the old network, not after.** Bring the new SSID up alongside the old
one if you can. Once the old network is down, every device that lives in
category 2 silently drops to category 3.

For devices in category 3 with `cloud_account` onboarding, there may be no
category at all — if the vendor service is gone, there is no supported way to
bind the device to any network, ever again.

## Documenting setup for a new device

Fill in `device.setup` in the device's spec YAML alongside the prose page.
[Reading a Device Spec](../api/spec-format.md) covers every field; the minimum
useful set is:

```yaml
device:
  setup:
    required: true              # false for BLE devices that just work
    confidence: "medium"        # high only if you ran it against hardware
    methods:
      - type: "softap_soap"
        verified: false         # true only after a successful replay
        softap:
          ssid_prefix: "Wemo."
          open_network: true
          gateway_ip: "10.22.22.1"
        steps:
          - action: "Join the device setup AP"
            actor: "user"
    factory_reset:
      confidence: "medium"
      effect: "Clears WiFi credentials and name; UDN and serial survive."
      procedures:
        - name: "Restore button held while power is applied"
          hold_seconds: 5
          indicator: "LED blinks, setup AP reappears"
    rejoin:
      in_place_supported: true
      requires_factory_reset: false
    credentials:
      wifi_passphrase_protection: "device_encrypted"
```

Rules of thumb:

- `confidence: "high"` means it was executed end to end against hardware, or
  there is a working open-source implementation that does. Vendor documentation
  alone is `medium`. Inference from an APK is `low`.
- `verified: false` is not a failure — it is the honest default, and it tells
  the next person exactly what to go and capture.
- Prefer a `low`-confidence block that names the gap over no block at all. "The
  onboarding exchange has not been captured" is useful information; silence is
  indistinguishable from "there is nothing to document".

## Per-device summary

| Device | Setup needed | Method | Rebind without reset | Confidence |
|---|---|---|---|---|
| [Belkin Wemo](../devices/wemo-setup.md) | Yes | `softap_soap` | Yes — `ReSetup` while still reachable | Medium |
| [Vector Robot](../devices/vector-robot.md) | Yes | `ble_provisioning` | Yes — BLE always available | High |
| [Chef iQ Sense](../devices/chef-iq-sense.md) | Only for cloud features | `ble_provisioning` | Yes — over BLE | Medium |
| [Philips Hue Bridge](../devices/hue-bridge.md) | Yes | `wired` + `button_pairing` | Yes — cable move | High |
| [Lutron Caseta Bridge](../devices/lutron-caseta-smart-bridge.md) | Yes | `wired` + `button_pairing` | Yes — cable move | Medium |
| [Roku ECP](../devices/roku-ecp.md) | Yes | `device_ui` | Yes — on-screen | High |
| [Enphase Envoy](../devices/enphase-envoy.md) | Yes | `wired` / `softap_http` | Yes — local web UI | Low |
| [Dyson purifier](../devices/dyson-air-purifier.md) | Yes | `softap_http` | No — reset and reprovision | Medium |
| [LIFX Z](../devices/lifx-z.md) | Yes | `softap_http` (uncaptured) | No — five power cycles | Low |
| [SmartThings Hub v2](../devices/smartthings-hub-v2.md) | Yes | `wired` + `cloud_account` | Yes — cable move | Low |
| [Rachio Controller](../devices/rachio-controller.md) | Yes | uncaptured | Unknown | Low |
| [Frigidaire ACs](../devices/frigidaire-ac.md) | Yes | `cloud_account` | No — cloud-bound | Low |
| All BLE-only devices | No | `ble_direct` | N/A | Medium |

## Related

- [Reading a Device Spec](../api/spec-format.md) — the `setup` block field by field
- [Wemo setup, reset and rebinding](../devices/wemo-setup.md) — the worked example
- [Common WiFi Patterns](wifi-common.md)
- [Common BLE Patterns](ble-common.md)
- [WiFi Discovery](../devices/wifi-discovery.md) — what happens after setup
