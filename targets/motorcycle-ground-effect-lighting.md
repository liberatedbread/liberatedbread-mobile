# Target: Motorcycle Ground Effect / Accent LED Lighting Controllers

## Target metadata
- target_id: motorcycle-ground-effect-lighting
- app package_id(s):
  - XKGlow ecosystem: com.xkglow.xkchrome, com.xkglow.xkdeluxe, com.xkglow.xkcommand, com.xkglow.alphapro, com.xkglow.ttl, com.xkglow.dinntu
  - LEDGlow ecosystem: com.seeblue.ledglow_moto, com.seeblue.ledglowv2
  - OPT7 ecosystem: com.leway.OPT7PLUS, com.opt7.glow
  - Custom Dynamics: com.ttcble.proglow
- device class: BLE LED controller (multi-zone RGB/RGBW strips, halos, underglow kits)
- transport(s): BLE (primary), some controllers may also support Bluetooth Classic/SPP fallback
- local-only viability: high — BLE direct device control, no cloud dependency expected

## Overview

Motorcycle ground effect / underglow / accent LED lighting systems are aftermarket LED kits
controlled via Bluetooth from Android/iOS apps. They typically consist of a BLE controller module
connected to multiple RGB or RGBW LED strips/zones, plus a mobile app for color selection,
brightness control, effect mode selection, and zone management.

This target covers the most popular motorcycle LED brands. Many of these apps may share
underlying BLE hardware modules (e.g., JDY-08, HM-10, Nordic nRF51/nRF52, Telink TLSR82xx)
or protocol patterns, but each ecosystem warrants independent RE analysis.

## Discovered apps

### XKGlow XKChrome (PRIORITY 1)
- **Package ID**: com.xkglow.xkchrome
- **Description**: "The most advanced app-enabled LED lighting for car, motorcycle, boat and more."
- **Rating**: TBD (check Play Store)
- **Ecosystem**: XKGlow sells multi-product LED kits — XKChrome, XKDeluxe, XKCommand, Alpha Pro, TTL, Dinntu. Each has a dedicated app but likely shares a common BLE protocol across hardware generations.
- **Hardware notes**: Multi-zone controller supporting up to 4+ independent LED channels. Products range from simple underglow to full vehicle accent lighting with app-synced music visualization.
- **Related app IDs** (same vendor, may share protocol):
  - com.xkglow.xkdeluxe
  - com.xkglow.xkcommand
  - com.xkglow.alphapro
  - com.xkglow.ttl
  - com.xkglow.dinntu

### LEDGlow Motorcycle (PRIORITY 2)
- **Package ID**: com.seeblue.ledglow_moto
- **Description**: "A Few Simple Swipes on Your Smartphone and Your Bike Will Be Transformed!"
- **Publisher**: Seeblue (OEM BLE module/app developer — likely a white-label BLE LED control platform)
- **Rating**: TBD
- **Hardware notes**: LEDGlow sells motorcycle-specific LED kits. The app is published by Seeblue (not LEDGlow), suggesting Seeblue provides the BLE module + app as an OEM solution. LEDGlow also sells a "Million Color" controller line.
- **Related app ID**: com.seeblue.ledglowv2 (newer version, supports both car and motorcycle)
- **Seeblue also publishes**: com.seeblue.golfcart (same BLE platform, different vehicle type)

### OPT7 Aura / OPT7 Glow (PRIORITY 3)
- **Package ID**: com.leway.OPT7PLUS (PLUS Series Ambient Lighting Control App)
- **Package ID**: com.opt7.glow (OPT7 Glow — "user-friendly app for controlling various lighting devices")
- **Publisher**: Leway (com.leway.OPT7PLUS) and OPT7 (com.opt7.glow)
- **Rating**: TBD
- **Hardware notes**: OPT7 is one of the most popular motorcycle LED brands. Their Aura Pro line uses a multi-zone BLE controller. The PLUS series and Glow series may use different controller hardware.
- **Known products**: Aura Pro, Aura Plus, OPT7 Glow motorcycle kits

### Custom Dynamics ProGLOW (PRIORITY 4)
- **Package ID**: com.ttcble.proglow
- **Description**: "Custom Dynamics, ProGLOW"
- **Publisher**: TTCBLE (another OEM BLE module developer — TTC BLE)
- **Rating**: TBD
- **Hardware notes**: Custom Dynamics is a premium motorcycle lighting brand. Their ProGLOW line adds Bluetooth-controlled ground effects. Published by TTCBLE, suggesting another white-label BLE module.
- **Note**: Custom Dynamics also has the AdMore Light Bar Pro (com.admorelighting.lightbar) — already analyzed in `admore-light-bar.md`. ProGLOW is a different product line (accent/ground effect vs. safety brake light).

