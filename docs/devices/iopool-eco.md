# iopool EcO / EcO Salt Pool Water Monitor

> **Status**: Spec Available. Everything was recovered from the vendor app and nothing has been run against a probe yet. The pH and temperature scalings are inferences.
> **Protocol**: BLE (readings are broadcast in advertisements; a small GATT service switches modes, sets the clock and beeps)
> **Manufacturer**: iopool SA (Belgium)
> **Manufacturer Status**: Active. The vendor cloud holds history, advice and calibration, but a local client needs none of it to read the probe.

## Overview

The EcO is a sealed probe that floats in a pool or spa and measures pH, ORP
(the app calls it "disinfection potential"), water temperature and
conductivity. It also reports its battery level. It is sold in iopool's EcO
Start pack, and there is a salt-water version, the EcO Salt. The only radio
is Bluetooth LE. An optional iopool Connect box relays readings to Wi-Fi when
no phone is near the pool.

Reading the probe needs no connection. It **broadcasts its latest measurement
in its advertisements** (manufacturer data under company ID `0x074C`), so
any BLE listener in range can decode pH, ORP, temperature, conductivity and
battery with no account, no pairing and no cloud. Connecting is only needed
to switch the probe between monitoring and winter standby, to set its clock,
to start a burst of live measurements, or to make it beep so you can find it.

The spec is `device-specs/devices/iopool-eco.yaml`. Where the two disagree,
the spec wins.

!!! warning "Uncalibrated values"
    The probe broadcasts raw values. iopool keeps each probe's pH and ORP
    calibration in its cloud, so a local client gets uncalibrated readings.
    The pH scale (1/100) and the temperature scale (0.01 °C) in this spec are
    inferences that nobody has checked against a probe. Compare with a test
    strip and a thermometer before you dose chemicals.

**Out of scope**: the iopool Connect gateway (the app's IGW and I10–I40
generations), the Ecotab chlorine-tablet dispenser, the iopool cloud API,
and pHin monitors. The iopool app also reads pHin advertisements, but that
format belongs to the separate pHin candidate
(`research-notes/phin-pool-monitor.md`).

## Hardware

