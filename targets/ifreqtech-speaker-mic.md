# IFREQTECH WM500 Wireless Speaker Mic — target spec starter

## Target metadata
- target_id: ifreqtech-speaker-mic
- app package_id(s): N/A — no companion app found (Google Play developer page for "IFREQTECH Electronic" returns 404)
- device class: Bluetooth audio accessory (wireless PTT speaker mic for two-way radios)
- transport(s): Bluetooth Classic (BR/EDR) — HFP (Hands-Free Profile) for audio, possibly SPP for PTT/control
- local-only viability: **high** — direct Bluetooth pairing between adapter and speaker mic, and between mic and smartphone; no cloud dependency

## Known facts (public + observed)

### Product details (from Amazon ASIN B0FPCBWV9P)
- **Model**: WM500
- **Manufacturer**: IFREQTECH Electronic
- **Kit contents**: 1x 2-Pin Wireless Adapter (plugs into radio's K-connector), 1x Wireless Speaker Mic, 1x Belt Clip, 1x Type-C Charging Cable, 1x User Manual
- **Price**: ~$25-35 (budget accessory segment)
- **Power**: Battery powered (nonstandard battery in mic unit), USB-C charging
- **Range**: Up to 10 meters Bluetooth range
- **Features**:
  - Dual-mode: works with two-way radio (via K-connector adapter) AND smartphone (via Bluetooth)
  - 360° rotatable belt clip
  - Voice prompts for status
  - 3.5mm earphone jack for private listening
- **Compatible radios**: Baofeng UV-5R, BF-F8HP, UV-82, UV-82HP, Kenwood, TYT, BTECH, Wouxun (2-pin K-connector)

### Architecture hypothesis
The system consists of two Bluetooth devices that pair with each other:
1. **K-Connector Bluetooth Adapter** ("wireless adapter"): A small dongle that plugs into the radio's 2-pin K-connector (speaker/mic port). Acts as a Bluetooth bridge — sends radio audio to the mic, receives mic audio for transmission, and handles PTT signaling.
2. **Wireless Handheld Speaker Mic**: The handset that the user holds. Contains speaker, microphone, PTT button, battery, and Bluetooth radio. Pairs with the adapter for radio communication and optionally with a smartphone for phone calls.

### Radio-interface side (K-connector)
The K-connector (Kenwood-style 2-pin) provides:
- Pin 1 (tip): Speaker audio (from radio)
- Pin 2 (ring/sleeve): Microphone audio + PTT (PTT is typically shorted to ground to key the transmitter)

The adapter must:
- Receive speaker audio from the radio, encode and send via Bluetooth to mic
- Receive mic audio via Bluetooth from handheld, decode and inject into radio mic input
- Detect PTT button press from handheld, ground the radio's PTT line

### No companion app
- `https://play.google.com/store/apps/developer?id=IFREQTECH+Electronic` → 404 Not Found
- No "IFREQTECH" apps on Google Play (search returns empty for apps category)
- Device appears to operate purely firmware-based with standard Bluetooth profiles
- This means: **no APK to decompile** — RE must be done via HCI snooping and/or hardware analysis

### No FCC filings found
- `fccid.io` search for "IFREQTECH" returns no results
- This is common for white-label Chinese imports sold primarily on Amazon
- The Bluetooth module inside likely has its own FCC ID (e.g., a JL, Bluetrum, or Beken chipset module)

## Device discovery signals

### Bluetooth Classic
- **Adapter (K-connector dongle)** likely advertises as:
  - Name patterns: "WM500", "BT-SPK", "IFREQTECH", or similar
  - CoD (Class of Device): likely 0x200404 (Audio/Headset) or 0x200408 (Hands-free)
  - Service UUIDs (SDP): HFP (0x111E), HSP (0x1108), possibly SPP (0x1101)
- **Handheld speaker mic** likely advertises as:
  - Name patterns: "WM500-MIC", "BT-MIC", or similar
  - CoD (Class of Device): likely 0x200404 (Audio/Headset) or 0x200408 (Hands-free)
  - May also support A2DP for higher-quality audio

### Pairing behavior (hypothesized)
1. Adapter powers on when radio is turned on (draws power from K-connector)
2. Handheld mic powers on via its own battery
3. The two devices auto-pair (likely pre-paired at factory or use "just works" pairing)
4. The mic can additionally pair with a smartphone for phone calls
5. PTT button on mic triggers radio transmission via Bluetooth command to adapter

## Threat model + guardrails
- Scope: only owned devices, no safety-critical use cases.
- Radio transmission must respect FCC/regulatory limits — replacement software should not modify transmission power or frequency.
- PTT control is safety-relevant (unintended transmission could interfere with emergency communications).
- Explicit non-goal: will NOT implement any functionality that modifies the radio's frequency, power, or other regulated parameters.

## First experiments (do these first)

### Phase 1: Device inventory & physical inspection
1. **Photograph and label** all components (adapter, mic, cable, manual)
2. **Check the manual** for:
   - Pairing instructions (how to pair adapter to mic, mic to phone)
   - LED status indicators and their meanings
   - Button combinations for factory reset, pairing mode
   - Any mention of Bluetooth version or profiles
3. **Open the adapter (if non-destructive)** to identify:
   - Bluetooth SoC/module (common candidates: JL AC69xx, Bluetrum AB53xx, Beken BK32xx, Qualcomm QCC30xx)
   - Audio codec chip
   - K-connector pinout mapping
4. **Open the speaker mic (if non-destructive)** to identify:
   - Bluetooth SoC/module
   - Battery type and capacity
   - Speaker, microphone, and button connections

### Phase 2: Bluetooth discovery
1. Power on both devices
2. Run `bluetoothctl` scan:
   ```bash
   bluetoothctl --timeout 30 scan on | tee workspace/logs/ifreqtech_scan_$(date +%Y%m%d_%H%M%S).log
   ```
3. For each discovered device (adapter and mic), record:
   - BD_ADDR (MAC address)
   - Device name
   - Class of Device (CoD)
   - Manufacturer (from inquiry response)
4. Use `sdptool` to enumerate SDP records:
   ```bash
   sdptool browse <BD_ADDR> | tee workspace/logs/ifreqtech_sdp_<role>_$(date +%Y%m%d_%H%M%S).log
   ```
   This reveals which profiles are supported (HFP, HSP, A2DP, SPP, etc.)

### Phase 3: HCI snoop (critical — no APK alternative)
Since there is no companion app, the HCI snoop log is the **sole source of protocol intelligence**. Two capture scenarios:

**Scenario A: Adapter ↔ Mic communication**
1. Power on both devices, let them auto-pair
2. Capture HCI log on a host that is NOT participating in the connection (monitor mode, or use an Ubertooth/ESP32 BT sniffer)
3. Key PTT button several times while capturing
4. Speak into mic, verify audio is forwarded to radio
5. Log all HCI traffic including SCO (audio) and ACL (data/control) packets

**Scenario B: Mic ↔ Smartphone communication**
1. Pair the speaker mic with an Android phone
2. Enable Bluetooth HCI snoop log in Android Developer Options
3. Make a test phone call, use PTT button during call
4. Pull the btsnoop_hci.log from the phone

### Phase 4: Static analysis (limited)
- No APK to decompile
- If Bluetooth module chipset is identified via physical inspection, search for:
  - Datasheets and SDK documentation
  - Known default pin codes, service UUIDs
  - Common AT command sets used by that chipset family
- Check if the adapter or mic exposes a firmware update mechanism (USB-C may be dual-purpose)

### Phase 5: Protocol analysis from HCI captures
1. Open HCI snoop logs in Wireshark
2. Identify:
   - Pairing/bonding sequence
   - Which profiles are actually used (HFP vs custom SPP)
   - SCO connection setup for audio
   - PTT signaling mechanism:
     - **If HFP**: PTT likely maps to an AT command (e.g., AT+CKPD or custom AT+PTT)
     - **If SPP**: Look for binary command sent on RFCOMM channel
     - **If HID**: PTT could be mapped to a keyboard/button report
3. Determine audio encoding:
   - Likely standard CVSD (8 kHz) for narrowband SCO
   - Possibly mSBC (16 kHz) for wideband speech over HFP 1.6+
4. Determine adapter-side behavior:
   - How does the adapter detect PTT? Does it send a Bluetooth command, then ground the K-connector PTT pin?
   - Is there any audio routing logic (mute speaker during transmit)?

## Protocol hypotheses (to validate)

### Pairing/bonding steps (adapter ↔ mic)
1. Adapter powers on → enters discoverable mode (LED indicator)
2. Mic powers on → scans and connects to adapter (saved bond)
3. SDP service discovery for HFP Audio Gateway role
4. Service Level Connection (SLC) establishment for HFP
5. SCO audio link established
6. Mic enters standby (listening to radio audio through speaker)

### Session state machine
```
[Power On] → Idle/Listening
                    ↓ PTT press
              Transmitting (mic audio → adapter → radio)
                    ↓ PTT release
              Idle/Listening
                    ↓ Incoming phone call
              Phone Call Mode (audio routed to phone, not radio)
                    ↓ Call end
              Idle/Listening
```

### Commands (hypothesized)
| Action | Likely mechanism | Notes |
|--------|-----------------|-------|
| PTT press | AT command over HFP or custom SPP message | Adapter responds by grounding K-connector PTT pin |
| PTT release | AT command over HFP or custom SPP message | Adapter releases PTT ground |
| Volume up/down | AT+VGM / AT+VGS over HFP | Standard HFP volume commands |
| Answer call | AT+ATA | Standard HFP |
| End call | AT+CHUP | Standard HFP |
| Battery level | AT+IPHONEACCEV? or custom | Battery status of mic reported to adapter |
| Voice prompt | Locally generated in mic | No Bluetooth traffic |

### Payload encoding (if custom SPP)
- Likely simple binary protocol: [command_byte] [optional_args...]
- Commands: PTT_DOWN (0x01?), PTT_UP (0x02?), VOL_UP, VOL_DOWN, STATUS_REQ, STATUS_RESP
- No encryption expected on budget devices

### Timing constraints
- PTT latency must be <50ms for acceptable user experience
- Audio latency (mic → adapter → radio) must be <100ms
- SCO retransmission windows may be tight

## Control surface inventory (what the replacement app must support)

### Onboarding/pairing UX
- Bluetooth Classic device discovery (not BLE scanning)
- Manual pairing with PIN (likely 0000 or 1234 for budget devices)
- Bond management for adapter ↔ mic pairing

### Core controls (MVP)
- Monitor connection state (adapter ↔ mic, mic ↔ phone)
- PTT virtual button (if implementing a software PTT replacement)
- Audio routing selection (radio vs phone)
- Volume control
- Battery level display

### Advanced
- Voice prompt language selection (if configurable)
- Sidetone adjustment (mic audio played back in speaker)
- Firmware update (if accessible via USB-C or Bluetooth)

### Error handling and recovery
- Connection loss detection and auto-reconnect
- Low battery warning
- Audio quality degradation alerts
- Pairing reset procedure

### Settings persistence
- Bond information (paired adapter BD_ADDR)
- Volume level
- Preferred audio routing

## Evidence checklist
- [ ] Photos of adapter PCB (both sides) with chip labels visible
- [ ] Photos of mic PCB (both sides) with chip labels visible
- [ ] HCI snoop log: adapter ↔ mic (Scenario A, Wireshark pcapng)
- [ ] HCI snoop log: mic ↔ smartphone (Scenario B, btsnoop_hci.log)
- [ ] SDP service records for both adapter and mic
- [ ] BT device discovery logs (bluetoothctl scan)
- [ ] Manual/photos of pairing instructions
- [ ] Chipset model numbers (adapter and mic) for datasheet research

## Spec output (clean-room)
Write a derived spec in:
- `docs/specs/ifreqtech-speaker-mic.md` — narrative protocol documentation
- Note: current `device-specs/` schema is BLE-only (GATT services/characteristics) and WiFi (HTTP/MQTT). This Bluetooth Classic device requires a different spec format. Consider:
  - HFP/AT command reference
  - Custom SPP protocol documentation (if applicable)
  - RFCOMM channel assignments
  - Audio codec configuration

## RE approach summary

### Difficulty assessment: MODERATE
- **If standard HFP**: The device uses well-documented Bluetooth profiles. HCI snoop + Wireshark is sufficient. AT commands are text-based and easily decoded. **RE effort: 1-2 days.**
- **If custom SPP**: The control protocol must be reverse-engineered from binary packet captures. Slightly more complex but still manageable since budget devices typically use simple protocols. No encryption expected. **RE effort: 3-5 days.**
- **If custom firmware + proprietary protocol**: Worst case. Would need firmware extraction from the adapter and/or mic, which may require hardware tools (JTAG/SWD, flash programmer). **RE effort: 1-2 weeks.**

### Most likely scenario
Budget Amazon Bluetooth accessories nearly always use off-the-shelf Bluetooth modules (JL, Bluetrum, Beken) with reference firmware. These modules typically implement:
- Standard HFP for audio
- A simple AT command extension for PTT (or SPP channel)
- No authentication beyond standard BT pairing PIN

**Recommended approach**: HCI snoop first, identify profiles via SDP, then decode AT commands or SPP traffic. Physical teardown only if traffic analysis is inconclusive.

## References (URLs only)
- https://www.amazon.com/gp/product/B0FPCBWV9P
- https://www.amazon.com/stores/IFREQTECH/page/E03E9194-0A57-409A-A2A5-CF90277CA38E (IFREQTECH storefront)
- https://play.google.com/store/search?q=IFREQTECH&c=apps (no companion app found)
- https://fccid.io/IFREQTECH (no FCC filings found)

### Related projects (Bluetooth PTT / radio accessories)
- None found for this specific device. Community RE for similar products:
  - Baofeng radio programming cables use CH340/CP2102 USB-UART chips (not relevant for Bluetooth, but familiar K-connector ecosystem)
  - Wireless PTT for smartphones (e.g., Bluetooth camera shutter remotes) use HID or SPP profiles — similar approach may apply
  - BTECH APRS-K2 cable uses Bluetooth SPP for APRS data — demonstrates SPP viability for radio accessories
