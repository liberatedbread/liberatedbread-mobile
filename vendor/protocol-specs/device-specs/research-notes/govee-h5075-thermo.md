# Govee H5075: research notes

What was confirmed, what was refuted, and what is still genuinely unknown after driving the device.

One unit, `GVH5075_0969` at `A4:C1:38:F9:09:69`, firmware 1.04.07 and hardware 1.03.02, both read
back off the device rather than off the box. Everything below was measured on a Raspberry Pi 5 on
BlueZ 5.82 with bleak 3.0.2, and the captures are in the captures repo under `govee/`. The
reproduction steps are in `govee-h5075-checklist.md` and every claim here can be re-run from it.

The spec carries 111 assertions once the twelve variant blocks are counted individually. 78 are now
settled outright and 3 more are partly settled. Of the 30 that are not, 23 cannot be reached with the
hardware here, 21 of those belonging to models nobody had in the room, and 3 are not claims about the
device, which leaves 4 that are testable with this unit and were not reached.

## The temperature formula was wrong, and it was the confident part

Read this one if you read nothing else.

The spec carried `temp = (value & 0x7FFFFF) / 10000.0` in three places, tagged `CONFIDENCE: HIGH`.
The packed value is a six digit decimal, `TTTHHH`, where the first three digits over ten are degrees
and the last three over ten are percent. Dividing the whole thing by 10000 does not separate them, it
leaves the humidity sitting in the temperature's decimal places.

Run it against the cited source's own worked example, `0x03519E`:

|  | Temperature | Humidity | Matches the source's own comment |
|---|---|---|---|
| GoveeBTTempLogger | 21.7 | 50.2 | yes |
| The spec | 21.7502 | 50.2 | no |

So the spec documents what that logger did **before** its issue #49 fix. The integer division in the
current source exists precisely to stop the humidity bleeding into the temperature, and the float
division puts it back. Every temperature this spec produces carries three junk decimals.

Refuted three ways on hardware, not just on paper. Against the LCD directly. Against a window of
advertisements where the temperature held at 24.1 across 33 of 36 packets while the humidity walked
from 46.2 to 53.3 percent, during which the old form reported 24.1456 through 24.1465, so the noise
riding on the temperature is visibly the humidity. And against a connected `aa 0a` read, which
returns the same measurement in centi-units and agrees with the corrected form.

There is a second, narrower problem in the same area, and this one resolves in your favour. The spec
masks 23 bits, `0x7FFFFF`, where GoveeBTTempLogger masks 19, `0x7FFFF`. Below 52.4 C the two agree
exactly, which is why nothing surfaces it.

Heated to a peak of 56.7 C to settle it. The crossover landed exactly where the arithmetic puts it.
The last packet where the two agreed was `07ff87`, 524167, sitting just under the 19 bit ceiling of
524287. The next one, `080755` at 526165, needs bit 19, and there your 23 bit mask reads 52.6 C at
16.5 % while the 19 bit mask reads **0.1 C at 87.7 %**.

**It does not drift, it wraps**, and it takes the humidity down with it. Near freezing and nearly
saturated, reported by a sensor sitting in hot dry air. Both fields fail together because the
temperature and humidity digits share one packed integer, so cutting the high bits corrupts the
whole value rather than just the top of the range.

35 of 305 packets diverged, and the two decodes converged again on the way back down through the
boundary in the same session, so this is a property of the boundary and not of the unit being hot.

Your mask is the correct one. The reference implementation is wrong above 52.4 C, and an indoor
hygrometer almost never goes near that, which is presumably why it has survived.

## The discovery UUID means the app never finds the device

The spec's discovery service UUID is byte swapped and matches nothing that is on the air. One line,
and it is the highest impact defect in the file, because a client using it finds zero devices.

What the device actually advertises: an `ADV_IND` of exactly 31 bytes carrying flags `0x05`, the
complete local name, the 16 bit service UUID `0xec88` and the six byte manufacturer payload. Passive
scanning is enough to read the sensor data, which the spec is right about.

The 128 bit `INTELLI_ROCKS_HW` value in the spec is not an advertised service UUID at all. It is an
iBeacon proximity UUID sitting in a **separate scan response**, under Apple's company ID `0x004C`,
with major `0x5075` and minor `0xf2ff`. A passive only scanner never sees it. Its ASCII reads
forward.

That last point needs a warning attached, because anyone re-checking it will get the opposite answer.
**btmon prints iBeacon fields byte swapped.** It renders the proximity UUID reversed, which makes the
ASCII look backwards, and it swaps major and minor too: ours render as `Version: 30032.65522`, which
is `0x5075` and `0xf2ff` swapped. bleak reports the raw bytes correctly. Check both before concluding
anything about byte order here. This cost us a wrong conclusion before it caught one.

## The auth service UUID is off by one digit, and the handshake is not required