| Property | Value |
|----------|-------|
| Models | EcO (FCC model "EcO v01"), EcO Salt. The app runs one parser and one command set for both, and no on-air difference between them is known. |
| Chipset | Texas Instruments CC2640R2F (legible in the FCC internal photos), plus an 8-pin part whose marking is not legible (possibly serial flash), a buzzer, and a two-lead switch |
| Radio | Bluetooth 4.0 LE only, 2402–2480 MHz, integral antenna |
| Battery | 3.7 V internal cell (FCC test report). The welcome guide gives two years' life with no recharging. The vendor's current product page describes a newer generation with a replaceable battery and sensors. |
| Advertised name | Exactly 8 characters: the probe's code, which the cloud registers against a pool. The exact format has not been seen on air. |
| Manufacturer data | Company ID `0x074C` (on air `ff 4c 07 …`). This ID is not in the Bluetooth SIG registry. |
| FCC ID | [2AVNQECO-V1](https://fccid.co/fcc/2AVNQECO-V1) (iopool SA, Belgium, granted 2020-04-15) |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | Yes: a new or wintered probe has to be switched to monitoring mode. Nothing is provisioned. |
| Method | `ble_direct` (primary, no account); `cloud_account` (the vendor app) |
| Setup AP / advertised name | 8-character name with manufacturer data `0x074C`, record mode byte = 3 |
| Passphrase protection | not_applicable |
| Confidence | medium (read from the vendor app, not replayed) |

A new probe, or one in winter standby, advertises **maintenance-mode records
(mode byte 3)**. The vendor app activates one like this:

1. The owner turns the probe upside down and back upright. The app asks for
   this gesture, and the switch in the FCC photos may be a tilt switch.
2. The app waits up to 5 s for a mode-3 advertisement and keeps its name.
3. It connects with no pairing and a 12 s timeout, then discovers services.
4. It writes the current Unix time to the clock characteristic `f3a00008`,
   which it does first on every connection.
5. It reads the software version from `f3a00011` as ASCII text.
6. It writes `0x04` (monitoring mode) to `f3a00002`, then disconnects.

None of these steps uses an account or a token. The vendor app then links the
probe's code and version to a pool in its cloud, after the owner has scanned
the EcO Start pack's QR code. Winter standby is the reverse: connect, set the
clock, write `0x05`, disconnect.

**Factory reset**: none is documented, and the probe holds no bond or
credential to clear. The app's pool settings have a "reset EcO" action that
sends `0x01` to `f3a00002`. What that clears is not established, so the spec
marks it `advanced`.

**Rebinding**: nothing binds the probe to a phone. Anyone in range can read
it and switch its mode. Moving it to another pool or account is a cloud
operation.

## Pairing

| Property | Value |
|----------|-------|
| Pairing required | No |
| Security mode | `none` |
| Bonding | `none` |
| PIN source | n/a |
| One central at a time | Unknown |
| One bond at a time | No (nothing bonds) |
| Confidence | medium (the vendor app's own flow, not replayed) |

**Entering pairing mode**: not applicable. Turning the probe over wakes it
into maintenance mode. That is a setup step, not a pairing window.

**Unpairing**: there is nothing to unpair.

**Recovery**: if a connection fails, close the vendor app and unplug any
iopool Connect gateway near the pool, since the gateway is itself a BLE
client of the probe. Then retry.

## Protocol Summary

All vendor UUIDs share the base `-f0a2-9b06-0c59-1bc4763b5c00`. Blueriiot's
Blue Connect analyser uses the same base (its `f330…` services), so never
identify a device on the base alone.

### BLE Services

| UUID | Name | Description |
|------|------|-------------|
| `f3a00001-f0a2-9b06-0c59-1bc4763b5c00` | EcO probe service | The only vendor service the app uses |
| `f3a00002-f0a2-9b06-0c59-1bc4763b5c00` | Command | One-byte opcodes, written with response |
| `f3a00008-f0a2-9b06-0c59-1bc4763b5c00` | Clock | Unix time in seconds, 8 bytes little-endian. Written on every connection |
| `f3a00009-f0a2-9b06-0c59-1bc4763b5c00` | Beep | `c8 00` (uint16 LE 200) sounds the buzzer once |
| `f3a0000a-f0a2-9b06-0c59-1bc4763b5c00` | Live-mode counter | `[count, 0x00]` starts a run of live measurements. Write only: nothing in the app reads or subscribes to it |
| `f3a00011-f0a2-9b06-0c59-1bc4763b5c00` | Software version | Read, decoded as ASCII |

**Not the EcO's.** Earlier notes attributed three more services to the probe.
In the app, each belongs to a different product:

| UUID | Belongs to |
|------|------------|
| `f4000001-…` (write `f4000002`, read `f4000003`) | iopool Connect BLE-to-Wi-Fi gateway |
| `f4100001-…` (write `f4100010`, read `f4100011`) | Ecotab chlorine-tablet dispenser, including its firmware update |
| `0000fe63-0000-1000-8000-00805f9b34fb`, `3206152c-76fd-4996-952b-2a1be2cb9450` | Adopted pHin monitors |

The app has **no firmware-update path for the EcO**. Its firmware-URL
configuration belongs to the gateway and the Ecotab, and no TI OAD service
UUID appears anywhere in it.

### Advertisement record

The app keeps an advertisement when its local name is exactly 8 characters
long and it carries manufacturer data under `0x074C`. Offsets below count
from the first byte after the company ID. **Multi-byte fields are
big-endian.**

| Offset | Length | Field | Decode |
|--------|--------|-------|--------|
| 0 | 1 | Format version | uint8. The values in use are not known |
| 1 | 1 | Mode | 1 standard, 2 live, 3 maintenance, 4 backup (meaning unknown) |
| 2 | 1 | Sequence | uint8 measurement counter. Counts from 1 in a live run |
| 3 | 2 | pH | int16 BE. × 0.01 is a *hypothesis* |
| 5 | 2 | ORP | int16 BE. mV is a *hypothesis* |
| 7 | 2 | Temperature | uint16 BE. × 0.01 °C is a *hypothesis*; 0.1 °C is the alternative |
| 9 | 2 | Conductivity | uint16 BE. Unit unknown, and the app does not upload it |
| 11 | 1 | Activity / battery | bits 7–6 activity (meaning unknown); battery % = (byte & 0x3f) × 2 |
| 12 | 2 | Time of day | minutes after 00:00 UTC = byte12 × 8 + (byte13 >> 5) |

**Dating a reading.** The record carries only the time of day, taken from the
probe's own clock. The app dates it today (UTC), or yesterday if that would
be more than 15 minutes in the future. If the result is more than 30 minutes
old or more than 5 minutes ahead, the app decides the clock has drifted:
it uses the current minute instead and reconnects to reset the clock. It
also resets the clock with the first reading it sees each day.

**Deduplicating.** A record repeats in every advertisement until the next
measurement. Treat it as new only when the name, sequence or time changes.
Skip mode-3 records, and treat mode-2 records as a live or calibration run,
as the app does.

**Test vectors.** These are built from the app's parser and are not
captures. The format-version byte and every value are invented.

| Record | Decodes to |
|--------|------------|
| `01 01 07 02 e4 02 b2 0a 1e 04 d2 b2 5a a0` | standard, seq 7, pH 7.40, ORP 690 mV, temp raw 2590 (25.90 °C if centi-degrees), conductivity 1234, activity 2, battery 100 %, 12:05 UTC |
| `01 02 01 02 d5 ff 38 07 d0 00 00 5e 7d 1f` | live, seq 1, pH 7.25, ORP −200 mV, temp raw 2000, activity 1, battery 60 %, 16:40 UTC |
| `01 03 00 03 0c 01 f4 09 c4 00 00 32 00 00` | maintenance: what the app waits for when adding a probe, not a measurement |

### Commands

All commands are written with response, after the clock write that opens
every connection.

| Command | Characteristic | Bytes | Notes |
|---------|----------------|-------|-------|
| Monitoring mode | `f3a00002` | `04` | Activates a new probe or wakes a wintered one |
| Maintenance mode | `f3a00002` | `05` | The app's winter standby |
| Reset | `f3a00002` | `01` | Effect unknown. **Advanced** |
| Set clock | `f3a00008` | Unix seconds, 8 bytes LE | 1790000000 → `80 3b b1 6a 00 00 00 00` |
| Beep | `f3a00009` | `c8 00` | The app's buzzer test beeps three times, 500 ms apart |
| Live mode | `f3a0000a` | `[count, 00]` | Default count 5. The calibration wizard uses 21 (`15 00`) |

**Calibration.** The app's calibration wizard has the owner hold the probe
in a reference solution, starts a 21-measurement live run, and accepts the
run once the collected values of the channel being calibrated spread by
less than 5 raw units. The raw samples go to the vendor cloud. Nothing about
calibration is written to the probe.

## Troubleshooting

These are defects and traps found in the vendor app.

- **Negative ORP shows as about 65 000 mV on Android.** The app's iOS build
  reads ORP as signed, but its Android build reads the same two bytes
  unsigned. Decode it as int16.
- **Readings carry the wrong time.** The probe dates readings from its own
  clock. A client that never connects never corrects it. Connect and write
  the clock at least once a day, as the app does.
- **A new probe cannot be found.** It has to be woken by turning it upside
  down and back, and until it is activated it only advertises mode-3
  records. A scanner that filters by service UUID or drops duplicates will
  miss it, because the app does neither.
- **The same reading appears again and again.** That is normal: the record
  repeats until the next measurement. Deduplicate on the sequence and time.
- **pH or ORP differs from the vendor app.** The app shows values the cloud
  has calibrated, and this spec's values are raw. Check with a test strip.
- **Battery reads above 100 %.** The field can hold up to 126. Clamp it.

## Tools Used

- Static analysis of the vendor Android app (com.iopool 2.43.6, React Native / Hermes), described by role only
- react-native-ble-manager source review (how manufacturer data is keyed)
- FCC exhibits for 2AVNQECO-V1 (test report, internal photos, welcome guide)

## References

- EcO welcome guide (FCC user-manual exhibit, model EcO v01): <https://fccid.co/api/files/s1/2avnqeco_v1_usersmanual_4689472_d7f4cefa85.pdf>
- FCC grant 2AVNQECO-V1: <https://fccid.co/fcc/2AVNQECO-V1>
- FCC internal photos: <https://fccid.co/api/files/s1/2avnqeco_v1_internalphotos_4689480_166016b092.pdf>
- FCC test report: <https://fccid.co/api/files/s1/2avnqeco_v1_testreport_4689476_47f9003ce3.pdf>
- iopool EcO Start product page: <https://iopool.com/products/eco-start>
- mguyard/hass-iopool (Home Assistant integration on the read-only cloud API, no BLE): <https://github.com/mguyard/hass-iopool>
- react-native-ble-manager, manufacturer-data keying: <https://github.com/innoveit/react-native-ble-manager/blob/master/android/src/main/java/it/innove/DefaultPeripheral.java> and <https://github.com/innoveit/react-native-ble-manager/blob/master/ios/Helper.swift>
- Bluetooth SIG company identifiers: <https://bitbucket.org/bluetooth-SIG/public/raw/main/assigned_numbers/company_identifiers/company_identifiers.yaml>
- [Pairing, Bonding and Unpairing](../protocols/pairing.md)
- [Initial Device Setup](../protocols/device-setup.md)

## Contributors

- Initial spec from static analysis of the vendor app and the FCC filing
