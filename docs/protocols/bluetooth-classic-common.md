# Common Bluetooth Classic Patterns

Bluetooth Classic — BR/EDR, the half of the standard that predates BLE — is
how a surprising amount of abandonable hardware talks: OBD-II dongles, label
and receipt printers, headphones and earbuds, GPS loggers, gamepads, and
small appliances built around a $1 serial module. The vendor app finds the
device, opens a **serial port** to it and streams bytes; there is no GATT, no
characteristic, no notification. This page covers what that means for a spec
and for a client. The BLE page is [Common BLE Patterns](ble-common.md); the
pairing vocabulary the two share is
[Pairing, Bonding and Unpairing](pairing.md).

## The three shapes a Classic device comes in

| Shape | What the app does | Examples in the catalogue |
|---|---|---|
| **Classic only** | BR/EDR inquiry, pair from the OS, open SPP | Brother QL-1110NWB (Bluetooth path), Classic ELM327 dongles |
| **Dual-mode, BLE for discovery** | BLE scan finds it; the *same address* takes an RFCOMM socket for all data | Quin / Daviky pill boxes (A170, A1310) |
| **Dual-mode, both usable** | A GATT serial pipe *and* an SPP channel carry the same protocol | OBDLink MX+ |

The distinction decides `device.protocol`. State the protocol of the link the
**control surface** actually runs on: the pill box is `bluetooth_classic` with
a `ble_scan` discovery method and `bluetooth_classic.ble_role: discovery_only`;
the MX+ stays `ble` because a BLE-only phone can drive it, and its Classic side
lives in the `bluetooth_classic` block beside the GATT services. A device
whose Classic side is only audio (a smartwatch with A2DP) is `ble` and says
`ble_role: primary_control`.

## Finding one: inquiry, not scan

A BLE scanner never sees a Classic-only device. Finding one is a **Bluetooth
inquiry** — the host asks who is discoverable, and each device answers with its
address, its 24-bit Class of Device and (on SSP hardware) EIR data carrying the
name and its service-class UUIDs. A spec records this as a
`bt_classic_inquiry` discovery method:

```yaml
device:
  discovery:
    methods:
      - type: "bt_classic_inquiry"
        bt_classic:
          name: { match: "prefix", value: "QL-1110NWB" }     # the needle
          service_uuids: ["00001101-0000-1000-8000-00805f9b34fb"]  # narrows it
          requires_discoverable_mode: true
```

The matchers combine differently from a BLE scan's. `name` is the needle, and
`service_uuids` and `class_of_device` only **narrow** a name match, because
every serial module ever made carries the SPP UUID: an OR would make the
example above match all of them. A Classic-only device's inquiry name lives
here and not in `device.identification`, which is what a BLE scan matcher
reads; a dual-mode device that advertises the same name over BLE states it in
both.

Two things about inquiry that BLE people trip over:

- **Most consumer hardware is discoverable only for a window.** A printer
  after its Bluetooth button, a headset held in pairing mode, a speaker for
  two minutes after power-on. Outside the window it answers no inquiry at all
  and looks dead. The button and the window belong in
  `device.pairing.enter_pairing_mode`; `requires_discoverable_mode: true`
  tells a client not to expect the device in a cold scan. Serial modules and
  OBD dongles are the exception: always discoverable, always the same name.
- **A dual-mode device is usually cheaper to find over BLE.** One radio, one
  public address: the BLE advertisement carries the name, and the RFCOMM
  connect goes to the same address the scan returned. That is what the Quin
  app does — an unfiltered BLE scan, a name-prefix check, then
  `createInsecureRfcommSocketToServiceRecord` to the scan result's address.
  `bluetooth_classic.address_shared_with_ble` records whether anyone has
  confirmed the two addresses match; say `unknown` until someone has.

## Opening the socket: SPP, the secure flag, and the bond

Nearly every Classic serial device publishes the **Serial Port Profile**,
SDP UUID `00001101-0000-1000-8000-00805f9b34fb`, on one RFCOMM channel. A
client opens the socket by that UUID (the OS resolves the channel through SDP)
or, on Linux, binds the channel directly:

```bash
rfcomm bind 0 aa:bb:cc:dd:ee:ff 1      # channel 1 is the common case
python -c 'import serial; s = serial.Serial("/dev/rfcomm0"); s.write(b"\x23\x47\x04\x00")'
```

