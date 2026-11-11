# FOREO Peach 2 (IPL hair removal)

> **Status**: Capture verified (stock app; no replacement-client replay)
> **Protocol**: BLE
> **Manufacturer**: FOREO AB (active; cloud not required for local control)

## Safety

!!! danger "IPL can permanently damage skin and eyes"
    This handset emits intense pulsed light, up to 7.3 J/cm². Misuse can cause burns,
    blistering, discoloration, scarring or serious eye injury. Patch-test first, match
    intensity to skin tone, never treat broken, tanned, tattooed or moled skin, and keep
    it away from eyes. This project is experimental and unaffiliated; FOREO's manual and
    safety guidance govern. Do not bypass the skin-contact or eye-safety interlocks.

- [Manufacturer safety guidance](https://www.foreo.com/mysa/find-out-if-peach-2-is-suitable-for-you)
- [Archived safety guidance](https://web.archive.org/web/20260831005900/https://www.foreo.com/mysa/find-out-if-peach-2-is-suitable-for-you)

## Overview and evidence

The Peach 2 family — Peach 2, go, Pro MAX and Duo — uses BLE and the FOREO For You
app. Static analysis of app 4.4.1 (559) recovered the offline activation algorithm,
command dialects and app-side subscription enforcement.

A 2026-11-07 Android HCI capture then recorded two stock-app connections to an
already-activated PEACH2 running `PEACH2 F.REV.K`. It confirms the FFF0 GATT layout,
security-access write, no-pairing session, 0A20 read, new-dialect intensity/mode writes,
and seven-byte cooling profile. It does **not** show a locked-unit activation, Pro-mode
write or replacement client implementing this spec.

Two findings remain important but have different evidence levels:

1. **Offline unlock is app-derived.** Static analysis shows that the activation bytes
   are a keyless permutation of the device BLE MAC, so the cloud registration call is
   not needed by the firmware. The captured unit already returned activation state 01,
   so the actual locked-unit write was not verified.
2. **Pro mode is gated by the app, but direct firmware acceptance is unknown.** Normal
   Pro selection requires an active eligible subscription; a separate testing flag
   bypasses that UI branch. Once permitted, the app writes `0ad0 06`. The capture has
   seven Basic writes (`0ad0 01`) and no Pro write, so it proves neither a downgrade nor
   firmware behavior outside the entitlement path. Security access on 0A10 is not a Pro
   unlock token.

## Initial setup

| Property | Value |
|----------|-------|
| Setup required | No network provisioning; locked units need BLE activation |
| Exact configured names | `PEACH2`, `PEACH2GO`, `PEACH2Duo`, `PEACH2ProMAX` |
| Reported aliases | `PEACH 2`, `PEACH™ 2`, `PEACH2 Pro MAX` |
| Pairing / bond | None |
| Offline setup confidence | Security/read path capture-confirmed; activation write reported |

1. Select the model and scan for its **exact** configured name. The app disables fuzzy
   matching and uses a 30-second timeout. It also interprets an activation-state marker
   from the raw advertisement; the specific flag in this capture is undecoded.
2. Connect without bonding and discover services. FFF0 contains FFF1, 0A10 and 0A20 on
   the captured firmware.
3. Write security access `01 a1 <MAC[3]> <MAC[4]> <MAC[5]>` to 0A10. The live write
   matched this derivation exactly; the app retries up to three times. After the ATT
   Write Response, it waits **500 ms** and validates no challenge response. This is
   connection setup, not Pro activation.
4. Read SW revision 2A28. The captured suffix `K` selects the new dialect.
5. Read 0A20. If it starts with `00`, static analysis says to write
   `01 02 <8-byte chipId>`. If it already starts with `01`, do not rewrite it.
6. Only if 0A30 exists, read it and write `01` when wake-up is not already enabled.
   The captured new-dialect unit did not expose 0A30; do not make this step mandatory.

PEACH2/GO/Pro Max skip the stock app's **pre-connect device-information API** lookup.
That is only a local scan exception: account registration is a separate later step and
its complete server behavior is not established by this research.

### chipId derivation (app-derived)

With MAC bytes `m0…m5` in printed order and
`b = [m5, m4, m3, 0, 0, m2, m1, m0]`, all arithmetic mod 256:

```text
out[0] = (b[2] & 0x0f) | (b[7] & 0xf0)
out[1] = (b[5] & 0x0f) | (b[1] & 0xf0)
out[2] = (b[7] & 0x0f) + (0xf0 - (b[6] & 0xf0))
out[3] = 0xff - b[6]
out[4] = b[5] + 1
out[5] = (b[1] & 0x0f) + (0xf0 - (b[2] & 0xf0))
out[6] = (b[0] & 0x0f) | (b[5] & 0xf0)
out[7] = (b[6] & 0x0f) | (b[0] & 0xf0)
```

Documentation-only MAC `aa:bb:cc:dd:ee:ff` gives security access
`01 a1 dd ee ff`, chipId `ad ec 4a 44 cd 2e cf fb`, and activation write
`01 02 ad ec 4a 44 cd 2e cf fb`. The unit's real MAC, serial and activation value are
not published in this repository.

**Factory reset** is unknown. **Rebinding** needs no reset: scan, connect and run the
security handshake from the new client. There is no bond to forget.

## Protocol summary

FFF1 commands are raw `opcode || payload`, with `0a` for set and `0b` for query. Write
the query, then **read FFF1 back**. `ff ff ff ff` means busy; the app retries up to
five times. Observed settings writes returned an 18-byte value beginning `01`.

### Captured GATT structure

| UUID | Role |
|------|------|
| `0000fff0-0000-1000-8000-00805f9b34fb` | Command and security service, confirmed |
| `0000fff1-0000-1000-8000-00805f9b34fb` | Command channel, read + write |
| `00000a10-0000-1000-8000-00805f9b34fb` | Security access, read + write |
| `00000a20-0000-1000-8000-00805f9b34fb` | Activation, read + write |
| `00000a02-0000-1000-8000-00805f9b34fb` | Serial number; 14 ASCII bytes read, no write attempted |
| `00000a0c-0000-1000-8000-00805f9b34fb` | Accelerometer input; 180 one-byte reads, axes/units unknown |
| `00000a18-0000-1000-8000-00805f9b34fb` | Body NTC; 165 one-byte notifications, units unknown |
| `00000a19-0000-1000-8000-00805f9b34fb` | Head NTC; 110 one-byte notifications, units unknown |
| `00000a0d-0000-1000-8000-00805f9b34fb` | Vibrator setting; 15 one-byte notifications, vocabulary unknown |
| `0000181c-0000-1000-8000-00805f9b34fb` | Separate service containing 0A05 |
| `0000180a-0000-1000-8000-00805f9b34fb` | Standard device information |

FFF0 also contains direct 0A01/0A02/0A03/0A04/0A06/0A08/0A09/0A40/0A44/0A50/0AF0
characteristics. The spec records their live properties. The roles of 0A44 and 0A09 are
undecoded. Notably, **0A08 is read + notify**, not an OTA-trigger write on this unit.

The captured normal-mode table had no 0A30, 0A07, Battery Service `0x180f`, TI OAD or
D0FF service. Their behavior on other firmware or in a separate update mode remains
unknown.

Client integration: `protocol_handler: ipl_foreo` selects the mobile setup
surface for security access, conditional activation and wake-up. Activation
requires the actual BLE MAC address; platforms that expose only a
CoreBluetooth UUID must not substitute it.

### Commands

| Command | Meaning | Evidence |
|---------|---------|----------|
| `0a 01 <level>` | Set intensity 0–5 | Levels 3 and 5 captured |
| `0b 01` | Read intensity, first byte | Returned 5 |
| `0a d0 01` | Basic removal mode | Seven captured writes |
| `0a d0 06` | Pro removal mode | App constant; not captured, direct acceptance unknown |
| `0b d0` | Read mode; 01 Basic, ≥6 Pro | Basic captured |
| `0a c0 0a` | Automatic fan | Accepted on new-dialect unit |
| `0a c4 <7 bytes>` | New cooling profile | Several captured; mapping incomplete |
| `0b c4 00 07` | Read seven-byte cooling profile | Captured; 18-byte response |
| `0a c0 <value>` | Old single-byte cooling write | Static analysis |
| `0b c0` | Old cooling read | Static analysis |
| `0a a2 <mode ×5>` | Old flash mode and separate Duo path | App constants; Duo Basic/Pro not captured |
| `0b a2` | Old flash-mode read | Static analysis |

The cooling profile is not a one-byte level. One wire example is
`0a c4 14 0d 21 02 1c 14 14`; it is evidence of the seven-byte layout, not a universal
recommended setting. Read the current profile first and do not send arbitrary values
on an IPL device. A separate `0a b1 a5` write was accepted after calibration polling,
but its semantics are unknown.

Duo Basic is `0a a2 02 02 02 02 02`; Duo Pro is `0a a2 03 03 03 03 03`. These are
model-specific app constants, not observed traffic. Duo's Pro switch is hidden in the
app.

## Cloud dependency

No cloud is needed for the captured local control path. FOREO's servers handle account
registration and subscription entitlement. Offline locked-unit activation is
implementable from static analysis but unverified. Pro's confirmed entitlement gate is
in the app; direct firmware acceptance outside that path is unknown.

## Open questions

- Locked-unit activation and persistence, plus the exact advertisement activation flag.
- Registration-server behavior after the PEACH2/GO/Pro Max pre-connect API exception.
- Direct Pro-mode acceptance, Duo command behavior and old-dialect suffix edge cases.
- Cooling-profile fields, NTC/accelerometer/vibrator conversion, other notification
  streams and the 0AB1 write.
- Temperature/NTC/voltage payload layouts and read-back formats.
- OTA entry, image transfer, update-mode identity and recovery; 0A08 is not a verified
  trigger.
- Single-central exclusivity and whether any model exposes a remote-fire command.

## References

- [FOREO PEACH 2 manual](https://www.foreo.com/manuals/peach-2)
- [FOREO For You on Google Play](https://play.google.com/store/apps/details?id=com.foreo.foreoapp)
- Analysis APK: `com.foreo.foreoapp` 4.4.1 (559), SHA-256 `90a4ec8f5c22c1085d1500f6bf1954c28edcd81531f0eed94bf8a13aa494ae79`