### Generic BLE LED Controllers (BONUS — may be used by some kits)
- **com.zengge.blev2** — Zengge BLE LED strip controller (very common generic app, $5-15 controllers)
- **com.xiaoyu.hlight** — HappyLighting (generic Bluetooth lamp control, very popular on AliExpress)
- **com.ledlamp** — LED LAMP (generic intelligent lighting control)
- **com.szelk.ledlamppro** — LotusLamp X (ELK-BLEDOM rebrand/variant, LED strip controller)
- **com.smile.ledv2** — Another generic BLE LED v2 controller
- **com.leddmx** — LED DMX (DMX512 over Bluetooth for professional setups)
- **com.leguangqi.smartled** — Smart LED control

**Note**: The generic controllers are partially covered by `elk-bledom-led-strip.md` and
`leds2rave4-lunchbox-led.md`. Only add motorcycle-specific OEM apps to this target spec;
generic controllers warrant their own spec if not already covered.

## Brand coverage and gaps

| Brand | App Found | Package ID | Notes |
|-------|-----------|------------|-------|
| XKGlow | ✅ | com.xkglow.xkchrome | Multiple related apps |
| LEDGlow | ✅ | com.seeblue.ledglow_moto | Seeblue OEM platform |
| OPT7 | ✅ | com.leway.OPT7PLUS, com.opt7.glow | Two generations |
| Custom Dynamics | ✅ | com.ttcble.proglow | TTCBLE OEM platform |
| Lumen8 | ❌ | Not found | May not have standalone app |
| Lamphus | ❌ | Not found | SoundAlert is PA/siren, not LED |
| MillionColor | ❌ | Not found | May use LEDGlow/Seeblue app |
| MICTuning | ❌ | Not found | May use generic BLE app |

## Known facts (public + observed)

### Public claims
- XKGlow XKChrome: Claims "most advanced app-enabled LED lighting" supporting cars, motorcycles, and boats. Multi-zone control with music sync.
- LEDGlow: Motorcycle-specific kits with "Million Color" LED controllers. App provides color wheel, preset patterns, brightness, and zone selection.
- OPT7 Aura Pro: Popular motorcycle underglow kit with 4-zone control, 300+ preset patterns, music sync, brake light integration.
- Custom Dynamics ProGLOW: Premium motorcycle accent lighting with app control. Used alongside their safety lighting products (AdMore Light Bar).

### Observed patterns
- All discovered apps are BLE-based (no WiFi apps found for motorcycle LED ground effects)
- Multiple apps are published by OEM BLE module developers (Seeblue, TTCBLE, Leway) rather than the LED kit brands themselves
- This suggests a white-label model: BLE module manufacturer provides the hardware + reference app, LED kit brand resells with their branding
- Generic BLE LED controllers (Zengge, HappyLighting, LED LAMP) are widely available on AliExpress for $5-15 and may power some budget motorcycle kits

### No existing known RE
- No public reverse engineering of XKGlow, LEDGlow, OPT7, or ProGLOW BLE protocols found
- This is greenfield RE work — no prior art to reference
- The Seeblue and TTCBLE OEM platforms suggest there may be a shared protocol across multiple brands using the same BLE module

## Device discovery signals
- BLE:
  - advertised name patterns (UNKNOWN — to be discovered via scan):
    - XKGlow: likely "XKChrome", "XKGlow", "XK-*"
    - LEDGlow/Seeblue: likely "LEDGlow", "SeeBlue", "SB-*"
    - OPT7: likely "OPT7", "Aura", "OPT7-AURA"
    - ProGLOW: likely "ProGLOW", "TTC", "CD-ProGLOW"
  - service UUIDs: UNKNOWN — primary target of RE
  - address behavior: likely public (consumer devices, no privacy features expected)
- Wi-Fi: not applicable (no WiFi-based motorcycle LED apps found)

## Threat model + guardrails
- Scope: only owned devices, no safety-critical use cases.
- These are decorative/accent lighting systems. They do not control brakes, turn signals, or headlights.
- Risk: incorrect light behavior could distract other road users or drain vehicle battery. Document safe default values.
- Non-goals: do not modify safety-related lighting (brake lights, turn signals). Focus only on ground effect/accent LED control.
- Some kits integrate with brake light input for flash-on-brake features — document but do not interfere with physical brake signal wiring.

## Protocol hypotheses (to validate)

### Hypothesis 1: Each brand uses unique BLE service/characteristic UUIDs
- XKGlow, OPT7, LEDGlow (Seeblue), and ProGLOW (TTCBLE) likely each use their own service UUIDs
- The OEM module developers (Seeblue, TTCBLE) may reuse UUIDs across their customer brands