Headphones and earbuds add a **vendor RFCOMM service** under a 128-bit UUID of
the vendor's own beside SPP (Bose BMAP, Sony's headphone control, Samsung's
Galaxy Buds channel); a spec lists it as `profile: vendor` with the UUID. Apple
AAP and a few others use raw **L2CAP** to a PSM instead of RFCOMM, which is
`device.transport: l2cap` (and `transport: l2cap` on its commands) with a
`psm` on the profile.

The flag that decides everything is **`secure`**. An RFCOMM socket is opened
either *secure* — authenticated and encrypted, which means a bond, which means
a pairing dialog on first contact — or *insecure*, which needs no pairing at
all. The vendor app's choice is visible in the decompile (Android has a
constructor for each) and is a fact about the firmware, because a device that
expects an insecure connection may never complete the pairing a secure socket
triggers, and a device that demands authentication rejects an insecure one.
Record it per profile:

```yaml
bluetooth_classic:
  dual_mode: true
  ble_role: "discovery_only"
  address_shared_with_ble: "unknown"
  profiles:
    - profile: "spp"
      uuid: "00001101-0000-1000-8000-00805f9b34fb"
      role: "control"
      secure: false          # insecure socket: no PIN, no bond, no dialog
      verification: "reported"
```

and state the device's pairing story beside it. For a device whose control
channel is its only profile the two agree: `secure: false` is `required:
false, security_mode: none, bonding: none`; a PIN dongle is `required: true,
security_mode: legacy_pin, pin.source: fixed_default`. A headset is the
exception worth knowing: it bonds for A2DP and HFP whatever flag its control
channel is opened with, so `secure: false` beside `required: true` is normal
there. `secure: unknown` tells a client to try an insecure socket first and a
secure one only after the host has bonded.

`device.pairing` describes the link `device.protocol` names. When Classic is
the *second* radio — an OBD family whose BLE members bond with nothing and
whose Classic members want a PIN, a LAN printer with a Bluetooth path — the
Classic story is `bluetooth_classic.pairing`, so neither radio's facts
overwrite the other's. Pairing from the host's own Bluetooth
settings — the step every printer manual gives — is a `setup.methods` entry of
type `bt_classic_pairing`. The link-layer facts stay in `pairing`; the method
carries the person-facing steps.

## The stream has no edges

RFCOMM delivers bytes, not messages. A `read()` returns whatever has arrived:
a reply can land in two pieces, or glued to the next reply, or with the tail of
the previous one. Vendor apps mostly ignore this and work by luck — the Quin
app parses its read buffer with per-command fixed lengths and throws the rest
away on a short read, which is one plausible cause of its "connection failed"
reports. A spec has to give a client what the app never had:

- **`bluetooth_classic.serial.framing`** — whether frames carry a length
  (`length_prefix`) and, if they do, where it sits and what it counts
  (`length_offset`, `length_size`, `length_endianness`, `length_adjust`);
  the checksum on every frame, if any (a checksum inside one command's
  payload, like the pill box's firmware-image CRC-16/XMODEM, belongs on that
  command instead); the leading bytes of each direction (`tx_start_bytes`,
  and `rx_start_bytes` as a list, because the pill box starts replies with
  `26` and pushes with `40`); and the `resync` rule.
- **`commands[].response`** — for a protocol with **no** length field, the
  only way to split the stream is to know each reply's prefix and length, so
  every command states what comes back: `prefix: "26 47 04"` and
  `length: 18` with a `format` for the fields inside, or `expected: false`
  when the device answers nothing, or `expected: unknown` with a note when
  nobody has looked. The `format` vocabulary is the one a BLE characteristic
  uses, offsets counted from the start of the frame, and multi-byte fields
  state their endianness.
- **`bluetooth_classic.serial.unsolicited`** — frames the device sends on
  its own: a low-battery alarm, a charging change, a stream of readings.
  These are as load-bearing as replies. A frame matching no reply prefix and
  no unsolicited prefix has no known length, and a client that meets one
  loses every frame after it.
- **`correlation`** and **`max_in_flight`** — whether a reply is matched to
  its command by prefix (the pill box app has two queries outstanding at
  once) or strictly in order (an ELM327 takes one command at a time).
- **Timing the app observes** — `inter_write_delay_ms` (firmware with a
  small UART buffer drops back-to-back frames), `read_chunk_bytes`,
  `connect_timeout_ms`. These are the numbers a replacement client has to
  copy to behave like the one the firmware was tested against.

ASCII protocols say `encoding: ascii_lines` and spell their delimiters in hex:
`line_terminator: "0d"` ends a line, `prompt: "3e"` ends an ELM327's whole
reply (several lines and then `>`), and `command_terminator: "0d"` goes after
every command a client writes. A text command may be a `body` — the ASCII
written as-is — rather than a byte `value`.

