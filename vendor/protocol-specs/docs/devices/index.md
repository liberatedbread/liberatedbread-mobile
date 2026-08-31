# Device Registry

A catalog of IoT devices we've documented (or are documenting).

| Status | Meaning |
|--------|---------|
| Research | Initial investigation |
| In Progress | Actively reverse engineering |
| Spec Available | Validated spec published; not yet replayed against hardware |
| Complete | Protocol fully documented |

## Guides

- [LED Sign & Panel Design Apps](led-sign-apps.md) — which app designs content for which LED
  panel family, and how to triage an unknown sign.
- [WiFi Discovery](wifi-discovery.md) — finding devices already on the network
- [Wemo Setup, Factory Reset and Rebinding](wemo-setup.md) — the worked provisioning example
- [Frigidaire Local API Audit](frigidaire-local-api-audit.md) — why some devices cannot be rescued
- [June Oven LAN & IP Recon](june-oven-lan-recon.md) — the IP-level playbook for the oven's closed
  local surface: what it exposes on the network and what can be done with it
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
| [LED space Wi-Fi LED Screen](led-space.md) | Wi-Fi (device AP) + BLE variant | Complete | None needed (device hosts its AP) | LOY SPACE / popled.cn |
| [SP105E Magic LED Controller](sp105e-magic-led.md) | BLE | Spec Available | None needed | Sperll-era OEM (BTF-LIGHTING, ALITOVE, …) |
| [BanlanX SP6xxE LED Controllers](banlanx-sp6xxe.md) | BLE | Spec Available | None needed | Sperll (BanlanX app) |
| [SP108E LED Shop WiFi Controller](led-shop-sp108e.md) | WiFi (device AP; TCP 8189) | Spec Available | Join device SoftAP (low) | Sperll-era OEM |
| [duoCo StripX / Lotus Lantern Pixel Strips](wl-smartled-pixel-strips.md) | BLE | Spec Available | None needed | fstart/easylink OEM (MELK/ELK) |
| [LotusLamp X (MELK/ELK/ELBU)](lotuslamp-x.md) | BLE | Spec Available | None needed | Shenzhen ELK |
| [iDeal LED Pixel Strings](ideal-led.md) | BLE | Spec Available | None needed | Heaton OEM |
| [Hello Fairy String/Curtain Lights](hello-fairy.md) | BLE | Spec Available | None needed | Avatar Controls (Lenze/ESP32/Bluetrum) |
| [CHEMION LED Glasses & Hat](chemion-glasses.md) | BLE | Spec Available | None needed | CHEMION (Funiot) |
| [Aurora LED Shoes](aurora-led-shoes.md) | BLE | Spec Available | None needed | jtkj OEM |
| [EmazingLights Spectra Gloves](emazinglights-spectra.md) | BLE (hub → 2.4 GHz gloves) | Spec Available | Hub pairing mode (medium) | EmazingLights (app delisted) |
| [Ignis Pixel Flow Props](ignis-pixel.md) | BLE (+ nRF24 prop sync) | Spec Available | None needed | Ignis Pixel |
| [Astral Hoops Atomic V AF](astral-hoops.md) | BLE | Spec Available | None needed | Astral Hoops |
| [MoTool Slacker](motool-slacker.md) | BLE | In Progress | None needed | MoTool |
| [AdMore Light Bar Pro](admore-light-bar.md) | BLE | Complete | None needed | AdMore Lighting Inc. |
| [ProGlow Motorcycle LED](proglow-motorcycle-led.md) | BLE | Spec Available | None needed | ProGlow |
| [SeeBlue Motorcycle LED](seeblue-motorcycle-led.md) | BLE | Spec Available | None needed | SeeBlue |
| [SmartDawn Smart Lights](smartdawn-smart-lights.md) | BLE (Wi-Fi variants) | In Progress | None needed | Hangzhou Daniao / SmartDawn |
| [KingSmith WalkingPad](kingsmith-walkingpad.md) | BLE | Complete | None needed | KingSmith Fitness (Xiaomi ecosystem) |
| [UREVO Walking Pad](urevo-walking-pad.md) | BLE | In Progress | None needed | UREVO |
| [Kwikset Kevo](kwikset-kevo.md) | BLE (lock is central) | In Progress | BLE tap-to-enroll (medium) | Kwikset / ASSA ABLOY (UniKey) |
| [Schlage Smart Locks](schlage-smart-locks.md) | BLE (uWeave; WiFi is cloud-relay only) | Complete | BLE SPAKE2 pairing, printed programming code (medium) | Schlage / Allegion |
| [Inkbird IBS-TH1/TH2 Hygrometer](inkbird-ibs-th.md) | BLE | Complete | None needed | Inkbird |
| [ThermoPro TP357-family Hygrometers](thermopro-tp357.md) | BLE | Complete | None needed | ThermoPro (Adsmart) |
| [Omron BLE Blood Pressure Monitors](omron-connect.md) | BLE | Complete | BLE button pairing + client key (high) | Omron Healthcare |
| [Aranet4 CO2 Sensor](aranet4.md) | BLE | Complete | None needed (broadcast); bonding for history (high) | SAF Tehnika JSC |
| [Bluetti Power Station](bluetti-power-station.md) | BLE | Complete | None needed | Bluetti (Shenzhen Poweroak) |
| [Johnson JLX LDM330/LDM130 Laser Distance Meters](jlx-laser-distance-meter.md) | BLE | Spec Available | None needed (medium) | Johnson Level & Tool (Precaster Enterprises OEM) |
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
| [Denon AVR-S720W](denon-avr-s720w.md) | WiFi (HTTP `/goform/` + ASCII on 23 + UPnP) | Spec Available | On-receiver menu / Ethernet (medium) | Denon |
| [Philips Hue Bridge](hue-bridge.md) | WiFi | Complete | Wired + link button (high) | Signify / Philips Hue |
| [Enphase Envoy](enphase-envoy.md) | WiFi | Complete | Wired / SoftAP (low) | Enphase Energy |
| [Dyson Air Purifier](dyson-air-purifier.md) | WiFi | Complete | SoftAP, sticker creds (medium) | Dyson |
| [iRobot Roomba (Wi-Fi models)](irobot-roomba.md) | WiFi (MQTT over TLS 8883) | Complete | Button-press or account credential extraction (medium) | iRobot / Picea Robotics |
| [LIFX Z](lifx-z.md) | WiFi | Complete | SoftAP, uncaptured (low) | LIFX |
| [Lutron Caseta Smart Bridge 2](lutron-caseta-smart-bridge.md) | WiFi | In Progress | Wired + cert pairing (medium) | Lutron |
| [TP-Link Kasa Smart Plug](tplink-kasa.md) | WiFi (JSON over TCP 9999) | Complete | SoftAP, uncaptured (low) | TP-Link |
| [Rachio Controller](rachio-controller.md) | WiFi | Research | Uncaptured (low) | Rachio |
| [Snapmaker U1 3D Printer](snapmaker-u1.md) | WiFi | Complete | None needed (Moonraker) | Snapmaker |
| [PurpleAir Air Quality Sensor](purpleair-sensor.md) | WiFi | Complete | None needed | PurpleAir |
| [UniFi Protect Camera](unifi-protect-camera.md) | WiFi | Complete | Enable RTSP in Protect | Ubiquiti |
| [Ubiquiti UniFi Device](ubiquiti-unifi-device.md) | UDP 10001 | Complete (identify-only) | None needed | Ubiquiti |
| [MikroTik RouterOS Device](mikrotik-routeros.md) | MNDP | Complete (identify-only) | None needed | MikroTik |
| [Synology DiskStation NAS](synology-diskstation.md) | findhostd (UDP 9999) | Identify-only (untested) | None needed | Synology |
| [IPP Network Printer](ipp-network-printer.md) | mDNS / DNS-SD | Identify-only (untested) | None needed | Various (IPP/AirPrint) |
| [Android Wireless-ADB Device](android-adb-wireless.md) | mDNS / DNS-SD | Identify-only (untested) | None needed | Various (Android 11+) |
| [Chamberlain Garage Opener (Security+)](chamberlain-garage-opener-secplus.md) | UART | Complete (needs bridge) | ratgdo/Konnected bridge | Chamberlain |
| [ratgdo Garage-Door Controller](ratgdo.md) | WiFi (ESPHome) | Complete (untested) | Flash + wire to opener | ratgdo / Konnected |
| [ESPHome Node (generic)](esphome-device.md) | WiFi (ESPHome REST/SSE + native API) | Complete (untested) | Owner-flashed; captive portal / Improv (medium) | Various (ESPHome open firmware) |
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
| [Beurer PO60 Pulse Oximeter](beurer-po60-pulse-oximeter.md) | BLE | Spec Available | BLE passkey bonding (medium) | Beurer |
| [Beurer Series 800 (BM92) Blood Pressure Monitor](beurer-series800-blood-pressure.md) | BLE (standard BP profile) | Spec Available | BLE bonding (medium) | Beurer |
| [FOREO Peach 2 IPL](foreo-peach-2.md) | BLE | Spec Available | None — offline MAC-derived unlock (low) | FOREO |
| [Braun Silk-expert Pro 5 IPL](braun-silk-expert-pro5.md) | BLE | Spec Available | BLE bonding (medium) | Braun / P&G |
| [Silk'n Infinity / Silk'n 7 IPL](silkn-infinity.md) | BLE | Spec Available | None needed | Silk'n (Home Skinovations) |
| [Hyperice Hypervolt Plus](hyperice-hypervolt-plus.md) | BLE | Spec Available | None needed | Hyperice |
| [BIO-key TouchLock Fingerprint Locks](biokey-touchlock-fingerprint-lock.md) | BLE | Spec Available | BLE enrollment (medium) | BIO-key / Champion OEM |
| [Safetech Quicklock Padlock](safetech-smart-padlock.md) | BLE | Spec Available | Static password (low) | Safetech (defunct) / Itonsoft OEM |
| [TIRO LED Helmet Display](led-helmet-display.md) | BLE | Spec Available | None needed | TIRO / Heaton |
| [Yeelight Cube Lamp](yeelight-cube-lamp.md) | WiFi (LAN TCP 55443) + Matter | Spec Available | App / Matter commissioning (medium) | Yeelight (Yeelink) |
| [Tuya Wi-Fi Gas Sensor (rqbj family)](tuya-wifi-gas-sensor.md) | WiFi (Tuya LAN TCP 6668) | Spec Available | Tuya pairing + local-key extraction (medium) | Tuya OEM |
| [June Oven](june-oven.md) | WiFi (cloud-only, no local surface) | Research | Cloud account — shutdown 2026-09-22 (low) | June Life / Weber |
| [Brava Oven](brava-oven.md) | WiFi (cloud-only, no local surface) | Research | Cloud account — vendor defunct, cloud zombie (low) | Brava / Middleby |
| [iPixel Color LED Panels](ipixel-color-led-panel.md) | BLE | Spec Available | None needed | TIRO / Heaton (JTPD-03-011, HCZ-001/002 SKUs) |
| [Triones / HappyLighting LED Strips](qh-happylighting-led-strips.md) | BLE | Spec Available | None needed | Qianghe (QHM) |
| [Tuya Bluetooth Soil Tester](tuya-bt-soil-tester.md) | BLE (encrypted GATT) | Spec Available | Tuya pairing + local key (medium) | Tuya OEM (HaiHao SGS01) |
| [Zigbee Soil Tester (TS0601 family)](zigbee-soil-tester.md) | Zigbee | Spec Available | Any Zigbee coordinator — Z2M native (low) | Tuya OEM (GIEX/HOBEIAN/COOLO) |
| [Vevor VT256 Thermal Imager](vevor-vt256-thermal-imager.md) | WiFi (device AP; RTSP + TCP 8080) | Spec Available | Join device AP (low) | Vevor / Hti-Xintai HT-W01 |
| [Flowtoys Props (Connect bridge)](flowtoys-props.md) | BLE + WiFi-OSC bridge → nRF24 RF | Spec Available | None needed (bridge) | Flowtoys (open-source bridge firmware) |
| [Enphase IQ Battery / Enpower BLE](enphase-iqbattery-ble.md) | BLE (Digi XBee 3 service) | Spec Available | SRP-6a unlock (medium) | Enphase Energy |
| [LimitlessLED / Mi-Light WiFi Bridge](limitlessled-milight-bridge.md) | WiFi (UDP 8899 / 48899) | Spec Available | None needed | LimitlessLED / Mi-Light (High-Flying module) |
| [Brother QL-1110NWB Label Printer](brother-ql-1110nwb.md) | WiFi (TCP 9100) + BT Classic SPP | Spec Available | On-device pairing (low) | Brother |
| [MXW01 Cat Printer](cat-printer-mxw01.md) | BLE | Spec Available | None needed | Generic (MXW01 family) |
| [Xiaomi Mi Scale S400](xiaomi-mi-scale-s400.md) | BLE (MiBeacon, encrypted) | Spec Available | Cloud bindkey extraction (medium) | Xiaomi / Yunmai |
| [Veryfit 2.0 Fitness Bands](veryfit-2-fitness-band.md) | BLE | Spec Available | None needed | ID107 / Veryfit OEM |
| [Govee H6001 Smart Bulb](govee-h6001-bulb.md) | BLE | Spec Available | None needed | Govee (Shenzhen Intellirocks) |
| [Govee H5080 Smart Plug](govee-h5080-plug.md) | BLE (+ Wi-Fi variants) | Spec Available | None needed (button-gated BLE auth key) | Govee (Shenzhen Intellirocks) |
| [Govee H5075 Thermometer/Hygrometer](govee-h5075-thermo.md) | BLE | Complete | None needed | Govee (Shenzhen Intellirocks) |
| [Govee H6101/H6104 TV Backlight](govee-h6101-backlight.md) | BLE | Spec Available | None needed | Govee (Shenzhen Intellirocks) |
| [Govee RGB Lights (classic)](govee-rgb-light.md) | BLE (+ Wi-Fi variants) | Spec Available | None needed | Govee (Shenzhen Intellirocks) |
| [Govee RGBIC / DreamColor Lights](govee-rgbic-light.md) | BLE (+ Wi-Fi variants) | Spec Available | None needed | Govee (Shenzhen Intellirocks) |
| [Logitech Squeezebox (SlimProto)](squeezebox-slimproto.md) | WiFi (TCP 3483/9000) | Spec Available | On-device, server-based | Slim Devices / Logitech |
| [Bose SoundTouch Speakers](bose-soundtouch.md) | WiFi (HTTP 8090) | Spec Available | App/wired (local since 2026) | Bose |
| [Logitech Harmony Hub](logitech-harmony-hub.md) | WiFi (WS 8088) | Spec Available | App config, then local (medium) | Logitech |
| [Google Chromecast (CASTv2)](chromecast-castv2.md) | WiFi (TLS 8009) | Spec Available | Google Home app (low) | Google |
| [Magic Home / Zengge LED](magic-home-zengge-wifi.md) | WiFi (TCP 5577) | Spec Available | SoftAP + UDP 48899 (low) | Zengge |
| [WiZ Wi-Fi Lights](wiz-wifi-light.md) | WiFi (UDP 38899) | Spec Available | App onboarding (low) | WiZ (Signify) |
| [Twinkly Smart Lights](twinkly-lights.md) | WiFi (HTTP 80 + UDP 7777) | Spec Available | SoftAP / app (low) | Ledworks (Twinkly) |
| [OSRAM Lightify Gateway](osram-lightify-gateway.md) | WiFi (TCP 4000) | Spec Available | Cloud gone; local only (low) | OSRAM / LEDVANCE |
| [Yeelight Wi-Fi Lights (LAN)](yeelight-wifi.md) | WiFi (TCP 55443) | Spec Available | App + LAN Control toggle (low) | Yeelight (Yeelink) |
| [Gree Air Conditioner (LAN)](gree-ac-lan.md) | WiFi (UDP 7000) | Spec Available | SoftAP + bind (low) | Gree |
| [Midea Air Conditioner (LAN)](midea-ac-lan.md) | WiFi (TCP 6444) | Spec Available | Token from cloud once (low) | Midea |
| [Radio Thermostat CT30/50/80](radiothermostat-ct50.md) | WiFi (HTTP 80) | Spec Available | SoftAP; disable dead cloud (low) | Radio Thermostat (RTCOA) |
| [Smarter iKettle / Coffee](smarter-ikettle.md) | WiFi (port 2081) | Spec Available | SoftAP (low) | Smarter |
| [WeatherFlow Tempest](weatherflow-tempest-udp.md) | WiFi (UDP 50222) | Spec Available | App onboarding (low) | WeatherFlow-Tempest |
| [Fronius Solar Inverter](fronius-solar-api.md) | WiFi (HTTP REST) | Spec Available | Device web UI (low) | Fronius |
| [OpenEVSE Charging Station](openevse.md) | WiFi (HTTP/MQTT) | Spec Available | SoftAP (low) | OpenEVSE |
| [Xiaomi miIO Protocol](xiaomi-miio.md) | WiFi (UDP 54321) | Spec Available | Mi Home + token (low) | Xiaomi ecosystem |
| [Aqara Hub family (M1S Gen 2 / M2 / P3)](aqara-hub.md) | WiFi (mDNS + UDP 10008 onboarding) | Spec Available | Cloud account binding (hard); steady-state control cloud-relayed | Lumi United (Aqara) |
| [Roborock Robot Vacuum (local)](roborock-local.md) | WiFi (TCP 58867) | Spec Available | Cloud login for local key (low) | Roborock |
| [Valetudo (rooted vacuum)](valetudo.md) | WiFi (HTTP /api/v2) | Spec Available | Requires rooting (low) | Hypfer + community |
| [Parrot Drones (AR.Drone / ARSDK)](parrot-arsdk-drone.md) | WiFi (UDP) | Spec Available | Join drone AP | Parrot |
| [eQ-3 Eqiva Radiator Thermostat](eqiva-eq3-ble-trv.md) | BLE | Spec Available | None (BLE pair on FW 1.20+) | eQ-3 (Eqiva) |
| [Concept2 PM5](concept2-pm5.md) | BLE | Spec Available | None needed | Concept2 |
| [Xiaomi Mi Band / Amazfit](xiaomi-huami-miband.md) | BLE | Spec Available | Auth-key extraction on newer bands (medium) | Xiaomi / Huami (Zepp) |
| [Pebble Smartwatch](pebble-smartwatch.md) | BLE | Spec Available | Bluetooth pairing | Pebble (Rebble / Core revival) |
| [openScale BLE Body Scales](openscale-body-scales.md) | BLE | Spec Available | None needed | Beurer / Medisana / Trisa |
| [Victron Instant Readout (BLE)](victron-instant-readout-ble.md) | BLE (broadcast) | Spec Available | Key from VictronConnect (high) | Victron Energy |
| [JBD / Xiaoxiang Smart BMS](jbd-xiaoxiang-bms-ble.md) | BLE | Spec Available | None needed | Shenzhen Jiabaida (JBD) |
| [Renogy BT-1 / BT-2 Solar Controllers](renogy-bt-ble.md) | BLE | Spec Available | None needed | Renogy |
| [Anki Overdrive / Drive Cars](anki-overdrive-ble.md) | BLE | Spec Available | None needed | Anki (defunct) |
| [TTLock / Sciener BLE Locks](ttlock-sciener-ble.md) | BLE | Spec Available | App pairing → per-lock key (medium) | Sciener (many OEM rebrands) |
| [SESAME (CANDY HOUSE) Locks](sesame-candyhouse-ble.md) | BLE | Spec Available | ECDH registration (high) | CANDY HOUSE |
| [Yale Access / August Locks](yale-august-ble.md) | BLE | Spec Available | Offline key from cloud account (medium) | August / Yale (ASSA ABLOY) |
| [Xiaomi M365 E-Scooter](xiaomi-m365-ble.md) | BLE | Spec Available | None needed (unauthenticated) | Xiaomi / Ninebot |
| [Ninebot / Segway E-Scooter](ninebot-segway-ble.md) | BLE | Spec Available | None needed (older FW) | Ninebot-Segway |
| [Electric Unicycles (WheelLog)](euc-wheellog-ble.md) | BLE | Spec Available | None needed | King Song / Gotway / Veteran |
| [Onewheel](onewheel-ble.md) | BLE | Spec Available | Firmware unlock handshake (≥4034) | Future Motion |
| [VESC Motor Controller](vesc-ble-uart.md) | BLE + UART | Spec Available | None needed | VESC project (open) |
| [RuuviTag Sensor](ruuvitag-ble.md) | BLE (broadcast) | Spec Available | None needed | Ruuvi Innovations |
| [b-parasite Soil Sensor](b-parasite-ble.md) | BLE (BTHome v2) | Spec Available | None needed | rbaron (open) |
| [Mopeka Pro Check Tank Sensor](mopeka-pro-check-ble.md) | BLE (broadcast) | Spec Available | Sync-button pairing | Mopeka Products |
| [Reolink IP Camera](reolink-camera.md) | WiFi (RTSP/CGI + Baichuan 9000) | Spec Available | Enable RTSP/ONVIF (low) | Reolink |
| [Amcrest / Dahua IP Camera](amcrest-dahua-camera.md) | WiFi (RTSP + CGI) | Spec Available | Set admin password (low) | Dahua / Amcrest |
| [Hikvision IP Camera (ISAPI)](hikvision-isapi-camera.md) | WiFi (RTSP + ISAPI) | Spec Available | Activate + password (low) | Hangzhou Hikvision |
| [Wyze Cam (docker-wyze-bridge)](wyze-bridge-camera.md) | WiFi (RTSP via bridge) | Spec Available | Wyze API key, then local (low) | Wyze Labs |
| [Bambu Lab 3D Printer (LAN)](bambu-lab-lan.md) | WiFi (MQTT 8883 + FTPS + RTSPS) | Spec Available | Enable LAN mode + access code (low) | Bambu Lab |
| [PrusaLink (MK4 / XL / Mini)](prusalink-local-api.md) | WiFi (HTTP /api/v1) | Spec Available | Enable PrusaLink; API key (low) | Prusa Research |

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
