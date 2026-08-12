# LIFX Z — target spec

## Target metadata
- target_id: lifx-z
- app package_id(s): com.lifx.lifx (official LIFX app)
- device class: multizone LED light strip
- transport(s): Wi-Fi LAN (LIFX binary protocol over UDP port 56700)
- local-only viability: **high** — the LIFX LAN protocol is a fully local, unauthenticated binary protocol over UDP. Once a strip is on the network, control needs no cloud, no account and no pairing. The one caveat is onboarding and the Matter firmware track (see below).

## Known facts (public + observed)

### The control protocol is documented and unauthenticated
LIFX publishes machine-readable message definitions in [LIFX/public-protocol](https://github.com/LIFX/public-protocol) (`protocol.yml`). Every device listens on **UDP port 56700** for a 36-byte header plus a typed payload, all little-endian. There is no authentication — anything on the LAN can drive a strip. The byte-exact layout of the header and the control messages is transcribed into `device-specs/devices/lifx-z.yaml` under `payload_formats`, and `scripts/test_lifx_spec.py` proves the spec reproduces its own example datagrams.

### Colour is HSBK; the strip is multizone
Colour is HSBK (hue/saturation/brightness as full-`u16` channels, kelvin the white point). LIFX Z is a multizone strip — commonly eight zones — controlled either whole (`SetColor` 102) or per zone (`SetColorZones` 501 … `StateMultiZone` 506).

### Discovery: a UDP broadcast, with mDNS as a weak fallback
A `GetService` (type 2) broadcast to `255.255.255.255:56700` is answered by every LIFX device with a `StateService` (type 3) whose header carries the device MAC. Observed strips also advertise HomeKit HAP over mDNS (`_hap._tcp`, TXT `md=LIFX Z`), but `_hap._tcp` is shared across hundreds of HomeKit products, so it identifies a strip only weakly; the UDP broadcast is the reliable, vendor-specific signal.

### Onboarding is the fragile part, and it forks by firmware
- **Original-generation firmware (v2.x):** joined to Wi-Fi over the deprecated access-point message family (`GetAccessPoints` 0x130 / `SetAccessPoint` 0x131 / `StateAccessPoint` 0x132) on the same UDP port 56700, over the strip's own open setup AP. The passphrase is sent in plaintext; the setup AP is the only transport protection. Documented in the spec's `setup` block; **not yet replayed against hardware.**
- **Matter/LCM3 firmware (Sept 2025+):** onboards over BLE via the vendor app, and taking the Matter update **decommissions the HomeKit/HAP integration** — those units stop advertising `_hap._tcp`, so discover them by UDP broadcast, and expect the legacy setup messages to be ignored.

## Device discovery signals
- BLE: used only for Matter-era onboarding (out of scope here).
- Wi-Fi:
  - SSID patterns (unprovisioned setup AP): `LIFX Z <serial>` (e.g. `LIFX Z 04A3C1`), open network, gateway `172.16.0.1`.
  - default gateway IPs: `172.16.0.1` on the setup subnet.
  - mDNS service types: `_hap._tcp.local.` (shared; TXT `md=LIFX Z`).
  - UDP LAN: `GetService` (type 2) broadcast to `255.255.255.255:56700` → `StateService` (type 3).

## Threat model + guardrails
- Scope: only owned devices on a network the operator controls. No safety-critical use.
- The LAN protocol is unauthenticated by design; documenting it does not weaken anything a LAN attacker could not already do.
- Provisioning carries a Wi-Fi passphrase in plaintext over the setup AP — a consumer of this spec must send it once and never store it.

## First experiments (do these first)
1. Broadcast a `GetService` to `255.255.255.255:56700` and confirm a `StateService` reply; record the MAC and source IP.
2. `LightGet` (101) → `State` (107): read current colour, power and label.
3. `SetColor` (102) full red, then `SetPower` (117) off/on — confirm against the spec's example datagrams.
4. `GetColorZones` (502) → `StateMultiZone` (506): confirm the zone count and per-zone colours.
5. Provisioning (a reset strip, on its setup AP): `GetAccessPoints` → collect `StateAccessPoint` → `SetAccessPoint` with a test network; confirm the strip joins.

## Control surface inventory (what a replacement app must support)
- Onboarding: join the setup AP (manual on mobile), scan, pick a network, hand over credentials.
- Core controls (MVP): power, whole-strip colour, brightness, colour temperature.
- Multizone: per-zone colour and gradients.
- State read: colour/power/label and per-zone colours.
- Discovery: UDP broadcast, with the shared mDNS type as a weak corroborator.

## Evidence checklist
- APK hashes + version code (com.lifx.lifx).
- PCAP of a `GetService`/`StateService` exchange and a `SetColor` on real hardware.
- PCAP of the legacy `SetAccessPoint` onboarding exchange (to lift `verified: false` on the setup methods).

## Spec output (clean-room)
- Spec: `device-specs/devices/lifx-z.yaml` (control-plane `payload_formats`, `lifx_lan_protocol`, `setup`).
- Verification: `scripts/test_lifx_spec.py`.

## References (URLs only)
- https://github.com/LIFX/public-protocol
- https://lan.developer.lifx.com/docs
- https://github.com/magicmonkey/lifxjs (legacy access-point Protocol.md)
