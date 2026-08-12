# Oregon Scientific Anywhere Weather (LW301/LW302) — Research Notes (VERDICT: dud, dead line)

## What it is
Oregon Scientific (IDT International, Hong Kong) "Anywhere Weather" kits:
LW301 (basic) / LW302 (pro) sensor arrays pushing to a vendor cloud service;
viewed via app/web. No display console — the cloud WAS the display.

## Local situation — none, and now moot
- Gateway/station pushed only to OS cloud servers; no local API, no
  custom-server option. weewx-interceptor lists "OS LW30x" support — via
  traffic **interception** (bridge/DNS), i.e. MITM, out of scope.
- **OS stopped internet support for the LW301 around 2018** — users were told
  the server went out of service and were offered a WMR89 (USB, non-networked)
  as replacement
  ([weather-watch discourse, 2018-09](https://discourse.weather-watch.com/t/replace-oregon-scientific-lw301-with-lw89-wd/65684);
  [allaboutcircuits, 2018-09](https://forum.allaboutcircuits.com/threads/oregon-scientific-lw301-weather-station.152485/)).

## Brand status (checked 2026-08-07)
Effectively defunct for smart/connected products: US store closed years ago;
remaining regional storefronts sell legacy clocks/basic stations and draw
"poor service" reviews (Trustpilot, 2023). No firmware/app maintenance for
the Wi-Fi line. Dead line confirmed — and with no local protocol, there is
nothing to rescue via Wi-Fi.

## Verdict
**Reject.** Cloud-only device whose cloud is dead; the hardware never had a
LAN interface worth specifying. Sensor RF protocols might be rtl_433-decodable
(OS v2.1/v3 decoders exist for classic OS sensors) — that would be an RF-tier
note, not Wi-Fi.

## APK
OS "Anywhere Weather" app long unmaintained; no local endpoints to find.
Not fetched.
