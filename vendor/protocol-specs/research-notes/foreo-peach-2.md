# FOREO Peach 2 (IPL) — Research Notes

## What this is

The FOREO Peach 2 is a mains-powered IPL hair-removal device with BLE. Companion app:
**FOREO For You** (`com.foreo.foreoapp`), analyzed at 4.4.1 (versionCode 559), base APK
SHA-256 `90a4ec8f5c22c1085d1500f6bf1954c28edcd81531f0eed94bf8a13aa494ae79`.
Family code paths cover Peach 2, Peach 2 go, Peach 2 Pro MAX and Peach 2 Duo.

Two app-derived findings motivate the spec:

- **Offline unlock.** The locked-unit activation bytes are a keyless permutation of the
  device BLE MAC. The vendor server records registration for warranty bookkeeping; its
  response does not feed those bytes. A replacement client should be able to activate a
  locked unit without network access.
- **App-side Pro paywall.** Normal Pro selection requires an active subscription in the
  stock app; a separate `testing == 1` flag bypasses that UI branch. Once permitted,
  the app writes `0AD006`. Whether firmware accepts that write outside the entitlement
  path is unknown. Security access on 0A10 is connection setup, not a Pro unlock token.

Neither finding is fully capture-verified: the live unit was already active and only
Basic mode was written. The authoritative spec marks these commands `reported`.

## Hardware capture — 2026-11-07

An owner-supplied Android HCI snoop (`foreoPeach2.pcapng`, SHA-256
`b301ad5b7d29608989238cc05945e6f12b428adb5e3dd529771dd888508f5021`)
recorded two stock-app connections to an already-activated PEACH2 running
`PEACH2 F.REV.K`. This is stock-app capture evidence, not a replacement-client replay.

The capture confirms:

- FFF0 contains FFF1, 0A10 and 0A20. The earlier stand-in 0A20 service was wrong.
- 0A10 is read + write and the captured security-access value matched the documented
  MAC derivation exactly.
- 0A20 began 01, so no activation write occurred.
- The stock app read a 14-byte ASCII serial from 0A02. The value is deliberately not
  reproduced here.
- New-dialect intensity 3/5, Basic mode, automatic fan and several seven-byte cooling
  profiles were accepted. Queries used the documented FFF1 write-then-read model.
- No SMP exchange or MTU request occurred.

Important negative findings and corrections:

- 0A05 belongs to a separate 0x181c service and was not used; it is not the serial read
  on this firmware.
- 0A30, 0A07, Battery Service 0x180f, TI OAD and D0FF were absent from normal-mode
  discovery. A setup client must not require 0A30.
- 0A08 is read + notify, not a verified OTA-trigger write. Do not write it as one.
- New cooling writes are `0AC4` plus seven bytes, not a one-byte value. `0BC4 0007`
  returned the current profile in an 18-byte read-back.
- Calibration produced repeated one-byte 0A0C reads and an accepted `0AB1 A5` write;
  its meaning is unknown. Other one-byte notification streams are also undecoded.

## Scan-to-add findings from the 2026-11-08 app comparison

The 4.4.1 implementation and a newly acquired 4.2.0 comparison build agree on the
following. The comparison bundle's SHA-256 is
`304f62e696975c580248dd3c1d63034f1e66a0177f8d4498dc6777144b4fd2a5`; JADX reported
69 errors elsewhere in the bundle, so only the matching PEACH2 paths are used.

- Configured names are exact: `PEACH2`, `PEACH2GO`, `PEACH2Duo` and `PEACH2ProMAX`.
  Fuzzy matching is disabled and the scan timeout is 30 seconds. Earlier spaced and
  trademark forms remain aliases, not a reason to match every PEACH-prefixed device.
- The scan handler derives activation state from the raw advertisement using an
  address-derived marker and a following nibble ending in 1 or 0. Inactive and OTA
  devices publish immediately; already-active devices accumulate for later filtering.
  The specific flag in this capture was not independently decoded.
- PEACH2/GO/Pro Max skip the normal pre-connect device-info API request and publish the
  scanned device directly. Account registration is a separate later step, so this
  exception does not prove registration unnecessary.
- Security access is connection setup, not Pro activation. After the ATT Write
  Response, the app waits 500 ms and validates no challenge response before continuing.
- Normal Pro selection requires an active subscription; `testing == 1` is a separate
  vendor-test exception. Once allowed, Pro writes `0AD006`. The capture contains seven
  Basic writes and no Pro write, so direct firmware acceptance outside the entitlement
  path remains unknown.
- Duo uses repeated 0AA2 mode bytes: Basic `0AA2 02 02 02 02 02` and Pro
  `0AA2 03 03 03 03 03`. Neither was captured, and Duo's Pro switch is hidden in the app.

A sanitized derivative, `peach2/evidence/capture-analysis-2026-11-08.json`, records 27
writes/responses, 210 reads/responses and 517 notification packets without addresses,
serials or the raw security payload.

## GATT map on the captured firmware

| UUID | Access | Role |
|---|---|---|
| `FFF0` | service | Command and security service |
| `FFF1` | read + write | Command channel; 26 acknowledged writes and 26 reads |
| `0A10` | read + write | Per-connect security access; one acknowledged write |
| `0A20` | read + write | Activation; two reads, no activation write |
| `0A02` | read + write | Serial number; one 14-byte read, no write |
| `0A18` | read + write | Body NTC; 165 one-byte notifications, units unknown |
| `0A19` | read + write | Head NTC; 110 one-byte notifications, units unknown |
| `0A0C` | read + notify | Accelerometer; 180 one-byte reads, axes/units unknown |
| `0A0D` | read + notify | Vibrator setting; 15 one-byte notifications, vocabulary unknown |
| `0A09` | read + notify | Unknown; 13 one-byte notifications |
| `0A44` | read + notify | Unknown; 214 one-byte notifications |
| `0A08` | read + notify | Role unknown; not an established OTA trigger |
| `0x181c / 0A05` | read + write | Separate direct characteristic, role unknown |
| `0x180a / 2A28` | read | SW revision and dialect selection |

