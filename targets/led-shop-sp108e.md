# LED Shop / SP108E WiFi pixel controller — target spec starter

## Target metadata
- target_id: led-shop-sp108e
- app package_id(s):
  - com.cdc.ledshop ("LED Shop") v1.13.0 (versionCode 17), minSdk 21 / targetSdk 36 —
    decompiled cleanly with jadx (no packer; obfuscated names, logic intact)
- device class: WiFi addressable-LED (SPI pixel) strip controller, 5-24 V input
- transport(s): Wi-Fi only — TCP port 8189 for control, UDP 8188 during provisioning.
  **No BLE anywhere**: the manifest has no BLUETOOTH* permissions and the decompiled
  tree has no BLE code.
- local-only viability: **total**. The app contains zero http(s):// URLs — no cloud,
  no OTA, no analytics. The INTERNET permission is used only for the TCP/UDP sockets
  to the controller. The device can never be bricked by a vendor shutdown because
  there is no vendor backend to shut down.

## The device is fully local — protect that
Unlike most targets here, there is no cloud dependency to route around. The value of
this spec is a clean reimplementation of the vendor app (which is Play-store-bound,
version-locked, and the only client that speaks the 0x38/0x83 framed protocol) before
the app itself rots off modern Android.

## Known facts (decompiled app, cross-checked)
- **Control channel: TCP port 8189.** The app's socket layer connects with a 1000 ms
  connect timeout, 5000 ms read timeout, keepAlive on.
- **Transport discrepancy (document both):** the prior public reverse engineering
  ([blacklizard/LED-Shop-SP108E](https://github.com/blacklizard/LED-Shop-SP108E), a
  macOS clone built from Wireshark + APK analysis) drives the same framing over
  **UDP 8189**. App v1.13.0 speaks TCP 8189 for all control traffic; UDP appears in
  it only during AP provisioning. The device most likely listens on both (framing is
  transport-agnostic) — needs a live unit to confirm.
- **LAN discovery: TCP port scan.** The app's host scanner iterates the /24, opens
  TCP:8189 to each address, sends a framed GET_DEVICE_NAME (0x77), and treats a valid
  keyed reply as a found device; the device name is in the reply payload.
- **SoftAP mode:** device hosts SSID prefix `SP108E_`, answers at 192.168.4.1.
- **Provisioning (AP mode):** client binds local UDP 8188 and waits for the
  controller's broadcast reply (starts with START_FLAG, bytes[2..5] = device IP,
  remainder = token text); on token match the client TCP-sends
  CMD_AP_NETWORK_CONFIG_OK (0x27). Credentials go out in the CMD_AP_NETWORK_CONFIG
  (0x26) frame with SSID/password XOR-obfuscated under per-frame random key bytes —
  obfuscation, not crypto.
- **Framing:** 6-byte command frame `[0x38, rnd0, rnd1, rnd2, CMD, 0x83]`; bytes 1-3
  are a per-frame random nonce (any byte equal to 0x38 or 0x83 is incremented by 1),
  and up to 3 parameter bytes override the nonce slots in order — every command
  carries at most 3 payload bytes.
- **Handshake key:** for CMD_CHECK_DEVICE (0xD5) / CMD_GET_DEVICE_NAME (0x77) the
  client derives a key byte from the three nonce bytes —
  `key = ((b2 >> 5) & 7) | (b0 & 0x53) | ((b1 << 2) & 0xFD)` — and the device must
  echo it in a fixed position of the reply.
- **ACK convention:** most set-command replies are a single byte 0x31 ('1').
- **State sync:** CMD_SYNC (0x10) returns a 17-byte state block (power, mode, speed,
  brightness, RGB order, segment counts, adapter RGB, IC model, record count, white
  brightness). Full layout in the device spec.
- **Command sequencing:** the app serializes commands through a queue with a 200 ms
  inter-command delay; most commands are dropped while the device reports "off"
  (toggle/name/sync/record-num/AP-mode/check are exempt); two-step writes
  (set-name/set-password) send the framed command, await 0x31, then send the raw
  UTF-8 payload; preview/record streams retry once on a bad first reply.