### Hypothesis 2: BLE write characteristic for commands
- Pattern: connect → discover services → write to characteristic → optionally receive notification
- Similar to ELK-BLEDOM (0xFFF0 service, 0xFFF3 write) and AdMore Light Bar (NUS service)
- Command format: likely fixed-length byte packets with header byte, command byte, payload, checksum/end marker

### Hypothesis 3: Multi-zone addressing
- Controllers support 4+ independent LED zones (front, rear, left, right for motorcycles)
- Zone selection embedded in command packet (zone ID byte or bitmask)
- Each zone can have independent color, brightness, and effect

### Hypothesis 4: Effect mode selection
- Static color (RGB/RGBW value per zone)
- Preset patterns (rainbow, fade, strobe, chase)
- Music sync (microphone-based, processed on phone → sends timed color updates)
- Speed/brightness parameters for dynamic effects

### Hypothesis 5: No authentication/pairing required
- Consumer BLE LED controllers typically use "Just Works" pairing or no bonding
- Open GATT characteristic writes — no encryption

## First experiments (do these first)

### Phase 1: App acquisition + static analysis (DO FIRST — no device needed)
1. **Fetch APKs using apkeep**:
   ```bash
   # XKGlow (highest priority)
   ./scripts/fetch_apks_apkeep.sh com.xkglow.xkchrome
   # LEDGlow
   ./scripts/fetch_apks_apkeep.sh com.seeblue.ledglow_moto
   # OPT7
   ./scripts/fetch_apks_apkeep.sh com.leway.OPT7PLUS
   ./scripts/fetch_apks_apkeep.sh com.opt7.glow
   # ProGLOW
   ./scripts/fetch_apks_apkeep.sh com.ttcble.proglow
   ```

2. **Static analysis — grep for BLE identifiers**:
   ```bash
   # For each APK, run static analysis to extract UUIDs
   ./scripts/run_static_target.sh motorcycle-ground-effect-lighting
   ```
   Key things to search for in each APK:
   - Service UUIDs (`grep -r "0000.*-0000-1000-8000-00805f9b34fb"` and custom UUIDs)
   - Characteristic UUIDs (read, write, notify)
   - Bluetooth adapter usage patterns (`BluetoothGatt`, `BluetoothLeService`, BLE library imports)
   - Package structure (native Android BLE vs. FlutterBlue vs. React Native BLE)
   - Command byte patterns in source code strings

3. **Identify OEM BLE modules**:
   - Seeblue publishes `ledglow_moto` and `ledglowv2` and `golfcart`
   - TTCBLE publishes `proglow`
   - Check if these apps share identical UUIDs (i.e., same BLE module, different branding)
   - If they share UUIDs, the protocol is the OEM module protocol — one RE covers all brands using it

4. **Compare app frameworks**:
   - Determine if apps are native Android (Java/Kotlin), Flutter, React Native, or WebView
   - Flutter apps require `blutter` for AOT snapshot analysis (like AdMore Light Bar)
   - Native Java apps can be analyzed with `jadx` or `apktool`

### Phase 2: BLE scan + HCI snoop (needs physical device or any BLE scanner)
5. **Run device detection scan**:
   ```bash
   ./scripts/detect_devices.sh
   ```
   While powering on each LED controller in turn, record advertised names and service UUIDs.

6. **HCI snoop capture (Android)**:
   - Enable Bluetooth HCI snoop log in Developer Options
   - Connect app to device, change color, change brightness, switch effect mode
   - Export `/sdcard/btsnoop_hci.log` (or `bt/btsnoop_hci.log`)
   - Analyze in Wireshark: filter by `btatt` to see GATT operations
   - Extract: service discovery, characteristic writes, notify values

### Phase 3: Protocol validation
7. **Replay commands**: Use `nRF Connect` or `gatttool` to replay captured write commands
8. **Fuzz parameters**: Vary color bytes, zone IDs, effect indices to map the protocol space
9. **Cross-reference apps**: If Seeblue/TTCBLE apps share UUIDs, test generic commands across brands

## Protocol hypotheses (to validate)
- Pairing/bonding steps: likely "Just Works" — no PIN, no bonding required (validate)
- Session state machine: connect → discover services → write characteristic for each command (stateless)
- Commands: set color (RGB/RGBW), set brightness (0-255), set effect mode (enum), music sync (timed color updates), zone selection
- Payload encoding: likely fixed-length byte packets (8-20 bytes). Common patterns:
  - Header: 0xAA, 0x55, 0x7E, or custom
  - Command byte: distinguishes color/brightness/effect/mode
  - Zone byte: which LED channel (0-3 for 4 zones)
  - RGB payload: 3-4 bytes (R, G, B, optional W)
  - Checksum: XOR, sum, or CRC
  - End marker: 0xEF, 0x55, or custom
- Timing constraints: music sync mode may require rapid writes (10-30ms intervals)

