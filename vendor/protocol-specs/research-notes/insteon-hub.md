# Insteon Hub (2242-222 v1 / 2245-222 v2) — Research Notes

## What it is
Gateway between IP and Insteon's dual-band (powerline + 915 MHz RF) mesh.
The hub embeds a PLM (power-line modem); the local APIs below are how
third parties drive the entire Insteon device estate without any cloud.

## Company timeline (verified)
- SmartLabs/Insteon shut down without warning **2022-04** — servers off
  ([PCMag 2022-04-22](https://www.pcmag.com/news/smart-home-company-insteon-shuts-down-servers-without-warning),
  [SiliconANGLE 2022-04-18](https://siliconangle.com/2022/04/18/home-automation-company-insteon-reportedly-goes-business/)).
- Assets bought mid-2022 by Insteon Technologies (customer-group led);
  insteon.com is **live and selling today (fetched 2026-08-07)**.
- Lesson this repo cares about: every local path below worked *throughout*
  the 2022 outage — hubs never depended on the cloud for LAN control.

## Local API — Hub v2 (2245-222), confirmed
- HTTP on **port 25105**, HTTP Basic auth with the **username/password
  printed on the hub's own label** — a local credential, no account needed.
- Send raw PLM commands: `GET /3?<hex>` (e.g. `0262<addr><flags><cmd1><cmd2>`
  for standard Insteon messages).
- Read responses: `GET /buffstatus.xml` (clear buffer with the trailing
  documented sequence).
- Info/status pages: `/index.htm`, `/sx.xml`, `/networkstatus.xml`.
- Implementations: Home Assistant `insteon` integration (iot_class
  local_push), `python-insteon`/`insteon-mqtt`; SmartThings community
  "Insteon Local Control" device handlers used 25105 since 2014.
- HA conversion threads after the 2022 death confirm local onboarding:
  [community.home-assistant.io 2022-04](https://community.home-assistant.io/t/insteon-hub-conversion-to-home-assistant/412598).

## Local API — Hub v1 (2242-222), confirmed
- Raw PLM serial-over-TCP on **port 9761** (same byte stream as the USB/serial
  PLM 2413U/2412S). Talked to directly by openHAB/Home Assistant.

## Cloud dependency
None for control. The retired Insteon app used cloud for setup/remote, but
25105/9761 are reachable with WAN down. Devices pair to the PLM by standard
Insteon linking (set-button or PLM link commands), no servers involved.

## APK
Not needed (label credentials + documented PLM command set). Not fetched.

## Rating
**Confirmed** — shipping integrations against both hub generations.
