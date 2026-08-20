# Ember Mug 2: research notes

What was confirmed, what was refuted, and what is still genuinely unknown after driving the device.

One unit, an Ember Mug 2, 10 oz, serial `WHCXXXXXXXX`, firmware 367 and hardware 10, both read off
the device with `fc54000c` rather than off the box. Measured from 2026-08-13 to 2026-08-16 on a
Raspberry Pi 5, BlueZ 5.82, bleak 3.0.2. Captures are in the captures repo under `ember/` and the
reproduction steps are in `ember-mug-checklist.md`.

Two things shape everything below.

**The mug arrived already claimed.** `fc54000f` read twenty non-zero bytes, the target was 62.77 C,
which is 145.0 F to the decimal, and the display unit was Fahrenheit. Nobody arrives at that pair by
accident.

That blocked the setup and claiming rows until 2026-08-16, when the mug was factory reset and the
whole block opened. Those results are below.

**This file covers five body styles and only the Mug 2 was here.** The characteristic table is not
uniform across them. Every Travel Mug, Cup and Tumbler row is untestable rather than untested, and
the difference matters.

Your spec carried 146 assertions. The working ledger now holds 171 rows, the extra ones being things
the device does that the file has nothing about. 81 are confirmed against the hardware and 19 are
refuted by it.

## The three findings the order names

**LED byte order is red, green, blue.** Settled by writing `BF FF 00 FF` and looking. Under red,
green, blue that is RGB(191, 255, 0), a yellow. Under orlopau's byte table it would be
RGB(191, 0, 255), a violet. Opposite sides of the wheel, so the eye settles it with no
instrumentation. The mug went yellow.

orlopau's table is a typo, and the worked example printed directly beneath it was right the whole
time. python-ember-mug agrees, and the vendor app is a third source: its debug string reads
`LED Color from mug: (r: ` with `, g: `, `, b: ` and `, a: ` after it. Your template already had the
correct order and only the prose called it open.

**Date and time is little endian, and the device will never tell you that.** The characteristic is
both readable and writable, so orlopau's description of it as a write-only sink is wrong on both
halves. It read `00000000fc` here: an unset clock, and a byte 4 of `0xfc`, which is -4 signed, so
somebody's client had written a UTC-4 offset onto this mug.

Then the part that matters more than the byte order. The probe wrote the same timestamp twice, once
each way round, chosen so the two readings sit thirteen years apart. Both were accepted. Both read
back byte for byte unchanged, including the one that lands past the signed 32-bit rollover in January
2038. Nothing was clamped, normalised or refused. It is a transparent five byte store and the
firmware does not appear to interpret it on any observable path.

So a client that writes the wrong byte order gets no error, no rejection, and a silently wrong clock.
There is no feedback channel here at all. The order is little endian on the strength of orlopau's own
documented capture, which decodes little endian to a time under a day before he committed the page,
and big endian to 2068. python-ember-mug's getter reads it big endian, and it is the only multi-byte
big endian GATT read in that library. It has no setter, so the value is never round-tripped and the
mistake has never had a chance to surface.

**DSK and UDSK, which the spec calls partially understood, and it was right to.** The important
practical result is that `fc54000e` requires an encrypted link, and the failure mode is silent.

A plain read gets a clean ATT `Insufficient Authentication (0x05)` back in about 400 ms. BlueZ then
starts SMP pairing on its own initiative without being asked, and if the host has no pairing agent,
`bluetoothd` answers its own confirmation request in the negative and the mug drops the link. What a
Python client sees is a read that never returns followed by a dead session where every subsequent
read fails with "Service Discovery has not been performed yet". Nothing surfaces the real cause
anywhere except a `btmon` capture.

Three outcomes are possible and the first two cannot be told apart without a capture. With no agent
the read fails at once. With an agent that never answers, it stalls and then dies on a link layer
timeout at thirty seconds. With one that answers, twenty bytes come back and the session stays up. Most headless boxes have no
pairing agent. This read also creates a bond, since BlueZ asked for No bonding and keys were
distributed anyway.

