# Govee H5075: hardware checklist

Every confirmed claim in the spec, in the order that makes sense to run them, with the command that
produced it and what a pass looks like. Working through this end to end takes about half an hour plus
whatever you leave the record-interval check running for.

Results below are from `GVH5075_BBCC` at `A4:C1:38:AA:BB:CC` on firmware 1.04.07, hardware 1.03.02.
Your unit will differ in the MAC, the name suffix, the device string in check 7, and possibly the
firmware. Nothing else should.

## What you need

A Linux host with a working Bluetooth adapter. This was run on a Raspberry Pi 5 on Debian Trixie,
BlueZ 5.82, with `hci0` UP RUNNING. `btmon`, `bluetoothctl` and `hcitool` come from BlueZ. Python
with `bleak` 3.0.2 in a virtualenv.

    python3 -m venv venv
    ./venv/bin/pip install bleak

Put your unit's MAC at the top of each script. They all hardcode it.

The device does not need to be paired, put into any mode, or reset. Take it out of the drawer and
put it near the adapter. Everything here is read-only apart from the history request in check 8,
which asks for records and changes nothing, and check 13, which pulls the batteries and destroys
whatever history is stored.

## 1. It is there and the advertisement decodes

    ./venv/bin/python govee-scan.py

Twenty seconds of passive scanning. Expect one line per unit with the name, RSSI, the raw 24-bit
value and two candidate temperatures.

    A4:C1:38:AA:BB:CC  GVH5075_BBCC  rssi -32
      manufacturer 0xEC88  0003c3126400
      raw 0x03C312
      temp, source form  24.6
      temp, spec form    24.6546
      humidity           54.6
      battery            100

Read the LCD. The source form should match it and the spec form should not. That one line is the
whole decode finding: dividing the packed value by 10000 leaves the humidity digits inside the
temperature.

Confirms: passive scanning is enough, manufacturer ID 0xEC88, the 6-byte payload, battery in byte 4,
the `GVH5075_` name pattern.

## 2. The temperature does not move when only the humidity moves

This is the check that settles the decode without needing to trust a photograph.

    ./scripts/capture-govee.sh

Ninety seconds of advertisements with `btmon` running alongside, both written to `captures/` under
the same UTC stamp. Find a run of packets where the temperature holds and the humidity walks. Ours
held 24.1 across 33 of 36 packets while the humidity moved from 46.2 % to 53.3 %.

Now decode those same packets the old way. The spec form reports 24.1456 through 24.1465 across a
window where the temperature never left 24.1, so the humidity noise is riding on the temperature.

Do not do this by taking a photo of the screen and comparing it to a reading from a different
moment. Two earlier attempts missed by a tenth and by 0.4 C for exactly that reason. Log a window,
note the wall clock, and correlate inside it.

Confirms: the decode formula, and that the wire value is Celsius no matter what the display is set
to. Flip the unit to Fahrenheit and run it again if you want that second half directly.

## 3. Advertising is split across two packets

Open the `.btsnoop` from check 2 in Wireshark, or watch live:

    sudo btmon

Expect an ADV_IND of exactly 31 bytes carrying flags 0x05, the complete local name, the 16-bit
service UUID 0xec88 and the manufacturer payload. Then a separate SCAN_RSP of 27 bytes carrying an
iBeacon frame under Apple's 0x004C.

**The trap.** btmon prints iBeacon fields byte-swapped. It renders the proximity UUID reversed, which
makes it look like the ASCII runs backwards, and it swaps major and minor too. Ours are 0x5075 and
0xf2ff on the wire and btmon reports `Version: 30032.65522`, which is those two values swapped. That
is how you catch it. bleak reports the raw bytes correctly, so check both before concluding anything
about byte order.

Confirms: the sensor data is in the ADV_IND so passive scanning works; the 128-bit INTELLI_ROCKS_HW
value is an iBeacon proximity UUID in the scan response and not an advertised service UUID; the
ASCII reads forward; the ~2.04 s broadcast interval.