FFF0 also exposes direct 0A01/0A03/0A04/0A06/0A40/0A50/0AF0 characteristics. The
machine-readable spec records their exact live properties and traffic. No semantics are
invented for them.

## Command protocol

FFF1 carries raw `opcode || payload`: `0A` for set, `0B` for query. Write the command,
then **read FFF1 back**. A read-back beginning `ff ff ff ff` means busy; the app retries
up to five times. Observed settings writes returned an 18-byte value beginning `01`.

| Command | Meaning | Evidence |
|---|---|---|
| `0A01 <level>` | Set intensity 0–5 | Levels 3 and 5 captured |
| `0B01` | Read intensity, first byte | Returned 5 |
| `0AD0 01` | Basic removal mode | Seven captured writes |
| `0AD0 06` | Pro removal mode | App constant; not captured, direct acceptance unknown |
| `0BD0` | Read mode; 01 Basic, ≥6 Pro | Basic captured |
| `0AC0 0A` | Automatic fan | Accepted on new-dialect unit |
| `0AC4 <7 bytes>` | New cooling profile | Several captured; mapping incomplete |
| `0BC4 0007` | Read seven-byte cooling profile | Captured |
| `0AC0 <value>` | Old single-byte cooling write | Static analysis |
| `0BC0` | Old cooling read | Static analysis |
| `0AA2 <mode ×5>` | Old flash mode and separate Duo path | App constants; Duo Basic/Pro not captured |
| `0BA2` | Old flash-mode read | Static analysis |
| `0AB2/0BB2` | Temperature-enable set/read | Opcodes only; set payload unknown |
| `0AB4/0BB4`, `0AB5/0BB5` | Head/body NTC threshold set/read | Opcodes only |
| `0AD1/0BD1` | Flash voltage table set/read | Opcodes only |

One observed cooling write is `0A C4 14 0D 21 02 1C 14 14`. This demonstrates the
seven-byte profile length, not a universally safe or recommended setting. Read the
current profile first and do not send arbitrary values on an IPL device.

The captured suffix `K` selects the new dialect. Static analysis says Peach 2 go and
Pro MAX use the new path; Duo instead uses repeated 0AA2 mode bytes even though the
broader new-dialect rules apply to it. Duo Basic is `0AA2 02 02 02 02 02`, Duo Pro is
`0AA2 03 03 03 03 03`, and neither was captured. Plain Peach 2 uses old when its suffix
is `a`–`c`. Old-dialect behavior and other suffix edge cases remain unverified.

## Connection and offline activation

1. Scan for a PEACH-family name, connect without bonding and discover services.
2. Write `01 A1 <MAC[3]> <MAC[4]> <MAC[5]>` to 0A10 after every service discovery.
   The app retries up to three times; this step is capture-confirmed.
3. Read SW revision 2A28.
4. Read 0A20. Static analysis says that if it begins `00`, write
   `01 02 <8-byte chipId>`. If it already begins `01`, do not rewrite it.
5. Only if 0A30 exists, read it and write `01` if wake-up is not enabled. The captured
   unit did not expose 0A30 and instead proceeded to the 0A02 serial read.

### chipId derivation (app-derived)

For MAC bytes `m0…m5` in printed order, let
`b = [m5, m4, m3, 0x00, 0x00, m2, m1, m0]`. All arithmetic is mod 256:

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

No key, nonce or server input is involved. With documentation MAC
`aa:bb:cc:dd:ee:ff`, the expected security-access write is `01 a1 dd ee ff`, chipId is
`ad ec 4a 44 cd 2e cf fb`, and the full activation write is
`01 02 ad ec 4a 44 cd 2e cf fb`. `scripts/test_foreo_peach2_spec.py` independently
transcribes and checks these vectors.

## Paywall and cloud

Normal Pro selection requires both the subscription flag and an active subscription
state. A separate `testing == 1` flag bypasses the inactive-subscription UI branch. Once
allowed, the app writes `0AD006`; Basic is `0AD001`. Static analysis says a non-Duo
device reporting mode >= 6 with an inactive subscription is switched back to Basic.
The capture contains seven Basic writes and no Pro write, so it proves neither this
downgrade nor direct firmware acceptance outside the entitlement path. Security access
on 0A10 is not a Pro unlock token.

Cloud hosts seen in static analysis include `apiadmin.foreo.com`, `appadmin.foreo.com`
and `www.foreo.com/api/…`. Product registration is account-scoped. None of the response
feeds the MAC-derived unlock. No cloud is needed for the captured ordinary local
control path, but complete registration-server behavior after the pre-connect API
exception remains unmapped.

## Remaining questions

- Locked-unit advertising and the exact activation-bit value, 0A20 locked value,
  activation write and persistence.
- Registration-server behavior after the PEACH2/GO/Pro Max local scan exception.
- Direct Pro-mode acceptance, Duo command paths, old-dialect behavior and 0A30 on
  firmware that exposes it.
- Cooling-profile fields, NTC/accelerometer/vibrator conversion, 0AB1 and the unknown
  0A44/0A09 streams.
- Temperature/NTC/voltage payload layouts and read-back formats.
- OTA entry, image fetch/transfer, update-mode identity and recovery.
- Single-central exclusivity and whether any model exposes a remote-fire command.

The corrected authoritative spec is `device-specs/devices/foreo-peach-2.yaml`; the
owner-facing summary is `docs/devices/foreo-peach-2.md`.
