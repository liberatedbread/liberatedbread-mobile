# Aeon Matrix Yardian / Yardian Pro — Local API Research Notes

## What it is
Smart sprinkler controller (8/12-zone) by Aeon Matrix; Yardian Pro adds an
HD security camera. Company active — yardian.com blog updated 2025-10 and
site serves HTTP 200 on 2026-08-07.

## Local protocol — REST API on the device
- Home Assistant **core** integration `yardian` (since 2023.9) is
  `iot_class: local_polling`, backed by the `pyyardian` library
  ([home-assistant.io/integrations/yardian](https://www.home-assistant.io/integrations/yardian/)).
- Config flow requires **Host** (device IP) and **Access Token** — the token
  is read from the Yardian app (device settings). Control then goes directly
  to the controller over the LAN (HTTPS REST with the token as bearer).
- Exposed: per-zone switches (start/stop with minutes), "stop all irrigation"
  button, watering/standby/freeze-prevent binary sensors.

## Cloud dependency — ONE-TIME step required
Wi-Fi onboarding and the access token both come from the Yardian **cloud
account + app**. After the token is extracted, day-to-day HA control is fully
local. **If Aeon Matrix's cloud dies, existing token holders keep local
control, but setting up a factory-reset device (or recovering a lost token)
would have no documented workaround** — the token lives behind the account.
This is the main liberation gap worth documenting.

## APK
Not fetched — local API works via documented HA path; the useful RE target
would be the provisioning/token-exchange flow (gap noted above).

## Rating
**Confirmed** (local control) — HA core integration; with the one-time-cloud
caveat above.

## Sources (accessed 2026-08-07)
- home-assistant.io/integrations/yardian (Local Polling; host + access token from app)
- yardian.com (active, blog 2025-10-09)
