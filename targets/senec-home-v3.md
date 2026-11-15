# SENEC.Home V2.1 / V3 battery storage — local lala.cgi API — target spec starter

## Target metadata
- target_id: senec-home-v3
- app package_id(s): TBD (the vendor "mein-SENEC" app is cloud-only and is
  not the path; the local surface is the storage unit's own web server)
- device class: residential battery storage with hybrid inverter (V2.1, V3
  Hybrid / Hybrid Duo); **V4 and Home 4 have no local API**
- transport(s): Wi-Fi/LAN, HTTP POST to `/lala.cgi` on the unit
- local-only viability: **medium-high** — the endpoint is unauthenticated
  and read-complete for live values, but it is undocumented, has been
  trimmed by firmware (daily statistics went missing; one owner reports HTTP
  405), and is absent on the current generation.

## Why now
- EnBW is winding down new SENEC sales (2026); the vendor cloud ("mein-SENEC")
  is the only official path and an unknown. Local reads keep the dashboards
  alive if the portal goes.

## Known facts (public; community clients 2019 → 2024)
- Request: JSON POST whose keys are groups (`ENERGY`, `PV1`, `PM1OBJ1`,
  `STATISTIC`, `BMS`, `WIZARD` …) each mapping field names to empty strings;
  the reply fills the same shape with typed strings.
- Values are typed by prefix: `fl_` + 8 hex digits is an IEEE-754 single
  (big-endian), `u8_`/`u1_`/`u3_`/`i3_` are unsigned/signed integers in hex,
  `st_` is a string. Clients convert `fl_` by unpacking the hex as a float.
- Live fields read by every client: house power, grid power (sign = import/
  export), PV power, battery charge/discharge power, state of charge, and
  system state code. Daily totals under `STATISTIC` stopped answering on some
  V3 firmware.
- Some firmware serves `/Vars.html` as an alternative view (anecdotal).
- Clients: [pysenec](https://pypi.org/project/pysenec) (V2.1; API details from
  ioBroker.senec) · [pysenechome](https://pypi.org/project/pysenechome/) (V3
  Hybrid) · [Ruby `senec` gem](https://rubydoc.info/gems/senec/file/README.md)
  (V2.1 + V3) · [ioBroker.senec](https://github.com/nobl/ioBroker.senec) ·
  [evcc meter docs](https://docs.evcc.io/en/meters/senec-home.md) · the
  openHAB SenecHome binding.

## Device discovery signals
- Wi-Fi/LAN: no mDNS or SSDP reported; the unit takes a DHCP address, and
  owners read it from the router. An HTTP probe (`POST /lala.cgi` with a
  minimal `ENERGY` request) identifies it.

## Threat model + guardrails
- READ-ONLY. `lala.cgi` also accepts writes (the vendor's own wizard uses it);
  a published spec carries none of them — a wrong write to a battery
  inverter is a safety matter.
- Placeholder the unit's serial and LAN address in examples.

## First experiments
1) Collect the exact field list and the `fl_`/`u*_` decoding rules from two
   clients and cross-check; note which fields each firmware still answers.
2) Confirm whether the endpoint is HTTP only or also HTTPS on recent V3
   firmware (the 405 report suggests a method or scheme change).
3) Write the decoding test (hex → float) first; it is the test vector.

## Control surface inventory (replacement app MVP, read-only)
- SoC · PV / house / grid / battery power · system state · (daily totals if
  the firmware still answers)

## References (URLs only)
- https://pypi.org/project/pysenec
- https://pypi.org/project/pysenechome/
- https://rubydoc.info/gems/senec/file/README.md
- https://docs.evcc.io/en/meters/senec-home.md
- https://community.openhab.org/t/senechome-binding/108152
