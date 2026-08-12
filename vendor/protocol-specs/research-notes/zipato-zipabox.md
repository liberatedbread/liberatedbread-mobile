# Zipato Zipabox / ZipaMicro / ZipaTile — Research Notes (REJECTED)

## What it is
Croatian (Tri Plus Grupa) Z-Wave/Zigbee multi-radio hubs, cloud-first
"Rule Creator" platform.

## Verdict: dud for local-only control on current firmware
- A local HTTP API **existed** pre-2019 but was broken by design:
  pass-the-hash auth flaw and a shared embedded root SSH key across all units
  ([BlackMarble "Breaking & Entering with Zipato SmartHubs" 2019-07-02](https://blackmarble.sh/zipato-smart-hub/)).
- Zipato's fix (firmware **1.3.60**, 2019-03) **disabled the local API**,
  disabled the serial console, per-device SSH keys, firewalled the web/API
  surface ([latesthackingnews 2019-07-05](https://latesthackingnews.com/2019/07/05/hackers-can-exploit-zipato-smart-home-hub-flaws-to-break-in/)).
- Result: patched hubs are cloud-only; the pre-patch local API requires
  running 7-year-old vulnerable firmware — not a recommendation this repo
  should make.

## Company status (checked 2026-08-07)
zipato.com is up and the cloud apparently still runs, but the site blog is
stale since 2022-04 and community support threads complain of missing
communication — zombie vendor.

## Rejected because
Only local path is (a) vulnerable pre-1.3.60 firmware, or (b) exploiting the
vendor-locked SSH surface — neither is a clean, documentable local API.
If Zipato's cloud dies, these hubs have no supported fallback.
