# Brultech GreenEye Monitor (GEM) / ECM-1240 — Research Notes

## What it is
Brultech Research Inc. (BC, Canada) multi-channel energy monitors:
- **GreenEye Monitor (GEM)**: 32 power channels, 8 temperature (1-Wire),
  4 pulse counters; comms via RS-232, EtherPort (Ethernet), WiFi or
  WiFi+Ethernet modules.
- **ECM-1240** (legacy): 7 channels, serial + optional EtherPort for TCP.

Manufacturer ACTIVE — store and docs live as of 2026-05 (brultech.com).

## Local protocol — push, not poll
The monitor is configured (via the comm module's web UI or Brultech's config
software) to **push** its measurement packet every N seconds to a host:port
on the LAN. Two wire formats, both documented by the vendor
("Packet formats and API available", brultech.com/software):

1. **Binary packet** (default): compact binary frame with per-channel
   watt-seconds, watts, volts, temperature and pulse data; includes device
   serial number. Consumed by Home Assistant's `greeneye_monitor` integration
   (local_push; HA listens on a TCP port, e.g. 8000) and by Brultech's own
   DashBox/BTMon software.
2. **HTTP/ASCII format**: GEM emits its data as a long HTTP GET query string
   to a configured web server — the old Vera/Ezlo plugin path (Ezlo community,
   2013-10).

Both formats are 100% LAN: the GEM has no cloud dependency at all; third-party
dashboards (SmartEnergyGroups etc.) were always opt-in push targets.

## Home Assistant
- Core integration `greeneye_monitor` (local_push, binary packets).
- Maintained HACS fork (2023-06) adds UI config, ECM-1220/1240 support,
  energy-dashboard entities, and discovery via packet serial numbers.

## Cloud requirement
None at any point. Setup (channel/CT types, packet format, destination
host:port) is done through the comm module's local web pages or Brultech's
Windows config tool over the LAN.

## Open questions
1. Transcribe the binary packet layout from Brultech's published packet-format
   document into the repo spec (byte offsets for serial, seconds, channels).
2. Document the exact HTTP/ASCII URL parameter names (channel volts/amps/ws).
3. ECM-1240 packet differs from GEM — capture both.

## Safety
CTs inside the breaker panel — installer-grade work. Measurement-only.
