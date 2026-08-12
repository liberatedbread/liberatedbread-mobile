# Wink Hub (v1) / Wink Hub 2 — Research Notes

## What it is
Multi-radio hubs (Zigbee, Z-Wave, Lutron Clear Connect, Kidde RF, BLE) from
Wink Labs → i.am+. Infamous for the 2020-05 ransom move: pay $4.99/mo or the
hub is crippled ([Consumer Reports 2020-07-14](https://www.consumerreports.org/smart-home/wink-tells-users-pay-up-or-we-will-disable-smart-home-hub/));
long outages in 2022 ([Stacey on IoT 2022-07-13](https://staceyoniot.com/wink-hub-got-you-down-here-are-some-smart-home-switching-options/)).

## Cloud status (checked 2026-08-07)
**Still operating**: wink.com is live and actively selling subscriptions
(fetched today). So the cloud token path below still works — for now.

## Local path A — stock local API, port 8888 (confirmed, cloud-coupled)
The hub serves a local HTTP API on **port 8888** that the phone app uses on
the LAN. Home Assistant's `wink` component exposed it as
`local_control: true`; python-wink implements it.
- **Catch**: requests need an OAuth bearer token minted by Wink's cloud, and
  device list comes from the cloud at startup
  ([HA forum 2019-04](https://community.home-assistant.io/t/wink-component-local-control/112822)).
- Verdict: local transport, cloud authorization. Works today; dies with Wink.

## Local path B — rooted hub, aprontest (confirmed, cloud-free)
- **Hub v1**: rootable via documented hardware method — open case, UART
  console, short NAND data pins at boot to drop to a shell (widespread guides
  since 2015; e.g. [HA forum "Rooted Wink Local Control" 2016](https://community.home-assistant.io/t/rooted-wink-local-control/4733),
  [HomeSeer forum Wink-v1 hack 2021](https://forums.homeseer.com/forum/hs4-products/hs4-plugins/lighting-primary-technology-plug-ins-aa/mcsmqtt-michael-mcsharry-aa/1455752-hacking-the-wink-hub-v1-to-work-with-homeseer-via-mscmqtt)).
- Rooted hub gives SSH + **`aprontest`** binary: direct local CLI to pair and
  control Zigbee/Z-Wave/Lutron/Kidde devices (`aprontest -l`,
  `-e <id> -t <attr> -v <val>`). Community MQTT bridges wrap aprontest for
  Home Assistant/HomeSeer. No Wink account needed after rooting; block WAN.
- **Hub v2**: no soft root; hardware voltage-glitch attacks demonstrated
  (NAND glitch research). Practical rescue today = v1.

## One-time cloud steps
Path A: ongoing cloud dependency (token). Path B: none after root; the
device-database on the hub covers pairing.

## APK
Not fetched — both paths already documented by community implementations.

## Rating
**Confirmed** both paths; B is the durable one.
