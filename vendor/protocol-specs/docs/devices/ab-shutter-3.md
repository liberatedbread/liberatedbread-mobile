# AB Shutter 3 and Generic Bluetooth HID Shutter Remotes

> **Status**: Spec Available (community-reported facts; no capture, not run against hardware)
> **Protocol**: Bluetooth Classic (HID); BLE HID-over-GATT on rings and newer clones
> **Manufacturer**: Various OEMs (YiChip-based AB Shutter 3, CamKix and unbranded clones)
> **Manufacturer Status**: Active (sold everywhere, supported by nobody; nothing to abandon)

## Overview

The "AB Shutter 3" is the two-button, coin-cell camera-shutter fob sold for
$2–15 under dozens of names. Page turners, selfie-stick buttons and scroll
rings behave the same way, so they are covered here too. It needs **no app,
no cloud and no account**. It is a standard Bluetooth **HID** peripheral, a
keyboard plus consumer-control device. You pair it from the host's own
Bluetooth settings, and the host's HID stack turns every press into an
ordinary key event. The shutter works because phone camera apps take a
picture when a volume key is pressed.

No companion app exists. A 2026-09 survey of the three Play Store / F-Droid
apps that carry the "BLE remote" name confirmed that none of them drives this
hardware. One is Nordic's stock UART sample, one sends user-defined strings to
hobby boards over SPP or BLE, and one turns the phone itself into a HID remote.

