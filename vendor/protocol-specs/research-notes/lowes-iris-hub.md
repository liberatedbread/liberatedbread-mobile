# Lowe's Iris Hub (v1 AlertMe / v2) — Research Notes (REJECTED)

## What it was
Lowe's retail smart-home platform: v1 hub (AlertMe-derived), v2 hub (2015+),
large Zigbee/Z-Wave device line.

## Timeline (verified)
- Lowe's announced the shutdown 2019-01-31 after failing to find a buyer;
  servers and accounts closed **2019-03-31**, rendering hubs and app dead
  ([CNET 2019-01-31](https://www.cnet.com/home/smart-home/lowes-pulls-the-plug-on-the-iris-smart-home-platform/),
  [CEPro 2019-02-06](https://www.cepro.com/news/lowes_iris_smart_home_platform_shut_down/7622/)).

## Verdict: dud
- All control flowed through the Iris cloud; neither hub generation shipped
  a documented local API, and no community root/local-control project of
  substance emerged before or after the shutdown (users migrated to
  Hubitat/SmartThings instead — see
  [Hubitat migration thread 2019-02](https://community.hubitat.com/t/lowes-iris-transition/9872)).
- Cloud-dead + no local path = e-waste hub.

## Residual value (worth one line in any spec)
Most **v2 Zigbee and Z-Wave devices** (contact/motion sensors, smart plugs,
keypads) pair fine to other ecosystems — that is where the Iris rescue value
actually lives. V1 (AlertMe) devices use quirky Zigbee profiles and are
mostly not reusable.
