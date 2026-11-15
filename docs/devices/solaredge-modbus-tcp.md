# SolarEdge Inverters (Modbus TCP / SunSpec)

> **Status**: Spec Available (from public sources; not replayed against hardware)
> **Protocol**: Wi-Fi/LAN: Modbus TCP on port 1502 (SetApp inverters) or 502 (older display inverters), SunSpec register map
> **Manufacturer**: SolarEdge Technologies
> **Manufacturer Status**: Active. Cloud Monitoring API V1 reported retired at the start of November 2026

## Overview

SolarEdge grid-tied PV inverters (HD-Wave single phase, three phase, Synergy
three phase, Energy Hub and StorEdge) carry a local Modbus TCP server that
speaks SunSpec. It needs no account, no cloud and no app once it is switched
on, and it is the path SolarEdge itself documents for third-party
monitoring.

Two things make it the durable local path now:

- Community reports say SolarEdge retires its cloud Monitoring API V1 at the
  start of November 2026 (1 or 3 November, depending on the source) in
  favour of an OAuth-based V2.
- Home Assistant 2026.10 removed its "SolarEdge Local" integration, which
  used the inverter's undocumented web API that newer firmware closes, and
  added a core SolarEdge Modbus integration built on this protocol.

> **One client at a time**: SolarEdge's technical note says the Modbus TCP
> server accepts a single connection and session. A second poller (another
> home-automation system, a datalogger, two integrations each opening their
> own socket) is refused or starves the first. Use one client, or put a
> Modbus proxy in front of the inverter.
>
> **Security**: Modbus TCP has no authentication and no encryption. Keep the
> port on a trusted LAN segment and never forward it to the internet.
>
> **Control registers**: the power-limit, export-limit and storage registers
> change what a grid-connected inverter produces and exports. Export limits
> are often part of the grid connection agreement, and persistent settings
> are stored in flash meant for occasional writes. They are documented in the
> spec but flagged `advanced`.

## Hardware

| Property | Value |
|----------|-------|
| Models | SetApp inverters (all SunSpec-capable); display (LCD) inverters with CPU firmware 3.xxxx or later |
| Network | Ethernet (the vendor-documented path for Modbus TCP); built-in or plug-in Wi-Fi on many models |
| Modbus over Wi-Fi | Works today per Home Assistant and binsentsu; SolarEdge may drop it in a future firmware |
| Also | RS485 Modbus RTU (115200 8N1 default), not covered here |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | Yes: Modbus TCP is off from the factory |
| Method | `device_ui`: SetApp or the inverter display |
| Port | 1502 (SetApp), 502 (display inverters); changeable |
| Unit id | 1 for the inverter on the network |
| Discovery | mDNS `_solaredge-modbus._tcp.local.` with a `MODBUS_ID` TXT key (as Home Assistant reads it), or by address |
| Passphrase protection | not_applicable (no credentials) |
| Confidence | medium (vendor technical note plus open-source clients) |

**SetApp inverters**: in SetApp, Commissioning > Site Communication >
Modbus TCP > Enable; the port menu shows 1502. Home Assistant's page and
binsentsu's README say the same page is reachable without the app by
flipping the inverter's red P switch briefly (under five seconds) to start
its commissioning Wi-Fi access point and opening the address the inverter
shows.

**Display (LCD) inverters**: enter the setup menu as the installation guide
describes, then Communication > LAN Conf > Modbus TCP. The display shows the
server state: Init, Ready, Connected or Failed (with Disconnected, Gateway
Ping Failed or No IP as the reason).

Then connect to the port and read 69 registers from 40000 with unit id 1:
the first two must be `SunS` (0x53756E53).

**Factory reset**: no procedure found. The power-control registers have
their own restore-defaults command (write 1 to 0xF101), which returns them
to the country defaults.

**Rebinding to a new network**: in place, from SetApp or the display. The
Modbus setting survives an address change; key the inverter on its serial
number (registers 40052-40067) to follow it.

## Pairing

| Property | Value |
|----------|-------|
| Pairing required | No |
| Security mode | `none` |
| One client at a time | Yes, per SolarEdge's note |
| Confidence | medium |

There is nothing to pair. The connection drops after 2 minutes without a
request; poll at least that often to keep it.