The spec gives the vendor service as `...1910`. This unit answers on `...1912`. Everything in the
command section is addressed to the wrong service as written.

More useful than the correction: **the device does not require the app layer handshake at all.** Nine
different command opcodes were written straight to `...2011` on a fresh connection with no handshake,
and every one answered. If the unit demanded it, those would refuse or drop the link. That single bit
gates the whole command and history section of the spec, and it turns out to be open.

Two related corrections. Three characteristic property lists in the spec are wrong against what the
device reports. And there is no Battery Service `0x180F`, which the spec correctly says, so that one
is a confirmation rather than a fix.

## What was confirmed

Confirming the correct claims counts as much as correcting the wrong ones, so these are stated
explicitly rather than left to be inferred from silence.

Passive scanning is sufficient. Manufacturer ID `0xEC88`. The six byte payload shape and battery in
byte 4. The `GVH5075_` naming pattern. The absent battery service. The `TTTHHH` decimal packing
itself, which was always right, it was only the arithmetic applied to it that was wrong. And the
payload is Celsius regardless of what the display is set to, captured with the screen in Fahrenheit
mode and checked against the Celsius reading.

## Things the device does that the spec does not mention

Found on the bench. These are additions rather than corrections, and the first two have consequences
for anything built on this.

**The device hangs up on its own.** Idle, it drops the GATT link after 11.51, 11.89 and 11.89 seconds
across three runs. With a write every 1.5 seconds it survived to about 20 seconds, twice, so traffic
extends it but there is a ceiling either way, and the device initiates the disconnect. Reconnecting
costs 8.39 seconds, so a client stitching a long transfer across reconnects runs at roughly a 60
percent duty cycle. Our largest download, 533 records, took 0.71 seconds of data time so it never
bit, but a full buffer would run well past 20 seconds. This is plausibly what the `aa 01` keep alive
in the spec exists for.

**The record interval is 61.3 seconds, not 60.** Measured by fitting the stored record counter against
time: 149 samples over 12.9 hours covering 755 records, slope 61.33, worst residual 0.61 of a record,
so the rate is flat across the window. That is 2.2 percent, and it compounds, because the device has
no clock to ask. Timestamping a history download means walking back from the transfer time, so across
a full 20 day buffer the oldest record lands about ten hours out. This is one unit's crystal and the
number to trust is the one you measure on yours.

Two commands that are not in the file at all. `aa 0a` returns the current measurement in
centi-units, two decimals against the advertisement's one, so connecting buys a decimal place. Its
temperature field is a **signed** little-endian int16, which only matters below freezing and is easy
to miss: at -5.61 C it reads `d1fd`, and read as unsigned that is 649.77 C. `aa ef` returns the stored
record count as a 32 bit big endian value, which is the piece a history client needs and whose absence
is why the download arguments look arbitrary.

Also, in shorter form: the broadcast interval is about 2.04 seconds; advertising flags are `0x05`, LE
Limited Discoverable, on a device that advertises permanently; Device Information holds only a PnP ID,
`028a2466820100`, with no firmware or hardware revision strings, which is why the command channel is
the only route to a version number; the GATT device name is null padded to 18 bytes while the
advertised name is 12 characters; and the device keeps advertising while connected, so a second radio
can read live values during a history download.

## History download, and three things the spec gets wrong about it

Subscribe to `...2013` before writing `33 01` to `...2012`. Reverse those two and it cannot be
recovered: nothing refuses the write and nothing drops the link, so there is no error to catch, and
no notifications arrive.

Each notification is a two byte big endian offset followed by six three byte records, each record the
same 24 bit encoding as the advertisement. Offsets count down by six per packet and offset 0 is the
newest record. The last packet pads unused slots with `ffffff`.

The three corrections. The stream never sends an `ee 01` terminator; it ends when the offset reaches
zero, across five dumps. Do not stop at offset 6 or below, because the last packet carries real
records down to offset 0 and discarding it loses up to six of them. And byte 19 is not a checksum on
this channel: two offset bytes plus six three byte records fills all twenty, so byte 19 is record
data, and validating it as a checksum fails on good data.

The request arguments do not select a range, which the spec implies they do. Ask for `first=10
last=5` and several hundred records come back rather than five. Repeat the identical request and the
packet count differs, 108 on air in one run and 92 in the next. Ask for everything and read the
offsets you get.

Two client side effects here will masquerade as device behaviour and both cost us time. One is the
capture script being killed part way through by a shell pipeline, leaving a short log that reads as
the device having deleted its own history. The other is bleak quietly losing notifications, so the
number sent on air and the number delivered disagree. Check 8 of the checklist has both, with the
measured counts and the margin that separates a stack problem from a device one.

## The sign bit, settled below freezing

The unit went into a freezer in a sealed dry container and came out at -10.6 C on its own display.
Bit 23 is a sign flag and it is confirmed three independent ways.

