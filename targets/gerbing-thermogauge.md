# Gerbing / Gyde Thermogauge Bluetooth Controller — target spec starter

## Target metadata
- target_id: gerbing-thermogauge
- app package_id(s):
  - Android: `com.gyde.thermogauge` ("Gerbing Heated Clothing – Thermogauge")
    — **unpublished from Google Play on 2024-04-05**
  - iOS: companion app of the same name, also gone from the App Store
- device class: BLE heated apparel controller (inline Bluetooth adapter for 7 V and 12 V heated gear)
- transport(s): BLE (app minSdk is Android 4.3 — the exact release that introduced Android BLE
  support, so this is GATT, not Bluetooth Classic/SPP)
- local-only viability: **high** — the adapter is an inline power controller between the battery/bike
  harness and the garment; heat control cannot depend on a network

## Why this target matters

This is the canonical OpenGreenIoT case: **the hardware is discontinued and the app is gone.**
Owners who still have a Thermogauge adapter on their jacket have a working piece of hardware whose
only control surface has been removed from both app stores. There is no vendor path back — a
replacement client is the only way this gear keeps working past the next phone replacement.

Contrast with `hotwired-heated-gear.md`, where the vendor app is still live: this one is already
orphaned, which makes it the higher-priority of the two.

## Known facts (public + observed)

### Hardware
Gerbing (and its Gyde-branded battery-powered line) sold Thermogauge Bluetooth adapters in two
electrical families, in single- and dual-output variants:

- **12 V Thermogauge Bluetooth adapter** — motorcycle gear, powered from the bike harness; pairs
  multiple 12 V garments through the controller
- **7 V Thermogauge Bluetooth adapter** — Gyde battery-powered garments (jackets, vests, puffers)
- **Dual-zone / Dual Bluetooth controller** — two independently controlled outputs (e.g. jacket +
  gloves, or jacket + pants)

Vendor-stated behaviour, from product listings:
- **4 optimized heat settings** (some listings describe finer app-side adjustment "with a single
  swipe" — resolve whether the wire protocol carries 4 discrete states or a wider range that the UI
  quantizes)
- Maintains the set temperature throughout use (i.e. the controller does closed-loop or duty-cycle
  regulation itself — the phone is a remote, not the regulator)
- App reports **battery status** (meaningful on the 7 V battery gear) and can **lock the garment to
  a specific temperature**
- Distinct product, do not confuse: Gerbing also sold a **12 V Wireless Temp Controller Remote**,
  which is an RF remote, not Bluetooth, and is out of scope here.

### App
- `com.gyde.thermogauge`, publisher "Gerbing Heated Clothing"
- Last release **v1.07 (build 107), April 2020**; an earlier v1.05 dates to August 2016
- ~29 MB, minSdk Android 4.3+, 1,000+ installs
- Store description: "a Bluetooth remote control for your heated garment" — when synced with a
  Gerbing/Gyde Bluetooth controller, adjust heat settings, check battery status, and lock the
  garment to a temperature
- **Unpublished 2024-04-05.** `apkeep` cannot fetch it from Play; see acquisition below.

### Prior art
- **None found.** No public RE of the Thermogauge BLE protocol, no GitHub project, no HA integration.
- A 2016-era, Android-4.3-minimum app is likely native Java with a hand-rolled GATT wrapper — a much
  friendlier static-analysis target than the Flutter apps in `admore-light-bar` and `motool-slacker`.
  Command bytes may well be recoverable from DEX alone, without any live capture.

## APK acquisition (this target's first real obstacle)

The app is not on Play, so the standard path does not work:

1. **Best: pull from a device that still has it.**
   ```bash
   ./scripts/pull_apks_adb.sh com.gyde.thermogauge
   # or directly:
   adb shell pm path com.gyde.thermogauge
   adb pull <path>/base.apk workspace/apks/adb/com.gyde.thermogauge.apk
   ```
   Ask in the heated-gear/motorcycle communities — 1,000+ installs means copies exist on phones.
2. **Fallback: third-party APK archives** (apkcombo/apkpure/APKMirror list v1.07). Treat these as
   untrusted: record the SHA-256, compare across at least two mirrors, and note in the evidence log
   that provenance is unverified. Never install a mirror APK on a daily-driver phone — use a
   throwaway device or emulator, and only for static analysis if provenance stays unconfirmed.
