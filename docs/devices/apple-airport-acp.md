# Apple AirPort Extreme / Time Capsule / Express (ACP)

> **Status**: Spec Available (unverified)
> **Protocol**: LAN (Bonjour `_airport._tcp`, ACP on TCP 5009)
> **Manufacturer**: Apple
> **Manufacturer Status**: Unsupported. Apple discontinued the line in April 2018.

## Overview

Apple's AirPort base stations are the AirPort Extreme, the AirPort Time
Capsule (an Extreme with a built-in disk) and the AirPort Express. They are
managed with ACP on TCP 5009, a protocol Apple never published. This spec
lets any client
read a base station's status, change its settings and restart it, all
locally. Two open-source implementations are the sources:
[node-acp](https://github.com/samuelthomas2774/node-acp) (TypeScript, with
SRP) and [airpyrt-tools](https://github.com/x56/airpyrt-tools) (Python,
archived).

> **Security**: legacy ACP puts the admin password into every request header
> in an easily reversed form. Authenticate with SRP, which also encrypts the
> session, and keep "setup over WAN" (property `waNM`) off so port 5009 cannot
> be reached from the internet.
>
> **Caution**: writing a property, even through the same path that renames
> the unit, can change Wi-Fi, WAN or DHCP settings and drop every device on
> the network, including the client that made the write. Read and save a
> value before you change it.

## Hardware

| Property | Value |
|----------|-------|
| Models | AirPort Extreme (802.11n, 802.11ac), AirPort Time Capsule, AirPort Express 802.11n |
| Product id (`syAP`) | 115 = Express 802.11n (2nd gen), 120 = Extreme 802.11ac; others not in the sources |
| Last firmware named by the community tooling | 7.9.1 (802.11ac Extreme / Time Capsule), 7.8.1 (Express) |
| Radio | Wi-Fi access point and router; Ethernet WAN/LAN |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No. The spec manages a unit that already has a base station password |
| Method | `wired`: discover, connect to TCP 5009, then authenticate |
| Discovery | Bonjour `_airport._tcp.local.`. node-acp reports that the TXT data arrives as one entry, `waMA=<mac>,raMA=…,raM2=…,raNm=…,raCh=…,rCh2=…,raSt=…,raNA=…,syFl=…,syAP=…,syVs=…,srcv=…,bjSd=…` |
| Credentials | The base station password (user name is always `admin` for SRP) |
| Passphrase protection | not_applicable |
| Confidence | medium (community code, not run here) |

First-time setup of a factory-fresh unit is out of scope. The sources do not
cover it.

**Factory reset**: these are the 802.11n and 802.11ac procedures from Apple's
archived support article. The reset button is recessed, so press it with a
pen tip.

- *Soft reset*: with the unit powered, hold the button about 1 s. The status
  light flashes amber. For the next five minutes the password is cleared and
  access control is off, so you can set a new password. If nothing is
  changed, the old settings come back.
- *Hard reset*: with the unit powered, hold the button about 5 s, until the
  light flashes amber rapidly. The unit becomes unconfigured, but it keeps
  the last configuration so you can restore it.
- *Factory default*: unplug the unit, hold the button while you plug it back
  in, and keep holding for about 6 s. This erases the saved configurations
  and profiles. Apple ties this procedure to firmware 7.9.1 on the 802.11ac
  models.

None of these resets erases a Time Capsule's disk or an attached USB disk.

**Rebinding to a new network**: nothing to redo. A base station that acts as
the router normally keeps its address. One that is bridged behind another router gets
a new address by DHCP, and a client finds it again through Bonjour.

## Pairing

| Property | Value |
|----------|-------|
| Pairing required | Yes: the base station password, proved again on every connection. Nothing is issued, and changing the password revokes every client |
| Security mode | `app_layer` (SRP-6a, or the legacy password key) |
| Bonding | `none` |
| PIN source | `user_chosen` |
| Confidence | medium |

## Protocol Summary

Every message starts with a 128-byte big-endian header:

