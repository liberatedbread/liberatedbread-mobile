# Device Registry

A catalog of IoT devices we've documented (or are documenting).

| Status | Meaning |
|--------|---------|
| Research | Initial investigation |
| In Progress | Actively reverse engineering |
| Complete | Protocol fully documented |

## Guides

- [LED Sign & Panel Design Apps](led-sign-apps.md) — which app designs content for which LED
  panel family, and how to triage an unknown sign.
- [WiFi Discovery](wifi-discovery.md) — finding devices already on the network
- [Wemo Setup, Factory Reset and Rebinding](wemo-setup.md) — the worked provisioning example
- [Frigidaire Local API Audit](frigidaire-local-api-audit.md) — why some devices cannot be rescued
- [Initial Device Setup](../protocols/device-setup.md) — provisioning patterns across devices

## Devices

The **Setup** column records how a factory-fresh device is provisioned, and how
well that flow is understood. The full machine-readable version lives in each
spec's `device.setup` block; the patterns are explained in
[Initial Device Setup](../protocols/device-setup.md).

| Device | Protocol | Status | Setup | Manufacturer |
|--------|----------|--------|-------|-------------|
| [Ember Mug](ember-mug.md) | BLE | Complete | None needed | Ember Technologies |
| [Bluetooth LED Name Badge](bluetooth-led-name-badge.md) | BLE | Complete | None needed | Generic (multiple vendors) |
| [iDotMatrix](idotmatrix.md) | BLE | Complete | None needed | iDotMatrix / LedHun |
| [LEDs2Rave4 Lunchbox LED](leds2rave4-lunchbox-led.md) | BLE | Complete | None needed | SP LED (SP107E / SP110E) |
| [SPOTLED LED Panels](spotled-led-panel.md) | BLE | Complete | None needed | Host No.4 Technology / generic OEM |
| [CoolLEDX / CoolLED1248 Signs](coolledx-led-sign.md) | BLE | In Progress | None needed | Juntong Technology |
| [Shining Mask](shining-mask.md) | BLE | Complete | None needed | Shenzhen Shining Bright Technology |
| [PAX Vape](pax-vape.md) | BLE | Complete | None needed | PAX Labs |
| [Shining Glasses](shining-glasses.md) | BLE | Complete | None needed | Shenzhen Shining Bright Technology |
| [Magic Display](magic-display.md) | BLE | Complete | None needed | tirohk / AiTURE |
| [Chef iQ Sense](chef-iq-sense.md) | BLE + Wi-Fi | Complete | BLE provisioning (medium) | Chefman / Chef iQ |
| [AUTOBABA LED Backpack](autobaba-led-backpack.md) | BLE + Wi-Fi | Complete | None needed | LOY SPACE / popled.cn |
| [Nyan BT Image Controller](nyan-bt-image-controller.md) | BLE | Complete | None needed | NYAN GEAR / LOY SPACE |
| [MoTool Slacker](motool-slacker.md) | BLE | In Progress | None needed | MoTool |
| [AdMore Light Bar Pro](admore-light-bar.md) | BLE | Complete | None needed | AdMore Lighting Inc. |
| [ProGlow Motorcycle LED](proglow-motorcycle-led.md) | BLE | Spec Available | None needed | ProGlow |
| [SeeBlue Motorcycle LED](seeblue-motorcycle-led.md) | BLE | Spec Available | None needed | SeeBlue |
| [SmartDawn Smart Lights](smartdawn-smart-lights.md) | BLE (Wi-Fi variants) | In Progress | None needed | Hangzhou Daniao / SmartDawn |
| [KingSmith WalkingPad](kingsmith-walkingpad.md) | BLE | Complete | None needed | KingSmith Fitness (Xiaomi ecosystem) |
| [Kwikset Kevo](kwikset-kevo.md) | BLE (lock is central) | In Progress | BLE tap-to-enroll (medium) | Kwikset / ASSA ABLOY (UniKey) |
| [Schlage Smart Locks](schlage-smart-locks.md) | BLE (uWeave; WiFi is cloud-relay only) | Complete | BLE SPAKE2 pairing, printed programming code (medium) | Schlage / Allegion |
| [Belkin Wemo Smart Devices](wemo-devices.md) | WiFi | In Progress | [SoftAP + SOAP](wemo-setup.md) (medium) | Belkin |
| [Anki Vector Robot](vector-robot.md) | WiFi + BLE | Research | BLE provisioning (high) | Anki / Digital Dream Labs |
| [Frigidaire Connected ACs](frigidaire-ac.md) | WiFi | Research | Cloud account only (low) | Frigidaire (Electrolux) |
| [Roku External Control Protocol](roku-ecp.md) | WiFi | Complete | On-device UI (high) | Roku / TCL |
| [Android TV / Google TV Remote](android-tv-remote.md) | WiFi | Spec Available | On-TV pairing code (medium) | Google / various |
| [Hisense VIDAA TVs](hisense-vidaa.md) | WiFi | Spec Available | On-TV PIN + mTLS cert (low) | Hisense |
| [LG webOS TVs](lg-webos.md) | WiFi | Spec Available | On-TV accept prompt (high) | LG |
| [Panasonic Viera TVs](panasonic-viera.md) | WiFi | Spec Available | None (pre-2019) / on-TV PIN (medium) | Panasonic |
| [Philips JointSPACE TVs](philips-jointspace.md) | WiFi | Spec Available | None (pre-2016) / on-TV PIN (medium) | TP Vision / Philips |
| [Samsung Tizen TVs](samsung-tizen-tv.md) | WiFi | Spec Available | On-TV allow prompt (high) | Samsung |
| [Sony Bravia TVs](sony-bravia.md) | WiFi | Spec Available | PSK or on-TV PIN (medium) | Sony |
| [Vizio SmartCast TVs](vizio-smartcast.md) | WiFi | Spec Available | On-TV PIN pairing (medium) | Vizio |
| [Philips Hue Bridge](hue-bridge.md) | WiFi | Complete | Wired + link button (high) | Signify / Philips Hue |
| [Enphase Envoy](enphase-envoy.md) | WiFi | Complete | Wired / SoftAP (low) | Enphase Energy |
| [Dyson Air Purifier](dyson-air-purifier.md) | WiFi | Complete | SoftAP, sticker creds (medium) | Dyson |
| [LIFX Z](lifx-z.md) | WiFi | Complete | SoftAP, uncaptured (low) | LIFX |
| [Lutron Caseta Smart Bridge 2](lutron-caseta-smart-bridge.md) | WiFi | In Progress | Wired + cert pairing (medium) | Lutron |
| [Rachio Controller](rachio-controller.md) | WiFi | Research | Uncaptured (low) | Rachio |
| [SmartThings Hub v2](smartthings-hub-v2.md) | WiFi | Research | Wired + cloud account (low) | Samsung SmartThings |
| [devolo Home Control](devolo-home-control.md) | Z-Wave | Spec Available | Exclude/re-include to any Z-Wave controller (medium) | devolo AG |
| [OBD-II Bluetooth Adapters](obd2-bluetooth-adapter.md) | BLE + Bluetooth Classic | Complete | Pairing (medium) | Generic / ScanTool / Vgate |
| [OBDLink MX+](obdlink-mx-plus.md) | BLE + Bluetooth Classic | In Progress | Button pairing (medium) | OBD Solutions / ScanTool |
| [Triumph Tiger 900](triumph-tiger-900.md) | OBD-II (CAN) | In Progress | None needed | Triumph Motorcycles |
| [BMW Motorcycle Diagnostics](bmw-motorcycle-diagnostics.md) | OBD-II (BMW D-CAN) | In Progress | None needed | BMW Motorrad |
| [Fardriver ND-series Motor Controller](fardriver-controller.md) | BLE | Research | None needed | Nanjing Fardriver |
| [Bafang BBS02 Mid-Drive](bafang-bbs02.md) | UART (BLE via bridge) | Research | None needed | Bafang |
| [Tongsheng TSDZ2 Mid-Drive](tsdz2-tongsheng.md) | UART (9600 baud) | Research | None needed | Tongsheng |
| [Bosch Performance Line CX Gen4](bosch-ebike-cx-gen4.md) | CAN | Research | None needed | Bosch eBike Systems |
| [NIU Electric Scooter](niu-escooter.md) | Cloud HTTP + BLE | Research | Cloud account only (low) | Niu Technologies |
| [WLED Addressable LED Controller](wled-controller.md) | WiFi | Complete | SoftAP portal (medium) | WLED project (open firmware) |
| [Rabbit Air Purifiers](rabbit-air-purifier.md) | WiFi (UDP 9009) | Complete | BLE-assisted / SoftAP via vendor app (medium) | Rabbit Air (vendor publishes the LAN library) |

## Not everything here was liberated

Almost every entry above is a reconstruction — somebody worked the protocol out
from captures, firmware or an app teardown. A few are not, and specs say which
they are in `device.openness`:

| Status | Means |
|---|---|
| `open_by_design` | Published protocol; third-party clients are the point. Read upstream, not us |
| `documented_api` | Official interface exists, product otherwise closed. Part cited, part reconstructed |
| `undocumented` | Nothing published. Our best reconstruction — the default here, and the usual case |
| `hostile` | Vendor actively fights third-party clients. Documented anyway; expect breakage |

[WLED](wled-controller.md) is the worked `open_by_design` example, and it is
here partly to keep the distinction honest: a registry framed around liberating
documentation should be able to say when there was nothing to liberate. See
[Reading a Device Spec](../api/spec-format.md) for the field.