This page documents what the specs do not say: which keys this family's
buttons send, how the clones differ, and how the remote behaves on the link.
The machine-readable version is
[`device-specs/devices/ab-shutter-3.yaml`](https://github.com/liberatedbread/liberatedbread-protocol-specs/blob/main/device-specs/devices/ab-shutter-3.yaml).

## Hardware

| Property | Value |
|----------|-------|
| Model Number | Sold as "AB Shutter 3" with no model number; CamKix D0027-SRC-BLA (and -BLU/-GRE/-RED/-WHI); selfie sticks with the button in the grip, such as Sumvision's monopod |
| Chipset | YiChip Bluetooth SoC, Classic Bluetooth (MobileRead report); the host names the input device "YiChip BT Keyboard" |
| Radio | Bluetooth Classic HID. AB Shutter3 manual: "Wireless V4.0". CamKix FCC manual: 2400–2483.5 MHz, max +3.9 dBm. Sumvision handle: Bluetooth 3.0, GFSK. BLE HID-over-GATT on rings and some newer clones |
| Controls | Fob: a larger and a smaller button (the AB Shutter3 manual calls them Button A and Button B; CamKix prints "iOS" on the larger and "Android" on the smaller), a side ON/OFF slide switch, a blue LED. Selfie-stick handle: camera key, two zoom keys, power key, green and red LEDs |
| Power | Fob: one CR2032, about 6 months at 10 presses a day (AB Shutter3 manual). Sumvision handle: 100 mAh lithium cell, micro-USB charging, 3–4.2 V, 1 mA working, 0.5 mA dormant |
| Range | 10 m / 30 ft (all three manuals) |
| FCC ID | [2AUYP-CAMKIX](https://fccid.io/2AUYP-CAMKIX) (CamKix Bluetooth Remote Shutter, grantee OEM Tech Bargains LLC); no FCC ID has been recorded for unbranded AB Shutter 3 units |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | Yes (OS-level pairing is the whole setup) |
| Method | `bt_classic_pairing` |
| Advertised name | `AB Shutter3` (manual), listed as "AB Shutter 3"; CamKix D0027-SRC: `CamKix Shutter`; Sumvision handle: `SUMVISION` |
| Passphrase protection | not_applicable |
| Confidence | medium (three retail manuals and community guides agree; not run here) |

### Shutter fob

1. Fit a CR2032 positive side up, or pull the isolation strip on a new unit.
2. Slide the side switch to **ON**. The blue LED flashes quickly, which means
   the remote is discoverable.
3. On the phone, tablet or computer, open Bluetooth settings and choose
   **AB Shutter3** (or **CamKix Shutter**, or the clone's own name). No PIN is
   asked for, and pairing finishes by itself.
4. Press each button and see what the host does with it (see the key map
   below).

On Samsung phones, the camera's volume-key setting must be set to take
pictures before the shutter fires. This is reported for One UI 6 and later,
and the menu wording varies by version.

### Selfie-stick handle

Sticks with the button in the grip have a power key instead of a slide
switch. The camera key doubles as the pairing button. These steps are from
the Sumvision manual, and other handles differ in hold time and LED colour.

1. Charge the handle over micro-USB if it has been stored. The red LED lights
   while it charges.
2. Short-press the power key. The LED lights and goes out after about a
   second.
3. Hold the camera key for **2 seconds**. The green LED flashes, which means
   the handle is in pairing mode.
4. Choose **SUMVISION** (or the stick's own name) on the phone. About
   8 seconds later the green LED stays lit, which means it is paired.

### Headless Linux

On a headless Linux host (a Raspberry Pi page turner, say), use
`bluetoothctl`:

```text
scan on                     # wait for "AB Shutter3"
pair aa:bb:cc:dd:ee:ff
trust aa:bb:cc:dd:ee:ff     # lets the remote's own reconnects through
connect aa:bb:cc:dd:ee:ff
```

Current BlueZ accepts HID connections only from **bonded** Classic devices
(`ClassicBondedOnly=true` in `input.conf`), so you cannot skip `pair`. Then
find the new node in `/proc/bus/input/devices` and read it with `evtest`.

**Factory reset**: none is documented. The remote has no reset button, and
none of the manuals or community sources describes one. Its only state is the
link key of the host it paired with. Nobody knows whether pulling the battery
clears that.

**Rebinding to a new host**: this works in place. Forget the remote on the old
host, or turn that host's Bluetooth off, so the remote cannot reconnect to it.
Then switch the remote off and on and pair it from the new host. This is
inferred from the reconnect behaviour, not tried.

## Pairing

| Property | Value |
|----------|-------|
| Pairing required | Yes (every host bonds it before its HID channels are used) |
| Security mode | `just_works` (inferred: no PIN anywhere, no display or keypad on the remote) |
| Bonding | `required` |
| PIN source | none asked for |
| One central at a time | Yes (a Classic HID device keeps one host link) |
| One bond at a time | Unknown |
| Confidence | medium |

**Entering pairing mode**: on a fob, switch it on. If it is already on and
connected, or asleep, switch it off and on again. The blue LED flashes
quickly while the remote is discoverable. On the Sumvision handle, hold the
camera key for 2 seconds until the green LED flashes. How long the fobs stay
discoverable is not recorded.

**LED once connected**: the Sumvision handle's green LED stays lit. Neither
fob manual says what the blue LED does. The Kindle guide describes it as on
while connected and flashing on each press.

**Unpairing**: no button sequence on the remote is documented. The only way
any source describes is to forget the device on the host.

**Recovery**: the remote reconnects to the host it knows, and **the remote,
not the host, starts the reconnection**. If it keeps landing on an old phone,
forget it there and power-cycle the remote. If a paired host has stopped
getting presses, press a button, or switch the remote off and on and wait
about 20 seconds.

Anyone within range can pair the remote while its LED is flashing. The pairing
has no PIN and no confirmation on the device.

## Protocol Summary

There are no commands. The remote only sends, and what a program receives is
the host's key event, not the HID report. The key codes in the table below are
what an application binds to.

### Bluetooth Classic profiles

| Property | Value |
|----------|-------|
| Control profile | HID, SDP service class `00001124-0000-1000-8000-00805f9b34fb` |
| Channels | L2CAP PSM `0x0011` (HID Control, opened first) and `0x0013` (HID Interrupt, input reports) |
| Report descriptor | In the SDP record, attribute `0x0206` (HIDDescriptorList); never dumped for this family |
| Socket | secure (bonded, encrypted); the client is the OS HID stack, not an app |
| Dual-mode | Unknown for the Classic units; the BLE rings and clones are separate products |
| iOS reachable | Yes as a keyboard (the Camera app's shutter fires on Volume Up); CoreBluetooth offers apps no access to the reports |

### Link behaviour

| Behaviour | Value | Source |
|---|---|---|
| Who reconnects | The remote; the host waits to be called | Kindle guide |
| Reconnect after the host restarts Bluetooth | 14–20 s, measured on one fob | Kindle guide |
| Reliable manual reconnect | Switch off and on, wait about 20 s | Kindle guide |
| Idle time before sleep | 300 s (5 minutes) on the Sumvision handle; not documented for the fobs | Sumvision manual |
| Wake | One short press; the remote reconnects by itself | Sumvision manual, community reports |

### Key map

Which **usage page** a clone uses has never been read from a descriptor.
Volume Up can come from the Consumer page or the Keyboard page, and every host
maps both to the same key. On Linux, evtest prints the usage as
`EV_MSC / MSC_SCAN` before each key event (`page << 16 | usage`), and that
value tells you which one a unit sends.

| Function | HID usage (page:usage) | MSC_SCAN | Linux | Android | Windows VK | Seen on |
|---|---|---|---|---|---|---|
| Volume Up | `0x0c:0x00e9` or `0x07:0x80` | `0xc00e9` / `0x70080` | `KEY_VOLUMEUP` 115 | `KEYCODE_VOLUME_UP` 24 | `VK_VOLUME_UP` `0xaf` | top (larger) button; both buttons in "Android mode"; Windows report |
| Enter | `0x07:0x28` | `0x70028` | `KEY_ENTER` 28 | `KEYCODE_ENTER` 66 | `VK_RETURN` `0x0d` | bottom (smaller) button on the AB Shutter 3 |
| Volume Down | `0x0c:0x00ea` or `0x07:0x81` | `0xc00ea` / `0x70081` | `KEY_VOLUMEDOWN` 114 | `KEYCODE_VOLUME_DOWN` 25 | `VK_VOLUME_DOWN` `0xae` | second button on some clones; Windows report |
| Play/Pause | `0x0c:0x00cd` | `0xc00cd` | `KEY_PLAYPAUSE` 164 | `KEYCODE_MEDIA_PLAY_PAUSE` 85 | `VK_MEDIA_PLAY_PAUSE` `0xb3` | Windows report; scroll rings |
| Next track | `0x0c:0x00b5` | `0xc00b5` | `KEY_NEXTSONG` 163 | `KEYCODE_MEDIA_NEXT` 87 | `VK_MEDIA_NEXT_TRACK` `0xb0` | Windows report; scroll rings |
| Previous track | `0x0c:0x00b6` | `0xc00b6` | `KEY_PREVIOUSSONG` 165 | `KEYCODE_MEDIA_PREVIOUS` 88 | `VK_MEDIA_PREV_TRACK` `0xb1` | Windows report; scroll rings |

**Genuine AB Shutter 3**: the top button sends Volume Up (115) and the bottom
one sends Enter (28). On the CamKix-sold fob the Kindle guide used, the top
button is the larger, iOS-labelled one. **Many clones** ship in an "Android
mode" where both buttons send Volume Up. They switch with a physical
iOS/Android slider or by holding both buttons for about 3 seconds. The
Sumvision handle's manual says it needs no such switch. Some remotes expose
two input nodes, a keyboard and a consumer-control device, so read every new
`/dev/input/event*`. What selfie-stick zoom keys send has not been reported.

**Events**: EV_KEY value 1 on press and 0 on release. While a button is held,
some hosts see value 2 (repeat) events, which the Kindle guide uses for long
presses. On stock Linux the kernel's own autorepeat also produces them. The
Kindle guide debounces at 200 ms because the remote sometimes repeats a press.

### Reports, for reference

These are standard layouts, **not a capture of this family**. The real layout
is whatever the remote's own descriptor says. HID fields are little-endian.

| Report | Bytes | Source |
|---|---|---|
| Boot keyboard input | `[modifiers][reserved][key1..key6]`, 8 bytes; Enter is usage `0x28` in a key slot | USB HID 1.11 Appendix B.1 |
| Consumer control | `[report id][usage lo][usage hi]`; Volume Increment is `e9 00`, release `00 00` | Atharok BtRemote `Constants.kt` |
| Relative mouse | `[report id][buttons: bits 0-2][x int8][y int8][wheel int8]` | Atharok BtRemote `Constants.kt` |

On the Classic interrupt channel each input report is preceded by the HIDP
transaction header `0xa1` (DATA, Input).

### BLE variants (HID over GATT)

Scroll rings, page turners and newer clones send the same usages over service
`00001812-0000-1000-8000-00805f9b34fb`. The table is the profile's own
definition; no ring has been read.

| UUID | Name | Notes |
|------|------|-------|
| `00002a4b-0000-1000-8000-00805f9b34fb` | Report Map | the report descriptor |
| `00002a4d-0000-1000-8000-00805f9b34fb` | Report | one per report; no ID byte in the value, the Report Reference descriptor `00002908-0000-1000-8000-00805f9b34fb` carries ID and type |
| `00002a4a-0000-1000-8000-00805f9b34fb` | HID Information | read |
| `00002a4c-0000-1000-8000-00805f9b34fb` | HID Control Point | suspend (`0x00`) / exit suspend (`0x01`) |
| `00002a4e-0000-1000-8000-00805f9b34fb` | Protocol Mode | boot (`0x00`) or report (`0x01`), boot-capable devices only |
| `0000180f-0000-1000-8000-00805f9b34fb` | Battery Service | required by HOGP; Battery Level `00002a19-0000-1000-8000-00805f9b34fb`, uint8, 0–100 % |
| `0000180a-0000-1000-8000-00805f9b34fb` | Device Information | required by HOGP; PnP ID `00002a50-0000-1000-8000-00805f9b34fb` |

The OS claims this service. Web Bluetooth blocklists it outright, and apps on
Android and iOS are understood not to reach it either. So on BLE too, an app
gets key events, not reports. Some rings add a relative mouse report for
swipe-scrolling, but its layout, and the names the BLE units advertise, have
not been collected.

### Host compatibility

| Host | Verdict | Basis |
|---|---|---|
| Android | compatible | manuals (Android 4.2.2+ for the AB Shutter3, 2.3.6+ for the Sumvision handle), community reports |
| iOS / iPadOS | degraded: works as a keyboard and camera shutter, no app access to the reports | manuals (iOS 6.0+ for the AB Shutter3, 5.0+ for the Sumvision handle) |
| Windows | compatible; Windows also acts on the volume keys system-wide | StackOverflow 33955141 |
| Linux (BlueZ) | compatible (hypothesis); the only Linux report used a userspace Bumble host on a Kindle | kindle-hid-passthrough |

## Troubleshooting

No vendor app exists, so there are no app defects to record. These are the
host-side failures the manuals and community guides describe:

- **Both buttons do the same thing.** The clone is in Android mode (try the
  slider, or hold both buttons for about 3 s). Or two usages map to one key
  code (compare `MSC_SCAN`). Or the second button is on a second input node.
- **The host sees the key but the camera takes no picture.** On Samsung,
  set the camera's volume-key setting to take pictures. Otherwise the camera
  app does not treat a volume key as a shutter. The CamKix manual's answer is
  a third-party camera app that does. The Sumvision manual warns that a few
  Android phone and tablet models do not support remote shutters at all.
- **Nothing happens after the host slept.** The host waits to be called and
  the remote has not called back. Press a button, or switch the remote off and
  on and wait about 20 s. Restarting the host's Bluetooth alone does not help.
- **A selfie stick stopped working after sitting unused.** The Sumvision
  handle sleeps after 5 minutes idle. A short press of the camera key wakes
  it, and it reconnects by itself.
- **Stops reconnecting on its own but keys still work.** The Kindle guide
  traced this to the battery contacts after the remote went through a washing
  machine. Clean the contacts and fit a fresh CR2032.
- **Windows changes the volume on every press.** Windows acts on the volume
  keys system-wide. The only remedy offered is disabling the HID access
  service, which also disables media keys on every other keyboard.
- **Kindle / KOReader.** The stock reader ignores input devices. The working
  setup is a userspace HID host (kindle-hid-passthrough) plus a key mapper
  that holds an exclusive grab. Without the grab, Enter reaches the reader
  and opens its menu.

## Tools Used

- [x] Retail manuals (AB Shutter3 on manuals.plus; CamKix FCC exhibit and the Sumvision leaflet via the Internet Archive)
- [x] Community guides and threads (MobileRead, GitHub gist, StackOverflow)
- [x] USB HID Usage Tables, Bluetooth HID / HOGP profiles, Linux `hid-input.c`, BlueZ `input.conf`
- [ ] `sdptool records` dump of the HID descriptor (pending hardware)
- [ ] HCI snoop of pairing and a key press (pending hardware)

## References

- [AB Shutter3 owner's manual (manuals.plus)](https://manuals.plus/ab-shutter3/wireless-remote-shutter-manual)
- [CamKix Bluetooth Remote Shutter manual, FCC ID 2AUYP-CAMKIX (Internet Archive)](https://web.archive.org/web/20250109110126/https://fccid.io/2AUYP-CAMKIX/User-Manual/User-Manual-4513779.pdf)
- [Sumvision monopod selfie stick and Bluetooth remote user guide (Internet Archive)](https://archive.org/details/sumvision-monopod-selfie-stick-bluetooth-remote)
- [MobileRead: Working Cheap Bluetooth page turner on PW6](https://www.mobileread.com/forums/showthread.php?p=4584542)
- [Bluetooth Page Turner for Kindle Paperwhite 6 (gist)](https://gist.github.com/liquidguru/1e9c77f9389cdf23f94d2a94b220c90a)
- [StackOverflow: Manage Bluetooth remote shutter keys from my Windows application](https://stackoverflow.com/questions/33955141/manage-bluetooth-remote-shutter-keys-from-my-windows-application)
- [kindle-hid-passthrough](https://github.com/zampierilucas/kindle-hid-passthrough)
- [Atharok BtRemote `Constants.kt` (HID descriptor)](https://gitlab.com/Atharok/BtRemote/-/blob/main/app/src/main/java/com/atharok/btremote/common/utils/Constants.kt)
- [Bluetooth HID Profile 1.1.1](https://www.bluetooth.com/specifications/specs/human-interface-device-profile-1-1-1/) ·
  [HID over GATT Profile 1.0](https://www.bluetooth.com/specifications/specs/hid-over-gatt-profile-1-0/) ·
  [USB HID Usage Tables 1.7](https://usb.org/document-library/hid-usage-tables-17)
- See also [Common Bluetooth Classic Patterns](../protocols/bluetooth-classic-common.md) and
  [Pairing, Bonding and Unpairing](../protocols/pairing.md)

## Contributors

- Initial spec from the 2026-09 generic "BLE remote" survey and community sources