A connect handshake — the pill box's firmware and serial-number queries, both
answered before the app counts the link as up, or an ELM327's `ATZ`/`ATE0` —
is an `initialization` list whose steps name a top-level `command` instead of
a GATT characteristic, with `expect_response: true` where the next step must
wait. A dual-mode adapter whose SPP link carries exactly what its BLE serial
pipe carries points at that characteristic with `serial.commands_from`, and
an RFCOMM client inherits its commands without the spec repeating them.

Commands themselves are top-level `commands` entries with `transport: rfcomm`,
spelled exactly like a BLE characteristic command — a fixed `value` or a
`template` with `{name}` holes filled from `parameters` — because there is no
characteristic to hang them on and one encoder should handle both:

```yaml
commands:
  set_ring:
    description: "Ring type (1-3) and volume (0-3)."
    transport: "rfcomm"
    template: [0x23, 0x53, 0x05, "{type}", "{volume}"]
    parameters:
      type:   { type: "uint8", min: 1, max: 3 }
      volume: { type: "uint8", min: 0, max: 3 }
    verification: "reported"
```

## Can a phone reach it?

The question asked about every SPP device, and the answer splits by platform:

| Host | `stack` value | RFCOMM / SPP | Notes |
|---|---|---|---|
| Android | `android` | Yes | `BluetoothSocket`, secure or insecure; the vendor app's own path |
| Linux (BlueZ) | `bluez` | Yes | `rfcomm bind`, or the socket API; SDP browse with `sdptool` |
| Windows | `windows` | Yes | WinRT `RfcommDeviceService`, or the legacy virtual COM port |
| macOS | `iobluetooth` | Yes | IOBluetooth exposes RFCOMM, L2CAP and SDP |
| **iOS / iPadOS** | `corebluetooth` | **No** | CoreBluetooth exposes GATT only — no RFCOMM, no SPP. The vendor's iOS path is MFi (iAP2 over the ExternalAccessory framework) or nothing — which is why the OBDLink MX+ carries iAP2 and why "Android only" is the honest label on most of these |

A `bluetooth_classic` spec therefore always carries a
`device.host_compatibility` verdict for `corebluetooth` on its BR/EDR link,
and the convention test insists on it:

```yaml
host_compatibility:
  - stack: "corebluetooth"
    link: "br_edr"            # on a dual-mode device the BLE link gets its own verdict
    status: "incompatible"
    symptom: "no_transport"   # the stack has no API for this link
    cause: { missing_api: "rfcomm" }
    workaround: "none_known"  # or "vendor_mfi": only the vendor's MFi app reaches it
    verification: "reported"
    basis: "..."
```

Say `unknown` instead when the vendor ships an iOS app you have not
analysed: it proves the device is reachable from an iPhone *somehow*, most
often over its BLE side, and that is worth finding out before writing the
device off.

The mobile app does not open RFCOMM sockets yet, and its BLE scan matcher
does not yet check `device.protocol` or `bluetooth_classic.ble_role` — so
until it does, a Classic spec that also matches a BLE advertisement is
offered as a BLE device. The schema states the rule a consumer must follow
(never open GATT when `ble_role` is `none` or `discovery_only`); the app
implementing it is the second half of this change.

## Capturing one

The cheapest capture is the same as for OBD dongles: Android's **Bluetooth HCI
snoop log** while the vendor app runs. RFCOMM payloads are visible in the
clear in Wireshark (`btrfcomm` filter), and because most of these protocols
are short binary or ASCII frames, one session that exercises each control —
connect, query, set two or three things, disconnect — verifies the advertised
name, the reply lengths, every byte order the decompile only implied, and the
socket flag. Note the address of your own unit only in your notes; the spec
gets a placeholder.

## Worked examples

- [Quin / Daviky smart pill boxes](../devices/quin-pillcalendar.md) — dual-mode,
  BLE for discovery only, insecure SPP with an unframed binary protocol; the
  first `bluetooth_classic` spec
- [OBD-II Bluetooth Adapters](../devices/obd2-bluetooth-adapter.md) — Classic SPP
  dongles with a fixed PIN, beside their BLE cousins
- [OBDLink MX+](../devices/obdlink-mx-plus.md) — dual-mode with both links usable,
  iAP2 for iOS
- [Brother QL-1110NWB](../devices/brother-ql-1110nwb.md) — a LAN printer whose
  Bluetooth path is Classic SPP after a button press
