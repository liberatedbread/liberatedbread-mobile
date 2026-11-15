# Automated device detection and pairing heuristics

Goal: discover device transports and identifiers quickly, before reverse engineering.

## BLE advertising patterns
- Scan BLE advertisements and grep for known prefixes:
  - "SP107e" (Lunchbox Dream LED Skin controller)
  - "LBXDRMSKIN_LED_" (Dream LED Skin 2.0)
- Record:
  - device name, address type (public/random), RSSI
  - service UUID list if available
- Capture "connect + one action" session with Android HCI snoop log.

## SSID heuristics (Wi-Fi gadgets)
- Scan SSIDs/BSSIDs and look for gadget APs.
- If connected to device AP, probe:
  - http://192.168.4.1 or gateway IP
  - known camera ports (RTSP 554, HTTP 80/8080, custom UDP)

## mDNS/DNS-SD
- Browse services:
  - avahi-browse -a -t
- Focus on _http._tcp and any vendor-specific service types.
- Read the TXT records, not just the service type. Several common service types
  identify a *firmware platform* rather than a product — `_esphomelib._tcp` is
  every ESPHome node, `_hap._tcp` every HomeKit accessory, `_http._tcp` every
  web server on the link — and it is a TXT record that names the product
  (ESPHome's `project_name`, HomeKit's `md`). A spec on such a service type
  carries that condition in `identification.mdns_txt_match`; without it the
  spec claims the whole platform. See
  [ESPHome Node (generic)](devices/esphome-device.md) for the worked pair.

## UPnP/SSDP
- Send M-SEARCH to 239.255.255.250:1900 and parse LOCATION headers.
- If a device description is found, extract service endpoints.

## MAC OUIs
- For observed BSSIDs/MACs, lookup OUIs in IEEE registry (best-effort hint).

## Passive Bluetooth telemetry (Android)
- Enable "Bluetooth HCI snoop log" in Android developer options.
- Pull /sdcard/btsnoop_hci.log via adb for analysis.

## Companion Device Manager (Android)
- Check whether app uses CompanionDeviceManager pairing flows.
- If yes, plan to replicate the user-consent pairing UX in the replacement app.
