# Common OBD-II / Vehicle Diagnostic Patterns

Cars, motorcycles and an increasing number of "smart" powersports vehicles expose a
diagnostic connector. Unlike a BLE gadget, almost nothing interesting on that connector
is standardised: the legislated OBD-II layer only covers emissions data. Everything an
owner actually wants — service interval reset, TPMS programming, ABS bleed, live sensor
data — sits in manufacturer-specific territory on top of the same transport.

That is the same shape as the rest of this repo: an open transport, a closed application
layer, and a paid tool in between.

!!! note "Scope: repair, not just research"
    This page exists to support **repair-café and owner-maintenance work** — clearing a
    service reminder after an oil change, reading fault codes, programming a replacement
    TPMS sensor. Those are writes, they are legitimate, and documenting them is the point.

    Functions that need real expertise — ECU coding, module flashing, immobiliser and key
    work — are **documented too, and flagged `advanced`**. Picking up a neglected bike is
    exactly when you need them: a second-hand cluster must be coded, a replacement ECU
    married to the immobiliser, a half-written flash recovered. The flag means "know the
    recovery path first", not "we won't tell you".

    Genuinely off the table: nothing on a vehicle in motion, and no falsifying a recorded
    odometer — that one is fraud in most jurisdictions rather than a technical risk. Brake
    and ABS procedures continue in the vehicle's service manual, not a protocol doc. See
    [Working a repair café](#working-a-repair-cafe) below.

## Layer cake

| Layer | What lives there | Standards |
|-------|------------------|-----------|
| Connector | Physical socket and pinout | SAE J1962 (16-pin, cars + older bikes), ISO 19689 (6-pin, Euro 5 bikes) |
| Physical/link | Signalling on the wire | ISO 9141-2, ISO 14230-4 (K-line), ISO 11898 (CAN), SAE J1850 |
| Transport | Segmentation of >7 byte payloads | ISO 15765-2 ("ISO-TP") |
| Application (legislated) | Emissions data, DTCs | ISO 15765-4 / SAE J1979 — "OBD-II modes" `01`–`0A` |
| Application (manufacturer) | Everything else | ISO 14229 ("UDS"), or a vendor dialect of KWP2000 |

The useful rule of thumb: **if a function is not emissions-related, it is not in the
OBD-II mode list, and you are looking at UDS or a vendor dialect.**

## Connectors

### SAE J1962 (16-pin)

The familiar trapezoid. Pins that matter:

| Pin | Signal |
|-----|--------|
| 4 | Chassis ground |
| 5 | Signal ground |
| 6 | CAN-H (ISO 15765-4) |
| 7 | K-line (ISO 9141-2 / ISO 14230-4) |
| 14 | CAN-L (ISO 15765-4) |
| 15 | L-line (rarely populated) |
| 16 | Battery +12 V (usually unswitched) |

Manufacturer-discretionary pins (1, 3, 8, 9, 11, 12, 13) are where vendors hide extra
buses. Do not assume they are unused.

### ISO 19689 (6-pin)

Euro 5 pushed motorcycles onto a compact sealed connector — JST MWT series, water-tight,
mounted under the seat per EU regulation 44/2014. Community-reported pinout
(**unverified against the paywalled standard**):

| Pin | Signal |
|-----|--------|
| 2 | CAN-H |
| 3 | Ground |
| 4 | Battery +12 V |
| 5 | CAN-L |

Pins 1 and 6 are optional/manufacturer-defined; K-line appears on one of them for bikes
that still carry a K-line ECU. 6-pin-to-J1962 adapter leads are commodity parts, which
means a bike with the new connector is still reachable with a normal OBD-II adapter —
provided the vendor did not also move the data.

## ISO-TP framing

Any UDS payload longer than 7 bytes is segmented by ISO 15765-2. This is the single most
common reason a cheap adapter "connects but the function fails".

| Frame | First byte(s) | Meaning |
|-------|---------------|---------|
| Single | `0L` | `L` = payload length (1–7), payload follows |
| First | `1LLL` | 12-bit total length, 6 payload bytes follow |
| Flow control | `3S BS ST` | Receiver's clear-to-send, block size, separation time |
| Consecutive | `2N` | `N` = sequence number 1–15, wrapping |

An 8-byte request therefore leaves the tester as two frames with a flow-control frame
coming back from the ECU in between. Clone ELM327 firmware frequently gets the transmit
side of this wrong, or ignores the ECU's requested separation time, which is why vendor
tools specify particular adapters by name.

## Application layer: the two dialects

### Legislated OBD-II modes

| Mode | Function |
|------|----------|
| `01` | Current powertrain data (PIDs) |
| `03` | Stored DTCs |
| `04` | Clear DTCs / MIL |
| `09` | Vehicle info (`09 02` = VIN) |

Broadcast request ID is `0x7DF` (functional); ECUs answer on `0x7E8`–`0x7EF`. Physical
addressing to the first ECU is `0x7E0` → `0x7E8`.

### UDS (ISO 14229) — where the interesting functions live

| Service | Name | Typical use in an owner-facing function |
|---------|------|------------------------------------------|
| `10` | DiagnosticSessionControl | `10 03` extended session — unlocks non-default services |
| `27` | SecurityAccess | `27 01` request seed, `27 02` send key |
| `22` | ReadDataByIdentifier | `22 <DID hi> <DID lo>` — read a value (odometer, service counter) |
| `2E` | WriteDataByIdentifier | `2E <DID> <data>` — write a value |
| `31` | RoutineControl | `31 01 <RID>` start a routine (bleed, calibrate, **reset**) |
| `3E` | TesterPresent | `3E 00` keepalive so the session does not time out |
| `11` | ECUReset | `11 01` hard reset |

A positive response echoes the service byte `+ 0x40` (`22` → `62`). A negative response
is `7F <service> <NRC>`; `7F .. 31` = request out of range, `7F .. 33` = security access
denied, `7F .. 7F` = service not supported in active session. Those three NRCs tell you
most of what you need while probing.

**The shape of nearly every "reset" function** is therefore:

```text
10 03                    -> 50 03 ...          enter extended session
27 01                    -> 67 01 <seed>       request seed        (if locked)
27 02 <key>              -> 67 02              answer challenge    (if locked)
3E 00 (every ~2 s)       -> 7E 00              keep session alive
31 01 <RID> [params]     -> 71 01 <RID> ...    run the reset routine
   or
2E <DID> <new value>     -> 6E <DID>           write the new counter
```

Finding the function means finding which of those last two it is, and with which
identifier. That is a search problem, not a cryptography problem.

## Classifying OBD-II devices

Two questions decide everything about an OBD-II device spec, so both are explicit fields
in `device-specs/schema.json`.

### 1. What is the device? (`obd.role`)

| Role | Meaning | Example |
|------|---------|---------|
| `vehicle` | The thing being diagnosed | [Triumph Tiger 900](../devices/triumph-tiger-900.md) |
| `adapter` | The dongle bridging a host to the connector | [OBD-II Bluetooth adapters](../devices/obd2-bluetooth-adapter.md) |
| `module` | A single ECU or accessory documented on its own | An ABS modulator, a TPMS receiver |

### 2. What can the adapter do? (`obd.adapter_profile.class`)

Adapters are not interchangeable, and "it connected" tells you almost nothing about
whether a given function will work. Four tiers:

| Class | Hardware | Reliably provides | Falls over on |
|-------|----------|-------------------|---------------|
| `basic-clone` | Cloned firmware, usually badged "ELM327 v2.1" | `single_frame` | Multi-frame transmit, client flow control, sometimes `ATCAF0` |
| `standards-elm327` | Genuine ELM327 v1.4/1.5 | `single_frame`, `multiframe_rx`, `custom_headers` | Multi-frame transmit and tight timing are firmware-dependent |
| `advanced-stn` | OBDLink LX / MX / MX+ / CX (STN11xx–STN22xx), UniCarScan UCSI-2100 (Cortex-M0) | adds `multiframe_tx`, `flow_control`, `raw_frames`, ST commands | Little; this is what vendor tools name when a function must work |
| `native-can` | SocketCAN, CANable, PCAN, Kvaser | adds `monitor_all`, `non_standard_bitrate` | Nothing — no AT layer between you and the bus |

The capability tokens are the useful part. A request declares what it `requires`, an
adapter declares what it `provides`, and a consumer can answer "will this dongle run this
command?" before connecting rather than failing halfway through a write:

| Capability | Meaning |
|------------|---------|
| `single_frame` | Payloads of 7 bytes or fewer |
| `multiframe_rx` | Reassembling segmented replies (ISO 15765-2) |
| `multiframe_tx` | **Sending** segmented requests — where clone firmware fails |
| `flow_control` | Client-supplied flow control (`ATFCSH`/`ATFCSD`/`ATFCSM`) |
| `custom_headers` | Arbitrary request/filter IDs (`ATSH`/`ATCRA`) |
| `raw_frames` | Auto-formatting off (`ATCAF0`); client does its own ISO-TP |
| `monitor_all` | Passive bus sniffing (`ATMA`) |
| `alt_can_bus` | Manufacturer buses on non-standard pins — Ford MS-CAN, GM SW-CAN. Only the OBDLink MX / MX+ / EX provide it, and FORScan needs it for body and chassis modules |
| `non_standard_bitrate` | Buses outside the legislated OBD-II rates |

### 3. Basic or advanced? (`command_class` per request)

| Class | What it covers | Adapter needed |
|-------|----------------|----------------|
| `basic` | Legislated OBD-II — SAE J1979 modes `01`, `03`, `09`. Single-frame, no session, no security. | Anything, clones included |
| `advanced` | Everything else: UDS and manufacturer dialects, non-default sessions, security access, custom headers, multi-frame, and every write. | `advanced-stn` in practice |

The schema defaults `command_class` to `advanced`, so an unclassified request is never
assumed to be the harmless kind.

**This split is a diagnostic tool in itself.** When a vendor accepts any adapter for
reading codes but names a specific one for a maintenance function, they have told you the
function is `advanced` — multi-frame, custom-headered, or session-gated — before you have
captured a single byte. That inference is what pins down the shape of the
[Tiger 900 service reset](../devices/triumph-tiger-900.md) despite the bytes still being
unknown.

Useful ELM327/STN AT commands when probing:

```text
ATZ            reset
ATE0           echo off
ATSP6          protocol 6 = ISO 15765-4, 11-bit, 500 kbit/s
ATSH 7E0       set request header (physical addressing)
ATCRA 7E8      accept only this response ID
ATFCSH 7E0     flow-control header
ATFCSD 30 00 00  flow-control data (BS=0, STmin=0)
ATFCSM 1       use our flow control settings
ATST 64        timeout 100 ms
ATCAF0         CAN formatting off — raw frames, you do ISO-TP yourself
```

`ATCAF0` is the one that matters for research: with auto-formatting off you see exactly
what a vendor tool would have to send.

## Working a repair café {#working-a-repair-cafe}

The functions in this repo divide cleanly by how much can go wrong, and that division is
more useful on a bench than a blanket warning.

| Tier | Functions | Notes for a volunteer |
|------|-----------|-----------------------|
| **Routine** | Service interval / date reset, read DTCs, clear DTCs, read live data, read identity | Reversible or re-derivable. A service reset writes a counter the owner could have paid a dealer to write. Clear DTCs only *after* recording them |
| **Care needed** | TPMS sensor ID programming, instrument menu and unit settings, throttle-body balance readings, adaptation resets | Correct but fiddly; a wrong TPMS ID means a warning light, not a hazard. Record the previous value first |
| **Service-manual territory** | ABS modulator bleed | A brake procedure that happens to be triggered over the connector. Follow the manual, and do not hand the bike back without a lever-feel check |
| **Advanced** (`advanced: true`) | ECU coding, module flashing, immobiliser and key operations, adaptation writes | Documented, because reviving an old bike needs them — a replacement cluster has to be coded, a used ECU has to be married to the immobiliser, a corrupted flash has to be rewritten. Have the recovery path ready before you start: know how to re-flash, keep the original coding dump, and expect a module that is unusable until you finish |

Practical notes that come up at every event:

- **Get the owner's consent for each write**, and tell them what changed. A service
  reminder that reappears at the next interval is expected behaviour, not a fault.
- **Record before you write.** Read the current service distance and date first — it is
  one command and it turns a mistake into an undo.
- **Battery.** These dongles draw from an unswitched pin. Unplug before the bike leaves,
  and watch voltage during long sessions; `ATRV` is one command.
- **Engine off, ignition on** for most functions. Anything needing the engine running says
  so explicitly, and then it needs ventilation.
- **One adapter that works** beats three that half-work. See the
  [adapter tiers](#classifying-obd-ii-devices) — for motorcycle service work an STN-based
  or UniCarScan adapter avoids most of the "it connected but the function failed" dead ends.
- **Right to repair.** Reading and resetting maintenance data on a vehicle with the
  owner's permission is ordinary repair work. The reason it needs documenting at all is
  that the information was locked up, not that the act is exotic.
- **Advanced work needs an exit plan.** Before coding or flashing anything: dump the
  current coding, know which tool re-writes it, and be honest with the owner that the bike
  may not start again this afternoon. That is the difference between advanced and
  reckless — not whether the function is documented.

## Vendor ECU-description files

Before reverse-engineering a frame by hand, check whether the manufacturer already
describes it. Most do, in a machine-readable file that their own tools consume:

| Format | Extension | Used by |
|--------|-----------|---------|
| EDIABAS SGBD | `.prg` | BMW — one compiled description per ECU variant |
| EDIABAS group | `.grp` | BMW — dispatches to the right `.prg` when the variant is unknown |
| ODX / PDX | `.odx`, `.pdx` | The ISO 22901 standard container; most European OEMs |
| CANdela | `.cdd` | Vector toolchain, common at suppliers |
| A2L | `.a2l` | ECU measurement and calibration (ASAM MCD-2 MC) |
| CAN database | `.dbc` | Broadcast bus decoding, not diagnostics |

These define jobs, results, ECU addresses, scaling and DTC text — the very things a
capture only tells you indirectly. The BMW result names recovered from MotoScan
(`STAT_SERVICE_KMSTAND_DATA` and friends) **are** SGBD result names, so the cluster's
`.prg` is where their units and scaling are authoritatively defined.

Specs reference them with `obd.description_files` at the vehicle level and per ECU, and
requests link to a specific `job` and its `results`. That turns a hand-decoded byte offset
into a lookup against the definition:

```yaml
ecus:
  - name: "KOMBI (instrument cluster)"
    description_files:
      - type: "sgbd-prg"
        name: "KOMBI.prg"
        provides: ["jobs", "results", "ecu_address", "scaling"]
        source: "EDIABAS/INPA/ISTA installation (ECU directory)"
requests:
  - name: "read_odometer"
    request: "22 E1 19"
    results: ["STAT_SERVICE_KMSTAND_DATA"]
```

**Name them, do not redistribute them.** These files are vendor copyright. `source` says
where a licensed copy comes from — an EDIABAS/INPA/ISTA installation, a workshop tool
bundle — and `sha256` pins the exact file a fact was derived from. A repair café that owns
a licensed diagnostic installation already has them; this repo just tells you which file
answers which question.

## Capture methodology

Ranked cheapest-first. The first option needs no CAN hardware at all and reuses the
Android capture workflow already used elsewhere in this repo.

1. **btsnoop the tool↔adapter link.** Vendor Android tools (TuneECU and friends) talk to
   a Bluetooth adapter over RFCOMM/SPP. Enable *Developer options → Enable Bluetooth HCI
   snoop log*, run the paid function once, pull `btsnoop_hci.log`, and open it in
   Wireshark. Because the ELM327 protocol is ASCII, the AT commands **and** the hex
   payloads are directly readable in the RFCOMM stream. This yields the exact request
   bytes without touching the vehicle bus.
2. **Passive CAN log across a known-good run.** T-tap CAN-H/CAN-L at the diagnostic
   connector, `candump -L can0 > before.log` while idle, run the vendor function, and
   diff. Vendor tool traffic is physically addressed, so filtering to `0x7E0`/`0x7E8`
   cuts the noise immediately.
3. **DID sweep.** With the vehicle stationary, walk `22 <DID>` across the manufacturer
   range and record every DID that answers `62`. Values that look like the odometer, the
   service-due distance, or a date are the write targets. Read-only, reversible, and it
   maps the address space before anything is written.
4. **Routine enumeration — last, and with care.** `31 01 <RID>` *executes* things. Do not
   sweep it blindly. Only invoke an RID recovered from an actual capture.

## What to write down

For each function, this repo wants the derived facts, not the vendor's binary:

- transport (`ISO 15765-4`, bitrate, 11- or 29-bit), request/response CAN IDs
- session and security prerequisites
- the request bytes, the positive response, and observed NRCs on failure
- which ECU actually owns the data (engine ECU vs instrument cluster vs ABS module)
- timing constraints (keepalive interval, post-write settle time)

## Worked examples

- [OBD-II Bluetooth Adapters](../devices/obd2-bluetooth-adapter.md) — the dongle itself:
  GATT families, Classic SPP, the AT/ST command set, and how to capture through it
- [Triumph Tiger 900](../devices/triumph-tiger-900.md) — service interval reset (SIA)
