# Wink Hub (v1) / Wink Hub 2 — Research Notes

## What it is
Multi-radio hubs (Zigbee, Z-Wave, Lutron Clear Connect, Kidde RF, BLE) from
Wink Labs → i.am+. Infamous for the 2020-05 ransom move: pay $4.99/mo or the
hub is crippled ([Consumer Reports 2020-07-14](https://www.consumerreports.org/smart-home/wink-tells-users-pay-up-or-we-will-disable-smart-home-hub/));
long outages in 2022 ([Stacey on IoT 2022-07-13](https://staceyoniot.com/wink-hub-got-you-down-here-are-some-smart-home-switching-options/)).

## Cloud status (reported 2026-08-07)
wink.com was reported live and selling subscriptions on 2026-08-07. That dated
service observation is not evidence of offline control and was not retested for
this correction.

## Local path A — stock LAN API (reported, cloud-gated)
The hubs have a local HTTPS REST/SSE API that the phone app uses on the LAN.
python-wink uses **port 8888**; the archived app takes the base URL from SSDP.
Home Assistant's `wink` component exposed this as `local_control: true`.
- **Cloud gates**: a new `local_control` bearer token is minted by Wink's
  cloud. The app also requires its cached cloud hub list and device catalog;
  pairing and radio administration remain cloud operations
  ([HA forum 2019-04](https://community.home-assistant.io/t/wink-component-local-control/112822)).
- An already-cached token can be reused without an immediate cloud round trip,
  but whether it continues working with WAN blocked, and for how long, is
  untested.
- Verdict: cloud-gated LAN transport, not a durable local-only replacement.

## Local path B — archival rooted Hub 1 integration (reported, untested here)
- Root reports are specific to **Hub 1 and its firmware**. The
  [2014 XDA web/SQL procedure](https://xdaforums.com/t/wink-hub-root.2969205/)
  is archival evidence for firmware **0.33 or earlier**, not a procedure for
  later units. Historical NAND-shorting/UART descriptions, including the
  [HA forum "Rooted Wink Local Control" 2016](https://community.home-assistant.io/t/rooted-wink-local-control/4733)
  and [HomeSeer forum Wink-v1 hack 2021](https://forums.homeseer.com/forum/hs4-products/hs4-plugins/lighting-primary-technology-plug-ins-aa/mcsmqtt-michael-mcsharry-aa/1455752-hacking-the-wink-hub-v1-to-work-with-homeseer-via-mscmqtt),
  are retained as archival pointers, **not as a current owner rooting recipe**.
  No later-firmware root/rollback procedure is verified here.
- On an **already-rooted Hub 1 running firmware 2.49 or 2.66**, the archived
  [`wink-mqtt` project](https://github.com/danielolson13/wink-mqtt/tree/e83d3f9a6faa93e1fc1e0813a857eb41fc8f2ee5)
  reportedly uses the stock `aprontest` tool to expose **already-paired**
  devices through local MQTT. It is not a root method. This limited integration
  does not replace Wink's cloud catalog, pairing, enrollment, radio
  administration or firmware-update services.
- **Hub 2**: no durable root or local-server route is established by this
  evidence. Do not generalize the Hub 1 reports to Hub 2.

## What remains cloud-dependent
Path A needs cloud-issued authorization and cached cloud objects; a stock hub
has no demonstrated fully offline new-owner provisioning route. Path B can
preserve local MQTT access to already-paired devices only after its narrow Hub
1 prerequisites are met. Neither path supplies a general replacement for cloud
catalog, pairing or enrollment. Migrating accessories to a maintained local
controller remains the safer durable option for many owners.

## APK
The original survey did not fetch one. This correction also draws on external
static analysis of an archived app and community source review; no hub was
rooted, reset, paired or controlled, and no live capture was made.

## Rating
**Reported and untested on hardware.** Path A is a cloud-gated LAN API. Path B
is a limited archival Hub 1 integration, not a universal or durable Wink
replacement; Hub 2 remains unresolved.
