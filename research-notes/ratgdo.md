# ratgdo — Research Notes

## What it is
ratgdo ("rage against the garage door opener") by Paul Wieland, sold by
ratcloud llc: an open-source ESP32/ESP8266 control board that wires to the
opener's terminals and gives **fully local** control with status feedback.
Two flavors: v2 board (Sec+ 2.0 serial decode) and ratgdo disco (adds
vehicle-presence sensor, parking laser, alarm buzzer). Vendor **active** —
paulwieland.github.io/ratgdo reachable 2026-08-07; URC announced a Total
Control integration 2025-10-14.

## Why it matters here
This is the canonical **rescue for MyQ-locked Chamberlain/LiftMaster/
Craftsman openers**. Security+ 2.0 (yellow learn button, 2011+) uses an
obfuscated serial line for wall-console functions, so plain dry-contact
relays can't control door/light; ratgdo speaks that serial protocol.
Chamberlain briefly blacklisted ratgdo's command pattern in Nov 2023 and
backed down after public pressure.

## Local protocols (confirmed)
Per paulwieland.github.io/ratgdo and the GitHub org (PaulWieland/ratgdo,
ratgdo/esphome-ratgdo):
- **ESPHome firmware** — native ESPHome API (local, encrypted optional),
  auto-discovered by Home Assistant (iot_class: local_push).
- **MQTT firmware** — local broker; topics for door state/commands
  (`open`, `close`, `light`, `lock`), availability LWT.
- **HomeKit firmware** — local HAP, no bridge needed.
- **Dry-contact mode** for non-Chamberlain openers (any brand with wall
  button terminals).
All three are LAN-only; no account, no cloud, open-source firmware
(Apache/MIT-style). Provisioning via device AP + web UI.

## Cloud status
None. There is no ratgdo cloud. (URC integration is also local.)

## APK
N/A — no companion app; control is via HA/ESPHome/HomeKit/MQTT.

## Rating
**Confirmed** — open-source firmware, mass-deployed, Ars Technica build log
(2024-09-06), active HA community thread since 2022-07.

## Safety
MEDIUM — provides unattended open/close of a heavy door. Firmware supports
the opener's own obstruction sensors; keep LWT/availability monitoring in
any client. Note: Sec+ 2.0 wall consoles show motion/lock states that
ratgdo mirrors — respect `lock` state.