## Control surface inventory (what the replacement app must support)

### Onboarding/pairing UX
- BLE scan with device name filtering per brand
- No pairing code required (Just Works)
- Auto-reconnect to last device

### Core controls (MVP)
- Power on/off (per zone and global)
- Color picker (RGB color wheel + RGBW for white-channel controllers)
- Brightness slider (0-100%)
- Zone selection (individual zone or all-zones mode)

### Effect modes
- Static color
- Fade between colors (speed adjustable)
- Strobe/flash (speed adjustable)
- Rainbow cycle
- Chase/sequential
- Music sync (phone microphone → BPM detection → timed color changes)

### Advanced (stretch)
- Brake light integration (flash red on brake input — read-only from controller, do not write)
- Turn signal sync (amber flash pattern)
- Custom pattern upload (if supported by controller)
- Preset save/load

### Error handling and recovery
- Connection loss → auto-reconnect with exponential backoff
- GATT write failure → retry with backoff
- Controller unresponsive → prompt user to power cycle

## Evidence checklist
- [ ] APK hashes + version codes for each app
- [ ] Static analysis: service UUIDs, characteristic UUIDs, command bytes
- [ ] App framework identification (native/Flutter/RN)
- [ ] OEM module identification (shared UUIDs across Seeblue/TTCBLE apps?)
- [ ] HCI snoop log: connect + set color + set brightness + change effect
- [ ] Device advertised name and service UUID table
- [ ] Command byte mapping (color, brightness, effect, zone)
- [ ] Protocol encoding validated via replay

## Spec output (clean-room)
Write derived specs in:
- docs/specs/motorcycle-ground-effect-lighting.md (protocol documentation)
- Include message formats, UUIDs, command tables, value ranges, and examples.

## RE plan — recommended approach

### Prioritization
1. **Start with XKGlow XKChrome** (com.xkglow.xkchrome) — most popular, most feature-rich, highest priority
2. **Then LEDGlow/Seeblue** (com.seeblue.ledglow_moto, com.seeblue.ledglowv2) — OEM platform may unlock multiple brands
3. **Then OPT7** (com.leway.OPT7PLUS, com.opt7.glow)
4. **Then ProGLOW** (com.ttcble.proglow)

### Static analysis strategy
```
For each APK:
1. apktool d → inspect AndroidManifest.xml for BLE permissions/services
2. grep -r for UUID patterns (8-4-4-4-12 format)
3. grep -r for "BluetoothGatt", "BluetoothLe", BLE library names
4. Identify app framework:
   - Native: use jadx to decompile Java/Kotlin → look for BLE service classes
   - Flutter: use blutter to dump Dart AOT snapshot → look for BLE service UUIDs
5. Extract all unique service UUIDs and characteristic UUIDs
6. Cross-reference: do Seeblue apps share UUIDs? Do TTCBLE apps share UUIDs?
```

### Dynamic analysis strategy (requires physical device)
```
1. Enable HCI snoop on Android device
2. Pair phone with LED controller via the OEM app
3. Perform one action at a time, clearing log between:
   a. Connect → observe service discovery
   b. Set color red → capture write
   c. Set color blue → compare payload
   d. Set brightness 50% → capture write
   e. Change effect mode → capture write
   f. Music sync on → observe write pattern (timing)
4. Replay captured packets with nRF Connect to validate
5. Map the command space by systematic parameter variation
```

### Key RE questions to answer
1. What BLE service UUID does each brand use?
2. What is the write characteristic UUID for commands?
3. Is there a notify/indicate characteristic for device state?
4. What is the command packet format? (header, command, zone, payload, checksum)
5. How are colors encoded? (RGB888, RGB565, GRB order, etc.)
6. How are zones addressed? (separate characteristic per zone or zone byte in packet)
7. What effect modes are available and how are they selected?
8. Do Seeblue apps (ledglow_moto, ledglowv2, golfcart) share the exact same UUIDs?
9. Do TTCBLE apps share UUIDs across their customer brands?

## References (URLs only)
- https://play.google.com/store/apps/details?id=com.xkglow.xkchrome
- https://play.google.com/store/apps/details?id=com.seeblue.ledglow_moto
- https://play.google.com/store/apps/details?id=com.seeblue.ledglowv2
- https://play.google.com/store/apps/details?id=com.leway.OPT7PLUS
- https://play.google.com/store/apps/details?id=com.opt7.glow
- https://play.google.com/store/apps/details?id=com.ttcble.proglow
- https://play.google.com/store/apps/details?id=com.xkglow.xkdeluxe
- https://xkglow.com/pages/app
- https://opt7.com/pages/aura-pro-app
- https://www.ledglow.com/motorcycle-led-lights/
- https://www.customdynamics.com/proglow
