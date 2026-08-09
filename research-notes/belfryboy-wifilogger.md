# Belfryboy WiFiLogger (for Davis Vantage consoles) — Local Wi-Fi Research Notes

## What it is
Third-party data logger from Belfryboy (Poland; wifilogger.net): an ESP-12S
class module that plugs into the expansion/datalogger port of **Davis Vantage
Pro2, Vantage Vue, and Envoy consoles** (and works in the Envoy8X). It gives
these serial-era consoles a Wi-Fi interface. WiFiLogger 2 is the current
hardware rev ([Météo-Shopping listing, 2024](https://www.meteo-shopping.com/en/software-and-datalogger/567-wifi-logger-v2-pour-vantage-pro-2vantage-vue.html)).

## Local interfaces (no cloud account needed)
- **HTTP web UI** on port 80 for full configuration and live view.
- **HTTP JSON export**: `wflexp.json` (current conditions + archive) — pulled
  by OpenEnergyMonitor users and others
  ([community thread](https://community.openenergymonitor.org/t/davis-wifi-logger-wflexp-json/17163)).
- **MQTT** publish (JSON), user-configured broker — pure LAN capable.
- **Custom HTTP/PUT/FTP upload** to arbitrary endpoints (Wunderground,
  Windy, own server).
- Also speaks the classic Davis LOOP/serial command set over Wi-Fi to local
  software (WeeWX/Cumulus treat it like a TCP datalogger).
- Vendor site headline: "MQTT – JSON file format, HTTP – JSON work with any
  external software" ([wifilogger.net](https://wifilogger.net/)).

## Why it matters for this repo
It is THE local Wi-Fi path for legacy Davis hardware: Davis' own WeatherLink
IP 6555 logger had no local API (cloud-only), and WeatherLink Live's local
API only covers the Live hub. WiFiLogger retrofits local-first access onto
any Vantage console.

## Cloud dependency
None. All features above run LAN-only. Optional uploads to WU/Windy/etc. are
user-configured, not account-gated.

## Company status (checked 2026-08-07)
Active niche vendor; site live, product stocked by EU weather retailers
(Météo-Shopping FR, others).

## APK
None — configuration is via the device's own web UI.

## Rating
**Confirmed** — shipping product, documented JSON/MQTT outputs, active
community use (WeeWX, CumulusMX, OpenEnergyMonitor, Windy forum).

## Spec-work notes
- Document `wflexp.json` field set and MQTT topic/payload from vendor manual
  (PDF on wifilogger.net) in own words.
- Note the Davis LOOP-over-TCP compatibility port for WeeWX/Cumulus use.
