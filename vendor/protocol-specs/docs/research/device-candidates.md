# Candidate Devices & Hardware Sourcing

**Survey date: 2026-07-30.** Candidates were checked against the catalogue as
it stood that day — 69 specs in `device-specs/devices/` and 51 target stubs in
`targets/`.

!!! warning "The catalogue has moved on; check before you buy"

    This is a survey with a date on it, not a live view. The catalogue has grown
    well past those counts since, and some candidates below have been specced in
    the meantime — iRobot Roomba and the June Oven both ship specs now, and each
    section says so inline. Before spending money on a candidate here, check
    `device-specs/devices/` and `targets/` for it first. The reasoning about
    *why* a device is worth doing survives; the "nobody has done this" half does
    not age.

This page answers two questions at once:

1. **What should we document next?** Devices whose vendor cloud is dead or dying,
   where enough public protocol work already exists to write a clean-room spec.
2. **What does the verification hardware cost?** Every candidate carries a real
   listing price, so a spec can be confirmed against hardware instead of
   staying a paper exercise.

!!! warning "Prices are snapshots, not quotes"
    All prices are eBay US listings observed on **2026-07-30**, sorted by
    lowest total price (item + shipping). They move constantly, and the
    cheapest listing is often "parts only" — the notes say which. Re-check
    before buying. Amazon was not surveyed programmatically (it returns 503 to
    automated fetches); Amazon prices for the new-hardware items in Tier 3 and
    Tier 6 are generally within a few dollars of the eBay figures.

!!! note "Clean-room discipline still applies"
    A public reverse-engineering write-up is a *reference*, not a license to
    copy. Follow [Clean-room Rules](../CLEANROOM_RULES.md): cite the source,
    re-derive the protocol, and never lift code or vendor assets into a spec.

## Vendor-risk classification (A / B / C)

The device tiers below sort candidates by *technical* fit. This axis is
orthogonal: it sorts by *how urgently the vendor relationship is failing the
owner*, which is what decides whether a spec is a rescue or just a nicety.

- **A — already subscription-gated or abandoned.** The cloud is off, the app
  is paywalled, or the company is in bankruptcy. Owners are hurting *now*. A
  spec is a rescue.
- **B — likely to land in A.** Going-concern warnings, a parent company
  folding related lines, a subscription on new models that will spread to old,
  or a track record of doing exactly this. Documenting ahead of the shutdown
  means the spec exists *before* owners need it.
- **C — unlikely to be abandoned, but still worthwhile** purely for local-first
  independence: one fewer cloud account, one fewer app, one less thing that
  phones home. Lower urgency, real value.

