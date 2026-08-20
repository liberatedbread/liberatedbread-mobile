# Ember Mug 2: hardware checklist

Every confirmed claim in the spec, in the order that makes sense to run them, with the command that
produced it and what a pass looks like. Checks 1 to 8 take about an hour. Check 9 needs water and a
full heat cycle on top of that, check 10 runs while 9 does, check 11 is three short writes, check 12 needs the mug
actively heating so run it off the back of 9, and checks 13 and 14 clear the claim, so do them last.

Results below are from an Ember Mug 2, 10 oz, at `E7:4D:5D:A9:95:74`, serial `WHC93801252`, firmware
367, hardware 10. Your unit will differ in the MAC, the serial, the LED colour and probably the
firmware. The body style matters more than any of those: this file covers five and only the Mug 2 was
tested, and the characteristic table is not the same across them.

One thing to know before you start. **This mug arrived already claimed**, so checks 1 to 12 are all
run on a claimed mug. Checks 13 and 14 reset it and cover the unclaimed state.

## What you need

A Linux host with a working Bluetooth adapter. This was run on a Raspberry Pi 5 on Debian Trixie,
BlueZ 5.82, with `hci0` UP RUNNING. `btmon` and `bluetoothctl` come from BlueZ. Python with `bleak`
3.0.2 in a virtualenv.

    python3 -m venv venv
    ./venv/bin/pip install bleak

Put your unit's MAC at the top of each script. They all hardcode it.

Read-only except checks 8, 11 and 12, which write and then restore, and check 13, which is a factory
reset and does not restore. Nothing touches the Nordic DFU service or the control registers at
`fc540010` and `fc540011`.

## 1. It is there, and discovery does not work the way the spec says

    ./venv/bin/python ember-scan.py

Twenty seconds of passive scanning, before you connect to anything.

    E7:4D:5D:A9:95:74  Ember Ceramic Mug  rssi -47
      manufacturer 0xFFFF  82
      advertised uuids: 0000180a-0000-1000-8000-00805f9b34fb

Three things to check, and the spec is wrong about all three.

**The company ID is 0xFFFF**, the SIG's reserved internal-use value, not the 0x03C1 (961) the spec
asserts in four places. It is 0xFFFF in idle and in pairing mode both. A shipping product advertising
under the test ID.

**None of the three service UUIDs in the spec is advertised.** The only one on the air is `0000180a`,
Device Information, and that service is not actually implemented on the device. `fc543622` appears
only while the base button is held, and only in the scan response, so a passive scanner never sees it
in either state.

**Both Home Assistant discovery patterns therefore match this mug in no state at all.** They ask for
local name `Ember C*` or `Ember T*` **and** manufacturer 961. The name half matches, the 961 half
never does, and the conjunction fails. What works is scanning for the local name prefix and accepting
whatever company ID comes with it.

**The trap.** Take this measurement before your first connection. Afterwards BlueZ merges its cached
GATT services into what it reports to a scanner, and a scan run at that point lists five UUIDs that
were never on the air. Two of our early advertising notes were wrong for exactly this reason. If you
have already connected, restart `bluetoothd` or clear the device before rescanning.

## 2. Getting a connection, and what to do when it refuses

    ./venv/bin/python ember-connect-poll.py

The mug refuses connections in some states and it is not subtle about it. Ours advertised normally,
accepted the link layer connection with `Status: Success`, then serviced nothing and dropped with
`0x3e`, forty four attempts in a row over about two hours.

Before you go looking for a cause, know what we ruled out, because all of it costs time: the capture
code, the connection parameters, the adapter, the host stack, a session left mid-hang, RF, and any
accumulated bench state. A house power cut cold booted the host, the adapter and the coaster in the
middle of it and the mug behaved identically afterwards.

**The recovery is a button hold.** Take the mug off the coaster, hold the base button, and release
the instant the LED changes colour. Ours went to a blinking blue and took a connection immediately
after.

**Release on the colour change.** Keep holding and blue goes to yellow and then red, which is the
factory reset, check 13. Ours was still claimed after the short hold, verified in check 5.

## 3. GATT enumeration

    ./ember-gatt-run.sh

Read-only, and it deadlines every read so one slow characteristic cannot stall the run. It skips
`fc54000e` by default for the reason in check 4.