The claim flow is where this stops. Measured and read-off-strings are separated below, deliberately.

From the app's own debug strings, the sequence is: read the DSK, derive a UDSK from it, write the
UDSK, read it back, compare, and treat the mug as unlocked only if they match. The snapshot is
unobfuscated and names four functions on that path, `generateUdsk`, `verifyUdsk`, `_utilSha256Hash`
and `_utilByteReorder`, so a SHA-256 and a byte reorder are involved somewhere. Those are function
names, not disassembly. **The algorithm itself is not established and this file will not guess at
it.**

What was measured, on 2026-08-16: **the UDSK is derived deterministically from the device, and
locally.** This unit was factory reset, which cleared the UDSK to twenty zero bytes. It was then
claimed by a different phone, on a fresh install signed in as a guest with no account. The value came
back byte for byte identical to the one the previous owner's app had left. Two unrelated clients,
neither able to look the other's value up, produced the same twenty bytes.

That is the part with consequences for an implementation, because it contradicts the model the public
library uses. python-ember-mug's `make_writable()` writes `os.urandom(14).hex()`, a value it invents
and then keeps. A value the client invents cannot be right if the device expects a derived one, so
that helper cannot claim a mug no matter how its encoding is fixed.

The derivation itself has not been recovered, and two searches against the known pair from this unit
came back empty: 3,283 candidate transforms of the DSK, MAC, serial and mug id, and then every
20-byte window of the app snapshot tried as an XOR constant through SHA-1 and SHA-256 with the
usual truncations and reversals, about 45 million candidates. Neither produced the UDSK. So the
derivation is not a simple keyed hash of the DSK over any constant stored plainly in the app.
Settling it needs the `generateUdsk` disassembly or a runtime hook on the app, and neither was done
here.

python-ember-mug's forty byte write into a field that reads back twenty looked like a defect, then
looked like the protocol. It is neither. Forty bytes cannot reach this characteristic at all; see the
MTU section below.

## The mug validates nothing you write to it

This came out of testing three unrelated characteristics and it is the single most
transferable thing in these notes, so it goes before the detail.

Eleven writes were made across four characteristics. Every one was accepted at the ATT layer and
every one read back byte for byte. Nothing was refused, clamped, truncated or normalised, at any
point, on any characteristic.

`fc540006`, date and time, took a timestamp in both byte orders, including the one that decodes past
the signed 32-bit rollover in January 2038.

`fc540003`, target temperature, took 40.00 C and 70.00 C. Those sit below and above the 49 to 63
window the file documents, at both ends, and the mug stored them without comment.

`fc540001`, mug name, took a space, which orlopau says is not allowed. It took 14, 15, 16, 17 and 20
byte names, so neither orlopau's 14 nor python-ember-mug's 16 is a device limit. It took `Café` as
five bytes of UTF-8 and returned it identical.

So every constraint documented in this spec is a client-side convention. Not one of them is enforced
by the hardware. An integration written against this device gets no protection from it and no error
when it is wrong: the wrong byte order gives a silently wrong clock, an out-of-range setpoint is
simply accepted, and an over-long name is stored whole.

That is worth keeping in the entity definitions rather than removing. Bounds that protect a user are
good, and the Target Temperature entity should keep its 49 to 63. But those numbers describe what a client should do and not what the mug will tolerate, and anything downstream that
reads them as device facts will be wrong.

Every write above was restored to its original value and the restoration verified by reading it back.

## Discovery does not work as written, and that is the widest problem

Three separate errors, and together they mean the documented method finds this mug in no state at
all.

The company ID is `0xFFFF`, which the SIG reserves for internal use, where the file asserts `0x03C1`
(961) in four separate places. Both states read `0xFFFF`, idle and pairing mode alike. A shipping
product is advertising under the test identifier.