Live advertisements carried the bit set on 61 packets while the unit warmed, with the magnitude
decoding smoothly from -10.2 up to -7.0 and the bit clear on every positive reading either side. The
unit's own display agrees inside that logged window rather than against a photograph from another
moment: -8.5 on the LCD at 21:44 local against -8.5 on the wire at 04:44:11Z, then -7.1 against -7.1
at 04:45:08Z.

Four display readings were called out at the moment they were on the screen and matched against the
wire inside the same logged window, which is the standard this whole engagement is sold on:

| On the LCD | Local time | On the wire | Channel |
|---|---|---|---|
| -8.5 C | 21:44 | -8.5 C at 04:44:11Z | advertisement, bit 23 set |
| -7.1 C | 21:45 | -7.1 C at 04:45:08Z | advertisement, bit 23 set |
| -5.6 C | 21:45 | -5.61 C at 04:45:53Z | `aa 0a` connected read |
| 23.1 C | 22:18 | 23.1 C at 05:18:46Z | advertisement, bit 23 clear |

Both signs, both channels, four independent moments, no photographs involved.

And the stored history carries it too, which no public source records and which is the part worth
having. Downloading the buffer afterwards recovered the whole excursion as the device logged it,
6.1 C down through zero to -10.9 C and back, as 111 consecutive records with bit 23 set. So a client
decoding history without sign handling reads every sub-zero record as a large positive number, and
that is a silent failure a whole winter's data could disappear into.

That download also answered a worry raised elsewhere in these notes. It pulled 4948 records in 825
notifications in a single connection, with no keep-alive and no reconnect, so a full transfer does
survive the idle disconnect at this buffer size.

One correction that belongs here rather than being quietly fixed. The `aa 0a` temperature field is a
**signed** int16, and an earlier version of the checklist said unsigned. At -5.61 C the field reads
`d1fd`, which read as unsigned is 649.77 C. That defect only becomes visible below freezing, which is
the entire argument for doing this test on hardware instead of reasoning about it.

## The battery pull, and the thing it destroyed

Factory reset is a power cycle and nothing more. Batteries out for ten seconds, back in, and the unit
was advertising again inside twenty seconds, decoding normally. Firmware and hardware revisions read
back identically, so nothing identifying the unit changed. That confirms both reset claims.

What it also does, and what nothing in the file or in either public library mentions, is **destroy the
entire stored history**. The record counter read 4946 immediately before the batteries came out and 0
immediately after they went back in. The buffer is volatile.

For anyone building on the history channel that is the single most important sentence on this device.
A routine battery change loses every record, silently, with no flag anywhere to say it happened. A
client that syncs infrequently and trusts the buffer will lose data it never knows existed.

It also closes off measuring the 20 day capacity in the near term, since the buffer now starts from
empty. The upside is that it starts from a known empty, so a capacity measurement from here would be
clean rather than inferred.

## What stays genuinely unknown

Four claims are testable with this unit and were not reached, and none of them is a gap that more
bench time would close. The `33` setter family, deliberately not run because it writes persistent
state to your device and no finding required it. And three internals of an auth handshake that this
firmware turns out not to require at all, so there is nothing to exercise.

The mask above 52.4 C used to head this list and no longer does; it was settled on 2026-08-16 and is
written up above.

**Two more are not gaps that anyone can close, and they are worth separating out.** The battery error
flag in the top bit of the battery byte, claimed in two places, needs a nearly dead cell to set. The
cells that shipped with this unit read 100 percent for the whole engagement and will outlast it by
months. Fitting a dying cell of our own would be testing a battery we introduced rather than the
device as you will use it, which is a different claim. So that one is marked untestable rather than
untested, because calling it untested would imply somebody is going to get to it.

The same distinction applies much more widely. Twenty one of the claims in this file belong to the
other eleven models in the family, and no amount of work here reaches them either.

One more that is cheap if the chance comes up. Whether the device can report a humidity of exactly
100.0 percent. The encoding has no room for it, since 100.0 times ten carries into the temperature
digits, and whether the firmware clamps below that or overflows is unknown.

Separately, what the `33 01` arguments actually mean is still open. Black box probing has been
exhausted on it, twenty trials, and the only thing that will settle it is capturing the vendor app
driving a real history transfer.

And `aa fe` returns sixteen ASCII hex characters that are constant on a unit and differ between
units. It may be key material. Ours is not published here and yours should not be either.

## The part that is a scope question rather than a work question

This is a twelve model family document and one H5075 was in the room. Twenty one of the 111 claims
belong to the other eleven models and cannot be verified against hardware here, ever, by any amount
of work.

They can be re-sourced, meaning traced to a named primary source and re-tagged honestly, and doing
that alone already found a real error in one of them. That is not the same thing
as hardware confirmation and the file should not read as though it were. Marking those rows as not
confirmed, which is the direction you were already going, is the right outcome.