Expect eighteen of the twenty characteristics the spec lists, all under
`fc54XXXX-236c-4c94-8fa9-944a3e5353fa`. Check these against the spec:

- `fc540009` volume is **absent**, and the spec is right that it should be, it is Travel Mug only.
- `fc54000b` acceleration is **absent**, and the spec lists it. That one is a spec error.
- `fc540012` push event is **notify only**, where the spec claims read and notify.
- `0000180a` Device Information is **advertised and not implemented**. There is no service behind it.

Three things are present that the spec documents nowhere:

- **A Nordic legacy DFU service** at `00001530-1212-efde-1523-785feabcd123`, with control point,
  packet and version characteristics, on a claimed mug in ordinary operation. **Do not probe it.**
  Writing to a DFU control point is how a mug gets bricked, and finishing a legacy DFU needs a signed
  vendor image you do not have.
- **A second, writable device name** at `00002a00` in Generic Access, reading `Ember Ceramic Mug`
  while `fc540001` reads `EMBER`. The Generic Access one is what discovery matches on.
- **Connection parameters** at `00002a04`, reading `5000a00000009001`, which asks for a 100 to 200 ms
  interval and a 4000 ms supervision timeout. BlueZ ignores it and opens at 420 ms.

## 4. The DSK needs an encrypted link

This one looks like a hang and is not, and it cost us five runs across two days before it was read
off the wire instead of guessed at.

    ./venv/bin/python pair-agent.py &
    ./venv/bin/python ember-dsk-pairing.py

Reading `fc54000e` without a pairing agent registered looks like a read that never returns, followed
by a dead session where every later read fails with "Service Discovery has not been performed yet".

What actually happens, visible only in `btmon`: the mug answers in about 400 ms with ATT
`Insufficient Authentication (0x05)`. BlueZ acts on that by starting SMP without being asked. With no
agent, `bluetoothd` answers its own confirmation request in the negative and the mug drops the link.

There are three distinct signatures and only a capture separates the first two:

- **No agent.** Fails immediately.
- **An agent that does not answer**, such as `bluetoothctl` prompting on a stdin nobody is reading.
  Stalls, then dies on a link layer timeout at thirty seconds.
- **An agent that answers.** The read returns 20 bytes and the session survives.

Ours returned `3f8774af8b2e9594dc1a337c8bc09e384b610837`.

**This creates a bond.** BlueZ asked for No bonding and keys were distributed anyway, so your host is
now paired to the mug. Clear it with `bluetoothctl remove <MAC>` when you are done. Nothing is
written to any characteristic to get this.

Most headless boxes have no pairing agent, so a client built against this will hang with no error
surfacing anywhere. That is the practical finding here.

## 5. Claim state, firmware, and the mug id

From the check 3 output, or directly:

**`fc54000f`** is the UDSK. Twenty non-zero bytes means the mug is claimed, all zeros means it is
not. Ours reads twenty non-zero bytes.

Two settings corroborate it, and they are worth reading because they tell you a human configured this
mug: `fc540003` reads `8518`, little-endian 6277, which is 62.77 C, and that is 145.0 F to the
decimal and the top of the range python-ember-mug will write. `fc540004` reads `01`, Fahrenheit.
Nobody arrives at that pair by accident.

**`fc54000c`** gives firmware and hardware. Ours is firmware 367, hardware 10. Attach this to every
result you record, because Device Information is advertised and absent so this is the only route to a
version number.

**`fc54000d`** is the mug id and it decodes as the BLE address, an ASCII hyphen, then the serial. Ours
gives `WHC93801252` after the hyphen, matching the box. That hyphen is the byte 6 the spec's format
block never accounted for.

## 6. Push events and the charging byte

    ./venv/bin/python ember-watch.py

Subscribes to `fc540012` and re-reads the state characteristics on every event. Lift the mug off the
coaster and put it back while it runs.

    03:11:31  on the coaster            fc540007 byte 1 = 0x01
    03:11:32  PUSH 3 charger disconnected
    03:11:33  off the coaster           fc540007 byte 1 = 0x00
    03:12:12  PUSH 2 charger connected
    03:12:14  back on the coaster       fc540007 byte 1 = 0x01

