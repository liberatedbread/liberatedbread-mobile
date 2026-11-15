# RainMachine (Mini 8, Touch HD, Pro) — Local REST API Research Notes

## What it is
Wi-Fi irrigation controllers by Green Electronics LLC: RainMachine Mini 8,
Touch HD-12/16, Pro-8/16 (2nd gen 2015 and newer). Vendor advertises
"CLOUD INDEPENDENT — all personal data stored locally; continues to work when
Wi-Fi is down" (Pro-8/16 product page).

## Local protocol — vendor-documented REST API
- HTTPS REST API on **port 8080** (self-signed cert); plain HTTP allowed on
  **port 18080** for local-network access
  ([vendor support article, 2016](https://support.rainmachine.com/hc/en-us/community/posts/216338708-TCP-IP-ports-8080-18080-but-how-about-port-80)).
- Full API reference published by the vendor (Developers section of the
  support site; also Postman collection).
- Auth: `POST /api/4/auth/login` with device password → `access_token`;
  token passed on subsequent calls. Device password is set locally on the
  touchscreen/setup — no cloud account needed for the local API.
- API covers programs, zones, watering history, weather parsers, restrictions,
  flow meter, system config. `POST /api/4/program/{id}/start`,
  `/api/4/zone/{id}/start`, etc.
- Home Assistant core integration `rainmachine` is `local_polling`
  ([home-assistant.io/integrations/rainmachine](https://www.home-assistant.io/integrations/rainmachine/)),
  incl. firmware-update entity.

## Company status (as of 2026-08-07)
Quiet but not officially dead. Support-site posts stop around 2021-2022;
a 2022-06 staff reply says "we are not out of business… devices will continue
to operate all their hardware lifetime"
([support.rainmachine.com](https://support.rainmachine.com/hc/en-us/community/posts/6625420556055-Are-you-all-still-in-business-Asking-again)).
`rainmachine.com` serves HTTP 200 today. **Key point: the local REST API and
on-device scheduling are fully self-contained, so even a total cloud shutdown
would not brick local control.** Weather-forecast adjustments depend on cloud
or user-configured local weather sources (NOAA/NetAtmo/WUnderground parsers).

## Cloud dependency
None for local API control. Cloud account only for remote access via
rainmachine.com relay.

## APK
Not fetched — vendor-published API docs + HA core integration suffice.

## Rating
**Confirmed** — vendor-documented local API, HA core integration.

## Sources (accessed 2026-08-07)
- support.rainmachine.com "Controlling RainMachine through REST API" + Developers section
- home-assistant.io/integrations/rainmachine
- support.rainmachine.com "Are you all still in business?" (2022-06-08)