- 28-opcode map fully recovered (see device spec).

## Corroboration
- [blacklizard/LED-Shop-SP108E](https://github.com/blacklizard/LED-Shop-SP108E) —
  independently RE'd macOS client; same 0x38/0x83 framing, same opcode set, UDP 8189.
- [psxde/sp108e-led-controller](https://github.com/psxde/sp108e-led-controller) and
  [BlitzKraig/SP108E-control](https://github.com/BlitzKraig/SP108E-control) — further
  desktop clients prototyped from Wireshark captures.

## Device discovery signals
- SoftAP SSID prefix `SP108E_` (device at 192.168.4.1 while hosting it).
- On a joined LAN: an open TCP listener on port 8189 that answers a framed
  GET_DEVICE_NAME with a keyed reply — that keyed answer IS the identification
  (no mDNS, no SSDP, no vendor beacon). Port-scan the /24 on 8189.
- No BLE signals of any kind.

## Threat model + guardrails
- Owned devices only. The controller has no authentication on its control port —
  anyone on the same LAN (or connected to its open SoftAP) can drive it, including
  the two-step SET_DEVICE_PASSWORD command, whose role in the handshake is not fully
  traced. Note this as a share-the-LAN consideration, not an attack surface to tool
  against.
- The provisioning frame carries the home Wi-Fi passphrase under trivial XOR
  obfuscation to any observer of the SoftAP segment. Treat provisioning traffic as
  effectively plaintext.
- No security_advisory is declared in the spec: no cited public advisory, just the
  open-LAN reality above.

## Remaining experiments
1) **UDP vs TCP 8189** — send the framed GET_DEVICE_NAME over UDP 8189 to a live
   unit. A reply resolves the blacklizard discrepancy and tells clients they can pick
   either transport.
2) **Sync bytes [8:9]** — determine whether the second big-endian count is
   LEDs-per-segment vs a secondary segment field (sync bytes [6:7] are the segment
   count, clamped ≥1). Needs a hardware capture while changing segment settings.
3) **Custom-effect row format** — CMD_CUSTOM_PREVIEW (0x24) / CMD_CUSTOM_RECODE (0x4C)
   stream up to ~300 rows with a 0x31 ACK each; the per-row byte layout lives in the
   app's UI layer and was not fully traced. Capture one preview and one record of a
   tiny custom effect.
4) **SET_DEVICE_PASSWORD flow** — where the password is later required (if anywhere)
   in the handshake.
5) Confirm the ESP8285 hypothesis (192.168.4.1 SoftAP default strongly suggests an
   ESP-family radio; not confirmed by app code).

## Control surface inventory (replacement-app MVP)
- SoftAP join + provisioning (AP_NETWORK_CONFIG / UDP 8188 token / CONFIG_OK)
- LAN discovery by /24 TCP scan on 8189 with keyed GET_DEVICE_NAME
- Power toggle (0xAA) + state sync (0x10) to know which way the toggle will go
- Mode/effect select (0x2C), auto-cycle (0x06), speed (0x03), brightness (0x2A),
  white brightness (0x08), static RGB color (0x22)
- RGB order (0x3C), LED chipset model (0x1C), pixel count (0x2D), segment count (0x2E)
- Device rename (0x14, two-step) for multi-controller setups
- Custom effects: preview (0x24) and record (0x4C) streaming — MVP can ship without
  this; it is the least-traced part of the protocol

## References
- LED Shop on Google Play: https://play.google.com/store/apps/details?id=com.cdc.ledshop
- blacklizard/LED-Shop-SP108E (prior RE, macOS client): https://github.com/blacklizard/LED-Shop-SP108E
- psxde/sp108e-led-controller: https://github.com/psxde/sp108e-led-controller
- BlitzKraig/SP108E-control: https://github.com/BlitzKraig/SP108E-control
- Tasmota device page (hardware teardown — STM32F0 drives the LED CLK/data lines; flashing alternative firmware needs a hardware mod): https://tasmota.github.io/docs/devices/SP108E-LED-strip-controller/
