# Keeping Devices Alive After the Vendor Cloud Dies

This guide is the practical companion to the protocol specs: for each device
family documented here, what is the realistic path to keep it working from a
local controller (Home Assistant, ESPHome, or a plain MQTT broker) once the
vendor's app and backend are gone — or today, while they still limp along.

Everything below is derived from the specs in this repository. Where a claim
rests on something we have not verified ourselves it is marked **unverified**.
Follow the per-device doc links for the actual protocol details; this page
deliberately does not duplicate them.

**Effort scale:** `None` = works locally today with an off-the-shelf
integration, `Low` = one-time setup, `Medium` = some DIY (custom component,
flashing, broker config), `High` = real engineering (emulate a cloud service),
`Blocked` = no known local path for the affected function.

## Quick reference

| Device / family | Transport | Keep-alive path | Effort | Details |
|---|---|---|---|---|
| Roku | Wi-Fi (HTTP ECP :8060, SSDP) | Local by design; HA `roku` integration | None | [doc](devices/roku-ecp.md) |
| Philips Hue Bridge | Wi-Fi (local REST/CLIP API) | Local API key via link-button press; HA `hue` | None | [doc](devices/hue-bridge.md) |
| WLED controllers | Wi-Fi (JSON API, WebSocket, MQTT) | Open firmware, no cloud at all; HA `wled` | None | [doc](devices/wled-controller.md) |
| LIFX Z | Wi-Fi (LAN UDP) | Local LAN protocol; HA `lifx` | None | [doc](devices/lifx-z.md) |
| TP-Link Kasa | Wi-Fi (UDP :9999 / KLAP) | Local protocol; HA `tplink` integration | None | [doc](devices/tplink-kasa.md) |
| Dyson purifiers/fans | Wi-Fi (local MQTT :1883) | Device *is* the broker; creds from sticker; custom `ha-dyson` | Low | [doc](devices/dyson-air-purifier.md) |
| iRobot Roomba (Wi-Fi) | Wi-Fi (local MQTT-over-TLS) | Password retrievable locally (dorita980); HA `roomba` | Low | [doc](devices/irobot-roomba.md) |
| Rabbit Air | Wi-Fi (local UDP protocol) | Local-only control; HA `rabbitair` | None | [doc](devices/rabbit-air-purifier.md) |
| Snapmaker U1 | Wi-Fi (Moonraker HTTP :80) | Unauthenticated local Klipper/Moonraker API | None | [doc](devices/snapmaker-u1.md) |
| TVs (Android TV, LG, Sony, Panasonic, Samsung, Vizio, Philips) | Wi-Fi (varies) | Per-brand local APIs; HA `androidtv_remote`, `webostv`, `braviatv`, `panasonic_viera`, `samsungtv`, `vizio` | None–Low | see §1 |
| Belkin Wemo | Wi-Fi (UPnP/SOAP) | Local SOAP control; HA `wemo` | None | [doc](devices/wemo-devices.md) |
| Lutron Caseta Smart Bridge 2 | Wi-Fi (LIP telnet :23) | Local LIP after local pairing; HA `lutron_caseta` | Low | [doc](devices/lutron-caseta-smart-bridge.md) |
| UniFi / MikroTik / UniFi Protect | Wi-Fi/LAN | Infrastructure gear, local by design; HA `unifi`, `unifiprotect`, `mikrotik` | None | [UniFi device](devices/ubiquiti-unifi-device.md), [MikroTik](devices/mikrotik-routeros.md), [Protect](devices/unifi-protect-camera.md) |
| Enphase Envoy | Wi-Fi (local REST/HTTPS) | Local API, but fw 7+ needs a cloud-minted JWT (~1 yr token); HA `enphase_envoy` | Medium | [doc](devices/enphase-envoy.md), §5 |
| Rachio | Wi-Fi (HomeKit HAP) | HomeKit pairing is local; vendor app path is cloud | Low | [doc](devices/rachio-controller.md) |
| PurpleAir | Wi-Fi (local JSON API) | On-device JSON API documented; no account needed | None | [doc](devices/purpleair-sensor.md) |
| devolo Home Control | Z-Wave | Re-pair sensors to any local Z-Wave controller (Z-Wave JS) | Medium | [doc](devices/devolo-home-control.md) |
| Nuki Smart Lock | BLE GATT (+ optional Wi-Fi bridge) | Local BLE keypair; HA `nuki` integration | Low | spec only (`nuki-smart-lock`) |
| Magic Display (LED) | BLE (+ cloud for OTA/ads/logs) | Fully local over BLE already; cloud loss is invisible | None | [doc](devices/magic-display.md), §2 |
| KingSmith WalkingPad | BLE (WiLink/FTMS); MIOT on Wi-Fi/CN models | Local BLE control; KS Fit cloud only syncs account/history/OTA | None–Low | [doc](devices/kingsmith-walkingpad.md), §2 |
| UREVO Walking Pad | BLE (+ UREVO cloud for account/OTA) | Local BLE control; cloud only metadata/OTA | None–Low | [doc](devices/urevo-walking-pad.md), §2 |
| Chef iQ Sense | BLE + Wi-Fi→AWS IoT MQTT | Probes broadcast readable BLE advertisements (HA `ble_monitor` decodes them) | Low | [doc](devices/chef-iq-sense.md), §2 |
| Frigidaire ACs | Wi-Fi→Electrolux OCP only | **No LAN API found**; local only via DNS/TLS emulation of OCP (nobody has built it) | High | [audit](devices/frigidaire-local-api-audit.md), §2 |
| Anki Vector | Wi-Fi (local gRPC/TLS) | wire-pod local voice/token server; WireOS on unlocked bots | Medium | [doc](devices/vector-robot.md), §2/§3 |
| Bafang BBS02/BBSHD | UART | bbs-fw open replacement firmware | Medium | [doc](devices/bafang-bbs02.md), §3 |
| Tongsheng TSDZ2 | UART | OpenSource-EBike-firmware (OSF) + wireless board | Medium–High | [doc](devices/tsdz2-tongsheng.md), §3 |
| Xiaomi LYWSD03MMC | BLE | pvvx/ATC_MiThermometer flash (browser, no soldering) or ZigbeeTLc | Low | spec only, §3 |
| Chamberlain/LiftMaster Sec+ | Wired (UART wall-panel bus) | ratgdo / Konnected blaQ board (ESPHome), fully local | Low | [ratgdo](devices/ratgdo.md), [Sec+](devices/chamberlain-garage-opener-secplus.md), §3 |
| Bluetooth LED name badge | BLE | fossasia/badgemagic-firmware on CH582M badges | Medium | [doc](devices/bluetooth-led-name-badge.md), §3 |
| Broadcast BLE sensors (Govee, Inkbird, ThermoPro, SwitchBot, SensorPush, Xiaomi, Aranet4, Airthings) | BLE adverts | Passive listen-only; HA Bluetooth / `ble_monitor` / ESPHome proxy / Theengs | None–Low | §4 |
| Kwikset Kevo | BLE (+ dead cloud) | Local BLE lock/unlock survives; eKeys/time-sync are cloud-mediated and partly lost | Low + Blocked parts | [doc](devices/kwikset-kevo.md), §5 |
| SmartThings Hub v2 | Ethernet (Edge drivers local) | Drivers run locally, but claiming a hub needs the cloud | Blocked (claim) | [doc](devices/smartthings-hub-v2.md), §5 |
| Withings | Wi-Fi/BLE | Cloud-keyed; no spec here, no known full local path | Blocked | §5 |