Confirms the charging byte and its polarity, and push events 1, 2, 3 and 5.

**Drive this from the push events, not from your memory of where the mug was.** Sixteen earlier reads
of that byte all returned `0x00` and one was written up as taken on a powered coaster, which would
have made the byte useless and the spec's Charging Base entity wrong. Nothing in that log recorded
where the mug actually was. The byte was fine. The note about the mug's position was not.

**The characteristic lags its own push event by a second or two.** A read taken immediately on PUSH 2
returns the pre-event value. The spec tells clients to re-read the affected characteristic on the
event, which is right, but doing it synchronously leaves you one state behind permanently. Put a short
delay in front of the read.

## 7. The statistics burst

    ./venv/bin/python ember-stats.py

`fc540013` has no published format anywhere. On the first connection of a day it produces four
notifications inside a second and then nothing:

    01 00 08  00 05 02 00 00 00 03 fc
    02 00 10  00 15 07 00 00 00 03 fc 05 00 00 24 ff ff ff ff
    04 01 08  ff ff ff ff 00 05 00 00
    05

Subscribe again a few minutes later, on a fresh connection, and you get a bare `05` and nothing else.
So `05` is what it says when it has nothing to say.

**It is not consumed.** The next day's first connection produced the same four notifications, byte for
byte, twenty hours and a charge cycle later, with no button hold in between. Seeing `05` does not mean
you have permanently missed anything. What re-arms it, and how long that takes, is not known: all that
is bounded is longer than two minutes and shorter than twenty hours.

Reading byte 0 as a record id, byte 1 as a subtype and byte 2 as a length gives a body length matching
byte 2 in all three multi-byte records, 3 plus 8, 3 plus 16, 3 plus 8. Nothing else tried fits all
three. What the fields mean is unknown.

**Run your first connection of the day under `btmon`.** That is the connection that carries it, and
no later one in the same window will.

## 8. LED byte order

The one write in this checklist. It is reversible and the script puts the original back.

    ./venv/bin/python ember-led-and-charge.py

Read `fc540014` first and write it down. Ours read `ff0400ff`.

Write `BF FF 00 FF` and look at the mug. Red, green, blue makes that RGB(191, 255, 0), a yellow. The
spec's older reference documents the order as red, blue, green, alpha, which would make the same write
RGB(191, 0, 255), a violet. Opposite sides of the wheel, so your eye settles it with no
instrumentation. **Ours went yellow.** The byte order is red, green, blue.

Two things about doing this by eye:

**Run it off the coaster**, and expect the mug to display the change and then go dark on its own. It
does not sit at the configured colour indefinitely. Any check by eye needs a fresh write.

**The characteristic holds the configured colour, not what you are looking at.** It read `ff0400ff`
unchanged across a whole day while the mug visibly showed a slow white pulse for every minute it spent
heating, going back to red only in standby. The heating animation overrides the colour on the hardware
and never appears on the wire. So there is no way to read the displayed colour, and a light entity
bound here will report red while the mug in front of you pulses white.

Byte 3 is not settled. Written at `0x40` against the same RGB the colour still read as yellow, with no
call either way on intensity, and an unnoticed dimming looks identical to an ignored byte if you were
not told to expect one.

Write your original value back and read it to confirm.

## 9. Fill it: liquid level and liquid state

    ./ember-fill-run.sh

Start it before any water goes in, so the empty baseline is in the same capture. It subscribes to the
push events, polls the state characteristics every five seconds and tags every sample with the
charging byte, so the log records where the mug was without anyone writing it down. Use
`./ember-mark.sh <note>` from another shell to stamp what you did into the same file.

Fill it with cold water, in stages, and leave it to run a full heat cycle.

**Expect this to go wrong the first time.** A full mug on the powered coaster
read `fc540005` = 0 and `fc540008` = 1 (empty) for twenty minutes and never started heating. It was
not wedged: `fc540002` tracked the cold water going in the whole time and nothing surfaced an error.
**One short press of the base button ended it** and the mug went to state 5, heating, and ran to
target normally. A client cannot treat state 1 as meaning empty, and nothing found so far
distinguishes the two cases.

