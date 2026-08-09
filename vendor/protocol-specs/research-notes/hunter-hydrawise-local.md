# Hunter Hydrawise (HC / Pro-HC / HPC) — Limited Local API Research Notes

## What it is
Hunter Industries' Hydrawise Wi-Fi irrigation controllers (HC, Pro-HC, HPC,
HPC-FP retrofit panel). Manufacturer very much active (2026). The official
integration path is the Hydrawise cloud REST API (API key from the account),
and the Home Assistant core integration is cloud-only — HA forum answer to
"local integration?" is flatly "No. There is no local access… Cloud only."

## Local path that DOES exist — undocumented HTTP API (openHAB)
The openHAB Hydrawise binding supports a **`local` Thing**: "an undocumented
API that allows direct HTTP access to an irrigation controller on the user's
network"
([openhab.org/addons/bindings/hydrawise](https://www.openhab.org/addons/bindings/hydrawise/)).

- Auth: HTTP basic auth with the **admin username/password set on the
  controller's touch panel** (Settings menu) — no cloud account needed for
  this path.
- Feature subset: zone start/stop (incl. custom run time), suspend,
  run-all. No sensors, no forecasts.
- Locally-controlled state is **not reported back to the cloud**/vendor apps.
- openHAB caveat: "Local control may not be available on later Hydrawise
  controller firmware versions." So this is real but firmware-fragile —
  treat as **confirmed-but-limited**, verify per firmware before relying on it.
- Use case documented by openHAB: zero-delay zone testing and fully local
  scheduling via openHAB rules.

The exact endpoint schema lives in the openHAB binding source
(`org.openhab.binding.hydrawise`, local API handler) — a spec-transcription
target for this repo.

## Cloud dependency
None for the local subset (panel-set admin password). Cloud account only for
the vendor app / official API / remote access.

## APK
Not fetched — openHAB binding source documents the local API; APK triage
would only matter if the local API disappears from new firmware.

## Rating
**Confirmed (limited)** — production openHAB binding; feature subset;
firmware-dependent availability.

## Sources (accessed 2026-08-07)
- openhab.org/addons/bindings/hydrawise (local Thing docs)
- community.home-assistant.io/t/hunter-hydrawise-sprinkler-system-integration/51003 (cloud-only consensus)
- hunterirrigation.com Hydrawise API information (cloud REST API v1.6)
