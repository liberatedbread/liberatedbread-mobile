# Quin / Daviky Smart Pill Boxes (A170, A1310)

> **Status**: Spec Available
> **Protocol**: Bluetooth Classic SPP (BLE for discovery only)
> **Manufacturer**: ZHUHAI QUIN TECHNOLOGY CO., LTD. (brand Daviky)
> **Manufacturer Status**: Active

## Overview

Daviky's app-connected pill boxes are medication reminders: the box keeps a
handful of alarm times against its own clock and rings with sound and light
when one comes due. The vendor's **PillCalendar** app sets the clock, writes
the alarm slots and picks the ring. Everything else (the medication list, the
dose history, the account) lives in the vendor's cloud. The box never needs
any of that to ring on time.

This is the catalogue's first `protocol: bluetooth_classic` spec, and the box
is the dual-mode case the
[Common Bluetooth Classic Patterns](../protocols/bluetooth-classic-common.md)
page describes. The app **finds** the box with a BLE scan and a name-prefix
check, then **talks** to it over Bluetooth Classic: an insecure RFCOMM socket
to the Serial Port Profile, opened to the address the BLE scan returned. There
is no GATT in the protocol at all.

Everything here comes from static analysis of the vendor Android app
(PillCalendar 3.10.1, read 2026-09-27). No box has been driven from this spec
and no traffic has been captured, so every byte is `reported`. The quickest way
to change that is one HCI snoop session; see
[Why an A170 might misbehave](#why-an-a170-might-misbehave).

Machine-readable spec: `device-specs/devices/quin-pillcalendar.yaml`. Where
this page and the spec disagree, the spec wins.

## Hardware

| Property | Value |
|----------|-------|
| Models | **A170**: 7 alarm slots, weekday repeats, 3 ring types and a sound switch. **A1310**: 6 alarm slots, fingerprint reader, speaker volume, a custom recorded ring, early pick-up lock. A third model the app supports, the A-1281, uses a different codec and is not covered here. |
| Advertised name | Starts `A170` or `A1310`. Whether it is the bare model name or carries a suffix is not established. |
| Chipset | Unknown |
| Radio | Dual-mode Bluetooth: BLE advertising (used only to find the box) plus BR/EDR with SPP (all control). The app assumes one address for both. |
| Power | Rechargeable battery; the box reports charge level, low battery and charging |
| FCC ID | Unknown (not looked up) |
| Vendor app | PillCalendar: Android `com.quin.pillcalendar`, iOS App Store id1592652731 |

Retail listings don't give these model numbers, and the boxes may be sold
under more than one name: besides Daviky, a review of the vendor's iOS app
mentions a "Zoksi" smart pill organizer, model unknown. Identify a unit by
what it advertises (for example with `bluetoothctl` or nRF Connect) rather
than by the box it came in.

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No |
| Method | `none`. Wake the box, scan, open the socket. |
| Advertised name | `A170…` / `A1310…` over BLE |
| Passphrase protection | not_applicable (no network, no credentials) |
| Confidence | medium (the vendor app's code; not replayed) |

A client's first contact is the same as the vendor app's, with two fixes:

1. **Wake the box.** It does not advertise until woken. The vendor app's
   wake-up animations show where to press:
   - **A170**: press once at the top/display end so the screen and Bluetooth
     indicator turn on. The instruction PDF says one press with the screen off
     enables both; another press with the screen on disables them. Keep the
     box awake through discovery. The app's animation shows a slot count such
     as `1/7`, a time and a battery icon.
   - **A1310**: the clock-marked button at the top of the round panel in the
     middle of the dial. The button flashes twice.

   Neither animation gives a hold time, and how long the box stays awake and
   connectable is not established. None of this has been tried on a unit.
2. **Scan BLE** for a local name starting `A170` or `A1310` and keep the
   address.
3. **Open an insecure RFCOMM socket** to
   `00001101-0000-1000-8000-00805f9b34fb` at that address. The vendor
   allows 10 s for this step and the next together.
4. **Handshake:** send `23 47 06 00` (firmware), wait 100 ms, send
   `23 47 04 00` (serial number). The app counts the link as up only once
   both replies have been parsed.
5. **Set the clock:** `23 53 02 00`, then `set_clock` with local time.
6. **Write every alarm slot**: 1-7 on an A170, 1-6 on an A1310, with the
   unused ones written disabled and 50 ms between frames. Writing only the
   slots in use is how old alarms survive (defect 1 below).

**Factory reset**: none is known, and none is needed to change hands. The box
holds no bond and no credentials, and a new client overwrites every setting
it has. To clear a box, write every slot disabled. The app's help text
says a box that "cannot be discovered" may be bound to someone else's
account and sends the user to customer service. Nothing in the box's protocol
carries an owner, so that looks like the vendor cloud's account record and not
state on the box. That hasn't been checked.

**Rebinding**: nothing to rebind. A new phone scans and connects.

## Pairing

| Property | Value |
|----------|-------|
| Pairing required | No |
| Security mode | `none` (insecure RFCOMM socket) |
| Bonding | `none` |
| PIN source | n/a |
| One central at a time | Unknown (likely; typical of SPP modules) |
| One bond at a time | n/a: nothing bonds |
| Confidence | medium (static analysis of the vendor app) |

**Entering pairing mode**: there is no pairing mode, but there is a **wake**
step, and the spec records it under `device.pairing.enter_pairing_mode`
because it gates everything the same way. See step 1 above.

**Unpairing**: nothing to unpair.

**Recovery**: close the vendor app, or turn off Bluetooth on the phone running
it, before connecting from anything else. The vendor app's own troubleshooting
says to remove the box from the phone's system Bluetooth list if it appears
there, toggle Bluetooth, and add the box again. Don't open a *secure* socket:
that makes the host start a pairing the box may never complete.

## Protocol Summary

### Bluetooth Classic profiles

| Property | Value |
|----------|-------|
| Control profile | SPP, `00001101-0000-1000-8000-00805f9b34fb`, RFCOMM channel by SDP (number unknown) |
| Socket | insecure (no bond) |
| Dual-mode | Yes. BLE role: discovery only. Same address assumed, not confirmed. |
| iOS reachable | No over SPP (CoreBluetooth has no RFCOMM, and nothing suggests MFi). The vendor does ship an iOS app; how it reaches these two models is an open question. |
| Stream | binary, no length field, no checksum; 1024-byte reads, 50 ms between writes |

### Frame format

```
host → box   23 ('#')  47 ('G')  <cmd>  <args…>      query (args are 00 on every query here)
host → box   23 ('#')  53 ('S')  <cmd>  <args…>      set
box → host   26 ('&')  47 / 53   <cmd>  <payload…>   reply: fixed length per command
box → host   40 ('@')  47        <cmd>  <1 byte>     unsolicited push
```

There is **no length field and no checksum**. RFCOMM delivers whatever bytes
have arrived, so a reply can land in two reads or share one with the next
reply. A client splits the stream by prefix and a known length per prefix:

| Reply prefix | Total length | Answers |
|---|---|---|
| `26 47 04` | 18 | serial number (15 ASCII bytes) |
| `26 47 05` | 5 | A170 ring type + volume |
| `26 47 06` | 6 | firmware `a b c` → "a.b.c" |
| `26 47 08` | 6 | battery: two unused bytes, then percent |
| `26 47 09` | to end of read | A1310 fingerprint list (see below) |
| `26 47 0A` | 4 | A1310 speaker volume |
| `26 47 0C` | 4 | A1310 play-ring status |
| `26 47 0D` | 4 | A1310 current ring |
| `26 47 0E` | 4 | A1310 custom-ring present |
| `26 47 11` | 4 | early pick-up (`00` = allowed) |
| `26 53 06` | 5 | firmware / upload CRC echo |
| `26 53 08` | 6 | A1310 fingerprint enrolment progress |
| `26 53 09` `0A` `0B` `0C` `0F` | 4 | A1310 status (`01` = ok) |
| `40 47 02`, `26 47 02` | 4 | push: low battery (`A2`) |
| `40 47 03`, `26 47 03` | 4 | push: charging (`11` = charging) |

A reassembler that does better than the vendor app needs about ten lines:

```python
LENGTHS = {b"\x26\x47\x04": 18, b"\x26\x47\x05": 5, b"\x26\x47\x06": 6,
           b"\x26\x47\x08": 6, b"\x26\x47\x0a": 4, b"\x26\x47\x0c": 4,
           b"\x26\x47\x0d": 4, b"\x26\x47\x0e": 4, b"\x26\x47\x11": 4,
           b"\x26\x53\x06": 5, b"\x26\x53\x08": 6, b"\x26\x53\x09": 4,
           b"\x26\x53\x0a": 4, b"\x26\x53\x0b": 4, b"\x26\x53\x0c": 4,
           b"\x26\x53\x0f": 4, b"\x26\x47\x02": 4, b"\x26\x47\x03": 4,
           b"\x40\x47\x02": 4, b"\x40\x47\x03": 4}
# 26 47 09 (A1310 fingerprint list) has no fixed length: send nothing else
# while waiting for it and read until the socket goes quiet.

def frames(buf: bytearray):
    """Yield complete frames from buf, leaving any partial frame in it."""
    while buf:
        if buf[0] not in (0x26, 0x40):
            del buf[0]                      # resync: skip to a start byte
            continue
        if len(buf) < 3:
            return                          # wait for the prefix
        n = LENGTHS.get(bytes(buf[:3]))
        if n is None:
            buf.clear()                     # unknown prefix: lost sync
            return
        if len(buf) < n:
            return                          # wait for the rest
        yield bytes(buf[:n])
        del buf[:n]
```

### Commands

All are `transport: rfcomm` in the spec, with the full parameter ranges,
reply formats and units there.

| Command | Frame | Reply | Model | Notes |
|---|---|---|---|---|
| `query_serial_number` | `23 47 04 00` | `26 47 04` + 15 ASCII | both | connect handshake |
| `query_firmware_version` | `23 47 06 00` | `26 47 06 a b c` | both | connect handshake |
| `query_battery` | `23 47 08 00` | `26 47 08 x y pct` | both | only `pct` is used; `x y` unknown |
| `query_ring` | `23 47 05 00` | `26 47 05 type vol` | A170 | type 1-3; vol 0 = off, 1 = on |
| `set_ring` / `set_ring_volume` | `23 53 05 <type 1-3> <vol 0-3>` | none parsed | A170 | one frame, two controls; send the other byte back unchanged |
| `set_time_format` | `23 53 02 00` | none parsed | both | the app always sends `00`; meaning unknown (12/24 h?) |
| `set_clock` | `23 53 01 YY MM DD hh mm ss` | none parsed | both | YY = year − 2000; plain binary, not BCD |
| `set_alarm_slot` | `23 53 03 slot en rep YY MM DD hh mm 00` | none parsed | both | see below |
| `clear_alarm_slot` | `23 53 03 <slot> 00 00 01 01 01 01 01 00` | none parsed | both | **advanced**; the disabled form of `set_alarm_slot`, bound to one button per slot |
| `firmware_push` | `23 53 06 <crc16 LE> <len u32 LE> <image>` | `26 53 06 <crc16 LE>` | both | **advanced**; no image exists |
| `firmware_commit` / `firmware_abort` | `23 53 07 01` / `23 53 07 00` | none parsed | both | after the CRC echo |
| `query_early_pickup` | `23 47 11 00` | `26 47 11 b` | A1310 | `00` = allowed; the app sends it only to an A1310 |
| `allow_early_pickup` / `refuse_early_pickup` | `23 53 16 00` / `23 53 16 01` | none parsed | A1310 | |
| `query_current_ring` | `23 47 0D 00` | `26 47 0D r` | A1310 | 0-2 built in, 3 custom |
| `set_ring_a1310` | `23 53 0F <0-3>` | `26 53 0F 01` | A1310 | |
| `query_horn_volume` / `set_horn_volume` | `23 47 0A 00` / `23 53 0D <0-3>` | `26 47 0A v` | A1310 | 0 off … 3 max |
| `play_ring` / `stop_ring` | `23 47 0C 00` / `23 53 15 00` | `26 47 0C 01` / none | A1310 | |
| `query_custom_ring_status` | `23 47 0E 00` | `26 47 0E b` | A1310 | `01` = recording stored |
| `custom_ring_upload` | `23 53 0C <crc16 LE> <len u32 LE> <audio>` | `26 53 0C 01` | A1310 | the app records MP3 at 8 kHz |
| `fingerprint_enroll` | `23 53 08 <id 1-10>` | `26 53 08 id count progress` | A1310 | |
| `fingerprint_enroll_cancel` | `23 53 0B 00` | `26 53 0B 01` | A1310 | |
| `fingerprint_list` | `23 47 09 00` | `26 47 09 ?? ??` then `id name… 0D` repeated | A1310 | runs to the end of the read |
| `fingerprint_set_name` | `23 53 09 <id> <UTF-8 name> 0D` | `26 53 09 01` | A1310 | |
| `fingerprint_delete` | `23 53 0A 00 <id>` | `26 53 0A 01` | A1310 | note the `00` before the id |

"None parsed" means the vendor app ignores anything that comes back. Whether
the box sends an acknowledgement is unknown. If it does, the acknowledgement
has no known length and costs a naive client its sync.

### Alarm slots

```
23 53 03  <slot>  <en>  <repeat>  <YY> <MM> <DD>  <hh> <mm>  00
```

- `slot`: 1-7 on an A170, 1-6 on an A1310. The vendor app sorts reminders by
  time and numbers them by position, so a slot number means nothing on its own.
- `en`: `01` enabled, `00` disabled. A disabled slot carries `01 01 01 01 01`
  for the date and time. The empty slots the app pads the list with get
  repeat `00`, but a reminder the user switched off keeps its weekday mask,
  so ignore `repeat` when `en` is `00`.
- `repeat` (A170): `00` one-shot, `01` every day, otherwise one bit per
  weekday. The A1310 always gets `01`.

  | Weekday index | 0 | 1 | 2 | 3 | 4 | 5 | 6 |
  |---|---|---|---|---|---|---|---|
  | Bit | `0x80` | `0x02` | `0x04` | `0x08` | `0x10` | `0x20` | `0x40` |

  Bit 0 is reserved for "every day", which the app sends instead of all seven
  bits. Index 0 is probably Sunday. That isn't confirmed.
- Date: the one-shot date for a one-shot reminder, and **the day of the
  write** for a repeating one. Time is 24-hour. All fields are plain binary.

Worked examples, computed from the app's encoder (not captured):

```
23 53 03 01 01 2A 1A 09 1B 08 1E 00   slot 1, on, weekday idx 1+3+5 (0x2A), 08:30, written 2026-09-27
23 53 03 02 01 01 1A 09 1B 14 00 00   slot 2, on, every day, 20:00
23 53 03 03 01 C0 1A 09 1B 07 2D 00   slot 3, on, weekday idx 0+6 (0xC0), 07:45
23 53 03 04 01 00 1A 0A 03 0C 0F 00   slot 4, on, one-shot 2026-10-03 12:15
23 53 03 07 00 00 01 01 01 01 01 00   slot 7, cleared
23 53 01 1A 09 1B 0E 05 09            clock 2026-09-27 14:05:09
```

There is no command to read a slot back, so a client can only overwrite.

### Unsolicited frames

`40 47 02 A2` means low battery. `40 47 03 11` means charging, and any other
last byte means not charging. The app also accepts the same two with a `26`
lead byte. When the box sends them isn't known. The spec binds both to binary
sensors through `bluetooth_classic.serial.unsolicited`.

### Firmware update

The app sends the whole image in one frame: `23 53 06`, then the
**CRC-16/XMODEM** of the image as u16 little-endian (poly `0x1021`, init 0,
no reflection; check value `0x31C3` over `"123456789"`), then the length as
u32 little-endian, then the image. The app names the checksum as if it were a
CRC-32, but it is 16 bits. The box answers `26 53 06` with its own CRC. The app
sends `23 53 07 01` on a match and `23 53 07 00` on a mismatch or a cancel.
Example with a made-up 4-byte image `01 02 03 04`:
`23 53 06 03 0D 04 00 00 00 01 02 03 04`, echo `26 53 06 03 0D`.

The vendor cloud's firmware lookup returned nothing for any model or version
tried, so **no image has been obtained**. Signing, image format and recovery
from an interrupted update are all unknown. The spec marks the push
`advanced`. A box that stops booting also stops reminding someone to take
their medication. See [Firmware Update](../protocols/firmware-update.md) for
the catalogue's conventions.

### Controls a client can offer

The spec's `entities` block binds these:

| Control | Platform | Model | Source |
|---|---|---|---|
| Battery | sensor, % | both | `query_battery` |
| Charging | binary sensor | both | `charging` push only; unknown until the box sends one |
| Low Battery | binary sensor | both | `low_battery` push only; nothing is known to clear it |
| Ring Tone | select (Ring A/B/C) | A170 | `query_ring` / `set_ring`, which sends the volume back unchanged |
| Alarm Sound | switch | A170 | `query_ring` / `set_ring_volume` (volume byte 0 or 1) |
| Ring Tone | select (Ring A/B/C, custom) | A1310 | `query_current_ring` / `set_ring_a1310` |
| Speaker Volume | select (off/low/medium/max) | A1310 | `query_horn_volume` / `set_horn_volume` |
| Allow Early Pick-up | switch | A1310 | `query_early_pickup` / `allow_early_pickup` / `refuse_early_pickup` |
| Play Ring, Stop Ring | buttons | A1310 | `play_ring`, `stop_ring` |
| Clear Alarm Slot 1-7 | buttons (advanced) | slots 1-6 both, 7 A170 only | `clear_alarm_slot` |

Writing an alarm has no entity: the vocabulary has no time or schedule
control, and a slot takes eight values. A client that edits reminders does
it with `set_alarm_slot` directly, and should also send `set_time_format`
and `set_clock` on every connection. Clock sync can't be a one-tap button
either, because no parameter source names the host's clock.

## Why an A170 might misbehave

These come from reading the vendor app's code. None has been observed on a
box yet. They're ranked by how well they fit the complaint "the box doesn't
work right with the app". Each one lists what to try and what a capture would
settle.

### 1. It rings for a reminder you deleted

**Cause.** The app has three ways of writing alarms. The main reminder sync
runs only when you save from the box's reminder-management screen (or the
reminder editor) while the box is connected. It pads the list to seven
entries on an A170 (six on an A1310), so removed reminders get cleared. The
other two paths are the per-reminder on/off switch on the home screen and
the write after a refresh (pull-to-refresh, or reopening the app). They send
only the reminders the server currently has, without padding. So if the list
shrinks any other way (say someone deletes a reminder from another phone on
the account), the next refresh writes slots 1 to *n* only. The slots past the
end of the new list keep their old times and keep ringing. The same two paths
sort by time, so adding or editing a reminder also renumbers every slot.

**Try.** With the box awake and connected, open its reminder-management
screen, make any change (or re-save an existing reminder) and save. That is
the only path that writes the empty slots. Reopening the app or pulling to
refresh does **not** clear leftovers; it goes through the unpadded path. From
your own client, write every slot and disable the unused ones, or just clear
the stale ones: with *n* reminders left, slots *n*+1 to 7 (6 on an A1310) are
the leftovers, and `clear_alarm_slot` (a button per slot in the spec) sends
`23 53 03 <slot> 00 00 01 01 01 01 01 00` for each. Clearing a slot that
still holds a live reminder silences it until the app next syncs, so count
your reminders first.

**A capture settles** whether the short list really goes out after a
refresh, and whether slots 6-7 of an old seven-reminder schedule keep
ringing. The test: set three reminders, delete one from a second phone
logged into the same account, pull to refresh on the first, and wait for
the deleted time.

### 2a. It is not found at all

A negative scan does not prove an unsupported model or a wrong address. A
sleeping, out-of-range, renamed or already-connected box looks the same. Work
through these checks before considering a reset:

1. Charge the box and use the A170 one-press wake procedure above. Keep the
   screen and Bluetooth indicator on.
2. Close other apps/phones connected to the box; do not reset merely to break
   a connection.
3. Check Android version/vendor permissions. Android 9–11 needs fine location
   and a location provider; Android 12+ needs nearby-device scan/connect
   permissions (some Huawei/OCE/honor builds also require location services).
4. Capture the **current** advertised name and address instead of relying on
   an old note. The supported exact names are `A170`, `A1310` and `A-1281`.
5. If the name has a suffix, the app's prefix scan can accept it while its
   exact-name model selection sends it to a no-op handler. That is an app
   defect, not a MAC-address problem.

The [A170 manual](https://m.media-amazon.com/images/I/B1688ivWcRL.pdf) and
[A1310 instruction sheet](https://m.media-amazon.com/images/I/C1C2N0jzkNL.pdf)
are now available for the physical procedures. A1310's FAQ says a factory
reset clears alarms, custom rings and fingerprints; it is not a routine fix
for discovery trouble.

### 2. It is found, but "connection failed" every time

**Cause.** The scan keeps any name that *starts with* `A170`, but the app's
model factory needs the name to *be* exactly `A170`. A box advertising, say,
`A170-1234` would be listed and would connect, and then would get a handler
that sends nothing. The handshake never completes, and after 10 s the app
reports a failed connection. The app registers the box with its cloud under
the scanned name and rebuilds the handler from the model name the cloud
returns, so unless the cloud normalises the name this fails on every
connection, not just the first.

**Try.** Look at the advertised name with `bluetoothctl` (`scan on`) or nRF
Connect. If it carries a suffix, this is the cause, and only a vendor app fix
or a third-party client gets around it.

**A capture settles** the advertised name, over BLE and over a Classic
inquiry.

### 3. "Connection failed" sometimes, then fine on retry

**Cause.** The app parses each RFCOMM read on its own. It has no length field
to work with and does no reassembly. If the serial-number reply (18 bytes)
or the firmware reply lands split across two reads, the parser throws, drops
the rest, and the handshake fails.

**Try.** Retry with the phone close to the box and nothing else using
Bluetooth heavily. The spec's reply-length table lets a replacement client
avoid the problem entirely (see the reassembler above).

**A capture settles** the real reply lengths, and how often replies arrive
split.

### 4. It went quiet after you changed the ring

**Cause.** One frame carries both the A170 ring type and the volume. The app
builds it in a single shared buffer and never refreshes that buffer from the
box. The byte a screen doesn't touch is whatever the app last wrote, which is
`00` after the app restarts. So the first ring-type change after launch also
sends volume `00` (sound off), and the first sound toggle sends ring type
`00`, outside the valid 1-3. Two quick changes can also race.

**Try.** After changing the ring, toggle the sound switch off and on again, so
that the app has written both bytes itself.

**A capture settles** what goes out on each change, and what the box does with
ring type `00`.

### 5. It rings at the wrong time, or not at all

**Cause.** The box has no clock source of its own. The app sets its clock
only after connecting from its device screen and on each reminder sync.
Repeating alarms also carry the date of the write. A box that drifted, or ran
flat and lost its time, stays wrong until the next connection.

**Try.** Charge the box, then open the app's device screen so it reconnects
and sets the clock.

**A capture settles** nothing here. Compare the box's display with a watch
over a few days instead.

### 6. Replies to sets (a possible sixth)

The app ignores any reply to the clock, alarm, ring and time-format frames.
If the box does acknowledge them, the app's parser drops the rest of that
read, and during its burst of queries after a sync that could swallow the ring
or battery reply behind it.

### Capturing a session

One Android HCI snoop session settles almost every open question in the spec:
the advertised name, whether the BR/EDR address is the BLE address, every
reply length, the weekday bit order, whether sets are acknowledged, and
whether a deleted slot keeps ringing.

1. On the phone, enable Developer options, turn on **Enable Bluetooth HCI
   snoop log**, then toggle Bluetooth off and on
   ([Android's guide](https://source.android.com/docs/core/connect/bluetooth/verifying_debugging)).
2. Wake the box and, in the vendor app, connect, set two or three reminders
   (one repeating on specific weekdays, one daily), delete one, change the
   ring, and flip the sound switch.
3. Note the wall-clock time of each action, then take a bug report
   (`adb bugreport`) and pull the `btsnoop_hci.log` out of it.
4. In Wireshark, the `btrfcomm` filter shows the payloads; the BLE
   advertising reports show the name and address.

Your own unit's address, serial number and name belong in your notes only.
The spec and this page use `aa:bb:cc:dd:ee:ff` and invented serials.

From Linux, a first look without the app:

```bash
bluetoothctl scan on                          # note the A170… name and its address
sdptool browse aa:bb:cc:dd:ee:ff              # find the Serial Port channel
```

```python
import socket, time
ADDR, CHANNEL = "aa:bb:cc:dd:ee:ff", 1        # channel from sdptool
s = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_STREAM, socket.BTPROTO_RFCOMM)
s.connect((ADDR, CHANNEL))                    # BlueZ default (low security): no PIN, no dialog
for frame in ("23 47 06 00", "23 47 04 00", "23 47 08 00"):
    s.send(bytes.fromhex(frame))
    time.sleep(0.1)
s.settimeout(2)
data = b""
try:
    while True:
        data += s.recv(1024)
except socket.timeout:
    pass
print(data.hex(" "))                          # expect 26 47 06 …, 26 47 04 …, 26 47 08 …
```

If that connects and answers, the BR/EDR address is the BLE address, and
`address_shared_with_ble` can become `true`.

## Tools Used

- [x] apkeep: vendor Android app (XAPK)
- [x] jadx: static analysis of the app's device layer
- [ ] Android HCI snoop log of an app session (pending hardware)
- [ ] `bluetoothctl` / `sdptool` against a real unit (pending hardware)

## References

- [PillCalendar on Google Play](https://play.google.com/store/apps/details?id=com.quin.pillcalendar): the Android app this spec was read from
- [PillCalendar on the App Store](https://apps.apple.com/us/app/pillcalendar/id1592652731): the iOS build
- [Android: Bluetooth verifying and debugging](https://source.android.com/docs/core/connect/bluetooth/verifying_debugging): HCI snoop logging
- [Wireshark `btrfcomm` display filter](https://www.wireshark.org/docs/dfref/b/btrfcomm.html)
- [CRC RevEng catalogue, 16-bit CRCs](https://reveng.sourceforge.io/crc-catalogue/16.htm): CRC-16/XMODEM parameters
- [Common Bluetooth Classic Patterns](../protocols/bluetooth-classic-common.md)
- [Pairing, Bonding and Unpairing](../protocols/pairing.md)

## Contributors

- @claude - static analysis of the vendor Android app, spec and page
