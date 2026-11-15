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

## Local feasibility — community replacement servers (reported, untested on appliances)
**This is not BLE.** Machines join Wi-Fi and talk HTTP(S) to vendor API
endpoints. The community replacement server
[chiefwigms/picobrew_pico](https://github.com/chiefwigms/picobrew_pico/tree/36acae3003845b72568ef5f7d6cf168acb6f9b69)
and the independent
[hotzenklotz/picobrew-server](https://github.com/hotzenklotz/picobrew-server/tree/3accef8edcc0a8de284fefaee2a8a8885eddb47f)
reimplement model-specific APIs on a LAN host. Reported coverage includes:
- local recipe creation/serving, session and temperature logs, and firmware-file
  responses for supported models — not verified full brew-session hardware
  control;
- PicoFerm and PicoStill support, with model-specific limitations;
- deployment through a trusted-LAN DNS override of `picobrew.com`.

A 2026-11 source review found no verified general start/stop/abort operation.
For Pico S/C/Pro, the current `picoChangeState` handler only returns a blank
CRLF response and performs no action. For Zymatic, ending a session closes a
server log; for ZSeries, closing `ZSession` finalizes that log. Neither is an
emergency stop or proof that heater/pump activity ceased.

The recorded upstream test runs (17 maintained-server and 115 independent
Zymatic-server host tests) exercise parsers, routes and firmware-file responses.
They are not appliance tests and do not verify heating, pumping, distillation,
fault handling or update compatibility. Any future specification must preserve
the model-specific request/response formats without presenting session logging
as hardware actuation.

## APK
No companion APK needed — the vendor interface was a web app; picobrew_pico
serves its own web UI. N/A for apkeep.

## What needs cloud
A compatible replacement server can provide the reported recipe, session/log
and firmware-file services without the vendor cloud. That is conditional on the
exact model/firmware and is not evidence of universal offline provisioning or
safe brew-session control. Pico U is not covered by the recovered
implementation; do not assign it Pico S/C/Pro routes.

## Firmware-update risk
Set an explicit update policy before connecting an appliance. The maintained
server can offer or force an update when its configured version is newer than
the appliance's. Disable or avoid unintended update delivery until exact
compatibility is established. An archived image or a passing firmware-endpoint
host test is not permission to flash hardware.

## Open questions
1. Verify each model/firmware's request/response schemas with read-only
   appliance logging; Pico, Zymatic and ZSeries differ.
2. Determine ZSeries TLS/certificate behavior per firmware instead of assuming
   that a DNS override or self-signed certificate works.
3. Establish real start/stop/abort and fault behavior independently of server
   session closure; none is verified by the host tests.
4. Pico U support is absent. PicoFerm lifecycle behavior and some PicoStill
   telemetry fields also remain unresolved.

## Safety
The independent Zymatic project warns that a blank-screen fault can stop the
pump while the heater remains on. Disconnect or isolate power safely rather
than relying on a server response or closed session log. Keep physical
power/isolation controls available; no documented HTTP response here is an
emergency-abort mechanism.
