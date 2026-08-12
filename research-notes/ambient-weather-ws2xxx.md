# Ambient Weather WS-2902x / WS-2000 / WS-5000 — Local Path Research Notes

## What it is
Ambient Weather (US brand, owned by Nielsen-Kellerman since 2019) resells
Fine Offset hardware: WS-2902A/B/C/D all-in-one stations, WS-2000/WS-5000
display consoles, ObserverIP (WS-0900-IP/WS-1400-IP) hub. All push to
ambientweather.net cloud by default.

## Local path — custom-server push (vendor feature)
- Firmware update rolled out ~April 2021 added a **Custom Server** upload
  option: protocol type `Ambient Weather` or `Wunderground`, plus
  user-supplied server IP/hostname, port, path, and interval
  ([HA community thread, 2021-04](https://community.home-assistant.io/t/ambient-weather-available-locally-now-integration-anyone/299180);
  confirmed for WS-2902B via awnet app and WS-2000/WS-5000 on-console menus;
  WXforum WS-5000 thread shows `Gear Setup -> Weather Server -> Customized`).
- Console then HTTP-GETs readings to the LAN host — same wire formats as the
  Ecowitt gateways (these ARE Fine Offset consoles; the Ecowitt/Froggit custom
  server docs apply).
- Configuration via the **awnet app** (Android `com.ambientweather.awnet`,
  iOS) — works over local Wi-Fi AP mode; no cloud account needed to set the
  custom server. AmbientTool / WS View Plus apps also configure these
  consoles (they are FO clones).

## Receivers for the push (community)
- [dancwilliams/awnet_to_hass](https://github.com/dancwilliams) HA add-on +
  `ambient_station_local` HACS integration (parses the Ambient-protocol GET).
- WeeWX `interceptor` driver (matthewwall/weewx-interceptor) in listen mode.
- Any Ecowitt-protocol parser (FOSHKplugin, ecowitt-controller) since the
  formats match.

## ObserverIP (WS-0900-IP)
Older hub has NO custom server, but serves a local web UI on port 80 with a
`livedata.htm` page — scrapeable HTML table of current readings
(well documented in WeeWX docs/forums). Also interceptable.

## Limitations
- Push-only on the stations: no pull API on WS-2902x/WS-2000/WS-5000 (unlike
  Ecowitt-branded GWxxxx, which add TCP 45000 + HTTP GET). Someone must listen.
- Cloud-only extras: derived fields (dew point, feels-like) are computed
  server-side, not sent in the local push — receivers must compute them.
- WS-2902A (oldest hw rev) may lack the custom-server option; B/C/D confirmed.

## Cloud dependency
None once custom server is set. Initial Wi-Fi provisioning is local (console
broadcasts its own AP; awnet app joins it). ambientweather.net optional.

## Company status (checked 2026-08-07)
Active. ambientweather.net and store live; WS-2902D/WS-5000 still sold.

## APK
Not needed — local behavior is community-documented and matches Ecowitt
formats. awnet is `com.ambientweather.awnet` if ever wanted.

## Rating
**Confirmed** — vendor feature, multiple community receivers in production.

## Spec-work notes
- Document the Ambient-protocol GET field set (`MAC`, `dateutc`, `tempf`,
  `humidity`, `windspeedmph`, `baromin`, `rainin`, `solarradiation`, `UV`,
  `aqin_*` for indoor AQ, …) vs the Wunderground variant.
- Note derived-field gap (compute dewpoint/feels-like client-side).