3. Record whichever route was used in the evidence checklist; the clean-room rules in
   `docs/CLEANROOM_RULES.md` still apply to whatever binary you end up with.

## Device discovery signals
- BLE:
  - advertised name patterns (UNKNOWN — to be discovered): likely "Thermogauge", "Gerbing", "Gyde",
    "TG-*", or an unchanged module default ("HMSoft", "BT05", "Bluno") given the 2016 design date
  - service UUIDs: UNKNOWN — primary RE objective. A 2016 BLE accessory very likely uses a serial
    bridge module: check `0xFFE0`/`0xFFE1` (HM-10/CC254x), `0xFFF0`/`0xFFF1-6`, Nordic UART
    (`6e400001-b5a3-f393-e0a9-e50e24dcca9e`), or a TI SensorTag-style custom 128-bit service
  - address behavior: expect public static
  - the 12 V adapter only advertises when the harness is live; the 7 V adapter needs its garment
    battery installed
- Wi-Fi: not applicable

## Threat model + guardrails

**Same safety class as `hotwired-heated-gear` — resistive heating worn against the body.**

- Scope: only gear you own; never bench-test unvalidated writes on a worn garment.
- **Burn risk.** The vendor controller regulates temperature itself and the app is only a remote.
  That means a badly formed write could plausibly change the *setpoint the controller regulates to*,
  or (worse) drop it into an unregulated pass-through state. Probe conservatively: measure element
  temperature on the bench before trusting any newly discovered opcode.
- **Fire/electrical risk.** Unattended stuck-on heat is the failure mode that matters. Assume nothing
  about firmware watchdogs until observed.
- **Battery gear (7 V).** Li-ion packs driving a resistive load: an over-current or over-discharge
  state is not just an inconvenience. Do not attempt to alter charge behaviour or cell protection.
- Explicit non-goals:
  - Do **not** try to exceed the 4 vendor heat settings, defeat the temperature-lock feature, or
    remove duty-cycle/thermal limits.
  - Do **not** ship a replacement client without a link-loss fail-safe (heat off, or bounded timeout).
  - Document that protections exist; do not document how to bypass them.
- Replacement clients must show the commanded setpoint unambiguously and put OFF one tap away.

## First experiments (do these first)

### Phase 1: APK static analysis (highest expected yield — do this first)
1. Acquire the APK (see above), then:
   ```bash
   ./scripts/run_static_target.sh gerbing-thermogauge
   ```
2. Because this is likely pre-Flutter native Java, `jadx` output should be readable. Look for:
   - UUID literals and the scan filter (name prefix or service UUID)
   - The GATT write path: `BluetoothGattCharacteristic.setValue(...)` call sites and whatever builds
     the byte array feeding them — this is where the command table lives
   - The 4 heat settings: expect an enum, a 4-entry constant array, or a percentage table
   - Battery-status parsing: the notification/read handler that produces the battery UI
   - "Lock" feature: is the temperature lock a device-side command or purely app-side UI state?
   - Dual-zone addressing: how the app selects output A vs B
3. Note the app's ProGuard state; a 2016/2020 app of this size is often only lightly obfuscated.

### Phase 2: BLE scan (needs an adapter)
4. Power the adapter (bike harness for 12 V, garment battery for 7 V), then:
   ```bash
   ./scripts/detect_devices.sh
   ```
   Record advertised name, service UUIDs, manufacturer data, address type. Repeat for both the 7 V
   and 12 V adapters if both are available — confirm whether they share one protocol.

### Phase 3: HCI snoop (confirmation, and required if static analysis stalls)
5. Enable Bluetooth HCI snoop logging, install the archived APK on a test device, then capture one
   action per log: connect → each of the 4 heat settings → temperature lock on/off → off →
   disconnect. Capture battery-status polling separately (leave it connected and idle to see whether
   status arrives by notification or by periodic read).
6. Analyze with Wireshark (`btatt`), and cross-check every decoded frame against the static findings.

### Phase 4: Validation
7. Replay writes with nRF Connect on an **unworn** garment on a bench supply, with a thermometer or
   IR camera on the element and someone present. Log setpoint vs measured temperature.
