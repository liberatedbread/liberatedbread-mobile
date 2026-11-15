# Rachio Controller

> **Status**: Local discovery documented; local HTTPS API surface identified
> **Protocol**: WiFi (mDNS HomeKit HAP + local HTTPS API on TCP 443)
> **Manufacturer**: Rachio
> **Manufacturer Status**: Active

## Overview

The observed Rachio controller (Gen 3) advertises HomeKit HAP via mDNS and has
port 80 open. A second local surface exists: the Gen 3 device HTTPS API on
TCP 443, live even after provisioning, authenticated with the device serial as
an API key. This entry documents local discovery, identity and that HTTPS
surface; zone control still requires HAP pairing (the setup code is shown only
in the vendor app) or the cloud API.

## Discovery

Browse `_hap._tcp.local.` and match Rachio model TXT values such as
`md=Rachio-AABBCC`. Use TXT `id` as the stable identity — re-observed unchanged
across a LAN move (2026-08-25), confirming stability.

Observed identity:

| Field | Value |
|---|---|
| Hostname | `WICED-hap-AABBCC.local` |
| HAP ID | `0A:01:0A:AA:BB:CC` |
| Model TXT | `Rachio-AABBCC` |

Full TXT set observed 2026-08-25: `id`, `md`, `c#=4`, `pv=1.1`, `ff=1`, `s#=1`,
`sf=1` (unpaired), `ci=2`, `sh`.

Port 80 answers `HTTP 470 Connection Authorization Required` to everything —
HAP only, no unauthenticated REST surface.

## Local HTTPS API (TCP 443, Gen 3)

The Gen 3 device HTTPS API used by the vendor app for SoftAP provisioning is
also served on the provisioned LAN. Verified live 2026-08-25/26, including an
authenticated session:

- TLS certificate: `CN=*-rachio.local`, issued by the vendor's device CA
  (validity 2020–2049) — matches the CA pinned in the vendor app, so
  third-party clients must extract or replace that CA.
- Auth: header `x-api-key: <device serial, uppercase>` — the serial printed on
  the unit's label / shown in the vendor app. A wrong key gets 403 (verified).
- Route and method map (live-verified):

| Path | Method | Unauthenticated | Authenticated |
|---|---|---|---|
| `/info` | GET | 403 | 200 — `{"fwv":"iro3-firmware-hk-5-645","wfv":"wl0: … 7.15.168.143 (Broadcom WLAN)","env":"prod","valve_num":16}` |
| `/conn` | GET | 403 | 200 — `{"con_state":{"current":"FULLY_CONNECTED","furthest":"FULLY_CONNECTED","code":0}}` |
| `/time` | POST `{"epoch": N}` | 403 | 200 (empty body); GET → 405 |
| `/fwupdate` | POST `application/octet-stream` | 403 | local OTA push — not exercised (would flash the unit); GET → 405 |
| `/config`, `/schedule`, `/done`, `/remove` | — | 404 | setup-AP-only routes |

The `conn` state machine (WIFI_CONNECTING → … → MQTT_SUBSCRIBED →
WAITING_INIT_DATA → FULLY_CONNECTED, with DNS/TLS/MQTT failure states) confirms
the Gen 3 cloud path is MQTT over TLS.

**Fragility warning:** after a burst of probe traffic the 443 listener stopped
accepting connections and stayed down 40+ minutes; it returned only after a
device reboot. Port 80 (HAP) was unaffected. Probe this API gently — single,
spaced requests.

No zone-control route exists on this API: local watering control remains
HAP-only.

## Firmware

- Naming: `iro3-firmware-hk-<major>-<build>` ("hk" = HomeKit). Live-verified on
  a 16-zone unit 2026-08-26: `iro3-firmware-hk-5-645`; community sightings run
  5-632 (2020–2023) and 5-640 (2023).
- **OTA-only — no public download host exists.** The vendor cloud hands the app
  a signed URL (gRPC `DeviceService/GetDesiredFirmware` → `desiredFirmwareUrl`),
  the app downloads the image (upgrading `http`→`https`, with a 128 MB cache),
  then pushes it to the controller's local `/fwupdate` endpoint. Gen 2 images
  (`iro-prod-iro2-firmware-5-34-ota-signed.bin`) are signed/encrypted
  containers: ~342 KB, length-prefixed header, high-entropy body.
- Wi-Fi firmware reported by `/info`: Broadcom/Cypress `wl0` build
  7.15.168.143 — consistent with the WICED platform.

Machine-readable spec: `device-specs/devices/rachio-controller.yaml`

Home Assistant: the core [Rachio integration](https://www.home-assistant.io/integrations/rachio/) covers these controllers (cloud API; the local HAP path above is independent).

