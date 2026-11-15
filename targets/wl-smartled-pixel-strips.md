# wl.smartled / fstart pixel strips (duoCo StripX / Lotus Lantern / Magic Lantern) — target spec starter

## Target metadata
- target_id: wl-smartled-pixel-strips
- app package_id(s) — **three channel skins of one vendor codebase ("fstart"/easylink
  LED platform); they are interchangeable for protocol purposes**:
  - wl.smartled.duoco.rgb (duoCo StripX, v6.3.7) — MELK- name filter
  - wl.smartled (Lotus Lantern / 宝莲灯, v6.5.08) — ELK- / ELK~ / XSL- / "LED LIGHT STRIP"
  - wl.smartled.rgb (Magic Lantern, v6.11.06) — MELK- filter only
  - same platform also reskinned as duoCo Strip, EasyLinkLED and others (channel list
    in the apps' branding constants)
- device class: addressable-pixel (dream-color / "symphony") LED strip controllers
- transport(s): Bluetooth (BLE GATT); secondary connectionless control via
  phone-advertised BLE relay frames for `ELK_*` mesh units
- local-only viability: **high** — BLE only, no account, no pairing, no OTA, no
  cloud dependency. The apps' only network calls are telemetry/FAQ/version-check
  and can be ignored entirely.

## Three apps, one protocol
All three apps are rebuilt from a single shared codebase with a per-channel branding
constant. They use the same service/characteristic, the same 9-byte `7E…EF` frames
and the same opcode set. Pick any of them as reference; differences are the
advertised-name filter and a handful of variant commands (countdown, laser lamp,
encrypted-device layer exist in the Lotus Lantern build).

Do **not** confuse this pixel platform with the sibling PWM (single-color)
ELK-BLEDOM protocol (`device-specs/devices/elk-bledom-led-strip.yaml`): same
0xFFF0/0xFFF3 UUIDs and 7E…EF envelope, but byte[1] is a sequence number there and
state notifies on 0xFFF4 — a different protocol on the same characteristic.

## Known facts (from app teardown)
- Service `0000fff0-…`, characteristic `0000fff3-…` — **write + read, no notify**.
  All commands are 9-byte writes; timer/system-time state is pulled by reading
  0xFFF3 after a query frame.
- Frame layout: `[0x7E][per-command constant 0x04–0x08][opcode][4 payload bytes,
  0xFF pad][flag byte][0xEF]`. No checksum, no crypto on GATT writes.
- Full opcode set mapped: power/channel-mask (0x04), brightness (0x01), speed
  (0x02), effect mode (0x03), scene (0x31), static/music color (0x05 flag 0x10/0x20),
  palette color and CCT (0x05 flag 0x08), external-mic sensitivity/on-off/EQ
  (0x06/0x07/0x03+0x80), RGB pin order (0x81), pixel count (0x21, uint16 LE),
  system time (0x83), timer set/query (0x82), countdown (0x76, Lotus build).
- 241-entry built-in effect table (mode opcode 0x03, groups 0–7) + 28 scenes
  (opcode 0x31, group 8) — transcribed in full into the device spec notes.
- Connect sequence: read 0xFFF3 once (probe), then push system time; space writes
  ≥ 5 ms; group control = up to 4 parallel GATT connections, client-side only.
- Advertised name gates features (MELK-OC/OT scenes, *CT* CCT, *W* white channel,
  DYDS extra scene, OE/OB/TX no external mic, TX = remote, "INTRO" flips the
  power-on byte to 0xFF).
- Broadcast relay: the phone advertises company-id **0xBEE8** manufacturer frames
  carrying the 9-byte command to `ELK_*` mesh devices, obfuscated with a
  counter-derived single-byte XOR (obfuscation grade).
- `ELK-*` encrypted-name variant: 21-byte `AA…55` wrapper, keystream from 12
  per-frame random bytes + a 16-byte preset key hardcoded in the app. Obfuscation
  grade; key recoverable from the APK — deliberately not reproduced in repo files.
- **No OTA/DFU anywhere** in any of the three apps; no Wi-Fi/UDP/TCP transport.
- Network endpoints (telemetry only, none required for control): device-stats
  upload to `lotus.elkled.com:8082`, version check on `www.elkble.com`, FAQ on
  `faq.elkled.com`, privacy pages on `elkble.com` / `easytrack.net.cn`.

## Device discovery signals
- BLE advertised name prefixes: `MELK-`, `ELK-`, `ELK~`, `XSL-`, `ELK_` (broadcast
  mesh), `ELK-*` (encrypted variant), exact name `LED LIGHT STRIP`
- Service UUID: `0000fff0-0000-1000-8000-00805f9b34fb` (shared with the PWM
  sibling — parse the name and, if unsure, test for 0xFFF4 notify: PWM strips have
  it, pixel strips do not)
- Relay adverts: manufacturer data, company id `0xBEE8`

## Threat model + guardrails
- Owned devices only. Controllers accept commands from anyone in range with no
  bonding — a co-located-privacy fact to document, not an attack surface to tool.
- The apps upload device name/MAC/RSSI/GATT table to the vendor telemetry endpoint
  (server-gated). A replacement client should simply never do this; note it for
  users who keep the vendor app installed.
- Clean-room: describe the app's components by role ("the app's BLE scanner
  post-filters on the advertised name") — never by internal class/method names.
  The `ELK-*` preset key stays out of the repo (algorithm documented, key noted as
  recoverable from the APK).

## Remaining experiments
1) **Live scan** — confirm which advertised suffixes a real strip uses
   (`MELK-OB/OC/OE/OT/TX` vs a `…CT`/`…W` variant) and which capability flags
   apply; the name-gating table is inferred from app code, not from hardware.
