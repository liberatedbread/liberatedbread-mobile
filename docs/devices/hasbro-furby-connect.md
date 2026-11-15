# Hasbro Furby Connect (2016)

> **Status**: Spec Available (unverified)
> **Protocol**: BLE (vendor GATT service, phone-direct)
> **Manufacturer**: Hasbro
> **Manufacturer Status**: Abandoned. The companion app is deprecated and the toy is unsupported

## Overview

Furby Connect is the 2016 Furby. It has LCD eyes, an antenna that lights up in
RGB and also works as a joystick, tickle and pet sensors, an accelerometer, a
speaker and motors. The Furby Connect World app controlled it directly over
Bluetooth LE. The app also downloaded "DLC" packs of new songs, eye
animations and reactions from Hasbro's servers and flashed them into the toy.
That app is now deprecated. PyFluff's README calls the toy "now unsupported",
and neither source gives a date.

Everything the app did locally can be done without it. You can play any
built-in action sequence, set the antenna colour, set the mood meters, switch
the eye backlight, set the Furby's name, receive sensor reports and upload
DLC files. This page and the spec consolidate
[bluefluff](https://github.com/Jeija/bluefluff), the original reverse
engineering, with [PyFluff](https://github.com/martinwoodward/PyFluff), a
modern Python port of it.

!!! note "Hasbro content is out of scope"
    The spec describes how a DLC file is uploaded and what is known about the
    container's structure. It does not describe the content of Hasbro's own DLC
    files, audio or images, and it does not reproduce bluefluff's catalogue of
    what the Furby says for each action.

## Hardware

| Property | Value |
|----------|-------|
| Model | Furby Connect (2016) |
| Chipset | Nordic nRF51-series BLE SoC (inferred from its stock DFU service) in front of a GeneralPlus MCU that runs movement, speech and the eyes |
| Radio | Bluetooth LE |
| FCC ID | Not recorded |
| Category / hierarchy | `other` |
| Aliases | Furby Connect, Furby 2016 |
| Companion apps | Furby Connect World (Android/iOS, deprecated) |
| Firmware seen | GeneralPlus `04`, Nordic `19 00 00 00` (bluefluff's unit) |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No |
| Method | `ble_direct`: connect, subscribe, then write a keep-quiet byte every 3 s |
| Advertised name | `Furby` (exact) |
| Passphrase protection | not_applicable |
| Confidence | medium (two published clients; not replayed here) |

Neither source records any advertised data besides the name, and other
devices may use the same name. Confirm the device after connecting by finding
the Fluff service. PyFluff reports that a Furby busy playing with another
Furby (F2F) can stop advertising. Touching or shaking it brings advertising
back.

While a client is connected it must keep the Furby busy, or the toy chats and
moves on its own. Both open clients write `00` every 3 seconds. The vendor app
wrote `20 06` instead.

**Factory reset**: unknown. Neither source describes one, and no instruction
sheet was fetched for this spec. `delete_dlc_slot` clears downloaded content
but is not a reset.

**Rebinding to a new phone**: nothing to rebind. There is no bond. A client
that crashes without disconnecting can leave the Furby refusing connections
(bluefluff). The sources give no recovery. Removing the batteries is the
obvious thing to try, but it is not documented.

## Pairing

| Property | Value |
|----------|-------|
| Pairing required | No |
| Security mode | `none` |
| Bonding | `none` |
| One central at a time | Unknown |
| Confidence | medium |

The Furby keeps advertising while it looks asleep, including with the sleep
mask on.

## Protocol Summary

### BLE Services

| UUID | Name | Description |
|------|------|-------------|
| `00001800-0000-1000-8000-00805f9b34fb` | Generic Access | Device Name is listed read/write. No source writes it |
| `0000180a-0000-1000-8000-00805f9b34fb` | Device Information | Six standard strings |
| `00001530-1212-efde-1523-785feabcd123` | Nordic legacy DFU | Stock buttonless DFU. Never written by either source |
| `dab91435-b5a1-e29c-b041-bcd562613bde` | Fluff service | Everything Furby-specific |

Fluff service characteristics. All share the tail `-b5a1-e29c-b041-bcd562613bde`:

| UUID | Name | Use |
|------|------|-----|
| `dab91383-…` | GeneralPlus write | Commands to the main MCU (write without response) |
| `dab91382-…` | GeneralPlus listen | Replies, events, sensor reports (notify) |
| `dab90757-…` | Nordic write | Commands to the BLE SoC |
| `dab90756-…` | Nordic listen | Nordic replies and upload acks (notify) |
| `dab90758-…` | File write | Raw DLC bytes during an upload |
| `dab90755-…` | RSSI listen | Subscribed by both clients. No data was seen |
| `dab91440-…` / `dab91441-…` | Unknown | Suspected Furby-to-Furby channel. Unused |

### Commands

Each command is one write of 1–20 bytes with the opcode first. There is no
length byte, no checksum and no encryption. Replies come back with the same
opcode-first shape.

| Command | Bytes | Notes |
|---------|-------|-------|
| Keep quiet | `00` | Every 3 s while connected |
| Play action | `13 00 input index subindex specific` | `10`/`11`/`12` fix only the first 1/2/3 numbers and the Furby picks the rest |
| Antenna colour | `14 R G B` | `14 00 00 00` is off |
| Set name | `21 n` | n = 0–128. Follow it with `13 00 21 00 00 n` so the Furby says the name |
| Mood meter | `23 mode type value` | mode 1 sets, 0 adds. Type 0 excited, 1 displeased, 2 tired, 3 fullness, 4 wellness |
| Eye backlight | `cd 01` / `cd 00` | Replies `20 17` / `20 18` |
| Debug screen | `db` | Cycles through seven LCD debug screens |
| Sensor stream | `20 0d` / `20 0e` | Starts or stops continuous `21` reports |
| Packet acks (Nordic) | `09 01 00` / `09 00 00` | Enable before a DLC upload |
| Announce DLC upload | `50 00 size(3, BE) slot name(12, NUL-padded) 00 00` | **Advanced**. Exactly 20 bytes |
| Load / activate / deactivate DLC | `60 slot` / `61` / `62 slot` | |
| Delete DLC slot | `74 slot` | **Advanced**. Official DLC cannot be downloaded again |

bluefluff's opcode table lists the mood meter command as `0x24`. Its own
client and PyFluff both send `0x23`, so the spec uses `0x23` and records the
conflict.

The names are 13 first syllables combined with 10 second syllables, in a fixed
order, without "Tay-Tah": 129 in total. Index 0 is Ah-Bay and index 128 is
Way-Toh. The spec carries the syllables and the rule.

### Notifications (GeneralPlus listen)

| Byte 0 | Meaning |
|--------|---------|
| `20 xx` | Event: sequence playing/ended, out of range, sleep mask on/off, LCD on/off, … |
| `21` + 7 bytes | Sensor report covering the antenna joystick, tickle/pet sensors and accelerometer. **The 7 bytes are not decoded by any source** |
| `22` + 18 bytes | "I'm here" reply to `20 06`. Not decoded |
| `24 xx` | DLC transfer status: `02` ready, `05` OK, `06` error, `03` timeout, `01` exists |
| `fe xx` | GeneralPlus firmware version |

### DLC upload (structure only)

1. Enable Nordic packet acks (`09 01 00`).
2. Send the announce frame with the file size, the slot and the name.
3. Wait for `24 02`.
4. Write the file raw to File write in 20-byte pieces, about 5 ms apart. There
   is no header and no sequence number. Watch for `09 xx` acks. A `0a` reply
   means the writes are too fast.
5. Wait for `24 05`. This takes 3–5 minutes.
6. Send Load (`60 slot`), then Activate (`61`). The content plays as action
   input 75.

The sixth debug screen shows each slot's state: `0` empty, `1` partial,
`2` downloaded, `3` active. The container format itself has not been
reversed. Only two facts about it are published: the audio uses the GeneralPlus
A1800 codec in 40-byte, 20 ms blocks, and the Furby does not checksum a file
it receives.

### Firmware update

The Nordic SoC carries the stock nRF5 SDK legacy DFU service. The spec
declares the stack's default entry command (`01 04` to the control point) as
`advanced` and as a hypothesis. No source has sent it to a Furby, no Furby
firmware image is public, and nothing says the GeneralPlus MCU can be updated
over BLE.

## Tools Used

- Source reading only: bluefluff documentation and Node.js client, PyFluff
  Python client and tests. No hardware session.

## References

- [Jeija/bluefluff](https://github.com/Jeija/bluefluff) (MIT, © 2017 Florian Euchner). See `doc/bluetooth.md`, `doc/generalplus.md`, `doc/nordic.md`, `doc/flashdlc.md`, `doc/dlcformat.md` and `fluffd/fluffaction.js`
- [martinwoodward/PyFluff](https://github.com/martinwoodward/PyFluff) (MIT, © Martin Woodward). See `pyfluff/protocol.py`, `pyfluff/dlc.py` and `docs/f2f-connectivity.md`
- Spec: `device-specs/devices/hasbro-furby-connect.yaml`
- Tests: `scripts/test_hasbro_furby_connect_spec.py`

## Contributors

- Spec consolidated from public sources. Not verified on hardware.