## 4. GATT enumeration

    ./venv/bin/python govee-gatt.py

Read-only. Nothing is written. Expect five services:

    494e5445-4c4c-495f-524f-434b535f4857
      ...2011  [read, write, notify]
      ...2012  [read, write, notify]
      ...2013  [read, notify]
    00010203-0405-0607-0809-0a0b0c0d1912
      ...2b12  [read, write-without-response, notify]
    0x1800 Generic Access
    0x180A Device Information   PnP ID only, 028a2466820100
    0x1801 Generic Attribute

Check the property lists against the spec, and check the auth service's last digit. Ours is `1912`.
There is no Battery Service 0x180F.

If your unit exposes `2b10` and `2b11` under the auth service, say so: this one does not, and the
question of whether that is a firmware difference or a spec error needs a second unit to settle.

## 5. It answers commands without a handshake

    ./venv/bin/python govee-cmd.py 08 0c 0d 0e 0f 03 04 06 07

Each line writes a 20-byte packet to `...2011` and prints the notification that comes back. If the
unit demanded the app-layer handshake it would refuse or drop the link here, and it does not.

    aa086400...c6                      battery 100
    aa0cccbbaa38c1a420c3...81          MAC reversed, then 20 c3
    aa0d312e30332e3032...97            ASCII 1.03.02
    aa0e312e30342e3037...96            ASCII 1.04.07
    aa0fccbbaa38c1a4...61              MAC reversed
    aa030000001027...9e                humidity alarm, 0.00 to 100.00 %
    aa040030f8701700...01              temperature alarm, -20.00 to 60.00 C
    aa06 / aa07 all zero               uncalibrated

Byte 19 is an XOR of bytes 0 to 18 and it should validate on every one of these.

**Expect the first command after connecting to be dropped**, roughly two times in three. Send a
throwaway first or retry. `aa 0c` returned nothing during the opcode sweep purely because it happened
to be first in a link, and it answers reliably otherwise.

Record the firmware from `aa 0e`. Device Information carries only a PnP ID, so this is the only route
to it, and a verification with no firmware attached to it ages badly.

## 6. The two commands worth having that are not in the older spec

    ./venv/bin/python govee-cmd.py 08 0a ef

`aa 0a` returns the current measurement at two decimals: four payload bytes at 2 to 5. Temperature is
a little-endian **signed** int16 in hundredths, humidity a little-endian unsigned uint16 in hundredths.

    aa0a8209870e...a2      0x0982 = 2436 -> 24.36 C,  0x0e87 = 3719 -> 37.19 %

The sign only bites below freezing, and it bit us. At -5.61 C this field reads `d1fd`, which as an
unsigned value is 649.77 C. An earlier version of this checklist said uint16 and would have produced
exactly that.

Compare against a scan taken at the same moment. The advertisement will read 24.3 where this reads
24.36, because the advertisement truncates rather than rounds. Connecting buys a decimal place.

`aa ef` returns the stored record count as a 32-bit big-endian value at bytes 2 to 5.

    aaef00000582...c2      0x582 = 1410 records

That count should exceed the highest offset any history dump reports at the same moment, because a
dump can be truncated and the counter cannot.

## 7. Full opcode sweep, if you want to reproduce the search

    ./venv/bin/python govee-opsweep.py 00 2f
    ./venv/bin/python govee-opsweep.py 30 ff

All 256 `aa` opcodes, reconnecting as it goes because the device hangs up on its own. Only `aa`, the
read prefix. Nothing here sends `33`.

Expect answers from 02, 03, 04, 06, 07, 08, 0a, 0c, 0d, 0e, 0f, 10, bd, ef, fe and ff, and silence
from the other 240. `aa 01` is silent, despite being documented elsewhere as the current measurement.
`aa ff` answers with a `33ff` prefix rather than `aaff`, the only opcode that does, which reads like
an unknown-command reply.

`aa fe` returns sixteen ASCII hex characters that are constant on a unit and differ between units.
Do not publish yours; it may be key material.

## 8. History download

    ./venv/bin/python govee-history.py 100 0

