# Logitech Squeezebox (SlimProto)

> **Status**: Spec Available (unverified — from Lyrion/Logitech Media Server docs)
> **Protocol**: WiFi (TCP)
> **Manufacturer**: Slim Devices / Logitech (server now community-run as Lyrion)
> **Manufacturer Status**: Abandoned — hardware line discontinued 2012, cloud shut; server continues as the GPL Lyrion Music Server

## Overview

Squeezebox network music players (Classic, Boom, Transporter, Radio, Touch)
never needed the vendor cloud: a player connects to a local music server and
streams from it. Logitech dropped the hardware in 2012 and later killed
mysqueezebox.com, but the server lives on as the community **Lyrion Music
Server** (GPL) — so the hardware keeps working as long as a server runs.

## Protocol Summary

Two protocols. **SlimProto** (TCP 3483) is the player↔server control channel:
the player connects out, the server pushes `strm`/`audg`/`grfe` and the player
answers `HELO`/`STAT`; audio is pulled over HTTP from the server (port 9000).
The **control API** — a line CLI on TCP 9090 and the equivalent JSON-RPC over
HTTP (`POST /jsonrpc.js` on port 9000) — is how an app drives playback,
addressing a player by its MAC. Discovery is a UDP 3483 broadcast.

See `device-specs/devices/squeezebox-slimproto.yaml` for the framing, the HELO/
strm fields and the JSON-RPC commands.

## References

- <https://github.com/LMS-Community/slimserver> (Lyrion Music Server, GPL)
- <https://lyrion.org/reference/slimproto-protocol/>
- <https://wiki.lyrion.org/index.php/SlimProto_TCP_protocol.html>
- <https://lyrion.org/reference/cli/using-the-cli/>
