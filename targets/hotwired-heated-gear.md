# HOTWIRED 12V Bluetooth Heated Gear — target spec starter

## Target metadata
- target_id: hotwired-heated-gear
- app package_id(s):
  - Android: `com.hotwired.mec` ("HOTWIRED Heated Gear App", publisher **Comoto Holdings, Inc.**)
  - iOS: `id1634504597` (same app, App Store)
- device class: BLE heated apparel controller (12V motorcycle jacket liner / pant liner / gloves)
- transport(s): BLE (heating controller integrated into the garment, not a separate dongle)
- local-only viability: **high** — the app talks directly to the garment over BLE; heat control has no
  plausible cloud dependency. Account/cloud features (if any) should be optional.

## Known facts (public + observed)

### Product line
HOTWIRED is Comoto Holdings' house brand for heated riding gear (Comoto owns RevZilla, Cycle Gear,
and J&P Cycles), so the hardware is almost certainly white-label/ODM-built to spec rather than
designed in-house. The `mec` segment of the package ID is likely the ODM's initials or product
codename — confirm from the APK manifest and native library names.

- **12V Bluetooth Heated Jacket Liner**
  - 6 carbon-fiber heating zones: 1 back, 2 chest, 2 sleeve, 1 collar
  - 74 W / 6.2 A draw at 12 V (wired to the motorcycle battery via SAE-style lead)
  - Integrated "smart soft touch" inline controller with **3** heat levels
  - App control offers **10** heat levels — i.e. the BLE protocol exposes finer granularity than
    the physical button does
  - Connector wires for HOTWIRED heated gloves; Y-splitter (sold separately) daisy-chains pants
- **12V Bluetooth Heated Pant Liner** — same platform, fewer zones
- **Heated gloves** — powered/controlled through the jacket liner's connectors, so they are very
  likely *not* independent BLE peripherals (validate: do gloves advertise separately?)

### App
- Version 1.1 (build 8), last updated 2024-01-02, ~15 MB, Play category "Sports", 1,000+ installs
- Play description: "Connect your Hotwired Integrated Heating System with Bluetooth and control the
  desired temperature right from your phone!"
- Still listed on both stores as of this writing (unlike the Gerbing Thermogauge app — see
  `gerbing-thermogauge.md`), but a 1,000-install, single-vendor app with a small dev budget is
  exactly the kind of thing that gets orphaned. Public reviews already cite Bluetooth connection
  drops and app instability, which is a second motivation for a replacement client.

### Prior art
- **None found.** No public reverse engineering of the HOTWIRED BLE protocol, no GitHub projects,
  no Home Assistant integration. This is greenfield RE.
- The closest documented neighbours in this repo are `admore-light-bar` (motorcycle BLE accessory,
  Flutter app) and `motool-slacker` (motorcycle BLE tool on an HM-10-class serial module) — expect a
  similar cheap-BLE-module shape here.

## Device discovery signals
- BLE:
  - advertised name patterns (UNKNOWN — to be discovered by scan): likely "HOTWIRED", "HW-*",
    "Heated*", or the raw module default (e.g. "BT05", "JDY-*", "HMSoft") if the ODM never changed it
  - service UUIDs: UNKNOWN — primary RE objective. Check first for the usual serial-bridge suspects:
    `0xFFE0`/`0xFFE1` (HM-10/CC254x), `0xFFF0` family, Nordic UART
    (`6e400001-b5a3-f393-e0a9-e50e24dcca9e`)
  - address behavior: likely public static (budget consumer module, no privacy rotation)
  - the garment is only powered when the bike's harness is live — the controller will not advertise
    on a bench unless you feed it 12 V
- Wi-Fi: not applicable

## Threat model + guardrails

**This is the highest-risk device class in this repo so far. Treat it as safety-relevant.**

- Scope: only gear you own, on your own bike, never worn while experimenting with unvalidated writes.
- **Burn risk.** These are resistive heating elements held against the body. A command that pins the
  element to maximum duty cycle, or that disables a firmware thermal cutback, can cause contact burns
  — and the wearer's own cold-numbed skin is a poor sensor. Never bench-test an unknown write while
  wearing the garment.
- **Fire/electrical risk.** 6.2 A continuous through garment wiring; a stuck-on state on an
  unattended garment is a real hazard. Assume the vendor firmware has a watchdog and do not assume a
  replacement client inherits it.
- **Vehicle electrical load.** Sustained 74 W (plus gloves/pants on the same circuit) is a meaningful
  fraction of a small bike's charging headroom. Document the draw; do not exceed the stock fuse.
- Explicit non-goals:
  - Do **not** attempt to raise output beyond the levels the stock app exposes, remove duty-cycle
    limits, or defeat any thermal/timeout protection found in firmware.
  - Do **not** ship a replacement client without a fail-safe: loss of BLE link must drive heat to
    off (or to the last *user-confirmed* level with a bounded timeout), never to "hold forever".
  - Do not document how to disable safety interlocks even if the RE uncovers them; record that they
    exist and leave it there.
- Any replacement app must make "off" reachable in one tap and must show the current commanded level
  unambiguously — a stale UI on a heat device is a safety bug, not a cosmetic one.

## First experiments (do these first)

### Phase 1: APK static analysis (no hardware needed)
1. Fetch the APK:
   ```bash
   ./scripts/fetch_apks_apkeep.sh com.hotwired.mec
   ```
2. Decompile and grep for protocol hints:
   ```bash
   ./scripts/run_static_target.sh hotwired-heated-gear
   ```
   Look for:
   - UUID literals (8-4-4-4-12) in `strings.xml`, DEX, and any `libapp.so`/`libflutter.so`
   - `BluetoothGatt`, `BluetoothLeScanner`, `writeCharacteristic`, or plugin names
     (`flutter_blue`, `react-native-ble-plx`, `cordova-plugin-ble-central`)
   - Scan filters — the name prefix or service UUID the app filters on is the cheapest possible win
   - Level tables: 10 app levels have to map to *something*; look for a 10-entry array of bytes or
     percentages
