# Hörmann BiSecur Gateway

> **Status**: Spec Available (unverified)
> **Protocol**: LAN (UDP 4001 discovery with replies on UDP 4002, TCP 4000 hex-ASCII frames)
> **Manufacturer**: Hörmann
> **Manufacturer Status**: Unsupported — replaced by the homee hub; no sales since December 2020

## Overview

The BiSecur Gateway connects Hörmann's BiSecur radio garage and gate
operators to the home network. Hörmann now sells homee in its place, and the
BiSecur app and remote relay are reported gone, but the gateway still answers
on the LAN. A client can find it by broadcast, log in as a gateway user, list
the doors, read each door's position and status, and send the same impulse a
hand transmitter sends.

> **Safety**: an impulse moves a heavy door or gate. Send one only as a
> deliberate action with the door in view. A `PORT_ERROR` reply does not mean
> the door stayed put: halacs reports that on ports added by copying a hand
> transmitter's code, `SET_STATE` answers `PORT_ERROR` (10) although the door
> moves. Never resend an impulse automatically. **Security**: the protocol is not
> encrypted and sessions can be taken over from the LAN (SEC Consult, 2020),
> so keep the gateway on a trusted segment and never expose TCP 4000.

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No (a gateway set up in the app keeps its users and doors) |
| Method | Discover, connect to TCP 4000 and log in |
| Discovery | UDP broadcast `<Discover target="Gateway" />` to port 4001; the reply goes to UDP 4002 on the sender, so bind 4002 first. bisdk and pysecur3 send `target="LogicBox"` instead |
| Credentials | A gateway user name and password, sent in clear |
| Confidence | medium |

## Protocol Summary

Every frame is sent as upper-case hex ASCII:

| Bytes | Field |
|-------|-------|
| 6 | Source address (gateway MAC, or the client's own small id) |
| 6 | Destination address |
| 2 | Packet length, big-endian (9 + payload) |
| 1 | Tag, echoed by the reply |
| 4 | Session token (0 before login) |
| 1 | Command id (reply sets bit 7) |
| n | Payload |
| 1 | Packet checksum: length value + byte sum of tag through payload, mod 256 |
| 1 | Transport checksum: sum of the ASCII codes of the hex text before it |

The commands a client needs: `LOGIN` (0x10), `JMCP` (0x06) with
`{"CMD":"GET_GROUPS"}` to list doors and ports, `HM_GET_TRANSITION` (0x70) to
read a port's position (0–200, halve it for percent) and status bits,
`SET_STATE` (0x33) to send a port's impulse, and `LOGOUT` (0x11). Errors come
back as command 0x01 with a one-byte code. User, port and Wi-Fi management
commands exist but are left out of the spec.

Session behaviour reported by halacs from one gateway: a token lasts about
30 minutes, then commands get `PERMISSION_DENIED` (12). If a connection closed
without `LOGOUT`, the next `LOGIN` is preceded by one `LOGOUT` frame (tag
0xFF) per stale session, which a client skips. `LOGOUT` gets no reply. Leave
about 100 ms between commands and poll `HM_GET_TRANSITION` no faster than
every 2 s, or the gateway resets the connection. Ports added by copying a hand
transmitter's code return `PORT_ERROR` instead of a position, and about 20 %
of polls on other ports return a transient `PORT_ERROR`.

`scripts/test_hormann_bisecur_gateway_spec.py` rebuilds every example frame
from the rule. The rule also reproduces all 30 frames in halacs/BiSecur's
tests.

See `device-specs/devices/hormann-bisecur-gateway.yaml` for the full spec.

## References

- [bisdk/sdk protocol notes](https://github.com/bisdk/sdk)
- [halacs/BiSecur Go SDK and CLI](https://github.com/halacs/BiSecur)
- [skelsec/pysecur3](https://github.com/skelsec/pysecur3)
- [SEC Consult advisory (2020)](https://sec-consult.com/blog/detail/hoermann-opening-doors-for-everyone/)
- [BiSecur Gateway quick guide TR20N001-B](https://www.hoermann.de/fileadmin/_country/dok/BiSecur_Gateway_TR20N001-B.pdf)
