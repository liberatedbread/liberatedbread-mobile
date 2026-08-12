# Sproutling Wearable Baby Monitor (Mattel / Fisher-Price) — Research Notes

## What it is
Sproutling (startup founded 2012; acquired by Mattel early 2015,
relaunched under Fisher-Price 2017) is an ankle-band baby monitor:
optical heart-rate sensor, temperature, motion/position, and room
conditions, docked on a "Smart Charger" that acts as a BLE-to-Wi-Fi hub.
Data path: band → BLE → Smart Charger → Wi-Fi → Sproutling cloud → app.

## Why it's abandoned (dated sources)
- Official Mattel/Fisher-Price service FAQ:
  "the Sproutling® Wearable Baby Monitor service will shut down on
  October 31, 2018" and "None of the features of the Sproutling device
  will function after October 31, 2018."
  https://service.mattel.com/us/productDetail.aspx?prodno=FNF59&siteid=27
- Acquisition timeline: https://d3.harvard.edu/platform-rctom/submission/lets-get-digital-digital/ (2017-01)
- The app itself fetches `https://s3-us-west-1.amazonaws.com/sproutling-app/eol.json`
  (EOL notice) and points at now-dead `api-*.sproutlingcloud.com` endpoints.

## APK Provenance
- **Package**: `com.fisherprice.sproutling` v1.2.4 (versionCode 180924), 5.9 MB
- **Source**: apkeep (APKPure mirror)
- **SHA-256**: `f5110d0c4e0fb3fb9fe7755fa4935f644dddde7b818a6aa2e9a27b5a7abcc924`
- jadx decompile OK (workspace/static/sproutling-baby-monitor), light
  obfuscation; key classes readable (`com.sproutling.*`, protobuf schema
  in `sproutling/Hub.java`, `EventOuterClass.java`, `Sleep.java`).

## BLE findings from static analysis (`com/sproutling/services/SHBluetoothLeService.java`)
The phone app's BLE role is **provisioning the Smart Charger's Wi-Fi** —
not streaming sensor data. Characteristics are self-describing in log
strings:

| UUID | Role (from log strings) |
|------|------|
| `4482ACDF-D160-4E10-8FE3-82599F334433` | Sproutling BLE service (hub provisioning) |
| `1F5FCD82-FE15-4962-A6B2-BAEDFF11FD76` | WIFI_SCAN_MODE (write) |
| `9C500CD5-C84A-459A-AF95-26E73C2D49D7` | WIFI_LIST_COUNT (read) |
| `FAB97310-7E7E-4F52-AB2A-51B2332E01A3` | WIFI_LIST (read/notify) |
| `1317D1BC-5F64-4CD2-A5BE-A7C436BE6F88` | WIFI_CONNECTION_PARAMETERS (write) |
| `1C4F894B-75D8-4008-8EC5-D3E77D75BD95` | WIFI_CONNECTION_PARAMETERS (secondary) |
| `ECB9EFD1-1CA6-4AE0-B579-2F58C6237F87` | WIFI_CONNECTION_STATE (notify) |
| `89277C18-8A79-48A4-89C8-11F754F0B02D` | (additional config char) |
| `7A4747B5-B7FB-4643-9C5E-5778F77CAE7E` | (additional config char) |
| `FB8C0001-D224-11E4-85A1-0002A5D5C51B` | Broadcom WICED OTA firmware service |
| `77880001-D229-11E4-8689-0002A5D5C51B` | Broadcom WICED OTA (secondary) |

This is enough to re-provision a stranded hub's Wi-Fi locally — useful
because hub setup after 2018-10-31 otherwise fails against the dead cloud.

## Local feasibility: HYPOTHESIS (moderate-hard)
- The **band↔charger link is BLE**, so a custom central could in
  principle pair with the band directly — but no public capture exists
  and the app's own code never does it. Needs an nRF Connect scan +
  HCI snoop against the band itself.
- The protobuf schema (`sproutling/EventOuterClass.java`, `Sleep.java`,
  `Hub.java`) documents the full event/data model — a big head start for
  a replacement hub-side or band-side decoder.
- The hub's Wi-Fi-side protocol (charger→cloud) is unexplored; if it is
  plain TLS to sproutlingcloud.com it is dead, but hub-local endpoints
  have not been ruled out.
- No known community RE effort found (searched 2026-08-04).

## What needs cloud
In the stock UX: everything — band data only reaches the phone via the
cloud relay. Nothing in the app reads band data over BLE.

## Open questions
- Does the band accept a direct GATT connection while docked/worn? What
  service UUIDs does it expose? (band firmware unknown)
- Hub Wi-Fi provisioning payload format on `1317D1BC` (likely SSID+PSK
  blob; easy to capture with the APK in hand).
- Does the hub expose any LAN API post-provisioning?

## Safety
MEDIUM — infant HR/sleep monitoring; wellness device, not FDA-cleared.
Any local client must show data verbatim and never as a medical alarm.