---

## 1. Local API / direct control — works today

These devices expose a real local control plane. Integrate them now and the
vendor cloud becomes irrelevant; the worst that happens when it dies is losing
firmware-update notifications.

**Network gear first.** Everything in this section is found by mDNS/SSDP on
the LAN, so give each device a DHCP reservation in your router *before* the
cloud disappears — an integration pointed at a stable IP keeps working even if
mDNS discovery changes in a later firmware.

- **Roku** — the External Control Protocol is plain HTTP on port 8060 with
  SSDP discovery, no auth. Home Assistant's core `roku` integration covers it.
  See [devices/roku-ecp.md](devices/roku-ecp.md).
- **Philips Hue Bridge** — the local CLIP API issues a key when you press the
  link button; no cloud account is involved at any step. HA `hue` integration.
  See [devices/hue-bridge.md](devices/hue-bridge.md).
- **WLED** — already the escape hatch: it *is* open firmware. JSON API,
  WebSocket push, MQTT, and realtime streaming protocols all work LAN-only.
  HA auto-discovers it via the `wled` integration. See
  [devices/wled-controller.md](devices/wled-controller.md).
- **LIFX Z** — local UDP LAN protocol; HA `lifx` integration. Cloud features
  (scenes synced to account) are the only casualty. See
  [devices/lifx-z.md](devices/lifx-z.md).
