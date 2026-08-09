# BlueSpray Wi-Fi Irrigation Controller — Local REST API Research Notes

## What it is
BlueSpray web-based Wi-Fi irrigation controllers (8/16/24-zone models, e.g.
BSC-08i/16i/24i) from a small US vendor. Site `bluespray.net` is live as of
2026-08-07 (Apache 301 → https); vendor advertises "REST API available…
Our API is simple to use, all HTTP" and 24/7 email support.

## Local protocol — vendor-documented, fully local
- The controller runs its own **web server**; the entire web UI is driven by
  the same HTTP REST API the vendor publishes (API docs linked from
  bluespray.net; user manual PDF on the site).
- Control covers zones, programs/seasons, schedules, rain delay, and status
  queries — all on-LAN, no account required.
- Typical client examples in the wild are `curl`-grade HTTP calls; several
  community posts and small GitHub projects script it directly.
- No cloud service is part of normal operation at all — the product was
  designed web-first/local-first, which makes it resilient to the vendor's
  small-company risk.

## Company status
Small vendor, still answering (support email advertised; site live 2026-08).
Even if the company vanishes, nothing in the control path depends on their
servers — firmware, UI, and API are on the device.

## Cloud dependency
None known. (Firmware updates are manual/file-based per the manual.)

## APK
Not fetched — vendor-documented HTTP API; no app dependency.

## Rating
**Confirmed** — vendor-documented local REST API.

## Sources (accessed 2026-08-07)
- bluespray.net (front page: "REST API available… all HTTP"; user manual PDF)
- curl check 2026-08-07: www.bluespray.net responds (301 → https)
