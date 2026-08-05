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
