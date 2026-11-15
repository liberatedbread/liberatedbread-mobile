# Hayward OmniLogic / OmniHub / OmniPL — Local UDP XML API Research Notes

## What it is
Hayward's pool/spa automation controllers. Manufacturer active (Aug 2026).
The vendor path is the OmniLogic cloud + app, but the controller also answers
a local UDP/XML API on the LAN — the same one the app uses on-premise.

## Local protocol — RE'd, working community integration
- Library: [cryptk/python-omnilogic-local](https://pypi.org/project/python-omnilogic-local/)
  (PyPI `python-omnilogic-local`).
- Integration: [cryptk/haomnilogic-local](https://github.com/cryptk/haomnilogic-local)
  (HACS; announced 2023-06, Trouble Free Pool thread confirms faster-than-cloud
  control of lights, valves, pump speeds).

### Transport
**UDP port 10444** on the controller (default; configurable in the library as
`controller_port`). Static IP/DHCP reservation recommended.

### Wire format (from library source, cloned 2026-08-07)
Each datagram = binary **lead-message header** (message id, message type,
version string, client type) + payload:
- XML-API messages carry an XML payload (`client_type: XML`);
  request/response schema mirrors Hayward's cloud XML API
  (`RequestConfiguration`, equipment state, etc.).
- "Simple" command messages use a command body without XML.
- Some message types are **always compressed** even when not flagged in the
  lead message (library handles transparently).

### Coverage (per haomnilogic-local README)
Multiple bodies of water; VS/single-speed pumps (speed presets + custom);
lights (on/off, brightness, show); relays/valve actuators; flow/temp/power
sensors; heaters (setpoint); chlorinators (timed-percent, no ORP yet);
schedule-restore button. Dual-speed pumps and ORP chlorinators unsupported.

## Cloud dependency
None for local control — IP address is the only integration parameter.
Hayward cloud account only needed for the vendor app's remote access.

## APK
Not fetched — library + integration fully document the protocol.

## Caveats
- Community thread (2023-06) notes one OmniLogic instance per HA install
  (integration limitation, not protocol).
- Discovery: no documented broadcast discovery in the library — user supplies IP.

## Rating
**Confirmed** — production HACS integration since 2023, library on PyPI.

## Sources (accessed 2026-08-07)
- github.com/cryptk/haomnilogic-local; pypi.org/project/python-omnilogic-local
- source: pyomnilogic_local/api/constants.py `DEFAULT_CONTROLLER_PORT = 10444`
- community.home-assistant.io/t/hayward-pools-local-integration-announcement/584634 (2023-06-22)
- troublefreepool.com Home Assistant / Hayward Omni Local Control thread (2023-06)