Not one of the three service UUIDs in the file is advertised in ordinary operation. The only one on the
air is `0000180a`, Device Information, and that service is advertised and not implemented, so there
is nothing behind it. `fc543622` appears only while the base button is held, and only in the scan
response, so a passive scanner never sees it in either state and an active scanner sees it only while
somebody is physically holding the button.

Both Home Assistant discovery patterns therefore match nothing. They ask for local name `Ember C*` or
`Ember T*` **and** manufacturer 961. The name half matches, since this unit advertises the complete
local name `Ember Ceramic Mug`, and the 961 half never does. What works is scanning for the name
prefix and accepting whatever company ID arrives with it.

**A trap for whoever re-checks this.** Take the advertising measurements before the first connection.
Once a connection has happened BlueZ starts folding its cached GATT table into what it hands a
scanner, so a scan taken afterwards reports services that were never broadcast. Two of our own early
advertising notes went wrong that way. The checklist gives the count and the recovery.

## What the device does that the spec does not mention

These are additions rather than corrections and several of them will bite an integration.

**A full mug can read empty, indefinitely, and refuse to heat.** Filled with cold water and sat on the
powered coaster, this unit reported liquid level 0 and liquid state `empty` for twenty minutes across
two connections and never started heating. It was not wedged: the drink temperature tracked the cold
water going in the whole time and nothing surfaced an error anywhere. One short press of the base
button ended it and the mug went to `heating` immediately and ran to target normally. So liquid state
`empty` cannot be taken to mean the mug is empty, and nothing found so far distinguishes the two
cases.

There are also two different dormant conditions and only one of them wakes on handling. During those
twenty minutes the mug was lifted, poured into, set down, replaced on the coaster and topped up, and
none of it helped. Later the same day, after it had dropped from `target_temperature` to `standby` on
its own, simply moving it to a desk was enough to restart heating with no button press.

**Emptying it, by contrast, is detected instantly.** Tipping the water out took the mug from `heating`
straight back to `standby` and level 0 within seconds. The sensor is not slow. The twenty minute
failure was about that first dormant state and not about liquid detection.

**Liquid level emits intermediate values, and you should not read them as a fill fraction.** We saw
0, 5, 6, 7, 8, 9, 10, 11, 12, 14 and 30, with 155 `liquid_level_changed` push events in one forty
minute capture, and it updates off the coaster as well as on it. So the note in the file that it may
only update on the charger and that only 0 and 30 are significant is wrong on both halves.

But across two captures where nobody touched the water, the raw byte wandered 5 to 12 and 7 to 12,
changing between consecutive reads on 9 and 27 percent of samples, and the two runs settled around
different values for the same water at different temperatures. Through the entity's scale that is a
sensor swinging between 17 and 40 percent with the mug sitting still. Solid as an empty-or-not
signal, unsound as a percentage. Which makes orlopau half right for a better reason than he gave: the
app treating this as binary looks like a sound engineering decision rather than a limitation.

**The mug leaves target and stops heating on its own.** With liquid in it and sitting on the powered
coaster it dropped out of `target_temperature` into `standby` at 60.56 C, after which the drink
cooled to 48.89 C and nothing reheated it. A finished heat cycle also ends in standby, so that state
on its own tells an integration nothing about whether the mug is empty, off the pad or switched off.

**Writing `0x0000` to the target switches the mug off for real, and it lands somewhere nothing had
reached before.** The write went in mid-cycle with the drink at 27.78 C against a 62.77 C setpoint,
so 35 degrees short of where a cycle ends by itself. Push event 8 arrived in the same second, the
state left `heating` for `3 cold_no_temp_control`, and the drink fell away from there, 27.78 through
22.23 C, then held at 22.23 for the rest of a five minute window with no reheat at any point. Your
Temperature Control switch is a real off switch and not merely a stored number.

The state it leaves behind is the part to build against. **`3 cold_no_temp_control` means there is
liquid in the mug and temperature control is off.** It is not `standby`, and the mug sits in it
rather than passing through it, so a client that reads state 3 as a fault or as an empty mug is
wrong on both counts.

