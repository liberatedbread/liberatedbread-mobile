# BMW Motorcycle Diagnostics (MotoScan)

> **Status**: In Progress (addressing, data model and reset payloads recovered; hardware confirmation pending)
> **Protocol**: OBD-II connector — BMW D-CAN (ISO 15765-4 with `0x6F1` addressing), KWP2000, UDS
> **Manufacturer**: BMW Motorrad
> **Manufacturer Status**: Active (protocol closed; owner-facing functions are dealer- or paid-tool-gated)

## Overview

The same problem as the [Triumph Tiger 900](triumph-tiger-900.md): a service interval an
owner cannot reset from the bike. The tool that does it is MotoScan
(`de.wgsoft.motoscan`, WGSoft.de), and the findings below come from decompiling it.

There is a neat structural tell here. **MotoScan's vendor also sells the UniCarScan
UCSI-2100 adapter**, whose headline feature is accepting messages up to 255 bytes where a
stock ELM327 stops at 8. That is not a general-purpose selling point — it is what BMW's
coding and adaptation writes need. The adapter told us something about the protocol before
the app was opened.

!!! note "Verification level"
    Derived from the shipped app, not yet reproduced on a bike — `verification: reported`.
    The APK was fetched with `apkeep` and its signature checked before analysis: it is
    signed by `O = WGSoft.de, CN = Wladimir Gurskij`, i.e. the genuine vendor build rather
    than a repack. MotoScan is a free download; the full feature set is an in-app purchase,
    so no cracked build is needed or was used.