| Offset | Length | Field |
|--------|--------|-------|
| 0 | 4 | Magic `acpp` |
| 4 | 4 | Version, `0x00030001` |
| 8 | 4 | Header checksum: Adler-32 of the header with this field zeroed |
| 12 | 4 | Body checksum: Adler-32 of the body (1 when there is no body) |
| 16 | 4 | Body size, or -1 when there is no body |
| 20 | 4 | Flags (4 on get-property and authenticate, 0 elsewhere; meaning unknown) |
| 24 | 4 | Unused, 0 |
| 28 | 4 | Command id |
| 32 | 4 | Error code |
| 36 | 12 | Zero |
| 48 | 32 | Key field |
| 80 | 48 | Zero |

### Commands

| Id | Name | Use |
|----|------|-----|
| `0x14` | GET_PROPERTY | Read properties |
| `0x15` | SET_PROPERTY | Write properties; writing `acRB` = 0 reboots |
| `0x18` | MONITOR | Start a stream of pushed status frames |
| `0x19` | RPC | Named functions, each with a plist of inputs |
| `0x1A` | AUTHENTICATE | SRP exchange |
| `0x1B` | GET_FEATURES | Feature plist; needs no password |
| `0x01`, `0x03`, `0x05`, `0x06`, `0x16` | Echo, flashing, perform | Not covered here |

**Properties** have four-character names, such as `syNm` (name), `syVs`
(firmware), `syAP` (product id), `syUT` (uptime), `raNm` (Wi-Fi network),
`waIP` (WAN address) and `logm` (log). Each property travels as an element:
the name, 4 bytes of flags, a 4-byte size, then the value. A read sends each
wanted name with a 4-byte zero value. The reply lists the elements and ends
with a marker of all zeros (`00000000 00000000 00000004 00000000`). If an
element has flag bit 0 set, its value is an error code instead, for example
-10 when the property is not available. Structured values, and the bodies of
AUTHENTICATE, GET_FEATURES, MONITOR and RPC, use Apple's compact `CFB0`
plist format.

**Authentication**:

- *Legacy*: the key field holds the password, NUL-padded to 32 bytes and
  XORed with a fixed keystream. Byte *i* of the keystream is
  `((i + 0x55) & 0xFF) ^ static_key[i % 16]`. AUTHENTICATE and GET_FEATURES
  always send the keystream itself, which is the result for an empty
  password.
- *SRP*: SRP-6a with SHA-1 and the 1536-bit group, as user `admin`. Stage 1
  sends `{state: 1, username: admin}` and gets back the salt, `B`, `g` and
  `N`. Stage 3 sends `{iv, publicKey: A, state: 3, response: M1}` and gets
  back `{response: M2, iv}`. After that, both directions use AES-128-CTR.
  Each direction's key is PBKDF2-HMAC-SHA1 of the SRP key with its own fixed
  salt (5 iterations for client to server, 7 for server to client), and its
  starting counter is that side's IV. The key field is then zero.

Firmware flashing exists (`0x03`, `0x05` and `0x06`). Both community
projects can also decrypt firmware images. This spec deliberately leaves
both out.

`scripts/test_apple_airport_acp_spec.py` rebuilds every example message in
the spec from these rules, using an invented password. That includes the
Adler-32 checksums, the legacy key and an example of the PBKDF2 session-key
derivation. The rules were also checked against node-acp's unit-test
vectors.

See `device-specs/devices/apple-airport-acp.yaml` for the full spec.

## Tools Used

- Source reading of node-acp and airpyrt-tools; a standard-library Python
  transcription of the framing rules

## References

- [samuelthomas2774/node-acp](https://github.com/samuelthomas2774/node-acp)
- [x56/airpyrt-tools](https://github.com/x56/airpyrt-tools)
- [Apple Support: How to reset your AirPort base station](https://support.apple.com/102330)
- [Apple QA1312: Bonjour service types (retired)](https://developer.apple.com/library/mac/qa/qa1312/_index.html)
- [9to5Mac: AirPort discontinued, how to reset (2018)](https://9to5mac.com/2018/04/26/how-to-reset-airport-base-station/)

## Contributors

- Initial spec from public community sources