- **TP-Link Kasa** — local UDP 9999 (legacy XOR protocol) and the newer KLAP
  handshake are both documented; the HA core `tplink` integration (python-kasa)
  drives them locally — verified current as of 2026-08. See
  [devices/tplink-kasa.md](devices/tplink-kasa.md).
- **Dyson purifiers/fans** — the machine runs its own MQTT broker on port
  1883 (mDNS `_dyson_mqtt._tcp`); username is the serial, password is derived
  from the sticker Wi-Fi password. Record both **now** while the sticker is
  legible. The maintained path is the custom
  [`ha-dyson`](https://github.com/libdyson-wg/ha-dyson) integration
  (Dyson Local/Dyson Cloud lineage). See
  [devices/dyson-air-purifier.md](devices/dyson-air-purifier.md).
- **iRobot Roomba (Wi-Fi models)** — local MQTT-over-TLS; the per-device
  password can be pulled from the robot itself with no iRobot account
  (dorita980's password-disclosure probe). One local client at a time. HA
  `roomba`. See [devices/irobot-roomba.md](devices/irobot-roomba.md).
- **Rabbit Air** — fully local UDP protocol (HA core `rabbitair`,
  local_polling); the cloud only adds account features and OTA. See
  [devices/rabbit-air-purifier.md](devices/rabbit-air-purifier.md).
- **Snapmaker U1** — Klipper-based; Moonraker REST/WebSocket on plain HTTP
  port 80 with no authentication (verified live against a real U1). Any
  Klipper client (Mainsail/Fluidd-style) works. See
  [devices/snapmaker-u1.md](devices/snapmaker-u1.md).
- **TVs** — every documented TV platform has a local protocol: Android
  TV/Google TV (HA `androidtv_remote`, plus ADB), LG webOS (`webostv`), Sony
  Bravia (`braviatv`), Panasonic Viera (`panasonic_viera`), Samsung Tizen
  (`samsungtv`), Vizio SmartCast (`vizio`), Philips JointSPACE, Hisense VIDAA.
  See the individual pages under Devices → WiFi Devices.
- **Belkin Wemo** — local UPnP/SOAP; HA `wemo`. Setup/reset quirks are in
  [devices/wemo-setup.md](devices/wemo-setup.md).
- **Lutron Caseta Smart Bridge 2** — local LIP over telnet; pairing files are
  generated locally. HA `lutron_caseta`. See
  [devices/lutron-caseta-smart-bridge.md](devices/lutron-caseta-smart-bridge.md).
- **UniFi, UniFi Protect, MikroTik** — infrastructure gear that is local by
  design; the specs here cover discovery/identification.
- **PurpleAir** — the sensor serves its own JSON API on the LAN, no account.
  (Note: the HA `purpleair` integration is cloud-based; use the local REST
  path from the spec instead.) See
  [devices/purpleair-sensor.md](devices/purpleair-sensor.md).
- **Rachio** — the controller advertises HomeKit HAP over mDNS; HomeKit
  pairing is a local exchange, so Apple Home / `homekit_controller` keeps
  working without Rachio's cloud. Only discovery is documented in the spec —
  pairing an accessory we haven't tested is marked unverified there.
- **Nuki Smart Lock** — BLE GATT with a locally established keypair; the
  optional Wi-Fi bridge is only for remote access. HA `nuki`. Spec:
  `device-specs/devices/nuki-smart-lock.yaml` (no docs page yet).
- **Enphase Envoy** — local REST API, but see §5: firmware 7+ gates it behind
  a JWT minted from Enphase's cloud. HA `enphase_envoy` handles the token
  flow. See [devices/enphase-envoy.md](devices/enphase-envoy.md).
- **devolo Home Control** — plain Z-Wave devices; exclude them from the
  devolo hub and include them into any local Z-Wave controller (Z-Wave JS with
  a USB stick) before the devolo cloud/app goes away. See
  [devices/devolo-home-control.md](devices/devolo-home-control.md).

## 2. Cloud-redirection / interception — the device wants a server, give it one

For Wi-Fi devices that phone home, the general play is: run split-horizon DNS
(Pi-hole, AdGuard Home, or your router) so the vendor hostname resolves to a
local emulator, and terminate TLS there. How feasible that is depends entirely
on certificate pinning and hardcoded IPs — noted per device. **None of the
emulators below exist yet unless stated; treat them as documented attack
surface, not finished solutions.**

- **Magic Display (e-toys.cn)** — good news: you don't need to do anything.
  Control is 100% local BLE; the cloud backend
  (`http://api.e-toys.cn/api/`) only feeds the app's OTA-version check, ads
  and telemetry, and the OTA images are bundled in the app itself. A DNS
  sinkhole for `api.e-toys.cn` is optional hygiene. See
  [devices/magic-display.md](devices/magic-display.md).
- **KingSmith WalkingPad** — control plane is local BLE (WiLink/FTMS frames);
  the KS Fit cloud (`eu.api.ks.fit/V0.1/index.php`, plus CN and staging
  variants) only handles account, workout-history sync and OTA notification —
  all losable. For the Wi-Fi/CN variant there is a better trick than
  emulation: it is a registered Xiaomi MIOT device (`ksmb.walkingpad.v1`),
  controllable through python-miio or the HACS **Xiaomi Miot Auto**
  integration (`al-one/hass-xiaomi-miot`, verified current 2026-08). Working
  local BLE controllers: ph4r05/ph4-walkingpad, mcdax/walkingpad-controller.
  See [devices/kingsmith-walkingpad.md](devices/kingsmith-walkingpad.md).
- **UREVO Walking Pad** — same shape: local BLE control plane; the cloud
  (`service.urevosports.com`, `urevo.urevosports.com`, H5 pages on
  `h5.urevosports.com`) holds account/workout/OTA metadata. Caveat for
  would-be interceptors: the app also carries two **hardcoded plain-HTTP IP
  endpoints** — DNS redirection will not catch those; you would need
  IP-level redirection on the router. See
  [devices/urevo-walking-pad.md](devices/urevo-walking-pad.md).
- **Chef iQ Sense** — the practical keep-alive path is not the cloud channel
  at all: the probes continuously broadcast BLE advertisements that are fully
  decoded (temperature/status byte layout verified against a live CQ60) and
  already supported by HA's `ble_monitor` custom component. The cloud leg is
  AWS IoT MQTT (topics under `ciq-v2/...`, Cognito auth, OTA URL push); a
  local broker could in principle interpose, but that means defeating AWS IoT
  TLS — unverified and likely blocked by certificate validation. Treat BLE as
  the path. See [devices/chef-iq-sense.md](devices/chef-iq-sense.md).
- **Frigidaire connected ACs (Electrolux OCP)** — the honest bad news. A
  systematic audit of three app generations found **no steady-state LAN
  control API**; everything goes through OCP
  (`https://api.ocp.electrolux.one`, regional `api.us.` / `api.eu.` bases,
  websocket `wss://ws.us.ocp.electrolux.one` / `ws.eu.`). Community HA
  integrations ([ha-electrolux](https://github.com/TTLucian/ha-electrolux),
  active as of 2026-08) use the official developer API and therefore die with
  the cloud. Keeping these alive post-cloud means writing an OCP emulator and
  DNS-redirecting the fleet — High effort, unverified, nobody has done it.
  The local provisioning code in old APKs (Delta NIU TCP/TLS setup channel)
  is a lead, not a solution. See
  [devices/frigidaire-local-api-audit.md](devices/frigidaire-local-api-audit.md).
- **Anki Vector** — the most successful interception story in the collection.
  The robot speaks gRPC/TLS on the LAN; the only cloud steps were voice-intent
  processing and onboarding token issuance, and **wire-pod**
  (`kercre123/wire-pod`) replaces both locally (built on the vendor's own
  open-sourced cloud code). Official OTA hosts already fail DNS as of
  2026-07-31 while subscriptions are still billed — exactly the zombie-cloud
  scenario this guide exists for. Production robots need a one-time
  recovery-mode detour with DDL's free "ep" OTA before wire-pod will accept
  them; unlocked (OSKR/dev) robots can skip to WireOS (§3). See
  [devices/vector-robot.md](devices/vector-robot.md).

## 3. Replacement firmware / hardware — replace the brain

When the device itself is fine but its firmware is the problem, reflash it.
After flashing, these devices move into category 1 or 4 permanently.

- **Xiaomi LYWSD03MMC thermometers** — the cheapest win in home automation.
  Flash [pvvx/ATC_MiThermometer](https://github.com/pvvx/ATC_MiThermometer)
  from a Chrome browser over BLE (TelinkMiFlasher, no soldering); the sensor
  then broadcasts unencrypted ATC/BTHome advertisements any BLE monitor can
  read. The same hardware converts to **Zigbee** via pvvx/ZigbeeTLc (Z03MMC).
  ⚠ Units sold since 2025-03 with newer PCB marks are not flashable — check
  before buying. Spec: `device-specs/devices/xiaomi-lywsd03mmc.yaml`.
- **Chamberlain/LiftMaster garage openers (Security+)** — the vendor cloud
  (myQ) is actively hostile: Home Assistant removed its MyQ integration in
  2023 after Chamberlain blocked third-party access. The community answer is
  a replacement controller board wired to the wall-panel bus:
  **[ratgdo](https://paulwieland.github.io/ratgdo/)** (DIY, ESPHome/MQTT,
  fully local) or the commercial **Konnected GDO blaQ**. Works with Security+
  1.0/2.0; note that openers sold from 2025 with a white learn button use
  Security+ 3.0, which neither board supports yet. See
  [devices/ratgdo.md](devices/ratgdo.md) and
  [devices/chamberlain-garage-opener-secplus.md](devices/chamberlain-garage-opener-secplus.md).
- **Bafang BBS02/BBSHD e-bike controllers** — flash
  [bbs-fw](https://github.com/danielnilsson9/bbs-fw) for open, tunable
  firmware on the stock controller. See
  [devices/bafang-bbs02.md](devices/bafang-bbs02.md).
- **Tongsheng TSDZ2 e-bike motors** — the OpenSource-EBike-firmware project
  replaces the stock firmware (and, with the TSDZ2_wireless nRF52840 board,
  the display stack too). Higher effort: motor-controller flashing, follow the
  project wiki. See [devices/tsdz2-tongsheng.md](devices/tsdz2-tongsheng.md).
- **Anki Vector (unlocked robots)** — [WireOS](https://github.com/os-vector/wire-os)
  is a full open firmware replacement for OSKR/dev units and the only
  supported path now that the official OTA servers are dead. Production robots
  stay on stock firmware + wire-pod (§2). See
  [devices/vector-robot.md](devices/vector-robot.md).
- **Bluetooth LED name badges** — CH582M-based badges can run
  [fossasia/badgemagic-firmware](https://github.com/fossasia/badgemagic-firmware);
  the stock badge is already fully local BLE (no pairing, no cloud), driven by
  FOSSASIA's Badge Magic app or the spec here. See
  [devices/bluetooth-led-name-badge.md](devices/bluetooth-led-name-badge.md).
- **WLED** — belongs here too: for cheap ESP-based LED controllers with a
  dying app, flashing WLED *is* the keep-alive move. See §1.

## 4. BLE-only devices — already cloud-free

Most of the BLE devices in this collection never needed a cloud: no account,
no pairing infrastructure, just advertisements and GATT. They survive every
vendor bankruptcy by construction. What you need is a receiver close to them:

- **Home Assistant Bluetooth integration** with one or more **ESPHome
  Bluetooth Proxies** (`bluetooth_proxy`) — cheap ESP32 nodes that extend BLE
  range to the whole house. Many broadcast sensors (Govee, Inkbird, SwitchBot,
  Xiaomi, ThermoPro, Aranet4, oral-b) are auto-discovered by core
  integrations.
- **`ble_monitor`** (`custom-components/ble_monitor`, HACS) — passive
  listen-only decoding for a long list of broadcasters; added Chef iQ CQ60
  support in 12.8.0, covers Govee/Xiaomi/Inkbird/ThermoPro families.
- **Theengs Gateway / OpenMQTTGateway** — BLE-to-MQTT bridges; right choice
  when your controller is not Home Assistant or when you want everything on a
  plain MQTT broker. Verified active as of 2025–2026.
- **The Liberated Bread mobile app**
  ([liberatedbread-mobile](https://github.com/liberatedbread/liberatedbread-mobile))
  — renders the specs in this repo directly for interactive BLE devices (LED
  signs, name badges, heated gear, mugs, walking pads): the open replacement
  for the vendor app itself.

Devices in this category include: Govee H5075/H5080/H6001, Inkbird IBS-TH and
BBQ thermometers, ThermoPro TP357 and TempSpike, SensorPush HT1/HTP.xw,
SwitchBot BLE, Xiaomi MiFlora and Mi Scale, Aranet4 (enable the "Smart Home
integrations" toggle once to make it broadcast), Airthings Wave, oral-b
toothbrushes, Omron BLE blood-pressure monitors, Ember Mug, iTag trackers, and
the whole LED sign/panel family (iDotMatrix, SPOTLED, CoolLEDX, Shining
mask/glasses, Divoom Pixoo, ELK-BLEDOM strips, SmartDawn, xkchrome, and the
motorcycle/bicycle LEDs). For the interactive ones, the per-device pages under
Devices → BLE Devices document pairing and reset.

Honest caveat: BLE is short-range. "Cloud-free" still means you need a proxy,
gateway, or phone within radio reach — plan ESPHome proxies for fixed sensors.

## 5. Dead ends and cloud-keyed devices — the honest list

Some families have no complete local path today. Documenting that is as
valuable as documenting a success — it tells you what to fix or what to avoid
buying again.

- **Kwikset Kevo** — a real post-mortem: ASSA ABLOY shut down the Kevo app
  and portal on **2025-11-14**. Local BLE lock/unlock, tap-to-enroll of new
  phones, history pull and even firmware-update transport all keep working
  (the full BLE protocol is in the spec). What is *lost*: remote access, eKey
  management, and **time sync** — the lock's clock certificate is computed
  server-side (`serverTimingInformationCertificate`) and is not reproducible
  locally, so scheduled/time-bounded eKeys are untested. Lesson: record
  everything while the cloud is alive. See
  [devices/kwikset-kevo.md](devices/kwikset-kevo.md).
- **Enphase Envoy (firmware 7+)** — local API in name only: the JWT the local
  endpoints demand is minted by Enphase's Enlighten cloud (~1-year validity).
  If Enlighten dies, tokens stop renewing and the gated endpoints degrade to
  the few unauthenticated ones. The installer/provisioning endpoints are not
  publicly documented at all. See
  [devices/enphase-envoy.md](devices/enphase-envoy.md).
- **SmartThings Hub v2** — Edge drivers genuinely run locally on the hub
  (that's what the `_smartthings-hedge._tcp` service is), but **claiming an
  unclaimed hub and distributing drivers both require the cloud**, and there
  is no documented alternative. Samsung already bricked the hub v1 fleet on
  2021-06-30, so this risk has precedent. If you depend on it: pair critical
  Zigbee/Z-Wave devices to a local stick as insurance. See
  [devices/smartthings-hub-v2.md](devices/smartthings-hub-v2.md).
- **Withings** — not covered by this knowledge base (no spec). Their devices
  are known to be cloud-keyed with no documented local API; treat as blocked
  pending reverse engineering. *(Unverified — outside this repo's evidence.)*
- **Frigidaire / Electrolux OCP devices** — listed in §2, but until an OCP
  emulator exists they effectively belong here too.

## General practices

1. **Do it before the funeral.** Extract credentials, tokens, BLID/passwords,
   API keys and sticker secrets now, while apps and clouds still answer.
2. **Freeze the addressing.** DHCP reservations (or static IPs) for every
   local-API device; integrations keyed to IPs outlive mDNS changes.
3. **Quarantine, don't amputate.** Devices that work locally can be denied
   WAN access at the router — but block *internet*, not the LAN, and keep DNS
   redirection rules documented for the devices in §2.
4. **Archive the app.** Keep an offline copy of the vendor APK/IPA and its
   version number; it is often the only place OTA images and setup flows live
   (the Magic Display OTA images survived precisely because they were bundled
   in the app).
5. **Prefer local-first hardware next time.** Everything in §1 and §4 stayed
   useful because somebody documented it — contributing a spec is how the next
   device gets saved. See [How to Contribute](contributing/index.md).