Subscribe to `...2013` first, then write `33 01` to `...2012`. The script does both in that order.
Doing it the other way round does not work and cannot be recovered: the write is accepted, the link
survives, and subscribing four seconds later yields nothing.

Each notification is a 2-byte big-endian offset then six 3-byte records, each record the same 24-bit
encoding as the advertisement.

    021403522c0359db035dbe0361a203619f03619c
    ^^^^ offset 532
        ^^^^^^ 0x03522c = 217644 -> 21.7 C at 64.4 %

Offsets count down by 6 per packet. Offset 0 is the newest record. The last packet pads unused slots
with `ffffff`.

Three things to check against the older spec, all of which it gets wrong:

- The stream never sends `ee 01`. It ends when the offset reaches 0. Five dumps, none.
- Do not stop at offset 6 or below. The last packet carries real records down to offset 0 and
  throwing it away loses up to six of them.
- Byte 19 carries record data, not a checksum. Two bytes of offset and six records of three bytes
  each already account for all twenty, so there is no spare byte for one. Validate it and it will
  fail on good data.

The arguments do not select a range. Ask for `first=10 last=5` and you get several hundred records,
not five. Repeat the identical request and you get a different number of packets: 108 on air in one
run and 92 in the next. Ask for the lot and read the offsets you get back.

Two client-side effects will masquerade as device behaviour here. Piping this script into `head`
SIGPIPEs it mid transfer and truncates the log, which briefly looked like the device deleting its own
history. And bleak drops one or two notifications per transfer even on a clean run, measured as 108
sent on air against 106 delivered. A count short by one or two is the stack. A count short by ninety
is the device.

## 9. Record interval

    ./venv/bin/python govee-recordrate.py

Reads `aa ef` every five minutes and appends `unix_time count` to `captures/recordrate.log`. Leave it
running for most of a day, then fit count against time.

Ours gave **61.3 s per record**, not the 60 you would assume: 149 samples over 12.9 hours covering
755 records, slope 61.33, worst residual 0.61 of a record, so the rate is flat across the window.

Do not try to settle this in ten minutes. Five records per interval quantises too coarsely to mean
anything, and the first hour of samples came back anywhere from 62 to 63.

Two counts far apart also work and need no fitting, but mind where the earlier one came from. Our
first estimate anchored to a count read during an opcode sweep, and the sweep log's timestamp is when
the file closed rather than when the probe ran. That put the anchor about two minutes late and biased
the answer low, by more as the baseline was shorter: 61.11 at 13 hours, 61.22 at 21.7, 61.24 at 25.8.
Both endpoints need a timestamp you took deliberately.

It matters because the device has no clock to ask. Timestamping a download means walking back from
the time of the transfer, and 2.2 % compounds: across a full 20 day buffer the oldest record lands
about ten hours out. This is one unit's crystal, so measure the unit in front of you.

## 10. Link lifetime

    ./venv/bin/python govee-linklife.py
    ./venv/bin/python govee-client-behaviour.py

The device hangs up on its own, not the host. Ours dropped at 11.51, 11.89 and 11.89 seconds idle
across three runs, and survived to roughly 20 seconds with a write every 1.5 seconds. Reconnecting
costs about 8.4 seconds, so a client stitching a long transfer across reconnects runs at roughly a
60 % duty cycle.

It keeps advertising while connected, so a second radio can read live values during a history
download.

A 533 record transfer took 0.71 s, so none of this bit here. A full buffer would, and has not been
tested.

## 11. The sign bit, below zero

    ./venv/bin/python govee-subzero.py

The only check here that needs more than the device and a host. Get the unit below 0 C and confirm
that bit 23 of the packed value is a sign flag.

Seal it in a dry container first. A bag with the air pressed out is enough. Condensation is what
kills these, not the cold. A freezer works and is what we used, but the door blocks the radio, so
either keep the adapter close and accept gaps in the log, or use ice with a heavy dose of salt in an
open bowl and stay in range throughout.