Each candidate below carries an **[A]**, **[B]** or **[C]** tag. The
[at-risk device groups](#at-risk-device-groups-subscription-and-abandonment-watch)
section near the end is organised entirely around this axis and collects the
groups surfaced specifically by scanning for subscription and shutdown risk.

## What this repo should actually spend effort on

Three filters decide whether a candidate is *our* work, applied in order. All
three must pass — the third is the one that usually settles it:

1. **Can it be saved locally at all?** If the device only ever talks to the
   vendor cloud with no LAN path (Cosori/VeSync, and — on the evidence — June),
   then no amount of RE gives local control; you'd be building a self-hosted
   cloud replacement. Those are parked in
   [No local path](#no-local-path-cloud-only-architecture), not worked now.
2. **Does the user's phone speak to the device's own radio, or must they add
   hardware?** This is the one that matters most for the sibling
   [Flutter BLE app](https://github.com/PigsCanFlyLabs/opengreeniot-mobile).
   Many "local" solutions are really an **ESP32 bridge** wired or soldered into
   the device — that's a different product, not a phone-native protocol. We
   want specs a phone app can implement to talk to the device's *existing*
   radio directly, the same path the vendor app uses. Anything whose only route
   is "add an ESP32" (Neato's serial pads, a keypad-only desk's pass-through
   dongle) fails this filter, however cheap.
3. **Is the protocol written down cleanly anywhere, or does it only live inside
   client code?** A maintained HA/ESPHome integration is a *client*, not a
   spec — but if it already documents the wire format well (Roomba via
   dorita980, RuuviTag, TTLock), re-specifying adds little. The differentiated
   work is protocols that exist **only as source code or scattered forum
   posts**: those are where a clean, implementation-independent spec is the
   thing nobody else has written.

The sweet spot is **cheap + phone-direct + protocol-unwritten**, on either
radio — a short list of
[undocumented BLE gadgets](#undocumented-local-ble-protocol-lives-only-in-client-code)
(the Qingping frame, blind motors, Bluetooth-equipped desks) and
[LAN-controllable Wi-Fi devices](#undocumented-local-wi-fi-lan-controllable-phone-direct)
(WiZ lights, AVRs) the phone can drive with no added hardware. Expensive,
cloud-only, or ESP-bridge-only candidates are kept but clearly marked as
heavier or parked.

---

## Tier 1 — Orphaned by the vendor (highest mission fit)

**Every device in this tier is risk class [A]** — orphaned or subscription-gated
by definition; that is what "Tier 1" means. The A/B/C tags matter more in the
lower tiers and in the [at-risk groups](#at-risk-device-groups-subscription-and-abandonment-watch)
section, where fit and urgency diverge.

These are the devices the project exists for: hardware that still works but
whose cloud has been switched off.

### 1. Spotify Car Thing

| | |
|---|---|
| Transport | USB (serial/ADB), Bluetooth |
| Status | **Bricked by vendor** — killed 2024-12-09; Spotify issued refunds |
| Public RE | [err4o4/spotify-car-thing-reverse-engineering](https://github.com/err4o4/spotify-car-thing-reverse-engineering), [iFixit custom-firmware guide](https://www.ifixit.com/Guide/How+to+Install+Custom+Firmware+onto+Car+Thing/178814), Nocturne replacement firmware (2026) |
| Cheap unit | **$40** used (no cable, auction) — $68 open-box, typical range $54–$75 |

The bootloader is unlocked-able and the community already has feature-parity
firmware. What is missing is a written protocol/interface spec: the USB
control surface, the display bus, and the dial/button event encoding. Good
first Tier-1 target because the device is inert without documentation.

### 2. Neato Botvac Connected (D3/D4/D5/D6/D7)

| | |
|---|---|
| Transport | Wi-Fi (cloud, now dead) + internal UART serial console |
| Status | **Cloud shut down 2025** by Vorwerk; app control and scheduling gone |
| Public RE | [pybotvac](https://pypi.org/project/pybotvac/) (Nucleo cloud API, RE by Lars Brillert), [RobertSundling/neato-botvac](https://github.com/RobertSundling/neato-botvac/discussions/12), `neato-connected` ESP32-on-UART approach |
| Cheap unit | **$99.99** used complete D5. Parts/spares $3–$15 |

The interesting half is the **local serial command set** on the robot's RX/TX
pads — that is what survives the cloud shutdown, and it is only documented as
scattered forum posts. Vorwerk explicitly refused to release the cloud API,
so this is the canonical "documentation is the only rescue" case. Most
expensive Tier-1 buy; worth one unit.

### 3. Logitech Harmony Hub

| | |
|---|---|
| Transport | Wi-Fi LAN — local WebSocket API + (restored) XMPP |
| Status | **Product line discontinued**; local API was removed in firmware 4.15.206, then restored in 4.15.250 as officially-unsupported |
| Public RE | [JordanMartin/harmonyhub-api](https://github.com/JordanMartin/harmonyhub-api), [maddox/harmony-api](https://github.com/maddox/harmony-api/issues/106) |
| Cheap unit | **$9.99** used hub-only — $10–$18 is the normal band |

Cheapest Tier-1 hardware by a wide margin, and the precedent matters: a vendor
removed a local API and public pressure got it back. A spec pins that down so
the next firmware change cannot quietly take it away again. Slots naturally
into the existing **WiFi Devices** cluster alongside `roku-ecp` and
`hue-bridge`.

### 4. Bose SoundTouch

| | |
|---|---|
| Transport | Wi-Fi LAN — local HTTP/XML API, plus Bluetooth/AirPlay |
| Status | **Cloud ended 2026-05-06** (extended from 2026-02-18). Bose shipped a final offline-capable app *and published the API* |
| Public reference | [Bose SoundTouch end-of-life page](https://www.bose.com/soundtouch-end-of-life), [SoundTouchPlus HA component](https://github.com/thlucas1/homeassistantcomponent_soundtouchplus/discussions/37) |
| Cheap unit | **$29.97–$50** parts-only SoundTouch 10; **~$60–$70** for a tested working unit |

Note this one needs *documentation*, not reverse engineering — Bose released
the specs. That makes it the fastest spec on this page to write and the
easiest to verify, and it is a useful contrast case in the docs: the vendor
did the right thing on the way out.

### 5. Insteon Hub 2245-222

| | |
|---|---|
| Transport | Wi-Fi/Ethernet LAN HTTP API; Insteon powerline + 915 MHz dual-mesh |
| Status | **Cloud died abruptly in 2022** when SmartLabs folded (later revived by a user group) |
| Public reference | Insteon's own published developer guides; `pyinsteon`, `insteon-terminal` |
| Cheap unit | **$14.88–$22** used hub; $9.99 parts-only |

Two protocol layers worth separate specs: the hub's local HTTP interface and
the underlying Insteon message format over the PLM serial link. The dual-band
powerline mesh is a transport the repo has no coverage of at all.

### 6. Nest Learning Thermostat, 1st & 2nd generation

| | |
|---|---|
| Transport | Wi-Fi (Weave/TLS, port 9243) |
| Status | **Support ended October 2025** after 14 years |
| Public RE | Fragmentary. No complete public local protocol map located |
| Cheap unit | **~$22.95** tested working; $15.90 unit-only, $10 parts-only |

Listed for reach, not for readiness — a very large installed base went dark at
once. Be honest about the state: the local Weave interface is authenticated
and not publicly mapped, so this is a **research target**, not a spec that can
be drafted from existing sources. Buy one only if someone intends to do the
capture work.

---

## Tier 2 — Cheap BLE sensors that extend families we already cover

Low cost, low risk, and each one broadens an existing spec cluster rather than
starting a new one. **All risk class [C]** — these vendors are fine; the value
is local-first sensor reads with no app. (RuuviTag is barely even that: the
vendor publishes the format, so it's cooperative rather than a rescue.)

| Device | Why | Public RE | Cheap unit |
|---|---|---|---|
| **Govee H5074 / H5179** | Extends the existing `govee-h5075-thermo.yaml` to the rest of the family | [Theengs decoder H5074](https://decoder.theengs.io/devices/H5074.html), [H5179](https://decoder.theengs.io/devices/H5179.html) | **$15 + $5 ship**; $17.81–$22 typical |
| **RuuviTag** | Vendor **publishes** its RAWv2 advertisement format — a reference-quality passive-advertisement spec | [Theengs RuuviTag RAWv2](https://decoder.theengs.io/devices/RuuviTag_RAWv2.html) | **$27.95** open box; $29.95 new; Pro $64 |
| **BLE TPMS sensors** | Fits the OBD-II / vehicle cluster; passive advertisement decode, no pairing | Theengs decoder TPMS support | **$19.98 for 4** (≈$5/sensor), new |
| **Qingping CGG1 / CGDK2** | Xiaomi-adjacent; sends both MiBeacon **and** an undocumented Qingping format — the Qingping format is the gap | [Theengs / ble_monitor by brand](https://home-is-where-you-hang-your-hack.github.io/ble_monitor/by_brand) | No eBay listings found 2026-07-30; source from AliExpress (~$10–15) |

The Qingping second format is the most interesting item in this tier: it is a
documented *absence* — decoders support MiBeacon from these sensors and
explicitly do not support the Qingping frames.

---

## Tier 3 — Battery, solar and energy (a transport family the repo lacks)

The repo had only `enphase-envoy` in this space at survey time — it now also
has `enphase-iqbattery-ble` and `bluetti-power-station` — and this is still the
best-documented and cheapest-to-buy category surveyed.

### JK-BMS / JBD (Xiaoxiang) / Daly BMS — BLE + UART

| | |
|---|---|
| Public RE | [syssi/esphome-jk-bms](https://github.com/syssi/esphome-jk-bms), [syssi/esphome-jbd-bms](https://github.com/syssi/esphome-jbd-bms), [fl4p/batmon-ha](https://github.com/fl4p/batmon-ha), [patman15/BMS_BLE-HA](https://github.com/patman15/BMS_BLE-HA) |
| Cheap unit | **JK BMS from $6.35** (4S entry) new; **JBD BLE module $12.35–$13** new; **Daly BLE/UART module ~$21** new |

Cheapest new hardware on this entire page, three vendors share one problem
space, and the protocols are already mapped in maintained implementations.
Highest specs-per-dollar of anything surveyed. Each vendor deserves its own
spec; a shared "BMS BLE patterns" protocol page would mirror the existing
`obd2-common.md`.

### Victron Instant Readout — BLE advertisement

| | |
|---|---|
| Public RE | [keshavdv/victron-ble](https://github.com/keshavdv/victron-ble), [felixwatts/victron_ble](https://github.com/felixwatts/victron_ble), [Olen/VictronConnect](https://github.com/Olen/VictronConnect) |
| Cheap unit | **$38.88–$39.10** new Smart Battery Sense |

Victron publishes its extra-manufacturer-data layout, and the community
decoders fill the rest. Encrypted advertisements with a per-device key — a
pattern nothing in the repo currently documents.

### Renogy BT-1 / BT-2 — BLE-to-Modbus bridge

| | |
|---|---|
| Public RE | `cyrils/renogy-bt`; also covered by [BMS_BLE-HA](https://github.com/patman15/BMS_BLE-HA) |
| Cheap unit | **$19.95** new; $19.99 open box |

A BLE wrapper around Modbus registers — worth documenting as a transport
pattern, since the same trick shows up across solar and inverter gear.

---

## Tier 4 — Locks and actuators

| Device | Transport | Public RE | Cheap unit |
|---|---|---|---|
| **TTLock locks** | BLE | [Fusseldieb/ttlock-reverse-engineering](https://github.com/Fusseldieb/ttlock-reverse-engineering) — packet framing documented down to CRC8/MAXIM and the `0d 0a` tail; [ttlock-sdk-js](https://github.com/Fusseldieb/ttlock-reverse-engineering), [ha-ttlock-ble](https://github.com/roquerodrigo/ha-ttlock-ble) | Lock bodies from **$28.50** (cabinet/NFC); full door locks $34+; G2 gateway $18 |
| **Tuya BLE (Fingerbot etc.)** | BLE | `redphx/python-tuya-ble`, [ShonP40/Tuya-BLE](https://github.com/ShonP40/Tuya-BLE), [BillyNate/esphome-tuya-ble](https://github.com/BillyNate/esphome-tuya-ble) | **Fingerbot from $8.99** new |

TTLock is the strongest lock candidate: the framing is already published, the
lock name encodes the MAC in reverse byte order (a nice discovery signal for
the spec's `discovery` block), and it complements the existing `nuki-smart-lock`
and `switchbot-ble` specs.

Tuya BLE is a **platform**, not a device — one spec covering the DP
(datapoint) framing and session key exchange would unlock hundreds of cheap
devices at once. Best leverage-per-spec on the page. Note the honest catch:
the local key normally comes from a one-time cloud enrolment, and that
dependency belongs in the spec.

---

## Tier 5 — Mobility (extends the existing e-bike/scooter cluster)

| Device | Transport | Public RE | Cheap unit |
|---|---|---|---|
| **Xiaomi M365 / Ninebot** | BLE serial with register map | [CamiAlfa/M365-BLE-PROTOCOL](https://github.com/CamiAlfa/M365-BLE-PROTOCOL) (protocol notes + register spreadsheet), [m365py](https://github.com/AntonHakansson/m365py), [macbury/m365](https://github.com/macbury/m365) | **BLE dashboard board $18.78–$22.99** new — no need to buy a whole scooter to bench-test |
| **Votol EM series controllers** | CAN bus + BLE programming dongle | [bananu7/votol](https://github.com/bananu7/votol), [Ming2k8-Coder/VotolAIO](https://github.com/Ming2k8-Coder/VotolAIO), Endless Sphere protocol threads | **$25–$28.72** new (LanDe EM25–EM150S / EM150-2 class) |

The M365 dashboard-board trick is the useful find here: the BLE module is sold
separately for under $23, so the protocol can be exercised on a bench supply.
Votol pairs directly with the existing `fardriver-controller.yaml` and would
give the repo a second CAN-based controller alongside the OBD-II references.

---

## Tier 6 — Wi-Fi and BLE commodity gear

| Device | Transport | Public RE | Cheap unit |
|---|---|---|---|
| **Zengge / Magic Home / LEDnetWF** | Wi-Fi binary + BLE | [flux_led](https://github.com/lightinglibs/flux_led) (Wi-Fi, protocol RE'd from captures), [8none1/zengge_lednetwf](https://github.com/8none1/zengge_lednetwf) (BLE), [vikstrous/zengge-lightcontrol](https://github.com/vikstrous/zengge-lightcontrol), [HA led_ble](https://www.home-assistant.io/integrations/led_ble/) | **$1.99–$5** new controller |
| **TP-Link Kasa** | Wi-Fi LAN, TCP/9999 XOR-obfuscated JSON | `python-kasa` | **$6.74** used HS103; ~$1.50/plug in used multipacks |
| **Electronic shelf labels (Solum ZBS243)** | 802.15.4 + BLE | [OpenEPaperLink](https://github.com/OpenEPaperLink/OpenEPaperLink) — SoC reverse engineered by dmitry.gr, unencrypted Zigbee-like packets | **~$4.90/tag** (Solum Newton Lite 20-pack, $97.99); 2.2" single $62.50 |

Zengge is the highest-volume LED family the repo does *not* cover, and it is
the cheapest hardware surveyed — dual-stack (Wi-Fi *and* BLE) with firmware
revisions that shift the framing, which is exactly the kind of variation a
written spec is good at capturing. It sits right next to the existing
`elk-bledom-led-strip` and `coolledx-led-sign` specs.

On the ESL listings: the **Solum** lots are the OpenEPaperLink-compatible
ones. The much cheaper **Altierre** lots (50 tags for $80.75, ≈$1.62/tag) are
a *different*, unmapped proprietary system — cheap, but they are a research
target, not a quick spec.

---

## Tier 7 — Kitchen BLE (cheap, but the vendors are still alive)

Documentable and inexpensive; lower mission fit because nothing here is
abandoned. Extends `inkbird-bbq-thermometer`, `ibbq-meat-thermo`,
`thermopro-tempspike-bbq` and `chef-iq-sense`. **Mostly risk class [C]**, but
Anova (its own section below) is the cautionary tale for the whole tier — a
subscription arrived on a "still alive" kitchen vendor, which nudges the rest
of this group toward **[B]** on a long horizon.

| Device | Public RE | Cheap unit | Vendor status |
|---|---|---|---|
| **Weber / iDevices iGrill 2, mini, v3** | [1mckenna/esp32_iGrill](https://github.com/1mckenna/esp32_iGrill), [fransakeson/ESP32_iGrill](https://github.com/fransakeson/ESP32_iGrill), [pilot1981/weber-igrill-integration-HA](https://github.com/pilot1981/weber-igrill-integration-HA) | **$17.99** used iGrill 2 | App still updated (v4.9.1, Jan 2025) — **not** abandoned |
| **MEATER / MEATER+** | [nathanfaber/meaterble](https://github.com/nathanfaber/meaterble) | **$19.99** open-box MEATER+ | Active |
| **Fellow Stagg EKG+ / EKG Pro** | [tlyakhov/fellow-stagg-ekg-plus](https://github.com/tlyakhov/fellow-stagg-ekg-plus), [calvinmclean/stagg-ekg-plus](https://github.com/calvinmclean/stagg-ekg-plus), `breiflabb/ekg-pro-ble-lib` | **$44** EKG Pro (parts-only); working units higher | Active |
| **Anova** | See the dedicated section below — three protocol generations | **$9.99** used circulator | Active, but app is now paywalled for new accounts |

The Stagg is the most technically interesting single device here: BLE
serial-port service `0x1820` / characteristic `0x2A80`, `0xEFDD` frame
separator, and a magic init sequence the kettle requires before it will talk —
a clean worked example for the BLE patterns page.

---

## Anova kitchen gear — three protocol generations

Anova earns its own section: it is not one device but three distinct protocol
families, two of which the **vendor documents publicly**, and the cheapest
hardware on this page that has a first-party protocol reference.

### Vendor status — the nuance that matters

| Date | What happened |
|---|---|
| Jul 2024 | Anova announced it would cut remote connectivity for the original **Bluetooth and Bluetooth+** cookers on 2025-09-28, with a 50%-off trade-up that expired 2024-08-01 |
| 2024-08-21 | App went **subscription**: $1.99/mo or $9.99/yr. Accounts created before this date are grandfathered free. Account creation, previously optional, became mandatory |
| 2025-01-16 | Anova **rescinded** the shutdown: "we will continue to support all versions of our products indefinitely" |

So Anova is not an abandoned vendor — credit where due, they reversed the
shutdown. The reason it still belongs here is the **interaction between the
grandfather clause and the used market**: a $10 circulator bought on eBay today
is being paired with a *new* account, which is not grandfathered. The hardware
outlives the entitlement. A local spec is what makes second-hand Anova gear
usable without a subscription — which is the same rescue as a dead cloud,
arriving by a different route.

### Generation 1 — original Precision Cooker (2014, "Anova PC"), 800W BT / 900W Wi-Fi

| | |
|---|---|
| Transport | BLE — a single service with a **single characteristic** carrying both TX and RX |
| Encoding | ASCII strings terminated with `\r`; responses arrive as notifications, possibly chunked across several |
| Vendor docs | [A2/A3 protocol overview](https://developer.anovaculinary.com/docs/devices/a2-a3/overview) — covers the 800W BT-only and 900W Wi-Fi variants |
| Public RE | [Aldaviva/SousVide](https://github.com/Aldaviva/SousVide) (+ its [Communication Protocol wiki](https://github.com/Aldaviva/SousVide/wiki/Communication-Protocol), tested against a 2014 PC 1.0), [pyanova](https://github.com/c3V6a2Vy/pyanova), `jshridha/anovamaster`, openHAB binding |
| Cheap unit | **$9.99** untested 900W · **$20.00** working 800W (BIN) · $25.99–$33.49 tested/excellent |

The easiest spec on this page to write and verify: line-oriented ASCII over one
characteristic, two independent descriptions to cross-check (vendor docs *and*
a community RE with a protocol wiki), and $10–$20 hardware. Note the quirk
worth capturing — one characteristic for both directions is unusual enough that
naive GATT clients get it wrong.

### Generation 2 — Nano and Mini (2018+)

| | |
|---|---|
| Transport | BLE — service `0e140000-0af1-4582-a242-773e63054c68`, three characteristics: **TX**, **RX**, **ASYNC** (unsolicited status) |
| Encoding | `[Domain byte][Message type byte][optional protobuf payload]`, **COBS**-encoded to strip zero bytes, zero-byte terminator, then chunked for the BLE MTU |
| Vendor docs | [Nano overview](https://developer.anovaculinary.com/docs/devices/nano/overview); separate pages for Mini and A2/A3 |
| Cheap unit | **$14.99** Nano (Wi-Fi+BT) · $25 Nano BT-only · **$19.95** Mini AN300-US00 (BIN) · $28 Mini open-box |

The most valuable of the three for the repo. **COBS framing appears nowhere in
`device-specs/` today** — protobuf does (`admore-light-bar`, `vector-robot`)
but consistent-overhead byte stuffing does not, and it is a recurring pattern
in BLE protocols that need a clean packet delimiter. A separate ASYNC
notification channel is also worth documenting as a pattern. First-party UUIDs
and encoding means the spec can be written with high confidence and then
confirmed against $15 hardware.

### Generation 3 — Wi-Fi devices and the Precision Oven

| | |
|---|---|
| Transport | WebSocket, real-time messaging |
| Auth | Personal access token, generated in the app under **More → Developer → Generate Personal Access Token** |
| Vendor docs | [Wi-Fi implementation example](https://developer.anovaculinary.com/docs/devices/wifi/implementation-example) — covers both Precision Cookers and Precision Ovens, with an official Python CLI reference implementation |
| Public RE | [bogd/anova-oven-api](https://github.com/bogd/anova-oven-api) (documents the oven API), [awgneo/anova-homeassistant](https://github.com/awgneo/anova-homeassistant) (local WebSocket control), [andr83/hacs-anova-oven](https://github.com/andr83/hacs-anova-oven), [kmdm/hass_anova_cooker](https://github.com/kmdm/hass_anova_cooker) |
| Cheap unit | Oven: **$50 parts-only** · $300–$400 faulty · **$783–$850** working/new. Wi-Fi circulator: **$25.99** |

Do the Wi-Fi *circulator* here, not the oven. The oven is the one genuinely
expensive item surveyed, and several 1.0 listings report the same
"temperature runaway" fault — poor value as a verification unit when the same
WebSocket API can be exercised on a $26 Wi-Fi cooker.

Worth flagging honestly: a token minted through the vendor app is a cloud
dependency, even though the transport is local. The spec should say so plainly
and record what happens to an already-issued token if the account lapses —
that is the question a subscription-era owner actually needs answered, and it
is exactly the kind of thing that goes unrecorded until the answer stops
mattering.

### Recommendation

Two specs, roughly **$35** of hardware:

1. **`anova-precision-cooker.yaml`** — Gen 1 ASCII/BLE, verified on a $20 unit.
   Fastest to land, two independent references.
2. **`anova-precision-cooker-nano.yaml`** — Gen 2 COBS+protobuf/BLE, verified
   on a $15 Nano. Brings a new framing pattern into the repo.

Gen 3 can wait for the `$26` Wi-Fi circulator; skip the oven.

---

## At-risk device groups (subscription and abandonment watch)

This section is the result of scanning specifically for **groups of devices
likely to be abandoned or to have a subscription bolted on** — the failure
modes the project exists to pre-empt. It is organised by the A/B/C axis, not by
transport, because here the *timing of the vendor's decision* is the point.
Prices are eBay US, observed 2026-07-30 unless noted.

### Group A — already abandoned or subscription-gated

The urgent ones. Owners are already losing function or paying for what they
used to own.

#### iRobot Roomba (900 / 960 / 980 / i / e series)

| | |
|---|---|
| Risk | **A** — iRobot filed **Chapter 11 on 2025-12-15** and is being taken private by Picea Robotics; a March 2025 going-concern warning preceded it |
| Transport | Wi-Fi LAN — local command channel, no cloud required |
| Public RE | [koalazak/dorita980](https://github.com/koalazak/dorita980) (900/960/980/i7/e5/690 and more), [koalazak/rest980](https://github.com/koalazak/rest980) (local REST wrapper) |
| Cheap unit | **$32.50** Wi-Fi robot w/ dock · **$40–$70** for a tested 980 |

!!! success "Done — `device-specs/devices/irobot-roomba.yaml`"

    This one was acted on after the survey and the spec ships, including a
    dated field test of the discovery probe. What is left here is hardware
    verification of the rest of the command set, not a fresh write-up.

The strongest single A-group find, and the reason it was picked up first. A
~50-million-device installed base whose maker is in bankruptcy, and the local
protocol *already* mapped in a mature, widely-forked library that talks straight
to the robot over the LAN. The spec largely wrote itself from dorita980, and $33
hardware verifies it. This is the canonical case the project was built for.

#### Eight Sleep Pod (Pod 2 / Pod 3)

| | |
|---|---|
| Risk | **A** — core features (Autopilot, temperature scheduling, sleep tracking) were retroactively moved behind a **mandatory ~$25/mo subscription**; the device also needs the internet to change temperature, so an AWS outage left beds stuck |
| Transport | Local network — the community firmware replaces the cloud-facing `dac` process and talks to the Pod's microcontrollers directly |
| Public RE | [LiamSnow/opensleep](https://github.com/LiamSnow/opensleep) (full open firmware), [bobobo1618/ninesleep](https://github.com/bobobo1618/ninesleep), [throwaway31265/free-sleep](https://github.com/throwaway31265/free-sleep), [freesleep-notes](https://github.com/appositeit/freesleep-notes), [ZeroSleep root-access writeup](https://blopker.com/writing/04-zerosleep-1/) |
| Cheap unit | Pod 3 hub **$60 parts/repair**; working cover+hub sets $579+ |

Unusually mature liberation ecosystem — there is already *complete open
firmware*, so a spec here is documentation of a solved problem, high-confidence
and high-value. The catch is hardware cost: the cover is expensive, and the
cheap listings are hub-only. Document from the existing firmware; buy a
$60 hub if bench verification is needed.

#### Snoo Smart Sleeper (Happiest Baby)

| | |
|---|---|
| Risk | **A** — in **July 2024** Happiest Baby paywalled features that shipped free (weaning/"sleepytime", car-ride mode) behind **$20/mo**; buyers before 2024-07-15 grandfathered, so the used market is squarely affected |
| Transport | Cloud API + PubNub messaging (not local today) |
| Public RE | [rado0x54/pysnoo](https://github.com/rado0x54/pysnoo), [DanPatten/pysnoo2](https://github.com/DanPatten/pysnoo2), [swar/homeassistant-snoo-smart-bassinet](https://github.com/swar/homeassistant-snoo-smart-bassinet) |
| Cheap unit | **$399** used bassinet (a $1,695 device new) |

Textbook subscription bait-and-switch, and the same grandfather-clause trap as
Anova: a used Snoo pairs to a new account that isn't grandfathered. Honesty
flag — the public work is all **cloud-API** RE via PubNub; nobody has a local
channel yet. So this is a *cloud-protocol* spec (how to talk to the Snoo
backend without the paywalled app), not a local rescue, and the spec must say
so. Lower priority than the local-capable A devices.

#### June Oven (Weber)

| | |
|---|---|
| Risk | **A** — Weber will **shut down all June connected services on 2026-09-22**; remote control and the in-oven camera die with the servers. A change.org petition is asking Weber to open-source the app |
| Transport | Wi-Fi / **cloud-only** — the app appears to reach the oven only through Weber's hosted service, with no local LAN control path |
| Public RE | Minimal — no complete local protocol map located; the petition exists precisely because owners have no fallback |
| Cheap unit | **$60 parts-only**; working Gen3 units $950 |

!!! info "Partly acted on — `device-specs/devices/june-oven.yaml`"

    A spec and a target stub exist, recording the cloud-only finding rather than
    a local protocol; `docs/devices/june-oven-lan-recon.md` and
    `scripts/june_discover.py` cover the recon. The open work is the
    capture-before-shutdown investigation described below, not a first write-up.

The honest revision: June has **no confirmed local path**, so it belongs with
the [no-local-path group](#no-local-path-cloud-only-architecture) — a clean RE
likely yields "impersonate the June cloud," not "control the oven on the LAN,"
and that is a self-hosted-server project, not a spec. Its one genuinely useful,
**time-boxed** action is capturing app↔cloud traffic *before 2026-09-22* while
the servers still answer — that window does not reopen. Don't buy a $950 oven
for it; capture from an owner's unit if one surfaces.

#### Echelon Connect bikes / fitness gear

| | |
|---|---|
| Risk | **A** — a **July 2025** firmware update forced a server connection; offline, resistance and metrics are disabled, and a **$40/mo** plan is needed for more than basics |
| Transport | BLE (the machine's own sensor/resistance channel) |
| Public RE | **Legally blocked.** A working jailbreak won a $20k Fulu Foundation bounty but **cannot be released** — DMCA §1201. See [404 Media](https://www.404media.co/developer-unlocks-newly-enshittified-echelon-exercise-bikes-but-cant-legally-release-his-software/), [TechSpot](https://www.techspot.com/news/109241-echelon-exercise-machines-lose-offline-functionality-after-update.html) |
| Cheap unit | Parts only in this survey; complete bikes not surfaced in the sorted results |

Included as a **documented non-starter**, deliberately. The protocol is
understood by at least one developer, but the legal situation makes a public
spec a §1201 problem in a way the rest of this page is not — most candidates
here rest on freely-published RE, whereas Echelon's is under a bounty NDA. Flag
it, watch it, and let a right-to-repair exemption or the older
pre-update-firmware BLE profile be the opening before spending effort. This is
the clearest example of *why the legal note at the top of the page matters*.

### Group B — likely to land in A

Not gated yet, but the signals are there: a subscription on new models that
will creep to old, a parent company shedding related lines, or a history of
exactly this move.

| Device group | Why B | Public RE | Cheap unit |
|---|---|---|---|
| **Owlet Smart Sock** | Baby vitals behind an app + cloud (Ayla Networks); FDA history already forced one product change, and vitals-as-a-service is the obvious paywall | [puco/owlet-api](https://github.com/puco/owlet-api), [ryanbdclark/pyowletapi](https://github.com/ryanbdclark/pyowletapi), [mbevand/owlet_monitor](https://github.com/mbevand/owlet_monitor) | Base station **$10–$18** |
| **Nanit / cloud baby cams** | Live view and history increasingly subscription-tied; no vendor RTSP, so local viewing already needs a proxy | [gregory-m/nanit](https://github.com/gregory-m/nanit) (local restream proxy) | Varies; not surveyed |
| **Furbo / Petcube pet cameras** | Newer Furbo models **require** a paid plan just to activate; AI alerts and history already paywalled — the direction of travel is clear | Community integrations exist; protocol not fully mapped | Not surveyed (new models subscription-locked) |
| **Tonal** | Movement library, training modes and Apple Watch link are subscription-locked today; hardware is inert without it — one bad quarter from an Echelon-style enforcement | None public located | Not surveyed |

Owlet is the actionable one: the Ayla Networks cloud API is well-documented by
three independent projects, base stations are $10, and it slots beside the
sensor specs the repo already carries. The rest are watch-list — record the
signal now so the work is scoped when the paywall lands.

### Group C — unlikely to be abandoned, but worth it for local-first

These vendors are healthy; the value is purely fewer clouds and fewer apps.

| Device group | Why still worth it | Public RE | Cheap unit |
|---|---|---|---|
| **Wyze Cam (v2 / v3 / Pan)** | Vendor pulled the official RTSP firmware and pushes cloud/AI plans; local streaming already needs community help | [mrlt8/docker-wyze-bridge](https://github.com/mrlt8/docker-wyze-bridge/discussions/1356), [thingino firmware](https://grokipedia.com/page/Thingino), [openmiko](https://github.com/openmiko/openmiko), [wyzecam PyPI](https://pypi.org/project/wyzecam/) | **$4.65–$12** camera |
| **TP-Link Kasa** | Healthy vendor, but a fully local TCP/9999 JSON protocol already exists — trivial spec, zero cloud | `python-kasa` | **$6.74** (already in Tier 6) |
| **Tile trackers** | Life360 keeps nudging Premium, but basic BLE find still works; a passive-advertisement spec removes the app entirely | BLE advertisement decoders | Low; not surveyed |
| **Zengge / Magic Home LED** | Active vendor, but local BLE/Wi-Fi control is fully mapped — no reason to route $2 LED controllers through a cloud | [flux_led](https://github.com/lightinglibs/flux_led) (already in Tier 6) | **$1.99** (already in Tier 6) |

Wyze is the standout C: cameras are almost free on the used market, the vendor
keeps trimming local features, and there is a deep community firmware base
([Thingino](https://grokipedia.com/page/Thingino), OpenMiko) plus a local
Python library. Not abandoned, but the direction is unmistakable and the
hardware is disposable-cheap.

### At-risk groups — buy list

| Device | Risk | Cheapest observed | Public RE ready? |
|---|---|---|---|
| Wyze Cam v3 / Pan | C | $4.65 | Yes (bridge + firmware) |
| iRobot Roomba 980 | A | $32.50 | **Yes (dorita980)** |
| Owlet base station | B | $10.00 | Yes (3 projects) |
| Eight Sleep Pod 3 hub | A | $60.00 (parts) | **Yes (opensleep)** |
| June Oven | A | $60.00 (parts) | No — capture before 2026-09-22 |
| Snoo bassinet | A | $399.00 | Cloud-only RE |
| Echelon bike | A | — | Blocked (DMCA) |

**Reading this section against the effort filter:** Roomba and Wyze are the
highest-*urgency* items here, but their protocols are already mapped and
documented — so for us they are **link-and-setup-guide**, not spec work (see
[Already liberated elsewhere](#already-liberated-elsewhere-link-dont-spec)).
Owlet (B) is the cheap pre-emptive pick where a written spec still has value,
because the cloud API is only encoded in three scattered projects.

---

## Undocumented local BLE (protocol lives only in client code)

**This is the sweet spot** the effort filter points at: devices that are cheap,
driven entirely over local BLE **by the phone's own radio** (no ESP32, no
soldering, no controller swap), and whose protocol has been figured out but
**only exists inside a client** — never written as an implementation-independent
spec. Writing that spec is exactly what the Flutter app needs, and none of
these need an expensive unit to verify.

All three are risk class **[C]** on the vendor axis (the makers are fine) but
top of the list on the *effort* axis. The **Hardware** column is the decider:
"phone only" means a phone app talks straight to the device, the same path the
vendor app uses.

| Device | Hardware to add | Protocol state | Public RE (code-only) | Cheap unit |
|---|---|---|---|---|
| **Qingping CGG1 / CGDK2** thermo-hygrometer | **None** — phone passively listens to advertisements | **Undocumented** — Theengs/ble_monitor decode the MiBeacon frames but explicitly *not* the Qingping-format frames these also emit | [ble_monitor by brand](https://home-is-where-you-hang-your-hack.github.io/ble_monitor/by_brand) | ~$10–14 AliExpress (no eBay listings 2026-07-30) |
| **AM43 / A-OK blind & shade motors** | **None** — the motor *is* the BLE peripheral; the phone connects to it directly ([homebridge-am43](https://github.com/renssies/homebridge-am43-blinds) confirms host-BLE, no ESP) | RE'd, but the frame format lives in code, not prose | [buxtronix/am43](https://github.com/buxtronix/am43) (ESP is *optional*, for MQTT), [homebridge-am43-blinds](https://github.com/renssies/homebridge-am43-blinds), [openHAB AM43 binding](https://community.openhab.org/t/new-binding-am43-blind-drive-motor-binding/90272) | **$30** open-box motor; $39 typical |
| **Jiecang / Uplift / Desky desks — BT-equipped only** | **None** *if* the desk has the factory BLE receiver ([JCP35N-BLT](https://www.jiecang.com/product/jcp35n-blt.html)); the vendor app already drives it over BLE. Keypad-only desks need an ESP dongle — **out of scope** | Clean `F1 F1 … 7E` framing with opcode/len/checksum — documented only in blog posts and sketches | [SitStand writeup](https://gregraiz.com/blog/sitstand-bluetooth-desk-controller/), [graiz/sitstand](https://github.com/graiz/sitstand), [tzermias/deskctl](https://github.com/tzermias/deskctl) | receiver box **$25** open-box |

Notes that make these good spec targets, not just good devices:

- **Qingping** is a documented *hole*, not a guess — the decoders tell you
  exactly which frames they refuse, so the spec has a precise, testable scope.
  It slots straight beside the existing `xiaomi-lywsd03mmc` MiBeacon work, and
  it's the purest phone-direct case on the page: no connection at all, just
  advertisement decode.
- **AM43** has a one-client-at-a-time quirk (the app and any controller can't
  both be connected) that belongs in the spec's connection notes — the kind of
  operational detail that only survives if it's written down.
- **Desks** share one BLE profile across many resellers (Uplift, Desky,
  Assmann, Jiecang OEM) *that carry the receiver box*, so a single spec covers
  a whole shelf of hardware — the same leverage the SPOTLED and CoolLEDX specs
  give the repo. Scope the spec to the BLE receiver, and say plainly that
  keypad-only desks are an ESP-bridge job we don't cover.

**Also phone-direct BLE, but pricier hardware:** **Acaia / Felicita / Bookoo
coffee scales.** The protocol is a genuine gap — it lives only in
[pyacaia](https://github.com/lucapinello/pyacaia) and
[AcaiaArduinoBLE](https://github.com/tatemazer/AcaiaArduinoBLE) code, the phone
talks BLE straight to the scale, and it's a popular niche. The catch is cost:
the RE'd scales run **$95+** (Bookoo SC-mini $95, Acaia $100+), so it's a good
spec for someone who already owns one, not a cheap bench buy.

**Recommended first specs:** **Qingping** and **AM43** — both are pure
phone-direct (no added hardware at all), cheap, and unwritten. The
**BT-equipped desk** is a strong third, scoped to units with the factory
receiver.

---

## Undocumented local Wi-Fi (LAN-controllable, phone-direct)

The Wi-Fi sibling of the section above, held to the same three filters — the
phone reaches the device **on the LAN** (UDP/TCP/HTTP), no cloud, no added
hardware, and the protocol is unwritten. The repo already carries LAN specs of
exactly this shape (`lifx-z` UDP, `wemo-devices` SOAP, `roku-ecp`), so these
slot in as siblings rather than a new category.

The trap here is filter #1: **most "smart Wi-Fi" gear is cloud-only** and has no
LAN path at all (see [No local path](#no-local-path-cloud-only-architecture)).
The winners are the few that expose a genuine local API the vendor app itself
uses on-network.

| Device | Local transport | Hardware to add | Protocol state | Public RE | Cheap unit |
|---|---|---|---|---|---|
| **WiZ (Philips) lights** | UDP :38899 JSON, **no auth**, UDP-broadcast discovery | **None** — phone sends JSON straight to the bulb | **No official spec** — protocol only in [pywizlight](https://github.com/sbidy/pywizlight) and blog posts | [pywizlight](https://github.com/sbidy/pywizlight), [wiz-hack](https://github.com/myselfshravan/wiz-hack), [CLI writeup](https://aleksandr.rogozin.us/blog/2021/8/13/hacking-philips-wiz-lights-via-command-line) | **$7.99** open-box bulb |
| **Denon / Marantz AVRs** | Telnet + an **undocumented HTTP API**; single connection | **None** — phone talks to the receiver directly | Telnet is semi-known; the **HTTP API is undocumented** (the real gap) | [HA denonavr](https://www.home-assistant.io/integrations/denonavr/), [openHAB denonmarantz](https://www.openhab.org/addons/bindings/denonmarantz/) | **$15–30** used networked AVR |
| **Govee Wi-Fi (LAN-API models)** | UDP multicast 4001/4002, control :4003 | **None** (must toggle LAN API on in the app) | **Partly documented** — Govee's own "LAN API 101" + [govee2mqtt LAN.md](https://github.com/wez/govee2mqtt/blob/main/docs/LAN.md) | [wez/govee-lan-hass](https://github.com/wez/govee-lan-hass) | **$9.99** Wi-Fi bulb |
| **Ecowitt GW1000/GW1100** weather gateway | HTTP `/get_livedata_info` JSON on the LAN | **None** — phone/HTTP polls the gateway | **Undocumented** — this JSON endpoint isn't in Ecowitt's docs (their published protocol is a separate TCP one) | [ecowitt_local](https://github.com/alexlenk/ecowitt_local), [gw1000-http](https://github.com/bmrzycki/gw1000-http) | **$22.99** open-box gateway |
| **Daikin Wi-Fi AC (BRP069A/B)** | HTTP REST on :80, **no auth** | **None** — phone hits the module directly | Older API community-documented; the **firmware-2.8+ `/dsiot/multireq` JSON is under-documented** (newest C4x modules are cloud-only — see below) | [daimik local-API docs](https://github.com/daimik/Daikin-BRP069C4x-Local-API), [ael-code/daikin-control](https://github.com/ael-code/daikin-control), pydaikin | adapter **$130** (or built into the unit) |
| **Yamaha AVRs (YNCA)** | Telnet `:50000` text protocol | **None** — phone talks to the receiver | Semi-gap — YNCA is less documented than MusicCast's leaked YXC spec | [mvdwetering/yamaha_ynca](https://github.com/mvdwetering/yamaha_ynca) | **$20–40** used networked AVR |

Notes:

- **WiZ is the standout** — the LAN equivalent of Qingping. Unauthenticated
  UDP+JSON, $8 hardware, one of the most common budget bulbs sold, and *no*
  vendor spec exists. It sits right next to `lifx-z` and would be one of the
  fastest, most reusable Wi-Fi specs on the page.
- **Ecowitt** is the second cheap standout: a $23 gateway with an *undocumented*
  local JSON endpoint, and a whole weather-sensor category the repo doesn't
  touch. The vendor documents a TCP protocol but not this HTTP one — a precise,
  testable hole like Qingping.
- **Daikin** opens HVAC — a big, high-value category — over a no-auth local
  HTTP API. Two honest caveats: the *newest* BRP069**C4x** modules are
  cloud-only (parked below), and the standalone adapter is ~$130, so this is
  best done by someone who already owns a Daikin, not bought to bench.
- **Denon/Marantz** and **Yamaha YNCA** together stake out AV receivers. Scope
  Denon to its **undocumented HTTP API** (telnet is semi-covered by vendor
  PDFs); YNCA is the lighter-documented Yamaha equivalent. Cheap used, just
  bulky.
- **Govee LAN** extends the repo's existing Govee BLE specs (`govee-h5075`,
  `-h5080`, `-h6001`) to Wi-Fi, but it's only *partly* a gap since Govee
  published a LAN primer — worth doing for family completeness, lower novelty.

**Already local but already written → link, don't spec:** a surprising number
of LAN protocols are *already cleanly documented*, so they go straight to the
[link registry](#already-liberated-elsewhere-link-dont-spec) rather than
becoming spec work:

- **Yeelight** — TCP :55443 JSON-RPC, but Yeelight [published an Inter-Operation Spec](https://www.yeelight.com/download/Yeelight_Inter-Operation_Spec.pdf).
- **Venstar thermostats** — a [vendor-published local REST API](https://venstar.com/localapi/).
- **Onkyo / Pioneer eISCP** — commands come from an [official Excel spec](https://github.com/miracle2k/onkyo-eiscp) (parsed into YAML). Documented.
- **Vizio SmartCast TVs** — the community already maintains [full API docs](https://github.com/exiva/Vizio_SmartCast_API) (token-paired, port 7345).
- **LG webOS TVs** — the local websocket protocol is well-mapped ([aiowebostv](https://github.com/home-assistant-libs/aiowebostv)).
- **PurpleAir** — local sensor JSON is [community-documented](https://community.purpleair.com/t/sensor-json-documentation/6917).

These are the WiFi analogue of the Roomba/dorita980 case: real local control,
but re-specifying would just duplicate an existing written protocol.

---

## No local path (cloud-only architecture)

Parked, deliberately. These devices only ever talk to the vendor cloud — there
is **no LAN control path to reverse-engineer**, so RE yields at best a
self-hosted replacement of the vendor's servers, not local control of the
device. That is a materially bigger project than a protocol spec, and it is
**not what we're taking on right now.**

| Device | Why it's here | Shutdown / gate |
|---|---|---|
| **June Oven** | App reaches the oven only through Weber's hosted service; no confirmed local path | Services off **2026-09-22** |
| **Cosori / VeSync air fryers** | Control is the VeSync cloud API with cloud token auth; no local network control | Vendor active, fully cloud-bound |
| **Snoo** (cloud-RE only) | RE exists but via the Snoo backend + PubNub, not a local channel | Paywalled July 2024 |
| **Traeger WiFire** | WiFi path relays through the vendor socket (the BLE-capable grills are the exception) | Vendor active |
| **Daikin BRP069C4x** (newest modules) | Unlike the BRP069A/B, the current-gen module is cloud-only — no local API. Buy the older module or a unit with it | Vendor active |

### If we ever come back to these

Two lighter-weight ideas were floated and are worth recording — both are
**future work, not now**:

- **Reclaim the domain on shutdown.** When a vendor turns off and lets its
  service domain lapse (June's, say), re-registering it and standing up a
  minimal look-alike endpoint could let already-configured devices keep
  working. Depends entirely on the device not pinning TLS certs and on the
  domain actually dropping — neither guaranteed, and it carries real
  operational and trust burden.
- **Local DNS redirect.** Rather than owning the public domain, point the
  device at a self-hosted endpoint from the user's own network — e.g. a DNS
  override on their Home Assistant / Pi-hole box that maps the vendor host to a
  local replacement server. Per-user setup, but no domain race and no
  cert-pinning fight if the device tolerates it.

Both need the same prerequisite: capturing the cloud protocol **while the
servers are still up**. For June specifically that means before 2026-09-22.
Until we decide to build a replacement server, the only cheap insurance is that
capture — everything past it is the heavier lift we're choosing not to start.

---

## Already liberated elsewhere (link, don't spec)

Lower priority by design: a maintained tool already gives local control **and**
documents the protocol well enough that a fresh spec would just compete with
it — exactly the pywemo situation the README describes. The useful contribution
here is a pointer (and maybe a setup guide or video), not a YAML.

| Device | Use this | Local? |
|---|---|---|
| iRobot Roomba (900/i/e/j) | [dorita980](https://github.com/koalazak/dorita980) / roombapy + HA native | Yes (LAN) |
| TP-Link Kasa | `python-kasa` + HA | Yes (TCP/9999) |
| Zengge / Magic Home | [flux_led](https://github.com/lightinglibs/flux_led) + HA `led_ble` | Yes |
| JK / JBD / Victron | [esphome-jk-bms](https://github.com/syssi/esphome-jk-bms), [victron-ble](https://github.com/keshavdv/victron-ble) | Yes (BLE) |
| Wyze Cam | [docker-wyze-bridge](https://github.com/mrlt8/docker-wyze-bridge), [thingino](https://grokipedia.com/page/Thingino) | Yes |
| Logitech Harmony Hub | [harmonyhub-api](https://github.com/JordanMartin/harmonyhub-api) + HA native | Yes (WS) |
| Neato Botvac (serial) | [OpenNeato](https://github.com/renjfk/OpenNeato), [botvac-wifi](https://github.com/sstadlberger/botvac-wifi) | Yes (UART) |
| Eight Sleep Pod | [opensleep](https://github.com/LiamSnow/opensleep) firmware | Yes (post-flash) |
| Husqvarna Automower | [automower-ble](https://pypi.org/project/automower-ble/) | Yes (BLE) |
| Yeelight | [python-yeelight](https://gitlab.com/stavros/python-yeelight); vendor [Inter-Op Spec](https://www.yeelight.com/download/Yeelight_Inter-Operation_Spec.pdf) | Yes (TCP :55443) |
| Venstar thermostats | [vendor local REST API](https://venstar.com/localapi/) + HA native | Yes (HTTP) |

Neato is the honest edge case: its protocol *isn't* cleanly written, but every
route (OpenNeato, botvac-wifi) solders an **ESP32 onto the robot's serial
pads** — there is no radio the phone can reach, so it fails the phone-direct
filter and stays here rather than graduating to a spec candidate. If a device
here turns out to be protocol-unwritten *and* phone-reachable, that one can
graduate up; Neato can't.

---

## Considered and deprioritised

Recording these so the same ground is not re-covered.

| Device | Why not now |
|---|---|
| **Sena / Cardo intercoms** | DFU images are signed and flash extraction needs hardware modification; no usable public protocol map. High effort, low odds. |
| **Chamberlain / LiftMaster Security+ 2.0** | [ratgdo](https://paulwieland.github.io/ratgdo/) already solves it properly with a wired board, and the rolling-code serial protocol is obfuscated. Document only if we can add something ratgdo has not. |
| **Logitech POP buttons** | Bricked in 2025 with two weeks' notice, but the hardware is a thin bridge-dependent button — little protocol surface to liberate. |
| **Broadlink RM4** | `python-broadlink` covers it and eBay results were all accessories; no clean price signal. Low priority. |
| **Wink / Lowe's Iris hubs** | Iris hubs stopped working in 2019, and Wink is the archetypal [A] cautionary tale — a "no monthly fees" hub that imposed a mandatory $5/mo in 2020 with one week's notice, then suffered multi-day outages. But no local protocol documentation surfaced in this survey, so a spec would need ground-up research. Cited in the write-up as *why the B watch-list exists* more than as a candidate. |
| **June Oven** | Moved to [No local path](#no-local-path-cloud-only-architecture): [A] urgency (2026-09-22 shutdown) but cloud-only, so it's a capture-before-shutdown investigation, not a local spec. |

---

## Consolidated buy list

Ordered by cost. Every price is the cheapest listing observed on 2026-07-30;
"parts" flags a listing sold as non-functional.

| Device | Cheapest observed | Condition | Tier |
|---|---|---|---|
| Zengge / Magic Home LED controller | $1.99 | New | 6 |
| JK-BMS (4S entry) | $6.35 | New | 3 |
| TP-Link Kasa HS103 | $6.74 | Used | 6 |
| WiZ (Philips) smart bulb | $7.99 | Open box | WiFi gap |
| Tuya Fingerbot | $8.99 | New | 4 |
| Govee Wi-Fi bulb (LAN-API) | $9.99 | New | WiFi gap |
| Qingping CGG1 / CGDK2 | ~$10–14 (AliExpress) | New | BLE gap |
| Denon / Marantz networked AVR | $15–30 | Used | WiFi gap |
| Yamaha AVR (YNCA) | $20–40 | Used | WiFi gap |
| Ecowitt GW1100 weather gateway | $22.99 | Open box | WiFi gap |
| Standing-desk BLE controller | $25.00 | Open box | BLE gap |
| AM43 / A-OK blind motor | $30.00 | Open box | BLE gap |
| Acaia / Bookoo BLE coffee scale | $95+ | New | BLE gap (pricey) |
| Daikin BRP069A/B Wi-Fi adapter | $130 (or built-in) | New | WiFi gap (pricey) |
| Anova Precision Cooker, original BT | $9.99 (untested) / $20.00 working | Used | Anova |
| Logitech Harmony Hub | $9.99 | Used | 1 |
| JBD / Xiaoxiang BLE module | $12.35 | New | 3 |
| Insteon Hub 2245-222 | $14.88 | Used | 1 |
| Anova Precision Cooker Nano | $14.99 | Used | Anova |
| Govee H5074-class thermo-hygrometer | $15.00 + ship | New | 2 |
| Weber iGrill 2 | $17.99 | Used | 7 |
| Xiaomi M365 BLE dashboard board | $18.78 | New | 5 |
| MEATER+ | $19.99 | Open box | 7 |
| Renogy BT-1 | $19.95 | New | 3 |
| BLE TPMS, set of 4 | $19.98 | New | 2 |
| Daly BMS BLE/UART module | ~$21 | New | 3 |
| Nest Learning Thermostat gen 2 | $22.95 | Used, tested | 1 |
| Votol EM controller | $25.00 | New | 5 |
| RuuviTag | $27.95 | Open box | 2 |
| TTLock cabinet/NFC lock | $28.50 | New | 4 |
| Bose SoundTouch 10 | $29.97 (parts) / ~$60 working | Mixed | 1 |
| Victron Smart Battery Sense | $38.88 | New | 3 |
| Spotify Car Thing | $40.00 | Used | 1 |
| Fellow Stagg EKG Pro | $44.00 | Parts | 7 |
| Solum ESL tags (20-pack) | $97.99 (~$4.90/tag) | New | 6 |
| Neato Botvac D5 | $99.99 | Used, complete | 1 |

**A Tier-1-plus-Tier-3 starter basket** — Harmony Hub, Insteon Hub, Car Thing,
JK-BMS, JBD module, Renogy BT-1, Victron Smart Battery Sense — comes to
roughly **$160** and covers five protocol families the repo has no spec for.

---

## Suggested order of work

Re-ordered against the effort filter — **phone-direct + protocol-unwritten
first**, not raw urgency. Already-liberated urgent devices (Roomba, Wyze, BMS,
Zengge) drop off to the
[link registry](#already-liberated-elsewhere-link-dont-spec); anything whose
only route is an added ESP32 (Neato serial, keypad-only desks) is excluded from
spec work by the phone-direct filter.

1. **Qingping CGG1 / CGDK2 frame** — ~$12, zero added hardware (passive
   advertisement listen), a precisely-scoped documented hole next to the
   existing MiBeacon work. The cleanest phone-direct spec on the page.
2. **AM43 / A-OK blind motors** — $30, phone talks BLE straight to the motor
   (confirmed, no ESP); the one-client quirk is worth writing down.
3. **WiZ lights** — $8, unauthenticated UDP+JSON on the LAN, no vendor spec,
   sibling to `lifx-z`. The Wi-Fi twin of Qingping and just as clean.
4. **Ecowitt GW1100** — $23, an undocumented local JSON endpoint, opens the
   weather-sensor category. Precise, testable hole.
5. **BT-equipped standing desks** — $25 receiver, phone-direct for units with
   the factory BLE box, one framed profile across many resellers. Scope to the
   receiver; keypad-only desks are out.
6. **Denon / Marantz (+ Yamaha YNCA)** — the AV-receiver category; scope Denon
   to its undocumented HTTP API, YNCA is the lighter Yamaha equivalent. Cheap
   used hardware.
7. **Spotify Car Thing** — $40, high-profile orphan with no protocol spec
   anywhere. Not BLE (USB/host), but it liberates the device itself rather than
   adding hardware, so it passes the spirit of the filter.
8. **Insteon PLM / powerline message format** — $15 hub; the hub HTTP layer is
   phone-reachable and the powerline layer is a transport the repo has zero
   coverage of.
9. **Anova Gen 1 and Gen 2** — ~$35, vendor-documented, phone-direct BLE; Gen 2
   brings COBS framing into the repo.

**Higher-value but pricier hardware** (do if you already own one): **Daikin**
BRP069A/B local HTTP (HVAC category, ~$130 adapter) and **Acaia/Bookoo** BLE
coffee scales (protocol gap, $95+).

**Time-boxed, separate track:** capture June Oven cloud traffic before
**2026-09-22** if a unit is reachable — the only cheap action on the parked
[no-local-path](#no-local-path-cloud-only-architecture) group.

**Not spec work (link, don't build):** point owners of Roomba, Wyze, Kasa,
Zengge, BMS, Harmony, Eight Sleep and Automower at the existing tools. Neato
belongs here too — its only route is an ESP on the serial pads, so it's a
hardware-mod to link to, not a phone-native spec to write. Where you want to
add value, record a setup guide or video — the schema's `helpful_videos` field
is built for exactly that.

**Time-boxed exception:** capture June Oven app/API traffic *before its
2026-09-22 shutdown* if any owner's unit is reachable — that window does not
reopen, unlike everything else here.

**Pre-emptive [B] pick:** Owlet Smart Sock — $10 hardware, three independent RE
projects, documents a vitals cloud API before the obvious paywall lands.

## Sources

Vendor status and shutdown timelines:

- [7 smart home brands that bricked their own products](https://www.howtogeek.com/smart-home-brands-that-bricked-products/)
- [Bose: SoundTouch cloud service ended](https://www.bose.com/soundtouch-end-of-life) ·
  [Hackster: Bose opens the API](https://www.hackster.io/news/bose-throws-end-of-life-soundtouch-owners-a-lifeline-plans-an-offline-app-update-and-opens-the-api-e6b4a59bd94c)
- [Neato: announcement, 6 Oct 2025](https://support.neatorobotics.com/support/solutions/articles/204000073686-announcement-6th-oct-2025) ·
  [Vorwerk explains the Neato cloud shutdown](https://www.wespeakiot.com/vorwerk-explains-neato-cloud-shutdown-why-your-smart-vacuum-just-got-dumb/)
- [TechCrunch: Spotify Car Thing refunds](https://techcrunch.com/2024/05/30/spotify-begins-offering-car-thing-refunds-as-it-faces-lawsuit-over-bricking-the-streaming-device)
- [Anova: ongoing product support, updated 2025-01-16](https://anovaculinary.com/blogs/blog/good-news-about-ongoing-product-support) ·
  [Anova sous vide subscription FAQ](https://support.anovaculinary.com/hc/en-us/articles/29269573803405-The-New-Anova-Sous-Vide-Subscription-FAQ) ·
  [Engadget on the subscription](https://www.engadget.com/home/kitchen-tech/anova-will-charge-customers-to-use-its-sous-vide-app-because-everything-must-be-a-subscription-151906912.html)
- [HA blog: Logitech Harmony removes local API](https://www.home-assistant.io/blog/2018/12/17/logitech-harmony-removes-local-api/)
- [Forrester: Insteon and the internet of bricks](https://www.forrester.com/blogs/insteon-and-the-internet-of-bricks)

At-risk groups — subscription and abandonment:

- [CNBC: iRobot going-concern warning](https://www.cnbc.com/2025/03/12/shares-of-irobot-tank-30percent-after-roomba-maker-issues-going-concern.html) ·
  [Manufacturing Dive: iRobot Chapter 11, acquisition by Picea](https://www.manufacturingdive.com/news/roomba-braava-maker-irobot-chapter-11-bankruptcy-acquisition-picea-china/807997/)
- [Washington Post: Snoo subscription backlash](https://www.washingtonpost.com/business/2025/01/18/snoo-bassinet-subscriptions/) ·
  [STAT: the Snoo paywall](https://www.statnews.com/2024/09/04/snoo-premium-features-sids-insurance/)
- [The Spoon: the June Oven is cooked (2026-09-22 shutdown)](https://thespoon.tech/its-all-but-official-the-june-oven-is-cooked/) ·
  [Change.org: demand a final June firmware](https://www.change.org/p/demand-a-final-firmware-update-for-june-ovens)
- [404 Media: Echelon unlock can't be legally released (DMCA §1201)](https://www.404media.co/developer-unlocks-newly-enshittified-echelon-exercise-bikes-but-cant-legally-release-his-software/) ·
  [TechSpot: Echelon offline lockout](https://www.techspot.com/news/109241-echelon-exercise-machines-lose-offline-functionality-after-update.html)
- [Tom's Guide: Peloton $40/mo to keep the treadmill working](https://www.tomsguide.com/news/peloton-will-brick-your-dollar4300-treadmill-if-you-dont-pay-the-dollar40-monthly-fee)
- [Consumer Reports: Wink pay-up-or-be-disabled](https://www.consumerreports.org/smart-home/wink-tells-users-pay-up-or-we-will-disable-smart-home-hub/)
- [Furbo: features available without the Nanny plan](https://help.furbo.com/hc/en-us/articles/17462722245785-Basic-Features-you-can-use-without-Furbo-Nanny)
- [Wyze: RTSP firmware (withdrawn) support note](https://support.wyze.com/hc/en-us/articles/360026245231-Wyze-Cam-RTSP)
- Eight Sleep mandatory subscription and local-control gap:
  [ZeroSleep root-access writeup](https://blopker.com/writing/04-zerosleep-1/)

Protocol references are linked inline in each candidate's row.