**The charging byte says charging while the battery falls.** Byte 1 of `fc540007` held `0x01` across
forty minutes while the percentage ran 13, 12, 11, 10, 6, with the mug on the powered coaster
throughout. An active heat cycle draws more than the coaster supplies. The fall stops once the mug
reaches target, and the cell then recovers normally, reading 91 percent a few hours later in standby
on that same coaster. Your Charging Base entity is right that the charger is connected and silent on
whether the cell is gaining, which is what a reader will assume it means. Off the coaster there is no
convergence at all: starting at 45 C on a full battery it gained 0.22 C per minute and spent about 2
percent of battery per minute, so it ran flat short of the 62.77 C target.

**The LED characteristic holds the configured colour, not what you are looking at.** `fc540014` sat
at `ff0400ff`, red, for a whole day. The mug itself pulsed slowly white through every minute of
heating and went back to red only in standby. So the heating animation is applied on the hardware,
overriding the stored colour, and none of it reaches the wire. A light entity bound to that
characteristic reports red while the mug in front of you pulses white, and the displayed colour
cannot be read at all. Neither public source mentions the override.

**Byte 3 is brightness, not alpha.** At 100 percent in the app `fc540014` reads `d701ffff`; at 50
percent, `d701ff7f`. Byte 3 goes 255 to 127, the RGB triplet does not move. orlopau labels it Alpha
and is wrong; python-ember-mug calls it brightness and is right.

**Characteristics lag their own push events by a second or two.** A read taken immediately on a
charger-connected event returns the pre-event value. The instruction to re-read the affected
characteristic on the event is right, but doing it synchronously leaves the entity one state behind
permanently. A short delay in front of the read fixes it.

**Battery temperature and drink temperature are different sensors**, which nothing public states
outright. Bytes 2 and 3 of `fc540007` gave 25.00 C at the same instant `fc540002` gave 23.89 C.
Watched over a charge on an empty mug that was never heated, it rose through 26, 27 and 28 C and came
back down once the battery was full, so what it tracks is charge current. Its resolution is coarser
too: across two days, 93 reads all landed on an exact multiple of 100, against 2389 and 2445 from the
drink sensor, so the field is in hundredths of a degree but the sensor only moves in whole ones. Bind
a drink temperature to `fc540007` and the number you show will move for reasons that have nothing to
do with the drink.

**`fc540013`, the statistics characteristic, has no published payload anywhere and now has a capture.**
On the first connection of a day it produces four notifications inside a second and then nothing.
Every subscribe for at least the next few minutes returns a bare `05`. It is not consumed, though:
the next day's first connection produced the same four notifications byte for byte, twenty hours and
a charge cycle later. Reading byte 0 as a record id, byte 1 as a subtype and byte 2 as a length gives
a body length matching byte 2 in all three multi-byte records, and nothing else tried fits all three.
What the fields mean is unknown.

**An undocumented Nordic legacy DFU service** at `00001530-1212-efde-1523-785feabcd123`, with control
point, packet and version characteristics, present on a claimed mug in ordinary operation. Your file
notes that the app ships Nordic DFU code and documents the service nowhere. **It was deliberately not
probed and should stay that way.** A write to the DFU control point is how these get bricked, and
there would be no way to finish the update in any case, because legacy DFU wants a signed vendor
image nobody here has.

Shorter items. There is a second, writable device name at `00002a00` in Generic Access reading `Ember
Ceramic Mug`, while `fc540001` reads `EMBER`, and the Generic Access one is what discovery matches on.
Connection parameters at `00002a04` read `5000a00000009001`, asking for a 100 to 200 ms interval and a
4000 ms supervision timeout, which BlueZ ignores in favour of 420 ms. `fc54000b` acceleration is
documented and absent. `fc540012` push event is notify only rather than read and notify. `fc540009`
volume is absent, which the file correctly predicts, since it is Travel Mug only. And the mug id at
`fc54000d` decodes as the BLE address, an ASCII hyphen, then the serial, which accounts for the byte 6
the format block never explained.