There are also two dormant conditions and only one wakes on handling. During those twenty minutes the
mug was lifted, poured into, set down, replaced and topped up, and none of it helped. Later the same
day, after the mug dropped from `target_temperature` to `standby` on its own, simply moving it was
enough to restart heating with no button press.

Once it is awake, expect:

- **Liquid level does emit intermediate values**, and constantly. We saw 0, 5, 6, 7, 8, 9, 10, 11, 12,
  14 and 30, with 155 `liquid_level_changed` push events in one 40 minute capture. It also updates
  with the mug off the coaster. The spec's note that it may only update on the charger and that only
  0 and 30 are significant is wrong on both halves.
- **And you should not read those intermediates as a fill fraction.** Across two captures where nobody
  touched the water the raw byte wandered 5 to 12 and 7 to 12, changing on 9 and 27 percent of
  consecutive reads. Through the spec's scale that is a sensor swinging between 17 and 40 percent with
  the mug sitting still. The two runs also settled at different values for the same water at different
  temperatures. Solid as an empty-or-not signal, unsound as a percentage.
- **Four liquid states, matching their names**: 0 standby, 1 empty, 5 heating, 6 target_temperature.
  `2 filling` never appeared through four separate pours. 4 and 7 were not reached; 3 is check 14.
- **The mug leaves target on its own.** Ours went from 6 to 0 while reading 60.56 C with liquid in it,
  on the powered coaster, and the drink then fell to 48.89 C with no further heating. Standby is where
  a finished heat cycle lands, so seeing it does not mean the mug is empty, off the pad or switched
  off.

## 10. Battery under a heat cycle

This runs alongside check 9 and needs nothing extra.

**The charging byte tells you the coaster is connected and nothing about whether the battery is
gaining.** Ours read `0x01` continuously from 19:18 to 19:57 while the percentage went 13, 12, 11, 10,
6, on the powered coaster the whole time. The coaster does not keep up with an active heat cycle. It
stops falling once the mug reaches target, and it does recover normally afterwards: left in standby on
the same coaster it read 91 percent by 23:32, up from 6 at 19:57.

**Off the coaster it does not converge at all.** From 45 C on a full battery ours climbed 0.22 C per
minute while spending about 2 percent of battery per minute, so it went flat before reaching a 62.77 C
target and never got there. Sustained heating is a mains activity.

Bytes 2 and 3 are a **battery** temperature and not the drink temperature, which no public source says
outright. They disagree: 25.00 C here against 23.89 C from `fc540002` at the same moment. It climbed
26, 27, 28 C while the mug charged on the coaster and fell back once full, on an empty mug that was
never heated, so it is responding to charge current. And 93 reads across two days all landed on an
exact multiple of 100 where the drink temperature gives 2389 and 2445, so the field is in hundredths
and the sensor is quantised to whole degrees. Anything binding a drink temperature to `fc540007` shows
a reading that moves for the wrong reasons.

## 11. The mug validates nothing you write to it

    ./venv/bin/python ember-datetime.py --write
    ./venv/bin/python ember-target.py --write
    ./venv/bin/python ember-name.py --write

Three short write tests. All three read the current value first, put it back at the end, and refuse
to write anything if that first read fails. Without `--write` each one prints what it would do and
stops.

**Date and time, `fc540006`.** The characteristic is both readable and writable, so any description
of it as a write-only sink is wrong on both halves. It reads all zeros on a mug whose clock was never
set, and zero is identical in both byte orders, so only a non-zero write settles it. Write the same
timestamp twice, once each way round, chosen so the two readings sit years apart. Ours accepted both
and returned each byte for byte, including the one that decodes past the signed 32-bit rollover in
January 2038. The order is little endian, on the strength of the reference implementation's own
worked example. The device itself will never tell you, which turns out to be the more useful half.

**Target temperature, `fc540003`.** `56.50 C` goes on the wire as `12 16` and reads back `12 16`, so
the documented encoding is right. Then write `40.00` and `70.00`. Both sit outside the 49 to 63 C
window the spec documents, at either end, and ours accepted both and read them back unchanged. That
window is a client convention, not a device constraint.

**Mug name, `fc540001`.** Ours took a space, which one source says is not allowed. It took 14, 15,
16, 17 and 20 byte names, so neither the documented 14 nor the documented 16 is a device limit. It
took `Café` as five bytes of UTF-8 and returned it identical.

