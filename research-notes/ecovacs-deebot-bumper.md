# Ecovacs Deebot (XMPP-era models) + Bumper — Research Notes

## What it is
Ecovacs Deebot vacuums from roughly 2015–2020 (M81/M88 Pro, Deebot 900/901,
N79 series, OZMO 610/900/920/930/950, Slim series) talk to the vendor cloud
over XMPP (plus an HTTPS device API). The community project
**bmartin5692/bumper** reimplements that central server on a LAN host, the
same rescue pattern as picobrew_pico: DNS-redirect the `*.ecouser.net`
domains to a local machine and the robots (and third-party clients) work
with zero Ecovacs infrastructure. Ecovacs the company is alive — the value
here is de-clouding, not abandonment.

## Local path (community-confirmed)
- Bumper serves: HTTPS device/login API (port 443, self-signed) + XMPP
  server (5223 legacy SSL / 5222) that robots connect to.
- DNS override needed: `msg-na.ecouser.net`, `msg-ww.ecouser.net` etc. →
  Bumper host (per-country domains; docs list them).
- Third-party clients driving the robot through Bumper: python `sucks`
  library (verified combo in docs), `bittles/ha_ecovacs_bumper` (2026,
  replaces HA's ecovacs component against a self-hosted Bumper),
  ioBroker.ecovacs-deebot (mrbungle64/mcm1957).
- The **official app** can also be pointed at Bumper but still authenticates
  against Ecovacs central at every start (Bumper docs) — so official-app
  use is NOT fully local; third-party clients are.

## What needs cloud
- Robot provisioning (Wi-Fi setup) uses the official app + account once.
- With third-party clients (sucks/ha_ecovacs_bumper): nothing afterwards.
- Caveat: robots must accept Bumper's self-signed cert — XMPP-era firmware
  does; some later firmwares pin certs.

## Newer models — limited/dud
OZMO T8/T9/T10/T20, X1/X2 and yeedi use an MQTT-based protocol (8883) with
different auth; Bumper does not cover them and ioBroker/HA integrations for
those models are cloud-connected. Valetudo does not support Ecovacs. No
local path is known for the MQTT generation.

## APK
- `com.ecovacs.ecohealth` (Ecovacs Home) — not fetched; protocol work is
  client-side (Bumper + sucks). Fetchability unverified.

## Open questions
1. Exact model/firmware cutoff where cert pinning breaks Bumper onboarding.
2. MQTT-generation local RE — greenfield opportunity, no public work found.