!!! note "Repair-café scope"
    The service reset is a write and is meant to be used — stationary bike, engine off,
    owner's consent, values read back first. ECU coding is flagged `advanced` rather than
    excluded: a second-hand module has to be coded to the bike before it works at all.
    Dump the existing coding first. See
    [Working a repair café](../protocols/obd2-common.md#working-a-repair-cafe).

## Addressing — BMW's `0x6F1` scheme

BMW does not use per-ECU CAN IDs the way Triumph does. The tester transmits on a **single
ID, `0x6F1`**, and the target ECU address is carried as the first payload byte via CAN
extended addressing. Each ECU answers on `0x600 + its address`.

MotoScan's init sequence, parameterised by the target address (`<aa>`):

```text
ATSPB                  select the ELM327 user-defined protocol
ATPBC101               protocol B options C1 01
ATSH6F1                transmit header 0x6F1 (BMW tester address)
ATFCSH6F1              flow-control header 0x6F1
ATFCSD<aa>300008       flow-control data: target, BS=0x00, STmin=0x08
ATFCSM1                use our flow control
ATCEA<aa>              CAN extended addressing — target ECU address
ATCM7FF                mask 0x7FF
ATCF6<aa>              filter to 0x6<aa>, this ECU's reply ID
ATST90                 timeout
ATBI                   bypass the standard init
STCSEGT1 / STCFCPC     STN-only segmentation + flow-control tuning
```

Three consequences worth stating plainly:

- **`ATCEA` is mandatory.** Extended addressing is not something clone firmware reliably
  implements, and without it every BMW ECU is unreachable. This — not multi-frame alone —
  is why MotoScan's adapter list is short.
- The scheme is *uniform*: every module is reached the same way, with only `<aa>` changing.
  That makes enumerating modules straightforward compared to Triumph's four bespoke stacks.
- `STCSEGT1`/`STCFCPC` are STN-only, so an STN adapter takes a faster path, while the
  UCSI-2100 achieves the same end through its long-message mode.

## Service interval model

MotoScan exposes four reset scopes (`Cu$m` in the decompile):

| Value | Meaning |
|-------|---------|
| `SI_ALL` | Reset every service counter |
| `SI_DATE` | Reset the date-based interval only |
| `SI_MILEAGE` | Reset the distance-based interval only |
| `SI_DATE_CAR` | Date variant used for the car-style cluster |

That distance/date split is the same one the Triumph work uncovered, which is now looking
like an industry pattern rather than a Triumph quirk.

The service data itself is named in the embedded diagnostic database:

| Identifier | Holds |
|------------|-------|
| `STAT_SERVICE_KMSTAND_DATA` | Odometer reading at last service |
| `STAT_SERVICE_DATUM_DATA` | Service date (composite) |
| `STAT_SERVICE_JAHR_WERT` / `_MONAT_WERT` / `_TAG_WERT` | Service year / month / day |
| `STAT_VENTILSPIELSERVICE_RESTWEG_WERT` | Distance remaining to the valve-clearance service |
| `STAT_VENTILSPIELSERVICE_ANZAHL_RESET_WERT` | How many times the valve service has been reset |
| `STR_VENTILSPIELSERVICE_RESET` | The valve-service reset itself |

BMW tracks a **separate valve-clearance service** with its own remaining-distance counter
and reset count — a second interval on top of the usual oil service, and the reset counter
means the bike remembers how often it has been zeroed.

## Modules

The embedded database uses BMW's SGBD naming (`STAT_*` results, `ECU_ID*` identity).
Motorcycle modules seen include:

| Short name | Module |
|------------|--------|
| `KOMBI` | Instrument cluster — owns the service and odometer data |
| `ZFE` | Central body electronics |
| `BMS` | Engine management |
| `ABS` | Brake modulator |
| `RDC` | Tyre pressure monitoring |
| `DWA` | Alarm system |
| `ILAF` | Adaptive headlight |

Also present: oil level and oil temperature sensing (`STAT_OELNIVEAU`,
`STAT_OELSTANDSANZEIGE`, `STAT_TEMPERATUR_OEL_WERT`, ADC voltages for the level and temp
senders), and reset counters for several subsystems.

## Adapter classification — from the vendor's own code

MotoScan carries an adapter enum that is, in effect, third-party validation of the
[capability tiers](obd2-bluetooth-adapter.md#capability-tier) this repo uses:

```text
ELM327_CLONE   ELM327_ORIGINAL   ELM327_UNKNOWN
OBDLINK_LX     OBDLINK_MX        OBDLINK_MX_PLUS     OBDLINK_MX_WIFI
UCSI_2000      (UI text: "UCSI-2000/2100", "UniCarScan")
```

The app distinguishes a **clone** from an **original** ELM327 at runtime and treats them
differently. A tool shipping clone detection is the strongest possible statement that the
tier distinction is real and load-bearing.

## The service reset — plain UDS on a BMW DID family

The reset payloads turned out **not** to be in the native library. `libmotoscan-helper.so`
holds the ECU description database — job and result names, localised parameter text — but
the frames themselves are built in Kotlin, in the control-unit class for the UDS-capable
cluster family. Only that one family implements the reset; the older families return
"not supported".

Every operation is standard UDS against the manufacturer DID range `0xE1xx`:

### Writes

| Scope | Request | Fields |
|-------|---------|--------|
| `SI_DATE_CAR`, `SI_ALL` | `2E E1 2B <hh> <mm> <ss> <dd> <MM> <yyyy hi> <yyyy lo>` | Sets the cluster clock from the current time |
| `SI_DATE`, `SI_ALL` | `2E E1 2C <dd> <MM> <yyyy hi> <yyyy lo>` | Next service date |
| `SI_MILEAGE`, `SI_ALL` | `2E E1 2D <km hi> <km lo>` | Service distance, **plain uint16 kilometres** |

Each write is issued with a 2000 ms timeout and a 1500 ms settle before the next, so a
`SI_ALL` reset is three writes spread over roughly five seconds.

### Reads

The read side matches the write layouts exactly, which is the best internal consistency
check available without a bike. Payload starts at offset 3 in every reply:

| Request | Reply length | Layout |
|---------|--------------|--------|
| `22 E1 19` | 7 | uint32 at offset 3 — odometer |
| `22 E1 2B` | 10 | `hh` @3, `mm` @4, `ss` @5, `dd` @6, `MM` @7, `yyyy` @8–9 — clock |
| `22 E1 2C` | 7 | `dd` @3, `MM` @4, `yyyy` @5–6 — service date |
| `22 E1 2D` | 5 | uint16 at offset 3 — service distance |

### At the bench

```text
# 1. Connect to the target module (<aa> = its address)
ATZ  ATE0  ATL0  ATH1
ATSPB  ATPBC101
ATSH6F1  ATFCSH6F1  ATFCSD<aa>300008  ATFCSM1
ATCEA<aa>  ATCM7FF  ATCF6<aa>  ATST90  ATBI

# 2. RECORD FIRST
22 E1 19                odometer
22 E1 2C                current service date
22 E1 2D                current service distance

# 3. Reset — the tool writes the clock first, then the values
2E E1 2B hh mm ss dd MM yy yy      set cluster clock
2E E1 2C dd MM yy yy               next service date
2E E1 2D km_hi km_lo               service distance (plain km)

# 4. Read back
22 E1 2C   /   22 E1 2D
```

Allow ~1.5 s between writes; MotoScan does, and the sequence is three writes over roughly
five seconds. Ignition on, engine off.

**Module addresses are not published, so scan for them.** The `6F1` scheme makes this
cheap: every module is reached identically with only `<aa>` changing, so sweeping the
address space and asking each for the standard VIN DID finds the live ones. Anything that
answers — positively *or* with a negative response code — is a module that exists.

```bash
# Find the modules on this bike. Read-only.
python scripts/obd_discover.py --port /dev/rfcomm0 --bmw-scan 0x00-0x7F

# Read service state from one of them (the cluster owns it).
python scripts/obd_discover.py --port /dev/rfcomm0 --bmw-module 0x60
```

That closes the gap between "we know the frames" and "a volunteer can use this": the scan
supplies the one value the decompile did not.

### Why this matters against the Triumph result

Same owner-facing function, opposite mechanism:

| | Triumph Tiger 900 | BMW (MotoScan) |
|---|---|---|
| Mechanism | Proprietary 2-byte frame, no ISO-TP | Standard UDS `2E` WriteDataByIdentifier |
| Address | Cluster on its own CAN ID `0x701` | Cluster via BMW `6F1` extended addressing |
| Distance encoding | `distance / 100` in one byte | Plain uint16 kilometres |
| Session / security | None | None observed for the service DIDs |
| Clock | Must be set beforehand, by the rider | Written by the tool as part of the reset |

**My earlier four hypotheses were wrong for Triumph and right for BMW.** The
WriteDataByIdentifier guess that failed on the Tiger 900 is exactly what BMW does. That is
worth remembering as a methodological point: the plausible-by-convention answer is a
coin flip, and only the capture settles it.

## Other diagnostic surface

Also recovered from the same code:

- **Read DIDs** beyond the service family: `F150`, and a low range including `0001`,
  `0004`, `0007`, `0009`, `0011`, `0012`, `0024`, `0031`, `0032`, `0033`, `0060`, `0062`,
  `0063`, `0064`, `0067`, `0070`, `0071`, `0090`, `0100`, `0101`, `0150`.
- **Other writes**: `2E 62 40 …` and `2E 64 40 …`.
- **RoutineControl** used extensively in the form `31 FA <routine> <sub>` — note the
  BMW-specific `FA` sub-function byte where UDS would normally carry `01`/`02`/`03`.
  Routine groups `FA 0C`, `FA 0D`, `FA 13` (sub-IDs 1–21) and `FA 14` appear.
- Utility identifiers `UTIL_UDS_BMSX_ADAPTION_RESET` and `UTIL_UDS_BMSX_ADAPTION_EARN_DONE`
  for engine adaption resets.

## The shortcut we have not taken: the SGBDs

Everything above was recovered by hand from a shipped app. BMW already describes these
modules formally, in EDIABAS SGBD files — `KOMBI.prg` and friends, selected by `.grp`
group files. The result names in MotoScan's embedded database are SGBD result names, which
means the cluster SGBD defines, authoritatively:

- the module address (the `<aa>` this page still lists as unknown)
- the job that each frame implements, and the results it returns
- scaling and units for every result, rather than the offsets decoded here
- DTC text

Anyone with a licensed EDIABAS/INPA/ISTA installation has these files already. Reading
`KOMBI.prg` would settle the open questions faster than another capture, and the spec now
has `description_files` entries ready to record exactly which file answered what. The
files are vendor copyright — reference them, never redistribute them.

## What is still unknown

1. **Module addresses** — the `<aa>` values MotoScan probes for each ECU.
2. **The `31 FA` routine semantics.** The frames are recorded above; what each routine
   does is not, and RoutineControl executes things, so these must not be guessed at
   against a vehicle.
3. **The valve-clearance service path.** `STR_VENTILSPIELSERVICE_RESET` and
   `STAT_VENTILSPIELSERVICE_RESTWEG_WERT` are named in the native database but no matching
   `E1xx` DID has been tied to them yet — it may run through the job engine rather than a
   direct DID write.
4. **Hardware confirmation** with read-back of `22 E1 2D`.

## Tools Used

- [x] `apkeep` fetch of `de.wgsoft.motoscan` + signature verification (genuine WGSoft build)
- [x] DEX string-pool extraction and jadx decompile (8708 classes)
- [x] Native-library string survey and ELF structure (`libmotoscan-helper.so`: 3.7 MB
      `.rodata` against 1.8 MB `.text`, stripped, string-in/string-out JNI surface)
- [x] Recovered the service reset and read frames from the Kotlin control-unit classes
- [ ] Module address enumeration and `31 FA` routine semantics
- [ ] Hardware confirmation with read-back

## References

- [MotoScan (WGSoft.de)](https://www.motoscan.de/)
- [MotoScan on Google Play (`de.wgsoft.motoscan`)](https://play.google.com/store/apps/details?id=de.wgsoft.motoscan)
- [UniCarScan UCSI-2100 — 255-byte messages, BMW protocols](https://www.wgsoft.de/unicarscan-ucsi-2100)

## Contributors

- APK acquisition, signature verification, decompile and native-string survey