## Protocol Summary

Standard Modbus TCP: a 7-byte MBAP header (transaction id, protocol id 0,
length of what follows, unit id) then the PDU, all big-endian, no CRC.

| Function | Use |
|----------|-----|
| 0x03 Read Holding Registers | All monitoring data |
| 0x06 Write Single Register | Active power limit (0xF001), commit (0xF100), restore defaults (0xF101) |
| 0x10 Write Multiple Registers | 32-bit control values (two registers written together) |

Errors come back with bit 7 set on the function code and one exception
code. Both community integrations report that some firmware stays silent on
unsupported registers instead, so a client should treat a timeout on an
optional block as "not present".

### SunSpec register map (zero-based addresses)

| Address | Block | Contents |
|---------|-------|----------|
| 40000 | Marker | `SunS` |
| 40002 | Common model (id 1, length 65) | Manufacturer, model, firmware version, serial, unit id |
| 40069 | Inverter model (101 / 102 / 103, length 50) | AC current, voltages, power, frequency, VA, var, PF, lifetime energy, DC current/voltage/power, heat-sink temperature, status, vendor status |
| 40121 | Multiple MPPT model 160 (Synergy only) | Per-unit DC current, voltage, power, temperature |
| 40121 / 40295 / 40469 | Meters 1-3 (common block, then model 201-204) | Current, voltage, frequency, power, VA, var, PF, import/export energy, events. +50 or +70 on Synergy inverters |

Every reading is an integer multiplied by 10 to the power of a signed
scale-factor register next to it (2071 with SF -2 is 20.71). SunSpec 32-bit
values are high word first; unsupported registers read 0x8000 (int16),
0xFFFF (uint16) or 0 (energy accumulators).

Inverter status (40107): 1 off, 2 sleeping (night), 3 starting, 4 producing,
5 producing curtailed, 6 shutting down, 7 fault, 8 standby.

### Control registers (advanced)

From SolarEdge's 2017 power-control note, implemented by both Home Assistant
integrations. They act only after AdvancedPwrControlEn (0xF142) is 1 and
ReactivePwrConfig (0xF104) is 4 (RRCR), followed by a commit (0xF100). Their
32-bit and float values are sent low word first, unlike SunSpec.

| Register | Meaning |
|----------|---------|
| 0xF001 | Active power limit, 0-100 % of rated power. Not saved; lost on restart |
| 0xF100 / 0xF101 | Commit settings / restore defaults (write 1; read back a result code) |
| 0xE000 | Export control mode (bit field) |
| 0xE002 | Export site limit, float32 W |
| 0xE004 on | StorEdge battery control |

`scripts/test_solaredge_modbus_tcp_spec.py` rebuilds every example frame in
the spec from the MBAP rule and decodes the example replies with their scale
factors.

See `device-specs/devices/solaredge-modbus-tcp.yaml` for the full spec.

## References

- [SolarEdge SunSpec technical note v3.2 (mirror)](https://github.com/WillCodeForCats/solaredge-modbus-multi/blob/main/doc/sunspec-implementation-technical-note.pdf)
- [SolarEdge power control protocol note v1.3 (mirror)](https://github.com/WillCodeForCats/solaredge-modbus-multi/blob/main/doc/Power-Control-Open-Protocol-for-SolarEdge-Inverters.pdf)
- [WillCodeForCats/solaredge-modbus-multi](https://github.com/WillCodeForCats/solaredge-modbus-multi)
- [Home Assistant SolarEdge Modbus integration](https://www.home-assistant.io/integrations/solaredge_modbus/)
- [Home Assistant 2026.10 release notes](https://www.home-assistant.io/blog/2026/10/07/release-202610/)
- [binsentsu/home-assistant-solaredge-modbus](https://github.com/binsentsu/home-assistant-solaredge-modbus)
- [frenck/python-solaredged](https://github.com/frenck/python-solaredged)
- [sunspec/pysunspec2](https://github.com/sunspec/pysunspec2)
- [HA Community: SolarEdge API V1 turned off in November](https://community.home-assistant.io/t/solaredge-api-v2-uses-oauth-old-api-will-be-turned-off-in-november/1026150)
