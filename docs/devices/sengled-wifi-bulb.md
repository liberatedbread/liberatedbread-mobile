# Sengled Wi-Fi Smart Bulbs

> **Status**: Spec Available (unverified)
> **Protocol**: WiFi (UDP 9080 JSON; MQTT over TLS once re-pointed at your own broker)
> **Manufacturer**: Sengled
> **Manufacturer Status**: Unsupported — cloud failing since June 2025, Alexa skill removed by Amazon on 1 August 2025

## Overview

Sengled's Wi-Fi bulbs (the "Smart Wi-Fi LED" A19/BR30 family: W11-N13,
W21-N13, W31-N15, W31-N11, W12-N15, W21-U23 and kin) join the home 2.4 GHz
network directly and were driven through Sengled's cloud. That cloud went down
for most of a week from about 18 June 2025, kept dropping through July, and on
1 August 2025 Amazon pulled the Sengled Alexa skill for "prolonged outages"
Sengled had not fixed. Trade press reported unpaid staff and an unresponsive
company. The bulbs still work at the wall switch, and two local paths survive:

- **UDP JSON on port 9080.** Every bulb on Wi-Fi answers
  `{"func": "...", "param": {...}}` datagrams with no authentication — on/off,
  brightness, RGB, colour temperature, a state read that doubles as the
  discovery broadcast. A bulb paired with the app years ago still answers.
- **Your own MQTT broker.** During Wi-Fi provisioning the bulb is handed two
  HTTP base URLs it treats as "the cloud"; it asks one of them where its MQTT
  broker is. Give it URLs on your LAN, answer two small JSON requests, run a
  TLS MQTT broker, and the bulb publishes to `wifielement/<MAC>/status` and
  takes commands on `wifielement/<MAC>/update` exactly as it did for Sengled.

**Not covered:** Sengled's Zigbee bulbs (Element, Z01-*/E11-*/E12-*) and
Bluetooth-mesh bulbs (B11-*) are different radios and protocols. OTA flashing
to Tasmota/ESPHome/WLED is possible on the ESP8266 models (W31-N15, W31-N11,
W21-U23) via the same firmware-URL command and is noted, not specified.

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | Yes (a bulb already on Wi-Fi needs nothing for UDP control) |
| Method | `softap_udp` — the bulb's setup AP, UDP 9080 at the bulb's fixed AP address |
| Setup AP | `Sengled_Wi-Fi Bulb_XXXXXX`, open |
| Passphrase protection | `device_encrypted` — RC4 under a fixed, public key, then base64; treat as plaintext |
| Confidence | medium (two open-source implementations have run it; this project has not) |

The route: stand up a stand-in cloud on the LAN — an HTTP server answering
`POST /life2/device/accessCloud.json` and `GET /jbalancer/new/bimqtt`
(`{"protocal":"mqtt","host":"<broker>","port":8883}`), and a TLS 1.2 MQTT
broker that allows anonymous clients and offers ALPN `x-amzn-mqtt-ca`. Reset
the bulb, join its AP, then over UDP 9080: `startConfigRequest` (returns the
MAC), optionally `scanWifiRequest`/`getAPListRequest`, `startConfigRequest`
again (`payload.result` true), one RC4+base64 `setParamsRequest` carrying the
SSID, passphrase and the two base URLs, then `endConfigRequest`. The bulb joins,
hits both HTTP endpoints within about 180 s, connects to the broker as
`<MAC>@wifielement` and starts publishing. The Sengled Home app route still
exists but depends on Sengled's cloud.

**Factory reset**: from on, switch the bulb off and on five times quickly; it
flashes three times, blinks twice, and the setup AP appears (support.com's
guide and the SengledTools README; one retailer guide says ten cycles — not
replayed here). `factory_reset` over UDP and `reset` over MQTT do the same on a
reachable bulb.

**Rebinding to a new network**: no in-place rewrite; reset and provision again.
A new broker address under the same CA needs only a reissued server certificate
— the bulb re-reads `/bimqtt` on every boot.

## Protocol Summary

### UDP 9080

Request `{"func": "<name>", "param": {...}}`; reply `{"func": "<name>",
"result": {"ret": 0, "msg": "...", ...}}` (`ret` 1 = error). 3 s timeout, no
retries, no checksum.

| func | param | Notes |
|------|-------|-------|
| `set_device_switch` | `switch` 0/1 | power |
| `set_device_brightness` / `get_device_brightness` | `brightness` 0–100 | percent |
| `set_device_color` | `red`,`green`,`blue` 0–255 | RGB engine; colour bulbs |
| `set_device_colortemp` | `colorTemperature` 1–100 | warm→cool; Kelvin ends unmeasured (2000–6500 or 2700–6500) |
| `set_device_pwm` | `r`,`g`,`b`,`w` 0–100 | volatile channel drive |
| `search_devices` | — | mac, ip, version, `MN`, `R/G/B/W {freq,value}`; broadcast it to discover |
| `get_software_version`, `get_device_mac`, `reboot` | — | |
| `factory_reset`, `set_factory_mode`, `update_led_firmware {ota_url}` | — | advanced |

Power is on when any channel reports `freq` 0; `W.value` > 0 means the white
engine is active; a white-only bulb's reply has no `R`/`G`/`B` keys.

### MQTT (after re-pointing)

Payloads are JSON **arrays** of `{"dn": "<MAC>", "type": "...", "value":
"<string>", "time": <epoch ms>}`. Publish to `wifielement/<MAC>/update`:
`switch` "0"/"1", `brightness` "0"–"100", `color` "R:G:B", `colorTemperature`
"0"–"100" (sent with `switch` "1"), `reset`, `update <url>`. Subscribe to
`wifielement/<MAC>/status` (full set on connect, then deltas: switch,
brightness, color, colorTemperature, colorMode, typeCode, identifyNO,
supportAttributes, version, ip, deviceRssi…), `/consumption`,
`/consumptionTime`, and `wifielement/c/status` for the connect announcement.

### Provisioning cipher

RC4 keyed with the 52 ASCII bytes of
`MTlCaWppbmdTaGFuZ2hhaVdpU2VuZ2xlZEZpMjBBQUJBU0U2NA==` (not base64-decoded),
no IV, over the compact JSON of the whole `setParamsRequest`; the base64 of the
ciphertext is the datagram. `scripts/test_sengled_wifi_bulb_spec.py` holds
the spec's vectors.

See `device-specs/devices/sengled-wifi-bulb.yaml` for the full spec.

## References

- [HamzaETTH/SengledTools](https://github.com/HamzaETTH/SengledTools) — the reverse engineering (no licence file; facts only)
- [FalconFour/HA-Sengled-Local-Server-AddOn](https://github.com/FalconFour/HA-Sengled-Local-Server-AddOn) — MIT server-side reimplementation
- [PCWorld, 2025-07-31: Amazon yanks Sengled's Alexa skill](https://www.pcworld.com/article/2864586/amazon-yanks-sengleds-alexa-skill-after-a-series-of-service-outages.html)
- [Inside Lighting, 2025-06-23: cloud failure leaves users in the dark](https://inside.lighting/news/25-06/smart-lighting-cloud-failure-leaves-users-dark)
- [support.com: How to reset the Sengled Smart Wi-Fi LED bulb](https://www.techsolutions.support.com/how-to/how-to-reset-the-sengled-smart-wi-fi-led-bulb-15391)
- [Sengled W11-N11 user manual (ManualsLib)](https://www.manualslib.com/manual/3741920/Sengled-W11-N11.html)