## The factory reset

Hold the base button about 15 seconds. The LED goes blue, then yellow, then red. Release at red. It
then blinks red, blinks yellow, pulses white, goes solid white and powers off. One press brings it
back.

Your file says 12 seconds and "the LED blinks red". Both are wrong. Ember's support page gives 15
and the three colour sequence, and this unit matched it exactly. Red is the last of three, not the
signal to watch for.

It **clears** the claim, the target, the display unit, the date-time zone byte and the LED colour. It
**preserves** firmware, hardware revision, serial, BLE address and the DSK, all byte identical
afterwards.

Which measures the one thing your file describes but nobody could reach: **the unclaimed default
target is 57.22 C, exactly 135.0 F.** The display unit resets to Celsius and the LED to white.

## An unclaimed mug accepts no writes at all

Target temperature, LED colour and mug name each came back ATT `0x03`, write not permitted. All three
had been written successfully on this unit an hour earlier, while it was claimed.

That makes the claiming section circular as written. Claiming is a write to `fc54000f`, and writes
are refused until claimed. Something else unlocks a fresh mug and your file describes none of it.

## The mug caps its ATT MTU at 23

BlueZ asked for 517 and the mug answered 23, leaving a 20 byte payload, and it does not answer
prepare-write. So no client can write more than 20 bytes to any characteristic on this device.

That kills python-ember-mug's 40 byte UDSK write outright, and it means the vendor app is not
writing 40 bytes either.

## The mug refusing connections, which cost a morning

The recovery is not obvious and the symptom looks like a client bug.

The symptom held steady across forty four attempts over about two hours. Advertising continued
throughout and the scanner found the mug every time. The link layer connection came up with
`Status: Success` on each one, the mug then serviced nothing, and the session died with `0x3e`.

Everything on our own side was eliminated before the cause was found, and check 2 of the checklist
carries that list so nobody works through it twice. The part worth keeping here is the power cut. It
cold booted the host, the adapter and the coaster in the middle of the run, without anyone choosing
to do it, and the mug behaved exactly as it had before. That is the cleanest elimination of our own
bench available and it is not a test anyone would have scheduled.

What recovered it was a button hold with the mug off the coaster, ended the moment the LED changed.
Ours turned a blinking blue and the next attempt connected. **Go by the LED and not by a count**:
hold past the colour change and you are into the factory reset, which clears the claim, and the
timing differs between models.

## What stays genuinely unknown

Thirty three rows are untested and testable, and these are the ones with substance.

**The entire setup, claiming and reset path**, for the reason at the top. This is the largest single
block and it is a property of the unit that arrived rather than of the work.

**What seeds the buffer in `generateUdsk`.** The shape of the claim flow is recovered and written up
above. This one value inside it is not, and it is recorded as unknown rather than reconstructed,
because guessing at a static trace is how a plausible wrong answer gets into a spec and stays there.
Settling it means calling the function on a live target with the app under instrumentation, which was
not set up here. Treat it as closed rather than pending: nothing further is coming on it from this
engagement, and the honest version of the answer is the one above, which is that the buffer resolves
through the object pool and its contents were not established.

**Liquid states 2, 4 and 7.** `2 filling` never appeared through four separate pours, so if a Mug 2
emits it at all it is not on the path from empty to full. `3 cold_no_temp_control` is no longer on
this list; see the off switch above.

**How long `fc540013` takes to re-arm**, bounded only between two minutes and twenty hours, and what
its fields mean.

**Anything behind the DFU service**, deliberately.

**Every other body style.** Travel Mug, Travel Mug 2+, Cup and Tumbler were never in the room, and the
characteristic table differs across them, so those rows cannot be confirmed here by any amount of
work. They can be re-sourced and marked honestly, which is a different thing and worth doing.