2) **HCI snoop of one full session**: connect probe read → time push → power →
   brightness → mode → scene → timer set/query. Verifies byte[7] routing semantics,
   the timer readback reply format, and whether 0xFFF3 ever returns anything on the
   unsolicited read.
3) **Mode-select ambiguity**: duoCo builds send `7E 05 03 mode 06 …` while the
   Lotus build sends `7E 05 03 (mode+0x80) 03 …` — capture which form a given
   hardware generation accepts.
4) **ELK-* encrypted variant**: capture a session to confirm whether responses are
   also wrapped (the 28-byte inbound wrapper has no caller in the decompiled flow).
5) **CCT and countdown ranges**: firmware clamps unknown (UI says 0–100; Lotus code
   suggests 0–255 for CCT; countdown timestamp math uses a 2001-01-01 epoch).
6) **Pixel-count limits** for command 0x21, and group-8 scene availability on
   non-OC/OT hardware.
7) Chip identification via GATT DIS (0x180A) — the apps carry no chip-vendor SDK;
   Bluetrum/Beken-class SoC is inference, not evidence.

## Control surface inventory (replacement app MVP)
- scan (0xFFF0 + name prefixes) → connect → read probe → push system time
- power on/off, brightness 0–100 (with light-mode channel select), effect speed
- 241-entry effect picker (mode opcode 0x03) + 28 scenes (opcode 0x31) with
  name-based gating (scenes only on OC/OT, CCT only on *CT*, white on *W*)
- static RGB color + palette color + CCT (warm/cold)
- music-reactive mode: phone-mic amplitude → 0x20-flag color frames at audio rate;
  external-mic on/off/sensitivity/EQ where the model supports it
- pixel-count and RGB pin-order configuration (the "my colors are swapped" fix)
- two timers (on-alarm/off-alarm) with weekday mask, incl. query/readback
- optional: multi-device group control (≤4 parallel connections), `ELK_*`
  broadcast-relay transmitter, `ELK-*` encrypted-variant wrapper

## References
- duoCo StripX on Google Play: https://play.google.com/store/apps/details?id=wl.smartled.duoco.rgb
- Lotus Lantern on Google Play: https://play.google.com/store/apps/details?id=wl.smartled
- Magic Lantern on Google Play: https://play.google.com/store/apps/details?id=wl.smartled.rgb
- Sibling PWM protocol spec (same 0xFFF3 characteristic): `device-specs/devices/elk-bledom-led-strip.yaml`
- dave-code-ruiz/elkbledom (HACS, ELK-family PWM sibling): https://github.com/dave-code-ruiz/elkbledom
- FergusInLondon/ELK-BLEDOM (clean-room RE, family background): https://github.com/FergusInLondon/ELK-BLEDOM
