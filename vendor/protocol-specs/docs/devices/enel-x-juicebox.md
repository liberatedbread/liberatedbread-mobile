# Enel X Way JuiceBox (JuiceNet UDP)

> **Status**: Spec Available (unverified)
> **Protocol**: WiFi (UDP, charger-initiated; telnet console on TCP 2000)
> **Manufacturer**: Enel X Way North America (formerly eMotorWerks)
> **Manufacturer Status**: Shutdown — apps and servers switched off 2024-10-11

## Overview

The JuiceBox is a 240 V Level 2 EV charger whose smart features — above all
*changing the charging current* — ran through Enel X's JuiceNet cloud. Enel X
Way announced on 2024-10-02 that it was leaving the US and Canada and turned
the apps and servers off nine days later. Every unit still charges at the
current it was last set to; nothing can change that unless something on the
LAN takes the server's place.

It can, because the charger never needed the cloud to be clever. It opens a
UDP "stream" to a configured host and port and sends a short ASCII status line
every 9–30 seconds. The server answers each line with a `CMD` line carrying two
current limits, the time of day and a counter, protected by a three-character
base-35 hash. A LAN host that receives those datagrams can read current,
voltage, energy and plug status, and by replying can set the online limit
(0 pauses charging) and the offline limit the unit falls back to.

Two things this spec cannot do: decode the **encrypted** variants (`v09e` on
generation 2 from June 2024, `v08` on generation 1 from mid-November 2024,
with a move to port 9004) — a unit kept off the internet stays plaintext — and
protect your wiring. The charger clamps to its own rating, not to the circuit
behind it; the spec carries a `safety_advisory` and marks both current
commands `advanced`.

## Hardware

| Property | Generation 1 (2016–2019) | Generation 2 "Next Gen" (2020–) |
|----------|--------------------------|----------------------------------|
| Models | JuiceBox Pro 32 / 40 / 40 Lite / 75 | JuiceBox 32 / 40 / 48 |
| Chassis | Metal, four screws | Plastic |
| Wi-Fi module | ZentriOS WZ (PCB 8.12–8.17) | Gecko OS on Silicon Labs WGM160P (PCB 9.x) |
| Firmware string | `EMWERK-JB_1_1-…` / `EMWERK-JB814-…` | `EMWERK-JB201-1.0.46` / `-1.0.69` |
| Protocol | `v07` (encrypted: `v08`) | `v09u` (encrypted: `v09e`) |
| Telnet (TCP 2000) | Yes | 1.0.46 yes; 1.0.69 disabled |

Pre-2016 "legacy" units do not run the Zentri stack and are out of scope.

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | Yes — on Wi-Fi, *and* the UDP stream pointed at a LAN host |
| Wi-Fi join | `softap_http`: setup AP `JuiceBox-###` / `JuiceNet-###` / `EXW-###`, passphrase `GoElectric`, web form at the module's address (also `setup.com`) for 2 minutes after power-up |
| Re-point routes (pick one) | DNS override of the server name (primary); router destination-NAT + masquerade; telnet `stream_close` / `udpc` on TCP 2000 (reverts within minutes unless re-applied) |
| Discovery | None — the charger initiates; its address is the datagram source, its identity the 28-digit ID the line begins with |
| Passphrase protection | plaintext HTTP on a WPA AP with a published passphrase |
| Confidence | medium (juicepassproxy's daily practice; not replayed here) |

Block `directory-api.emotorwerks.com` whichever route you take: its reply is
what switches a unit into the undecodable encrypted mode.

**Factory reset**: none documented in either manual (`applicable: unknown`).
The setup AP re-appears for two minutes after every power-up, so new Wi-Fi
credentials never need one.

**Rebinding to a new network**: power-cycle, join the setup AP within two
minutes, submit the new network. The old network need not exist. The UDP target
is kept; recreate the DNS override or router rule on the new network.

## Protocol Summary

**Status line** (charger → host), every 9 s charging / 30 s idle:

```
<28-digit id>:v09u,s001,F31,u00412974,V2400,L00004262804,S02,T28,M0024,C0040,m0040,t09,i23,e-0001,f5990,r99,b000,B0000000,P0,E0004501,A00161,p0996!ZYK:
```

Fields are `<letter><integer>` tokens; parse by letter, never by position.

| Field | Meaning | Scale / unit |
|-------|---------|--------------|
| `V` | line voltage | ×0.1 V |
| `A` | charging current (absent when unplugged) | ×0.1 A |
| `f` | line frequency | ×0.01 Hz |
| `p` | power factor | ×0.001 |
| `T` | internal temperature | °C |
| `L` / `E` | lifetime / session energy | Wh |
| `S` | 0 unplugged · 1 plugged in · 2 charging · 5 error | — |
| `M` / `C` / `m` | online limit in force / offline limit (v09 only) / unit rating | A |
| `i` / `e` | 15-minute slot 0–95 / energy in it | Wh |
| `t` | report interval | s |
| `F`, `r`, `b`, `B`, `P`, `X`, `Y` | unknown | — |

**Reply** (host → charger), one per status line:

```
CMD<d><HHMM>A<online>M<offline>C006S<counter>!<crc>$
e.g.  CMD31830A0016M040C006S001!RAS$
```

`d` weekday (0 = Sunday), `HHMM` local time, `A` online amps (4 digits on
v09, 2 on v07; 0 pauses), `M` offline amps (EEPROM; 3 / 2 digits), `C006`,
`S` counter 001–999. No reply for ~5 min → the unit falls back to `M`.

**Hash**: `h = (h ^ ((h<<5) + (h>>2) + ord(c))) & 0xFFFF` over the payload
before `!`; `h mod 35³` as three base-35 digits, least-significant first,
alphabet `0-9 A-N Z P-Y` (digit 24 is `Z`; `O` never appears).
`scripts/test_enel_x_juicebox_spec.py` holds the spec's frames and six
server-captured `CMD` frames from juicepassproxy to that rule.

**Console** (TCP 2000, prompt `>`): `list` shows `# 1 UDPC host:port (n)`;
`stream_close 1` then `udpc <host> <port>` re-points the stream; `set
udp.client.remote_host` / `remote_port` + `save` + `reboot` persist it (with
a reported risk of not getting the old target back); `network_lookup <name>`
confirms a DNS override.

See `device-specs/devices/enel-x-juicebox.yaml` for the full machine-readable
spec.

## References

- [JuiceRescue/juicepassproxy](https://github.com/JuiceRescue/juicepassproxy) (Apache-2.0)
- [JuiceboxRescueWiki: How the communication works](https://github.com/JuiceRescue/JuiceboxRescueWiki/wiki/How-the-communication-Works-(Basic-info))
- [JuiceboxRescueWiki: Console commands](https://github.com/JuiceRescue/JuiceboxRescueWiki/wiki/Juicebox-Console-Commands)
- [home-assistant/core #86588](https://github.com/home-assistant/core/issues/86588)
- [philipkocanda/juicebox-protocol](https://github.com/philipkocanda/juicebox-protocol) (MIT)
- [Electrek: Enel X Way North America is shutting down](https://electrek.co/2024/10/02/enel-x-way-north-america-is-shutting-down-heres-what-we-know/)
- [Next Gen JuiceBox user manual (32A/40A/48A)](https://support-emobility.enelx.com/content/dam/support-hub/canada-en/JuiceBox-Manual-JuiceBox-32A-40A-48A.pdf)
- [JuiceBox user manual, 2019 (generation 1)](https://support-emobility.enelx.com/content/dam/support-hub/canada-en/Commercial-JuiceBox-Manual-2019.pdf)