Ours reached -10.6 C on its own display. One excursion produced three independent confirmations and
any one of them settles it.

**Live advertisements.** Bit 23 was set on 61 packets while the unit warmed, and the magnitude ran
from -10.2 up to -7.0 with the bit clear on every positive reading either side.

**The display, correlated inside the logged window.** Call the LCD out at a moment you can timestamp
and match it against the wire in the same capture, rather than against a photograph taken separately.
Ours gave -8.5 on the LCD against -8.5 on the wire, then -7.1 against -7.1, then -5.6 against a
connected `aa 0a` read of -5.61, then 23.1 against 23.1 once it had warmed back up.

**The stored history, which no public source mentions.** Download the buffer afterwards and the whole
excursion comes back as the device logged it. Ours held 111 consecutive records with bit 23 set,
running 6.1 C down through zero to -10.9 C and back. **A client decoding history without sign
handling reads every one of those as a large positive number**, and nothing in the data says so.

The same download ran to the end on a single connection, 4948 records across 825 notifications, with
no keep-alive sent and no reconnect needed.

Run this before check 13. The reset empties the buffer and takes the history half of it with it.

## 12. The mask above 52.4 C

    ./venv/bin/python govee-mask.py

Read-only, passive, nothing connects. It prints both decodes of every packet side by side, the spec's
23-bit mask against GoveeBTTempLogger's 19-bit one. Below 52.4 C they are identical, which is why
this needs heat.

**The unit is rated to 60 C and the window is only 52.4 to 60.** A hair dryer crosses all of it in
seconds. Keep it moving, work at a distance rather than parking it on the unit, and stop as soon as
you are past 53. The script warns at 58 and tells you to stop at 59.5. Ours peaked at 56.7, already
more headroom than the test needed.

The crossover lands on the 19-bit ceiling, 524287, and nowhere else:

    07ff87  524167   23-bit 52.4 C 16.7 %    19-bit 52.4 C 16.7 %   agree
    080755  526165   23-bit 52.6 C 16.5 %    19-bit  0.1 C 87.7 %   diverge

The narrow mask does not drift, it wraps, and it takes the humidity with it, because both digits
share one packed integer and cutting the high bits corrupts the whole value.

Let it cool in room air rather than anywhere cold. The case is hot and its humidity has just been
driven right down, and cooling it fast is how moisture gets into a sealed unit. Leave the capture
running while it cools: ours converged again crossing back below the boundary, which shows the split
belongs to the boundary rather than to the unit being hot.

## 13. Factory reset, and what it costs you

    ./venv/bin/python govee-cmd.py 08 ef

Read the record count first and write it down. Then take the batteries out for ten seconds, put them
back, and read it again.

Ours went from 4946 to 0.

The reset itself is just a power cycle. Advertising resumed inside twenty seconds and decoded
normally, and `aa 0d` and `aa 0e` returned the same hardware and firmware revisions afterwards, so
nothing identifying the unit changes.

But **the stored history does not survive it**. The buffer is volatile and a routine battery change
destroys every record with no flag anywhere to say it happened. If you are building anything on the
history channel, that is the sentence to design around: a client that syncs infrequently will
silently lose data it never knew was there.

Do this check last. It costs you whatever is in the buffer.

## Not done

Listed so nobody reads this checklist as complete.

- **The 20 day storage figure.** The buffer had not wrapped when check 13 emptied it, so the largest
  count seen here is 4948 records, which is about 3.5 days at the measured interval. Capacity is
  bounded below by that and nothing here reaches 20 days. It does now start from a known empty, which
  makes a measurement from here cleaner than an inferred one.
- **The battery error flag** in the top bit of the battery byte. Nobody is going to get to this one.
  Setting it needs a nearly dead cell, the cells that ship with the unit last months, and fitting a
  dying cell of your own tests that battery rather than this one.

One more that is cheap if the chance comes up: whether the device can report a humidity of exactly
100.0 %. The encoding has no room for it, since 100.0 times 10 is 1000 and would carry into the
temperature digits, and it is not known whether the firmware clamps below that or overflows.