Counting the LED in check 8, that is eleven writes across four characteristics with nothing refused,
clamped, truncated or normalised anywhere. What follows from it is `E66` in the research notes.

Read each value back after the restore and confirm it.

## 12. The off switch, against a running cycle

    ./ember-offswitch-run.sh --write

The one check that has to happen while the mug is busy, because writing `0x0000` to an idle mug
proves nothing.

Fill the mug, put it on the coaster, and short-press the base button if it sits at level 0 state
empty. The script waits until it has seen `5 heating` for twenty continuous seconds, writes `0000` to
`fc540003`, watches for five minutes, then puts your original target back. It does nothing without
`--write`, reads the baseline first, and refuses to write at all if that read fails.

Ours went in at a drink temperature of 27.78 C against a 62.77 C target, 35 degrees short of where a
cycle ends by itself, which is what makes the result mean anything. What followed:

- push event 8, `liquid_state_changed`, in the same second as the write
- the state left `5 heating` for `3 cold_no_temp_control`
- the drink fell 27.78, 27.23, 26.12, 25.00, 24.45, 23.34, 22.78, 22.23 and then held at 22.23 for
  the remaining four minutes, with no reheat at any point
- by eye, the LED stopped pulsing white and went back to the configured red

**Watch the state, not only the temperature.** A cycle that reaches target drops to `standby` by
itself, so a transition alone proves nothing. What proves it is the pair: the drink well below target
when the write lands, and the state going to 3 rather than 0.

**`3 cold_no_temp_control` is where the mug sits with liquid present and temperature control off.**
It is the only way we reached state 3. Do not read it as a fault or as an empty mug.

The script always restores. If it ever exits without doing so, run
`./venv/bin/python ember-offswitch.py --restore-only`.

## 13. Factory reset

Hold the base button about 15 seconds. Blue, then yellow, then red. Release at red. It then blinks
red, blinks yellow, pulses white, goes solid white and powers off. One press brings it back.

The spec's 12 seconds and "the LED blinks red" are both wrong. Ember's support page gives 15 and the
three colour sequence, and this unit matched it. Red is the last of three.

Read `fc54000f` before and after. Ours went from twenty non-zero bytes to twenty zeros.

Clears: the claim, target to `5a16` (57.22 C, which is 135.0 F), unit to `00` Celsius, the date-time
zone byte to `00`, LED to `ffffffff`. Preserves: firmware, hardware, serial, address and the DSK,
byte identical.

This costs you the claim, and you cannot write it back; see check 14. Re-claiming needs Ember's app.

## 14. What an unclaimed mug will not do

Run this straight after check 13.

Every write is refused with ATT `0x03`, write not permitted. Target temperature, LED and mug name all
returned it, and all three had been written on this unit an hour earlier while claimed.

`fc54000f` refuses too, on a plain link, on an encrypted one, in pairing mode and out of it, at 20
bytes and at 40. So the documented claiming procedure, write a UDSK, cannot bootstrap: writes are
locked until the mug is claimed. Something else unlocks a fresh mug and no public source says what.

Also here: the mug caps its ATT MTU at 23. BlueZ asks 517 and gets 23, leaving a 20 byte payload, and
it never answers prepare-write. No client can write more than 20 bytes to this device.

## Not done

Listed so nobody reads this checklist as complete.

- **The whole setup, claiming and factory reset path.** This unit arrived claimed. Exercising the
  claim flow from scratch means a factory reset first, and the spec rates reset confidence no better
  than medium, so the safety net is untested before you would be leaning on it.
- **What seeds the buffer in the app's `generateUdsk`.** The shape of the claim flow is recovered and
  written up. This one value inside it is not, and it is recorded as unknown rather than guessed.
  Pinning it down means calling the function on a live target with the app under instrumentation,
  which was not set up here. Closed rather than pending.
- **Liquid states 2, 4 and 7.** State 3 is reached in check 12.
- **How long `fc540013` takes to re-arm**, bounded only between two minutes and twenty hours.
- **Anything behind the Nordic DFU service**, deliberately.
- **Every other body style.** Travel Mug, Travel Mug 2+, Cup and Tumbler were never in the room.
