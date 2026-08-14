# PicoBrew Pico / Zymatic — Research Notes

## What it is
PicoBrew (Seattle) automated home beer-brewing appliances: Zymatic (2013),
Pico S/C/Pro (2016+), plus Pico U, PicoFerm (fermentation monitor) and
PicoStill. The machines brew "PicoPak" ingredient cartridges; brew sessions and
recipes were managed through the vendor web service.

## Why it's abandoned (dated sources)
- Forbes via Brauwelt (2020-06-10): PicoBrew filed for bankruptcy in Washington
  state in February 2020, court-managed receivership.
  (https://brauwelt.com/en/international-report/the-americas/641655-the-end-of-picobrew)
- The Spoon (2020-04-30): "PicoBrew … is effectively shutting down."
  (https://thespoon.tech/rest-in-peace-picobrew/)
- Trevor Mack (2022-09-23): the reluctant new owner put the shuttered startup's
  assets up for sale. (https://trevor-mack.com/2022-bru-year-in-review/)
- As of 2026-08-03, `https://picobrew.com/` does not answer (connection fails).

## Local feasibility — already solved by the community
**This is not BLE.** Machines join Wi-Fi and talk plain HTTP(S) to vendor API
endpoints. The community replacement server
[chiefwigms/picobrew_pico](https://github.com/chiefwigms/picobrew_pico)
(active since 2020-05, 250+ stars) impersonates the PicoBrew API on a LAN host:
- full brew-session control for Pico S/C/Pro and Zymatic (start/monitor/stop,
  temperature steps),
- local PicoPak/recipe creation (community "PakHacking" guides),
- PicoFerm and PicoStill support,
- typically deployed via DNS override of `picobrew.com` on the LAN.

So "local control" here = local server emulation, not protocol RE; the on-wire
API is documented in that repo. A repo spec would document the machine↔server
HTTP API (session upload/download, firmware endpoints) so any LAN server can
drive the machines.

## APK
No companion APK needed — the vendor interface was a web app; picobrew_pico
serves its own web UI. N/A for apkeep.

## What needs cloud
Nothing after picobrew_pico: DNS redirect + local server covers brewing,
recipes, and firmware endpoints the community has replicated. First-time Wi-Fi
provisioning of the machine is local (machine AP or on-device controls).

## Open questions
1. Exact request/response schemas for each model (document in spec from
   picobrew_pico source; Pico vs Zymatic differ).
2. TLS: do later firmwares pin certificates? (Affects how DNS redirect works;
   community notes suggest plain HTTP on most units.)
3. Pico U / PicoFerm endpoint coverage gaps.

## Safety
Boiling wort + pumps: keep the documented session-abort endpoint prominent in
any client.