8. Verify the fail-safe: what does the adapter do when the phone disconnects mid-session? Time it.
   This single measurement determines what a replacement client is allowed to do.

## Protocol hypotheses (to validate)
- Pairing/bonding: "Just Works" or none; no PIN expected on a 2016 serial-bridge module
- Session state machine: connect → subscribe to notify → write setpoint → periodic status
  notifications (battery, current level) → disconnect. The controller holds the setpoint itself, so
  the phone is not in the control loop.
- Commands (expected surface):
  - set heat level (4 states, or a wider range quantized by the UI)
  - select output/zone (dual-zone adapters)
  - temperature lock on/off
  - query/subscribe status (battery %, current setting, possibly measured temperature)
  - off
- Payload encoding: short ASCII or fixed-length binary frames over a serial-bridge characteristic —
  2016-era HM-10 designs frequently use plain ASCII commands (e.g. `AT`-ish or `#L3$` style), which
  would make this one of the easier protocols in the repo. Binary framing with header + checksum is
  the alternative; compare against `docs/protocols/ble-common.md`.
- Keep-alive: unlikely to be required given the controller self-regulates, but confirm — and confirm
  what happens on link loss either way.
- Timing constraints: none expected beyond a status-poll interval.

## Control surface inventory (what the replacement app must support)
### Onboarding/pairing UX
- BLE scan filtered by name/service UUID, connect, remember device, auto-reconnect
- Support both 7 V and 12 V adapters if they differ
### Core controls (MVP)
- 4 heat settings + explicit OFF
- Per-output control on dual-zone adapters
- Battery status display (7 V gear)
- Temperature lock (parity with the original app)
### Safety behaviours (not optional)
- Link-loss fail-safe (heat off or bounded timeout), matching whatever the hardware actually does
- Session auto-off after N minutes without interaction
- Never command above the stock app's maximum setting
### Error handling and recovery
- GATT write failure → retry with backoff, surface failures instead of showing a stale level
- Adapter unresponsive → prompt to power-cycle at the harness / reseat the battery
### Settings persistence
- Bonded adapter address, per-output last level (restored only on explicit user confirmation)

## Evidence checklist
- [ ] APK provenance recorded (adb pull vs mirror) + SHA-256 + version code for `com.gyde.thermogauge`
- [ ] App framework and obfuscation state
- [ ] Service + characteristic UUIDs
- [ ] Command table recovered from DEX (or explicitly marked unrecoverable, per the
      `motool-slacker` precedent)
- [ ] Advertised name pattern / scan filter
- [ ] HCI snoop: connect, each of 4 settings, lock on/off, off, idle status polling
- [ ] Battery-status payload decoded
- [ ] Dual-zone addressing mechanism
- [ ] Link-loss behaviour measured (does heat latch or drop, and after how long?)
- [ ] Bench thermal log: setpoint vs measured element temperature
- [ ] Whether 7 V and 12 V adapters share a protocol

## Spec output (clean-room)
Write a derived spec in:
- `docs/specs/gerbing-thermogauge.md` — message formats, UUIDs, heat-setting table, examples, tests
- `device-specs/devices/gerbing-thermogauge.yaml` once UUIDs are confirmed (schema-validated; ship
  UUIDs only if command bytes are still unrecovered — do not invent opcodes)
- Record the measured link-loss/fail-safe behaviour in the spec itself; for a heat device that is
  protocol-level information, not an implementation detail.

## References (URLs only)
- https://www.gerbing.com/products/gerbing-thermogauge-12v-bluetooth-temperature-controller
- https://www.gerbing.com/12v-thermogauge-bluetooth-adapter
- https://www.mycoolingstore.com/gerbing-gyde-thermogauge-bluetooth-controller.html
- https://www.rockymountainatvmc.com/riding-gear/gerbing-dual-bluetooth-controller-p
- https://www.appbrain.com/app/gerbing-heated-clothing-ther/com.gyde.thermogauge
- https://apkcombo.com/gerbing-heated-clothing-ther/com.gyde.thermogauge/
- https://apkpure.com/gerbing-heated-clothing-%E2%80%93-ther/com.gyde.thermogauge
- https://www.gl1800riders.com/threads/heated-gear-app-controlled.490898/