3. Identify the framework. If it is Flutter, command construction is AOT-compiled and only the UUIDs
   will be statically recoverable (see `motool-slacker.md` for how that dead-end was recorded) —
   plan on an HCI capture.
4. Try to identify the ODM: manifest package prefixes, native lib names, leftover sample strings, or
   an FCC ID string in the app. If the ODM also sells the same module to other heated-gear brands,
   one RE covers several products.

### Phase 2: BLE scan (needs the garment + 12 V)
5. Power the garment from a bench supply or the bike, then:
   ```bash
   ./scripts/detect_devices.sh
   ```
   Record advertised name, service UUIDs, manufacturer data, and address type both with the inline
   controller off and on — some designs only advertise once the button wakes the controller.

### Phase 3: HCI snoop (the decisive step)
6. Enable Bluetooth HCI snoop log in Android Developer Options, then perform **one action per
   capture**, clearing between: connect → level 1 → level 5 → level 10 → off → disconnect.
7. Also capture: what the app shows when the inline button is pressed physically (does the garment
   *notify* state changes, or does the app poll?).
8. Analyze in Wireshark (`btatt` filter); extract service discovery, every write, and every
   notification.

### Phase 4: Validation
9. Replay captured writes with nRF Connect **on an unworn garment, on a bench supply, with a
   thermometer or IR camera on the element and someone present.** Log element temperature against
   commanded level so the replacement app can ship real limits, not guesses.
10. Sweep the level byte across its range to map the space — but stop at the maximum the stock app
    emits and record where that boundary is.

## Protocol hypotheses (to validate)
- Pairing/bonding: "Just Works" or no bonding at all; no PIN expected on a budget module
- Session state machine: connect → (optional handshake) → write level → optional notify of
  state/battery/temperature → disconnect. Likely stateless per-write.
- Commands (expected surface):
  - set heat level (0–10, or 0–100 %, or an enum of 11 states)
  - set zone/garment (jacket vs pants vs gloves — if the app addresses them separately rather than
    the jacket relaying)
  - query status (current level, possibly bus voltage or element temperature)
  - off / all-off
- Payload encoding: short fixed-length frames — header (e.g. `0xAA`/`0x55`/`0x7E`), command byte,
  level byte, checksum (XOR or sum), terminator. Compare against the ELK-BLEDOM and Govee framings
  already documented in `docs/protocols/ble-common.md`.
- Keep-alive: **specifically look for one.** A heat device that stops heating when the phone walks
  away implies a periodic keep-alive write; if the protocol has one, a replacement client must
  implement it *and* must not accidentally implement a "hold heat forever" bug.
- Timing constraints: level changes are human-paced (no tight timing), but any keep-alive interval
  must be measured precisely.

## Control surface inventory (what the replacement app must support)
### Onboarding/pairing UX
- BLE scan filtered by name/service UUID; connect; remember the device; auto-reconnect on ride start
### Core controls (MVP)
- Heat level 0–10 (with the physical controller's 3 levels shown as equivalents)
- Explicit, always-visible OFF
- Per-garment control if the protocol addresses jacket/pants/gloves independently
- Connection state and last-acknowledged level
### Safety behaviours (not optional)
- Link-loss fail-safe (heat off or bounded timeout)
- Session timeout / auto-off after N minutes without user interaction
- Refuse to command a level above the stock app's maximum
### Nice to have
- Bus voltage / battery warning if the controller reports it
- Ride profiles (e.g. drop level at highway speed) — phone-side logic only
### Error handling and recovery
- GATT write failure → retry with backoff, and surface the failure rather than silently keeping the
  last commanded level on screen
- Controller unresponsive → tell the user to power-cycle at the harness
### Settings persistence
- Bonded device address, last level (restored only after explicit user confirmation, never auto-applied)

## Evidence checklist
- [ ] APK hash + version code for `com.hotwired.mec`
- [ ] App framework identified (native / Flutter / RN / Cordova)
- [ ] Service + characteristic UUIDs (static and/or from scan)
- [ ] Advertised name pattern and scan filter used by the app
- [ ] HCI snoop: connect, each of the 10 levels, off, physical-button interaction
- [ ] Notification payloads decoded (status/battery/temperature, if any)
- [ ] Keep-alive presence/absence and interval
- [ ] Bench thermal log: commanded level vs measured element temperature
- [ ] ODM/module identification (chipset, FCC ID if traceable)

## Spec output (clean-room)
Write a derived spec in:
- `docs/specs/hotwired-heated-gear.md` — message formats, UUIDs, level table, examples, tests
- `device-specs/devices/hotwired-heated-gear.yaml` once the UUIDs are confirmed (schema-validated;
  do **not** publish invented opcodes — follow the `motool-slacker.yaml` precedent of shipping
  UUIDs only when command bytes are not yet recovered)
- The spec must carry the safety limits (max level, keep-alive semantics, fail-safe behaviour)
  alongside the wire format; a heat protocol documented without its limits is incomplete.

## References (URLs only)
- https://play.google.com/store/apps/details?id=com.hotwired.mec
- https://apps.apple.com/us/app/hotwired-heated-gear/id1634504597
- https://www.revzilla.com/motorcycle/hotwired-12v-bluetooth-heated-jacket-liner
- https://www.jpcycles.com/product/hotwired-12v-bluetooth-heated-pant-liner
- https://www.revzilla.com/heated-gear-temperature-controllers
- https://www.appbrain.com/app/hotwired-heated-gear-app/com.hotwired.mec
