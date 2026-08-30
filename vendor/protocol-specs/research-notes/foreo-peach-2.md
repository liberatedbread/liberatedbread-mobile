# FOREO Peach 2 (IPL) — Research Notes

## What This Is

The FOREO Peach 2 is a mains-powered IPL (intense pulsed light) hair-removal
device with BLE connectivity. Companion app: **FOREO For You**
(`com.foreo.foreoapp`), analyzed at version **4.4.1 (versionCode 559)**,
sha256 of base APK `90a4ec8f5c22c1085d1500f6bf1954c28edcd81531f0eed94bf8a13aa494ae79`.

The device ships **locked**: it will not turn on until "registered" from the
app. The headline finding of this note:

> **The unlock is fully computable offline.** The bytes the app writes to the
> device to unlock it are derived only from the device's own BLE MAC address
> via a fixed, keyless permutation. The FOREO server is used to *record* the
> registration (warranty bookkeeping); the stock app sequences BLE activation
> after that server call succeeds, but the firmware requires nothing from the
> server. A replacement app can unlock a brand-new Peach 2 with zero network
> access.

Separately, the app gates the Peach 2 family's **"Pro" removal mode** behind a
paid subscription (server-side Recurly entitlement) — but enforcement is
**app-side only**: the firmware accepts the Pro-mode command unconditionally.
See "Paywall" below.

Device family covered by the same code path: Peach 2, Peach 2 go, Peach 2 Pro
MAX, Peach 2 Duo (BLE-advertised names `PEACH2`, `PEACH 2`, `PEACH2GO`,
`PEACH2ProMAX`, etc.).

## Transport

- BLE (GATT), Telink-based chipset. No pairing/bonding (the app never bonds).
- No MTU negotiation on the Peach connect path; 20-byte writes suffice.
- Advertised names: `PEACH2`, `PEACH 2`, `PEACH™ 2`, `PEACH2GO`,
  `PEACH2ProMAX` / `PEACH2 Pro MAX`.
- Custom 16-bit UUIDs on the standard Bluetooth base
  (`0000xxxx-0000-1000-8000-00805f9b34fb`). The app resolves the *service*
  dynamically from the discovered GATT table (characteristic `FFF1` is very
  likely under service `FFF0`; confirm on hardware).

## GATT map (Peach-relevant)

| UUID (16-bit) | Access | Role |
|---|---|---|
| `FFF1` | write + read | **Command channel.** All Peach commands written here; answers read back from the same characteristic |
| `0A10` | write | **Security access** — session handshake, written once after every service discovery |
| `0A20` | read + write | **Activate** (unlock/register) |
| `0A30` | read + write | **Wake-up** |
| `0A05` | read | Serial number |
| `0A07` | read | Chip ID |
| `0A0C` | read | Skin-sensor / accelerometer polling (calibration) |
| `0A08` | write | OTA trigger (reboot into OTA mode) |
| `2A28` | read | SW revision — read at every connect; selects old/new command dialect |
| `2A19` | read + notify | Battery level (mains device; still exposed) |
| `2A24/2A26/…` | read | Standard DIS |

Also present in the app: TI OAD service `f000ffc0-0451-4000-b000-000000000000`
(chars `…ffc1`/`…ffc2`) for firmware update after the OTA reboot, and legacy
Telink service `0000d0ff-3c17-d293-8e48-14fe2e4da212` (declared, apparently
unused in 4.4.1). Peach OTA firmware images are referenced under an OTA path
on the vendor's CDN; whether 4.4.1 can actually OTA a Peach is unconfirmed.

## Command format

No framing: no header, length, or checksum. Writes to `FFF1` are raw
`opcode || payload` bytes:

- First byte `0A` = write/set, `0B` = read/query; second byte = sub-opcode.
- Query protocol: write `0B xx`, then **read `FFF1` back** and parse the
  returned bytes. If the read-back starts with `FFFFFFFF` the device was busy;
  the app retries (≤5).
- Every write is verified by reading `FFF1` back the same way.

### Opcode table (Peach)

| Command (hex) | Meaning |
|---|---|
| `0A01 <level>` | Set IPL intensity, 1 byte, levels **0–5** (six levels) |
| `0B01` | Read IPL intensity (first byte of read-back) |
| `0AC4 <val>` | Set cooling/fan level (new firmware; value via firmware-specific map) |
| `0AC0 <val>` | Set cooling level (old firmware); `0AC0 0A` = auto-fan |
| `0BC0` / `0BC40007` | Read cooling level (old / new) |
| `0AD0 01` / `0AD0 06` | Removal mode: **Basic** / **Pro** (new firmware) |
| `0BD0` | Read removal mode (`>= 6` ⇒ Pro) |
| `0AA2 0202020202` / `…0303030303` / `…0101010101` | Flash mode Basic / Pro / Face (old firmware; mode byte repeated 5×) |
| `0BA2` | Read flash mode |
| `0AB2/0BB2` | Temperature-enable set/read |
| `0AB4/0BB4` | Head-NTC (temperature) threshold set/read |
| `0AB5/0BB5` | Body-NTC threshold set/read |
| `0AD1/0BD1` | Flash voltage table set/read |

Dialect selection: Peach 2 go / Pro MAX / Duo always use the new dialect; a
plain Peach 2 uses the old dialect when the last character of its SW revision
(`2A28`) is `a`–`c`, otherwise new.

## Connection + unlock sequence (offline-reproducible)

1. Connect (no bonding), discover services.
2. **Security access**: write `01 A1 <MAC[3]> <MAC[4]> <MAC[5]>` to `0A10`
   (last 3 bytes of the device's own BLE MAC). Retried ≤3; required before the
   device answers other commands.
3. Read SW revision `2A28` → device ready.
4. **Activation (only needed on a locked/factory device)**: read `0A20`; if the
   value starts with byte `00`, write `01 02 <8-byte chipId>` to `0A20`. Then
   read `0A30`; unless it starts with `01`, write `01` (wake-up enabled).
   Activation is idempotent — the stock app re-runs it on every connect.

### chipId derivation (verified from app code)

`chipId` is a fixed, keyless permutation of the 6-byte BLE MAC
(`m0 m1 m2 m3 m4 m5`, in the usual printed order). Let:

```
b = [m5, m4, m3, 0x00, 0x00, m2, m1, m0]
```

Then the 8 output bytes are (all arithmetic mod 256):

```
out[0] = (b[2] & 0x0F) | (b[7] & 0xF0)
out[1] = (b[5] & 0x0F) | (b[1] & 0xF0)
out[2] = (b[7] & 0x0F) + (0xF0 - (b[6] & 0xF0))
out[3] = 0xFF - b[6]
out[4] = b[5] + 1
out[5] = (b[1] & 0x0F) + (0xF0 - (b[2] & 0xF0))
out[6] = (b[0] & 0x0F) | (b[5] & 0xF0)
out[7] = (b[6] & 0x0F) | (b[0] & 0xF0)
```

No key, no nonce, no server input — pure MAC arithmetic. Example with
placeholder MAC `AA:BB:CC:DD:EE:FF` (scrubbed; compute on hardware).

(Other FOREO models use an older variant: `01 01 <ASCII serial number>` to the
same characteristic. Peach uses the chip-id variant.)

## Paywall (the "charges to unlock" question)

- The app has **no in-app purchase store integration**; monetization is a
  server-side subscription (Recurly) bought via an in-app web flow.
- "Pro mode" is a **software mode on the same device**, not distinct hardware:
  the Basic/Pro mode UI is shown for Peach 2 go / Pro MAX always, and for a
  plain Peach 2 when its firmware is new (SW revision not ending in `a`–`g`);
  it is hidden on Peach 2 Duo. (Distinct from the "Peach 2 Pro MAX" *model*,
  which is a separate hardware SKU.)
- Subscription status is fetched from the vendor API, cached locally, and
  checked in the UI. If the device reports Pro mode while no subscription is
  active, **the app writes Basic mode back to the device** — enforcement lives
  entirely in the app.
- The Pro-mode command (`0AD0 06`) is a static constant; the firmware accepts
  it without any credential. A replacement app writes Pro mode directly.
- The same app-side-only pattern gates features on other FOREO devices (e.g.
  BEAR microcurrent treatment steps take the subscription flag as a plain
  boolean argument).
- Intensity levels 0–5 and Basic mode are **not** paywalled.

## Cloud surface (bookkeeping only)

Hosts seen: `apiadmin.foreo.com`, `appadmin.foreo.com`, `www.foreo.com/api/…`.
Device registration = account-scoped POST under `users/{uuid}/product_registration`;
requires login (session expiry forces re-login). None of the response data
feeds the BLE unlock bytes. Offline replacement-app flow: skip all of it.

## Feasibility

- **Confirmed by static analysis: offline unlock YES, offline Pro mode YES,
  offline intensity/mode/cooling control YES.**
- Remaining to verify on hardware (user plans to buy a unit): exact service
  UUID containing `FFF1` (hypothesis `FFF0`), advertised-name/MAC behavior of
  a factory-locked unit (does it advertise before activation? — the app finds
  it, so presumably yes), read-back formats for `0BD0`/`0BC4…`, OTA path.

## Evidence

- App: FOREO For You 4.4.1 (559), base APK sha256
  `90a4ec8f5c22c1085d1500f6bf1954c28edcd81531f0eed94bf8a13aa494ae79`
  (APKPure via apkeep, 2026-08-29).
- Decompile + working notes: `~/research/ipl/` (not committed).
- Vendor manual (peach-2) confirms ship-locked behavior and registration
  requirement; also confirms 5-level hardware buttons vs 6 app levels.

## Open questions

- Does a factory-locked Peach 2 answer the security-access write and `0A20`
  read immediately, or is a first-connect delay involved?
- Old vs new dialect detection edge cases (SW revision suffixes beyond `a`–`c`).
- Whether OTA applies to Peach in current app/firmware.
- FOREO Bear 2 (microcurrent, same app): same activation + subscription
  pattern per code structure; worth a follow-up note if a unit is acquired.
